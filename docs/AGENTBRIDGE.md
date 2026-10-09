# AgentBridge for PAYDAY 3

AgentBridge is a separate UE4SS Lua development mod. Version 0.2.0 reads game
state and accepts fixed commands through local files. It starts disabled.
Use telemetry, acknowledgements, and the mod's logs for troubleshooting in this
project; do not inspect the screen or use Windows keyboard automation unless
the user separately requests that method.

`ENABLE` starts 300 ms game-thread sampling. `DISABLE` stops that sampler,
game-object reads, and periodic telemetry writes. A 1 Hz file reader remains
to accept control commands. This removes sampling overhead while idle; it
does not unload UE4SS or other mods. `PING` confirms liveness while disabled;
`SNAPSHOT` takes one explicit sample without enabling continuous sampling.

The adapter reads each weapon slot's magazine/reserve ammo, health/max health,
armor, consumables, and throwables. Unidentified health packs or grenades are
reported as `null` with a reason, rather than guessed from generic counts.
`MASK_UP` and `UNMASK` use an optional UnmaskAgain console endpoint that runs
its existing request/apply/ack path and preserves its Stealth/Search rule.
`FIRE_ONCE` sends one game ability press/release pulse and requires exactly
one loaded-ammo decrease before success. Target hits are not measured.

## 0.2.0 live acceptance

On 2026-10-06, the native command sequence MASK_UP, UNMASK, MASK_UP, FIRE_ONCE,
UNMASK passed in the user's solo/private heist. Dispatch gaps were 6, 10, 6,
and 6 seconds, meeting the requested five-second spacing. Both unmask states
remained correct eight seconds later, and host logs confirmed receipt of their
acknowledgements. S40 ammo changed from 12/132 to 11/132 through one pulse with
confirmed release; CAR-4 stayed 30/480. Health stayed 100/100, armor 260/260
(four chunks), shock grenades three, and carried consumables/health packs zero.
This observed sequence did not reproduce an unmask failure after shooting.

Disabled-idle counters stayed fixed at 198 samples/game-thread callbacks over
a 12-second measurement while command polls increased 194→207. State-file
modification time did not change between commands. ENABLE resumed fresh samples;
the bridge was then disabled. No bridge error event occurred in the recorded
session. These are instrumentation-work checks, not an FPS measurement.

Evidence is in `.research/agentbridge-validation/acceptance-v020.json`, labelled
ACK/state files, `v020-events.jsonl`, and `v020-UE4SS.log`. All four source/install
hashes matched for the normal gameplay run. Twenty-six offline tests cover the
core/adapter, and 60 existing UnmaskAgain regressions plus seven endpoint checks
passed. The final review additionally fixed retry state after repeated native
fire-release failures. That failure case is covered offline; its final deployed
control check is recorded separately from the earlier normal gameplay run.
The final installation loaded, answered PING, ENABLE, SNAPSHOT, DISABLE, and
PING in a fresh session, sampled the menu, then held sample/game-thread counts
at 41 for 12 seconds while disabled. All source/install hashes matched again.
It was left disabled with no pending cleanup. See `v020-final-controls.json`
and `v020-final-source-install-hashes.json` for that final build's evidence.

The first live adapter run exposed callable-userdata FName construction and
incorrect successful-ACK error text; both were corrected before gameplay tests.
See `v020-initial-findings.md` for the recorded cause and regression evidence.

These raw traces and research files are retained in the original development
workspace and are not distributed in this repository. The results above are
the recorded validation summary; create new local evidence for your own tests.

## Earlier 0.1.0 validation

Validated on **2026-10-05/06** with PAYDAY 3 Steam build **25617818**, UE4SS
**3.0.1 Beta #0 / 0290beda**, and bridge **0.1.0**. Source and installed Lua
SHA256 both match
`4e137c4341f4ab54cba1e55a89a86cd91a9220d55f98e8711ba83c55a1ee8003`.

The first heist capture contains 100 valid increasing samples and 68 distinct
positions, with approximately 7.86 m of X movement and 24.36 m of Y movement.
Events record menu to heist and back to menu in that same runtime session,
with no bridge error events or sampling errors. A new session on October 6
also acknowledged PING/SNAPSHOT and produced 26 fresh samples while the user
was paused in the heist. Its unchanged coordinates are expected while paused.
A retained command from the first session was correctly rejected after restart.

The 12 offline tests passed before deployment. Live evidence is stored locally
under `.research/agentbridge-validation`, including the acceptance record,
`live-01.jsonl`, `live-02.jsonl`, and `live-03-paused-20261006.jsonl`. Raw runtime
events and the loader log are copied there for the completed acceptance record.
The private-test context comes from the user-directed test; telemetry does not
identify lobby privacy. These results validate the bridge's listed capabilities
in the recorded sessions, rather than every gameplay feature or a full mission.

## Installation and use

