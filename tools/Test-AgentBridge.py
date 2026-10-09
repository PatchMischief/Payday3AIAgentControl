"""Exercise the actual AgentBridge Lua script with real temporary protocol files.

These checks establish offline protocol and lifecycle behavior only. Changed
commands still need live PAYDAY 3 validation; mocks do not establish game success.
"""
from pathlib import Path
import json
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "AgentBridge" / "Scripts" / "main.lua"
SPEC = ROOT / "tests" / "agentbridge_spec.lua"
sys.path.insert(0, str(ROOT / ".tools" / "python"))
try:
    from lupa.lua54 import LuaRuntime
except ImportError as error:
    raise SystemExit(
        "Install test dependencies with: python -m pip install "
        "--target .tools/python -r requirements-dev.txt"
    ) from error


def reject_nonfinite(value):
    raise ValueError(f"Invalid JSON numeric constant: {value}")


class BridgeHarness:
    def __init__(self, mod_path, auto_enable=True):
        self.mod_path = Path(mod_path)
        self.protocol = self.mod_path / "bridge"
        self.protocol.mkdir(parents=True, exist_ok=True)
        script_path = self.mod_path / "Scripts" / "main.lua"
        script_path.parent.mkdir(parents=True, exist_ok=True)
        for source in SCRIPT.parent.glob("*.lua"):
            (script_path.parent / source.name).write_text(
                source.read_text(encoding="utf-8"), encoding="utf-8"
            )
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().package.path = (
            script_path.parent.as_posix() + "/?.lua;" + self.lua.globals().package.path
        )
        self.fixture = self.lua.execute(SPEC.read_text(encoding="utf-8"))
        self.lua.eval("dofile")(script_path.as_posix())
        if auto_enable:
            self.send("harness-enable", 1, command="ENABLE")

    def sample(self):
        # Multiple async ticks also exercise queue coalescing. The fixture
        # models control/sampler callbacks independently of actual wall time.
        self.fixture.tick(4)
        self.fixture.drain()
        return self.read("state.json")

    def read(self, filename):
        return json.loads(
            (self.protocol / filename).read_text(encoding="utf-8"),
            parse_constant=reject_nonfinite,
        )

    def send(self, command_id, seq, command="PING", session_id=None, **extra):
        state = self.read("state.json")
        value = dict(schema_version=1, session_id=session_id or state["session_id"],
                     id=command_id, seq=seq, command=command)
        value.update(extra)
        self.write_command(json.dumps(value, separators=(",", ":")))
        self.sample()

    def write_command(self, text):
        (self.protocol / "command.json").write_text(text, encoding="utf-8")

    def events(self):
        return [json.loads(line, parse_constant=reject_nonfinite)
                for line in (self.protocol / "events.jsonl").read_text(encoding="utf-8").splitlines()]

    def close(self):
        self.fixture.close()


