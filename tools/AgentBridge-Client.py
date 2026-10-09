"""Read PAYDAY 3 telemetry and run bounded AgentBridge commands."""
import argparse
import json
import os
from pathlib import Path
import sys
import time
import uuid

DEFAULT_BRIDGE = Path(r"C:\Program Files (x86)\Steam\steamapps\common\PAYDAY3\PAYDAY3\Binaries\Win64\ue4ss\Mods\AgentBridge\bridge")


def read_json(path, timeout=1.0):
    deadline = time.monotonic() + timeout
    while True:
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(value, dict):
                raise ValueError(f"Expected a JSON object in {path}")
            return value
        except (OSError, ValueError) as error:
            if time.monotonic() >= deadline:
                raise RuntimeError(f"Cannot read {path}: {error}") from error
            time.sleep(0.05)


def live_state(bridge, allow_frozen=False):
    state = read_json(bridge / "state.json")
    if state.get("schema_version") != 1:
        raise RuntimeError("Unsupported bridge schema; expected version 1.")
    timestamp = state.get("timestamp")
    if isinstance(timestamp, bool) or not isinstance(timestamp, (int, float)):
        raise RuntimeError("Bridge state has no valid timestamp.")
    age = time.time() - timestamp
    frozen = state.get("enabled") is False and state.get("telemetry_frozen") is True
    if age < -5 or (age > 5 and not (allow_frozen and frozen)):
        raise RuntimeError(f"Bridge state is stale or its clock differs ({age:.1f}s). Start the game with AgentBridge enabled.")
    if not isinstance(state.get("session_id"), str) or not state["session_id"]:
        raise RuntimeError("Bridge state has no session ID.")
    seq = state.get("command_seq")
    if isinstance(seq, bool) or not isinstance(seq, int) or seq < 0:
        raise RuntimeError("Bridge state has no valid command sequence.")
    return state


def send_command(bridge, command, timeout=15.0):
    # Disabled telemetry deliberately stops changing. A matching fresh ACK,
    # rather than an old frozen file, proves that this session is still alive.
    state = live_state(bridge, allow_frozen=True)
    request = {
        "schema_version": 1,
        "session_id": state["session_id"],
        "id": uuid.uuid4().hex,
        "seq": state["command_seq"] + 1,
        "command": command,
    }
    # One CLI writer at a time. The server rejects sequence collisions instead
    # of executing commands out of order. Replace a fully written request file.
    temporary = bridge / ("command-" + request["id"] + ".tmp")
    try:
        temporary.write_text(json.dumps(request, separators=(",", ":")), encoding="utf-8")
        os.replace(temporary, bridge / "command.json")
    finally:
        temporary.unlink(missing_ok=True)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            ack = read_json(bridge / "ack.json", timeout=0)
        except RuntimeError:
            time.sleep(0.05)
            continue
        if all(ack.get(field) == request[field] for field in ("id", "session_id", "seq", "command")):
            if ack.get("status") != "ok":
                raise RuntimeError(f"Bridge rejected {command}: {ack}")
            return ack
        time.sleep(0.05)
    raise RuntimeError(f"No acknowledgement within {timeout:g}s for {request['id']}. Inspect events.jsonl and UE4SS.log; do not assume the command ran.")


def status(bridge):
    state = live_state(bridge, allow_frozen=True)
    result = dict(state)
    result["client_observation"] = {
        "state_age_seconds": round(time.time() - state["timestamp"], 1),
        "connection_verified": False,
        "note": "A file alone does not prove liveness; use ping for a fresh acknowledgement.",
    }
    return result


def observe(bridge, seconds, output=None):
    deadline = time.monotonic() + seconds
    last_key = None
    samples = []
    stream = output.open("w", encoding="utf-8") if output else None
    try:
        while time.monotonic() < deadline:
            state = live_state(bridge)
            key = (state["session_id"], state.get("seq"))
            if key != last_key:
                samples.append(state)
                line = json.dumps(state, separators=(",", ":"), ensure_ascii=False)
                if stream:
                    stream.write(line + "\n")
                    stream.flush()
                else:
                    print(line, flush=True)
                last_key = key
            time.sleep(0.25)
    finally:
        if stream:
            stream.close()
    sessions = {sample["session_id"] for sample in samples}
    moving_positions = {
        (sample["player"]["position"]["x"], sample["player"]["position"]["y"], sample["player"]["position"]["z"])
        for sample in samples
        if isinstance(sample.get("player"), dict) and isinstance(sample["player"].get("position"), dict)
    }
    return {
        "samples": len(samples),
        "sessions": len(sessions),
        "statuses": sorted({sample.get("status", "unknown") for sample in samples}),
        "distinct_positions": len(moving_positions),
        "evidence": str(output) if output else None,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bridge-path", type=Path, default=DEFAULT_BRIDGE)
    commands = parser.add_subparsers(dest="action", required=True)
    commands.add_parser("status", help="Read telemetry; disabled state may be intentionally frozen")
    for name in ("ping", "snapshot", "stats", "enable", "disable", "mask-up", "unmask", "fire-once"):
        command = commands.add_parser(name)
        command.add_argument("--timeout", type=float, default=15)
    watch = commands.add_parser("observe", help="Capture changing live state; no game inputs")
    watch.add_argument("--seconds", type=float, default=10)
    watch.add_argument("--out", type=Path)
    args = parser.parse_args()
    try:
        if args.action == "status":
            result = status(args.bridge_path)
        elif args.action != "observe":
            if not 0 < args.timeout <= 60:
                raise RuntimeError("Timeout must be between 0 and 60 seconds.")
            action = "SNAPSHOT" if args.action == "stats" else args.action.upper().replace("-", "_")
            result = send_command(args.bridge_path, action, args.timeout)
            if args.action == "stats":
                state = live_state(args.bridge_path, allow_frozen=True)
                if state["session_id"] != result["session_id"] or state.get("seq", -1) < result["result"]["state_seq"]:
                    raise RuntimeError("Snapshot acknowledgement has no matching published state.")
                result = {"ack": result, "state": state}
        else:
            if not 0 < args.seconds <= 60:
                raise RuntimeError("Observation must be between 0 and 60 seconds; run again for another capture.")
            result = observe(args.bridge_path, args.seconds, args.out)
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return 0
    except (RuntimeError, OSError) as error:
        print(f"AgentBridge: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