The existing PAYDAY 3 loader is used. Close the game, then install from this
project folder in PowerShell:

```powershell
.\tools\Install-AgentBridge.ps1 -WhatIf
.\tools\Install-AgentBridge.ps1
# Include the inspected UnmaskAgain 0.5.4 command endpoint when needed:
.\tools\Install-AgentBridge.ps1 -WithUnmaskAgainEndpoint -WhatIf
.\tools\Install-AgentBridge.ps1 -WithUnmaskAgainEndpoint
```

The default installation is
`C:\Program Files (x86)\Steam\steamapps\common\PAYDAY3`. Supply `-GamePath` for
a different installation. The installer deploys `ue4ss\Mods\AgentBridge`.
It preserves an old copy in `ue4ss\ModBackups`, outside the auto-loaded Mods
folder, and starts the new copy with an empty bridge directory.
The optional switch also backs up and updates only UnmaskAgain's main script
and endpoint module. It verifies that the installed source matches the
inspected 0.5.4 hash before replacing it. Run the real installation with
permissions that can see the game's process and write its files; the restricted
shell can hide processes that are visible outside its sandbox.

The installer writes `Scripts\agentbridge_paths.lua` with the absolute data
directory. A manually copied mod needs that path file and an existing `bridge`
directory; relative working-directory assumptions are avoided.

Start PAYDAY 3 through Steam. Telemetry is written under:

```text
PAYDAY3\Binaries\Win64\ue4ss\Mods\AgentBridge\bridge\
    state.json
    events.jsonl
    command.json
    ack.json
```

From this project, use a working Python 3.12 interpreter:

```powershell
python .\tools\AgentBridge-Client.py status
python .\tools\AgentBridge-Client.py ping
python .\tools\AgentBridge-Client.py enable
python .\tools\AgentBridge-Client.py stats
python .\tools\AgentBridge-Client.py snapshot
python .\tools\AgentBridge-Client.py mask-up
python .\tools\AgentBridge-Client.py unmask
python .\tools\AgentBridge-Client.py fire-once
python .\tools\AgentBridge-Client.py disable
python .\tools\AgentBridge-Client.py observe --seconds 30 --out telemetry.jsonl
```

Use a working Python interpreter. If `python` resolves to an inaccessible
Windows Store alias, invoke your installed interpreter by its full path with
PowerShell's `&`, followed by the script and arguments.

The client supports `--bridge-path <directory>` before the action for a custom
installation. Use one command writer at a time. It reads a fresh session ID and
command sequence from state, writes a complete request, and checks an
acknowledgement for the same session, ID, sequence, and command. A timeout is
inconclusive; inspect the events and UE4SS log before proceeding.
Disabled telemetry is intentionally frozen. `status` labels its file-only
observation as unverified; a new matching `ping` acknowledgement proves the
reader is alive. Mutation commands require an enabled bridge and a verified
unpaused local heist pawn. Initial installation or code changes require a
restart; runtime enable/disable does not.

Before running mask/fire tests, capture baseline stats in the user's intended
solo/private heist. Each action is dispatched once; its final ACK follows the
observed assertion rather than RPC submission. Match session, ID, sequence,
command, and `completed`. Save the ACK and its assertion `state_seq` together.
Check unmask state again after the mod's 6.5-second rollback deadline before
calling it stable. For shooting, compare before/after magazine values and
verify release. If shooting changes the heist to Alarm/Assault, record the
unmask restriction as the observed cause; do not silently bypass that rule.

Requests have a bounded, strict JSON schema:

```json
{"schema_version":1,"session_id":"read-from-live-state","id":"unique-client-id","seq":1,"command":"PING"}
```

Sequence numbers must increase within a runtime session. Commands from older
sessions and duplicate command IDs are rejected. This is a runtime handshake;
it does not promise exactly-once recovery after a process crash. There is no
arbitrary Lua evaluation command.

To verify the source offline:

```powershell
python .\tools\Test-AgentBridge.py
```

Offline checks validate the file protocol and mocked object lifecycles. For
in-game acceptance, capture a successful PING/SNAPSHOT, increasing telemetry
sequence numbers, changing position while walking in a solo/private heist,
and continued telemetry when returning to the menu and entering a fresh heist.
Review `events.jsonl` and `UE4SS.log` for bridge errors. Store the game/runtime
versions and live evidence before extending the project skill required by
`AGENTS.md`.

To verify idle behavior, save a PING ACK after DISABLE, wait at least 10 seconds,
and PING again. `sample_count`, `game_thread_ticks`, and `queued_callbacks`
should not increase; the command reader's poll count should increase. Check
that state-file modification time stops between explicit commands. Then
ENABLE and verify fresh samples resume. These counters establish skipped
instrumentation work, not an FPS benchmark.

For complete removal, close the game and move the entire `AgentBridge`
directory outside `ue4ss\Mods`. Keep its telemetry as test evidence if needed.