class AgentBridgeTests(unittest.TestCase):
    def setUp(self):
        # Windows' sandbox temp redirect can allow the initial directory but
        # deny descendants. Keep isolated fixtures in this writable project.
        temp_parent = (ROOT / ".tools").resolve()
        self.temp = tempfile.TemporaryDirectory(prefix="agentbridge-test-", dir=temp_parent)
        self.assertTrue(Path(self.temp.name).resolve().is_relative_to(temp_parent))
        self.addCleanup(self.temp.cleanup)
        self.bridge = BridgeHarness(Path(self.temp.name) / "AgentBridge")
        self.addCleanup(self.bridge.close)
        self.seq_base = self.bridge.read("state.json")["command_seq"]

    def assert_safe(self):
        self.assertEqual(self.bridge.fixture.cross_thread_calls, 0)
        self.assertEqual(self.bridge.fixture.invalid_member_calls, 0)

    def use_idle_bridge(self):
        self.bridge.close()
        self.bridge = BridgeHarness(Path(self.temp.name) / "IdleAgentBridge", auto_enable=False)
        self.addCleanup(self.bridge.close)
        self.seq_base = 0

    def assert_state(self, state, status):
        self.assertEqual(state["schema_version"], 1)
        self.assertEqual(state["status"], status)
        self.assertIsInstance(state["session_id"], str)
        self.assertTrue(state["session_id"])
        self.assertIsInstance(state["seq"], int)
        self.assertGreater(state["seq"], 0)
        self.assertIsInstance(state["timestamp"], (int, float))
        self.assertGreater(state["timestamp"], 0)
        self.assertIsInstance(state["command_seq"], int)
        self.assert_safe()

    def test_menu_heist_menu_transitions_produce_fresh_state(self):
        menu = self.bridge.sample()
        self.assert_state(menu, "menu")
        self.assertIsNone(menu["player"]["pawn_name"])
        self.assertIsNone(menu["player"]["position"])
        self.bridge.fixture.world = "heist"
        heist = self.bridge.sample()
        self.assert_state(heist, "in_heist")
        self.assertIsInstance(heist["player"]["pawn_name"], str)
        self.assertEqual(heist["player"]["position"], {"x": 125, "y": -250, "z": 350})
        self.bridge.fixture.world = "menu"
        returned = self.bridge.sample()
        self.assert_state(returned, "menu")
        self.assertIsNone(returned["player"]["pawn_name"])
        self.assertIsNone(returned["player"]["position"])
        self.assertEqual(menu["session_id"], returned["session_id"])
        self.assertLess(menu["seq"], heist["seq"])
        self.assertLess(heist["seq"], returned["seq"])
        self.assertLessEqual(menu["timestamp"], returned["timestamp"])

    def test_missing_invalid_and_native_null_pawns_are_safe(self):
        self.bridge.fixture.world = "heist"
        for kind in ("missing", "invalid", "null"):
            with self.subTest(pawn=kind):
                self.bridge.fixture.pawn_kind = kind
                state = self.bridge.sample()
                self.assert_state(state, "no_pawn")
                self.assertIsNone(state["player"]["position"])
        self.bridge.fixture.pawn_kind = "valid"
        self.assert_state(self.bridge.sample(), "in_heist")

    def test_async_loop_queues_at_most_one_native_sample(self):
        self.bridge.fixture.drain()
        calls_before = self.bridge.fixture.native_calls
        self.bridge.fixture.tick(100)
        self.assertEqual(self.bridge.fixture.native_calls, calls_before)
        self.assertEqual(len(self.bridge.fixture.queue), 1)
        self.bridge.fixture.drain()
        self.bridge.fixture.tick(100)
        self.assertEqual(len(self.bridge.fixture.queue), 1)
        self.bridge.fixture.drain()
        self.assert_safe()

    def test_supported_commands_acknowledge_exact_id_session_and_sequence(self):
        self.bridge.sample()
        enabled_ack = self.bridge.read("ack.json")
        self.assertEqual(enabled_ack["command"], "ENABLE")
        self.assertEqual(enabled_ack["status"], "ok")
        self.assertNotIn("error", enabled_ack)
        for seq, command in enumerate(("PING", "SNAPSHOT"), start=self.seq_base + 1):
            self.bridge.send(f"cmd_{seq}", seq, command)
            ack = self.bridge.read("ack.json")
            state = self.bridge.read("state.json")
            self.assertEqual(ack["id"], f"cmd_{seq}")
            self.assertEqual(ack["session_id"], state["session_id"])
            self.assertEqual(ack["seq"], seq)
            self.assertEqual(ack["command"], command)
            self.assertEqual(ack["status"], "ok")
            self.assertNotIn("error", ack)
            self.assertEqual(state["command_seq"], seq)
        self.assert_safe()

    def test_duplicate_id_and_nonincreasing_sequence_cannot_execute(self):
        self.bridge.sample()
        self.bridge.send("first", self.seq_base + 5)
        for command_id, seq in (("first", self.seq_base + 6),
                                ("second", self.seq_base + 5),
                                ("third", self.seq_base + 4)):
            with self.subTest(id=command_id, seq=seq):
                self.bridge.send(command_id, seq)
                self.assertEqual(self.bridge.read("state.json")["command_seq"], self.seq_base + 5)
                ack = self.bridge.read("ack.json")
                self.assertFalse(ack.get("status") == "ok" and ack.get("id") == command_id
                                 and ack.get("seq") == seq)
        self.bridge.send("recovered", self.seq_base + 7)
        self.assertEqual(self.bridge.read("state.json")["command_seq"], self.seq_base + 7)

    def test_commands_from_previous_session_never_execute_after_reload(self):
        old = self.bridge.sample()
        self.bridge.send("old-command", self.seq_base + 1)
        self.bridge.close()
        # The same files survive a restart, as in the installed mod folder.
        self.bridge = BridgeHarness(self.bridge.mod_path, auto_enable=False)
        self.addCleanup(self.bridge.close)
        new = self.bridge.sample()
        self.assertNotEqual(old["session_id"], new["session_id"])
        self.assertEqual(new["command_seq"], 0)
        self.bridge.send("stale-command", 2, session_id=old["session_id"])
        self.assertEqual(self.bridge.read("state.json")["command_seq"], 0)
        self.bridge.send("current-command", 1)
        ack = self.bridge.read("ack.json")
        self.assertEqual(ack["id"], "current-command")
        self.assertEqual(ack["session_id"], new["session_id"])
        self.assertEqual(ack["status"], "ok")

    def test_malformed_oversized_and_unknown_input_is_bounded_and_recovers(self):
        state = self.bridge.sample()
        prefix = json.dumps(dict(schema_version=1, session_id=state["session_id"],
                                 id="malformed", seq=self.seq_base + 1, command="PING"))
        seq_token = f'"seq": {self.seq_base + 1}'
        malformed = (
            "{", "[]", "null", prefix[:-1] + ',"id":"duplicate"}',
            prefix[:-1] + ',"unexpected":true}', prefix + " trailing",
            prefix.replace(seq_token, '"seq": 1.5'),
            prefix.replace(seq_token, '"seq": -1'),
            prefix.replace('"malformed"', '"bad id"'),
            " " * 1025 + prefix,
            prefix + " " * 1_000_000,
        )
        for command in malformed:
            with self.subTest(input=command[:100]):
                self.bridge.write_command(command)
                self.assertEqual(self.bridge.sample()["command_seq"], self.seq_base)
                self.assert_safe()
        self.assertEqual(self.bridge.fixture.unbounded_command_reads, 0)
        self.assertLessEqual(self.bridge.fixture.largest_command_read, 1025)
        self.bridge.send("after_bad_input", self.seq_base + 1)
        self.assertEqual(self.bridge.read("ack.json")["status"], "ok")

    def test_unsupported_command_is_rejected_and_next_command_can_recover(self):
        self.bridge.sample()
        self.bridge.send("unsupported", self.seq_base + 1, command="TELEPORT")
        ack = self.bridge.read("ack.json")
        self.assertEqual(ack["id"], "unsupported")
        self.assertEqual(ack["command"], "TELEPORT")
        self.assertEqual(ack["status"], "error")
        self.bridge.send("after_unsupported", self.seq_base + 2)
        self.assertEqual(self.bridge.read("ack.json")["status"], "ok")
        self.assert_safe()

    def test_native_sampling_error_does_not_wedge_the_pending_queue(self):
        self.bridge.fixture.world = "heist"
        self.bridge.fixture.pawn_kind = "error"
        self.bridge.sample()
        self.bridge.fixture.pawn_kind = "valid"
        self.assert_state(self.bridge.sample(), "in_heist")
        self.assertEqual(len(self.bridge.fixture.queue), 0)

    def test_transient_scheduler_failure_allows_later_sample(self):
        self.bridge.fixture.drain()
        self.bridge.fixture.enqueue_failure = True
        self.bridge.fixture.tick(1)
        self.bridge.fixture.enqueue_failure = False
        self.assert_state(self.bridge.sample(), "menu")

    def test_transient_write_failure_allows_later_valid_telemetry(self):
        state = self.bridge.sample()
        state_path = self.bridge.protocol / "state.json"
        state_path.unlink()
        state_path.mkdir()
        self.bridge.fixture.tick(1)
        self.bridge.fixture.drain()
        state_path.rmdir()
        recovered = self.bridge.sample()
        self.assert_state(recovered, "menu")
        self.assertGreater(recovered["seq"], state["seq"])

    def test_native_strings_and_nonfinite_coordinates_cannot_corrupt_json(self):
        self.bridge.fixture.world = "heist"
        self.bridge.fixture.pawn_name = 'Player "quoted"\\name\n\t\x01'
        valid = self.bridge.sample()
        self.assertEqual(valid["player"]["pawn_name"], self.bridge.fixture.pawn_name)
        self.bridge.fixture.position.X = float("nan")
        damaged = self.bridge.sample()
        self.assertIsNone(damaged["player"]["position"])
        self.bridge.fixture.position.X = 12
        self.assertEqual(self.bridge.sample()["player"]["position"]["x"], 12)
        self.assert_safe()

    def test_disabled_startup_and_idle_polls_do_no_native_work_or_file_writes(self):
        self.use_idle_bridge()
        initial = self.bridge.read("state.json")
        writes = self.bridge.fixture.write_opens
        self.assertFalse(initial["enabled"])
        self.assertEqual(initial["status"], "disabled")
        self.bridge.fixture.tick(200)
        self.bridge.fixture.drain()
        self.assertEqual(self.bridge.fixture.native_calls, 0)
        self.assertEqual(self.bridge.fixture.native_writes, 0)
        self.assertEqual(self.bridge.fixture.write_opens, writes)
        self.assertEqual(self.bridge.read("state.json"), initial)
        self.assertEqual(self.bridge.fixture.active_loop_count(1000), 1)
        self.assertEqual(self.bridge.fixture.active_loop_count(300), 0)
        self.assertEqual(len(self.bridge.fixture.queue), 0)

    def test_idle_ping_and_one_shot_snapshot_keep_sampling_disabled(self):
        self.use_idle_bridge()
        self.bridge.send("idle-ping", 1)
        self.assertEqual(self.bridge.read("ack.json")["status"], "ok")
        self.assertEqual(self.bridge.fixture.native_calls, 0)
        self.bridge.send("idle-snapshot", 2, command="SNAPSHOT")
        self.assertEqual(self.bridge.read("ack.json")["status"], "ok")
        sampled = self.bridge.read("state.json")
        self.assertFalse(sampled["enabled"])
        self.assertGreater(self.bridge.fixture.native_calls, 0)
        calls = self.bridge.fixture.native_calls
        writes = self.bridge.fixture.write_opens
        self.bridge.fixture.tick(100)
        self.bridge.fixture.drain()
        self.assertEqual(self.bridge.fixture.native_calls, calls)
        self.assertEqual(self.bridge.fixture.write_opens, writes)
        self.assertEqual(self.bridge.read("state.json"), sampled)
        self.assertEqual(self.bridge.fixture.active_loop_count(300), 0)
        self.assert_safe()

    def test_disable_stops_active_loop_and_enable_resumes_fresh_sampling(self):
        self.bridge.fixture.world = "heist"
        active = self.bridge.sample()
        self.bridge.send("disable", self.seq_base + 1, command="DISABLE")
        self.assertFalse(self.bridge.read("state.json")["enabled"])
        calls = self.bridge.fixture.native_calls
        self.bridge.fixture.tick(100)
        self.bridge.fixture.drain()
        self.assertEqual(self.bridge.fixture.native_calls, calls)
        self.assertEqual(self.bridge.fixture.active_loop_count(300), 0)
        self.bridge.fixture.position.X = 987
        self.bridge.send("enable-again", self.seq_base + 2, command="ENABLE")
        resumed = self.bridge.sample()
        self.assertTrue(resumed["enabled"])
        self.assertEqual(resumed["player"]["position"]["x"], 987)
        self.assertGreater(resumed["seq"], active["seq"])
        self.assertEqual(self.bridge.fixture.active_loop_count(300), 1)
        self.assert_safe()

    def test_disabled_actions_are_rejected_and_cannot_replay_after_enable(self):
        self.use_idle_bridge()
        self.bridge.fixture.world = "heist"
        for seq, command in enumerate(("MASK_UP", "UNMASK", "FIRE_ONCE"), start=1):
            self.bridge.send(f"disabled-{seq}", seq, command=command)
            ack = self.bridge.read("ack.json")
            self.assertEqual(ack["status"], "error")
            self.assertEqual(ack["command"], command)
            self.assertEqual(self.bridge.fixture.native_calls, 0)
        self.bridge.send("enable-after-rejection", 4, command="ENABLE")
        self.bridge.send("disabled-3", 5, command="FIRE_ONCE")
        ack = self.bridge.read("ack.json")
        self.assertEqual(ack["status"], "error")
        self.assertIn("Duplicate", ack["error"])
        self.assert_safe()

    def test_unknown_native_stats_stay_explicit_null_and_do_not_call_null_objects(self):
        self.bridge.fixture.world = "heist"
        stats = self.bridge.sample()["player"]["stats"]
        for field in ("health", "health_max", "armor", "armor_max", "health_packs", "grenade_count"):
            with self.subTest(field=field):
                self.assertIsNone(stats[field])
        for slot in ("primary", "secondary", "tertiary"):
            self.assertIsNone(stats["weapons"][slot]["magazine"])
            self.assertIsNone(stats["weapons"][slot]["reserve"])
        self.assertTrue(stats["unknowns"])
        self.assertEqual(self.bridge.fixture.native_writes, 0)
        self.assert_safe()

    def test_known_stats_report_each_weapon_ammo_and_classified_consumables(self):
        self.bridge.fixture.configure_character()
        stats = self.bridge.sample()["player"]["stats"]
        self.assertEqual((stats["health"], stats["health_max"], stats["armor"], stats["armor_max"]),
                         (85, 100, 75, 100))
        self.assertEqual((stats["health_packs"], stats["grenade_count"]), (1, 3))
        for slot, expected in (("primary", (30, 90)), ("secondary", (12, 36)), ("tertiary", (0, 0))):
            self.assertEqual((stats["weapons"][slot]["magazine"], stats["weapons"][slot]["reserve"]), expected)
        self.assert_safe()

    def test_fire_has_one_pulse_releases_input_and_acknowledges_only_after_exact_ammo_assertion(self):
        self.bridge.fixture.configure_character()
        self.bridge.send("fire-one", self.seq_base + 1, command="FIRE_ONCE")
        self.assertEqual(self.bridge.fixture.fire_presses, 1)
        self.assertEqual(self.bridge.fixture.fire_releases, 1)
        self.assertFalse(self.bridge.fixture.fire_pressed)
        self.assertNotEqual(self.bridge.read("ack.json")["id"], "fire-one")
        self.assertTrue(any(e["event"] == "action_accepted" and e.get("id") == "fire-one"
                            for e in self.bridge.events()))
        self.bridge.sample()
        ack = self.bridge.read("ack.json")
        self.assertEqual(ack["id"], "fire-one")
        self.assertEqual(ack["status"], "ok")
        self.assertTrue(ack["result"]["accepted"])
        self.assertTrue(ack["result"]["completed"])
        self.assertEqual(ack["result"]["ammo_consumed"], 1)
        self.bridge.send("fire-one", self.seq_base + 2, command="FIRE_ONCE")
        self.assertEqual(self.bridge.read("ack.json")["status"], "error")
        self.assertEqual(self.bridge.fixture.fire_presses, 1)
        self.assert_safe()

    def test_multiple_rounds_cannot_report_one_shot_success(self):
        self.bridge.fixture.configure_character()
        self.bridge.fixture.fire_delta = 2
        self.bridge.send("fire-too-many", self.seq_base + 1, command="FIRE_ONCE")
        self.bridge.sample()
        ack = self.bridge.read("ack.json")
        self.assertEqual(ack["status"], "error")
        self.assertTrue(ack["result"]["accepted"])
        self.assertFalse(ack["result"]["completed"])
        self.assertIn("multiple-round", ack["error"])
        self.assertEqual(self.bridge.fixture.fire_presses, 1)
        self.assertFalse(self.bridge.fixture.fire_pressed)
        self.assert_safe()

    def test_press_error_still_releases_and_failed_release_gets_disable_cleanup(self):
        self.bridge.fixture.configure_character()
        self.bridge.fixture.press_error = True
        self.bridge.fixture.release_failures = 2
        self.bridge.send("fire-failure", self.seq_base + 1, command="FIRE_ONCE")
        self.assertEqual(self.bridge.fixture.fire_presses, 1)
        self.assertEqual(self.bridge.fixture.fire_releases, 2)
        self.assertTrue(self.bridge.fixture.fire_pressed)
        self.bridge.send("stop-with-cleanup", self.seq_base + 2, command="DISABLE")
        self.assertEqual(self.bridge.fixture.fire_releases, 3)
        self.assertFalse(self.bridge.fixture.fire_pressed)
        action_acks = [e for e in self.bridge.events()
                       if e["event"] == "command_ack" and e.get("id") == "fire-failure"]
        self.assertEqual(len(action_acks), 1)
        self.assertEqual(action_acks[0]["status"], "error")
        self.assertFalse(action_acks[0]["result"]["completed"])
        self.assertFalse(self.bridge.read("state.json")["enabled"])
        self.assert_safe()

    def test_paused_and_burst_weapons_refuse_native_fire(self):
        self.bridge.fixture.configure_character()
        self.bridge.fixture.paused = True
        self.bridge.send("paused-fire", self.seq_base + 1, command="FIRE_ONCE")
        self.assertEqual(self.bridge.read("ack.json")["status"], "error")
        self.bridge.fixture.paused = False
        self.bridge.fixture.set(self.bridge.fixture.fire_data, "FireMode", 1)
        self.bridge.send("burst-fire", self.seq_base + 2, command="FIRE_ONCE")
        self.assertEqual(self.bridge.read("ack.json")["status"], "error")
        self.assertEqual(self.bridge.fixture.fire_presses, 0)
        self.assertEqual(self.bridge.fixture.fire_releases, 0)
        self.assert_safe()

    def test_mask_success_needs_matching_endpoint_token_and_observed_state(self):
        self.bridge.fixture.configure_character()
        self.bridge.fixture.masked, self.bridge.fixture.casing_tags = False, 1
        self.bridge.send("mask-request", self.seq_base + 1, command="MASK_UP")
        self.assertEqual(self.bridge.fixture.console_calls, 1)
        self.assertNotEqual(self.bridge.read("ack.json")["id"], "mask-request")
        self.bridge.fixture.masked, self.bridge.fixture.casing_tags = True, 0
        self.bridge.fixture.shared["AgentBridge.UnmaskAgain.Result"] = "wrong-token|completed|nonce-old"
        self.bridge.sample()
        self.assertNotEqual(self.bridge.read("ack.json")["id"], "mask-request")
        self.bridge.fixture.shared["AgentBridge.UnmaskAgain.Result"] = "mask-request|completed|nonce-new"
        self.bridge.sample()
        ack = self.bridge.read("ack.json")
        self.assertEqual(ack["status"], "ok")
        self.assertTrue(ack["result"]["completed"])
        self.assertEqual(ack["result"]["unmaskagain_confirmation"], "nonce-new")
        self.assertEqual(self.bridge.fixture.console_calls, 1)
        self.assert_safe()

    def test_pending_fire_does_not_release_or_repeat_input_on_replacement_pawn(self):
        self.bridge.fixture.configure_character()
        self.bridge.fixture.release_failures = 2
        self.bridge.send("fire-before-travel", self.seq_base + 1, command="FIRE_ONCE")
        self.bridge.fixture.replace_character()
        self.bridge.sample()
        ack = self.bridge.read("ack.json")
        self.assertEqual(ack["id"], "fire-before-travel")
        self.assertEqual(ack["status"], "error")
        self.assertFalse(ack["result"]["completed"])
        self.assertIn("Pawn/world changed", ack["error"])
        self.assertEqual(self.bridge.fixture.wrong_pawn_actions, 0)
        self.assertEqual(self.bridge.fixture.fire_presses, 1)
        self.assert_safe()

    def test_casing_tag_count_accepts_native_callable_userdata_fname(self):
        self.bridge.fixture.configure_character()
        self.bridge.fixture.masked, self.bridge.fixture.casing_tags = False, 1
        self.bridge.fixture.use_callable_fname()
        stats = self.bridge.sample()["player"]["stats"]
        self.assertEqual(stats["casing_tag_count"], 1)
        self.assertFalse(stats["masked"])
        self.assert_safe()

    def test_failed_fire_cleanup_survives_terminal_ack_and_disable_retries_release_only(self):
        self.bridge.fixture.configure_character()
        self.bridge.fixture.release_failures = 4
        self.bridge.send("fire-needs-cleanup", self.seq_base + 1, command="FIRE_ONCE")
        self.assertEqual(self.bridge.fixture.fire_releases, 2)
        self.bridge.sample()  # Failure ACK and the first cleanup attempt.
        failed = self.bridge.read("ack.json")
        self.assertEqual(failed["id"], "fire-needs-cleanup")
        self.assertEqual(failed["status"], "error")
        self.assertFalse(failed["result"]["completed"])
        self.assertEqual(self.bridge.fixture.fire_releases, 3)
        self.assertTrue(self.bridge.read("state.json")["cleanup_required"])
        self.bridge.send("blocked-new-fire", self.seq_base + 2, command="FIRE_ONCE")
        blocked = self.bridge.read("ack.json")
        self.assertEqual(blocked["status"], "error")
        self.assertIn("cleanup required", blocked["error"])
        self.assertEqual(self.bridge.fixture.fire_presses, 1)
        self.assertEqual(self.bridge.fixture.fire_releases, 3)
        self.bridge.send("disable-retry-failed", self.seq_base + 3, command="DISABLE")
        self.assertEqual(self.bridge.fixture.fire_releases, 4)
        self.assertEqual(self.bridge.read("ack.json")["status"], "error")
        self.assertFalse(self.bridge.read("ack.json")["result"]["completed"])
        self.assertTrue(self.bridge.read("state.json")["cleanup_required"])
        self.assertFalse(self.bridge.read("state.json")["enabled"])
        self.bridge.send("disable-retry-success", self.seq_base + 4, command="DISABLE")
        self.assertEqual(self.bridge.fixture.fire_releases, 5)
        self.assertEqual(self.bridge.fixture.fire_presses, 1)
        self.assertFalse(self.bridge.fixture.fire_pressed)
        self.assertEqual(self.bridge.read("ack.json")["status"], "ok")
        self.assertTrue(self.bridge.read("ack.json")["result"]["completed"])
        self.assertFalse(self.bridge.read("state.json")["cleanup_required"])
        self.bridge.fixture.tick(100)
        self.bridge.fixture.drain()
        self.assertEqual(self.bridge.fixture.fire_releases, 5)
        self.assertEqual(self.bridge.fixture.fire_presses, 1)
        self.assert_safe()


if __name__ == "__main__":
    unittest.main(verbosity=2)
