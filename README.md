# PAYDAY 3 AI Agent Control

**AgentBridge 0.2.0** is a local telemetry and command bridge for PAYDAY 3
UE4SS mod development. An external AI agent or developer can read player stats,
run a small set of game commands, and check their results through files and
logs. Gameplay tests use game APIs rather than screen recognition or simulated
Windows key presses.

## What it does

- Reports the local pawn's position, health, armor, weapon magazine/reserve
  ammo, consumables, and throwables. Unavailable or unidentified values are
  `null`, with diagnostic reasons.
- Runs mask/unmask tests through the included **UnmaskAgain integration** and
  a bounded fire-input pulse through the game's ability system.
- Returns matching acknowledgements after observed action completion.
  A successful fire command requires exactly one loaded round consumed and
  confirmed input release.
- Enables and disables continuous sampling **while the game runs**. The
  bridge starts disabled and can take an explicit one-off snapshot in that state.
- Records session, sequencing, sampling counters, errors, and state changes for
  troubleshooting and repeatable playtests.

## How it works

```text
External agent/developer → Python client → command.json
                                          ↓
                                  UE4SS AgentBridge
                                          ↓
                              Game-thread reads/actions
                                          ↓
External agent/developer ← state.json / ack.json / events.jsonl
```

The Python client reads the current session and sequence, atomically replaces
the command file, and waits for an ACK with the same session, ID, sequence,
and command. The Lua bridge accepts only the fixed commands listed below;
old sessions, duplicate IDs, and non-increasing sequences are rejected.
There is no arbitrary Lua evaluation endpoint.

A 1 Hz file-command listener stays active while disabled. Enabling starts a
300 ms sampler that queues validated native reads on the game thread, with at
most one pending callback. Disabling stops continuous native sampling and
periodic telemetry writes; explicit commands can still publish responses.
Other UE4SS mods keep their own behavior. These checks measure skipped
instrumentation work, not an FPS improvement.

Mask commands use UnmaskAgain's existing request/apply/ack path and its
Stealth/Search restrictions. Fire sends one immediate press/release pulse,
then checks ammunition. Actions require an enabled bridge and a verified
unpaused local heist pawn. Failed fire-release cleanup retains its identity so
`DISABLE` can retry release without pressing fire again.

## Requirements and installation

Use Windows, PowerShell, Python 3, and an existing compatible PAYDAY 3 UE4SS
installation. The tested setup is PAYDAY 3 Steam build **25617818** with UE4SS
**3.0.1 Beta #0**, commit **0290beda**. Compatibility after game/runtime updates
needs rechecking. The installer deploys Lua scripts; it does not install UE4SS.

Close PAYDAY 3, then run from the repository root:

```powershell
.\tools\Install-AgentBridge.ps1 -WhatIf
.\tools\Install-AgentBridge.ps1
```

The default game root is
`C:\Program Files (x86)\Steam\steamapps\common\PAYDAY3`.
Use `-GamePath 'D:\YourSteamLibrary\steamapps\common\PAYDAY3'` for another
installation. The installer backs up the existing bridge outside the
auto-loaded Mods directory and generates its absolute data-path module.
Restart the game after installation or Lua code changes.

For mask/unmask commands, the installer requires an existing **UnmaskAgain
0.5.4** matching the inspected source hash, or this integration's current hash:

```powershell
.\tools\Install-AgentBridge.ps1 -WithUnmaskAgainEndpoint -WhatIf
.\tools\Install-AgentBridge.ps1 -WithUnmaskAgainEndpoint
```

That switch backs up and updates UnmaskAgain's main script and command endpoint.
It refuses missing or unfamiliar versions instead of overwriting them.
The integration sources are under `integrations/UnmaskAgain/Scripts/`.

## Commands

Run these from the repository root using your Python interpreter:

| Client action | Bridge command | Purpose |
| --- | --- | --- |
| `ping` | `PING` | Fresh connection acknowledgement, including while disabled |
| `status` | None | Read the current file; frozen state alone does not prove liveness |
| `stats` / `snapshot` | `SNAPSHOT` | One explicit native sample; stays disabled if already disabled |
| `enable` | `ENABLE` | Start continuous sampling |
| `disable` | `DISABLE` | Stop sampling and retry pending fire-release cleanup |
| `mask-up` | `MASK_UP` | Request and verify masking through UnmaskAgain |
| `unmask` | `UNMASK` | Request and verify unmasking through UnmaskAgain |
| `fire-once` | `FIRE_ONCE` | Send one bounded pulse and verify one round consumed |
| `observe` | None | Capture changing telemetry for up to 60 seconds |

```powershell
python .\tools\AgentBridge-Client.py ping
python .\tools\AgentBridge-Client.py stats
python .\tools\AgentBridge-Client.py enable
python .\tools\AgentBridge-Client.py observe --seconds 15 --out telemetry.jsonl
python .\tools\AgentBridge-Client.py disable
```

For an authorized solo/private heist test, leave the game unpaused, enable the
bridge, and run the following **one at a time**. Wait at least **five seconds
between gameplay actions**. After each unmask, wait over **6.5 seconds** and take
a snapshot to check that it remains stable:

```powershell
python .\tools\AgentBridge-Client.py mask-up
python .\tools\AgentBridge-Client.py unmask
python .\tools\AgentBridge-Client.py mask-up
python .\tools\AgentBridge-Client.py fire-once
python .\tools\AgentBridge-Client.py unmask
python .\tools\AgentBridge-Client.py disable
```

Use one command writer at a time. Preserve baseline/after-action stats and ACKs;
inspect logs before retrying any timeout. `fire-once` refuses burst, charged,
unknown, or unsupported ammunition configurations. A capability flag is a
preflight result, not proof that an action succeeded. Target hits, aiming,
movement automation, and objective completion are outside the current commands.

The files live under:

```text
<GamePath>/PAYDAY3/Binaries/Win64/ue4ss/Mods/AgentBridge/bridge/
    state.json
    command.json
    ack.json
    events.jsonl
```

Use `--bridge-path '<data-directory>'` **before** the client action for another
data location. The UE4SS loader log is `ue4ss/UE4SS.log`. No listening network
service is created by this bridge.

## Project skill

The proven workflow is included at
[.agents/skills/payday3-playtest/SKILL.md](.agents/skills/payday3-playtest/SKILL.md).
Open this repository as your Codex project to discover the project-local skill,
or explicitly request `$payday3-playtest`. It directs the agent to use commands
and logs, preserve unknown values, verify completion, space gameplay actions,
check unmask rollback, and leave sampling disabled afterward.

See [docs/AGENTBRIDGE.md](docs/AGENTBRIDGE.md) for detailed protocol, installation,
runtime constraints, and the recorded validation summary.

## Validation and scope

Live testing on **2026-10-06** completed
`MASK_UP → UNMASK → MASK_UP → FIRE_ONCE → UNMASK` in a solo/private heist.
The S40 consumed one round (12→11), input was released, and both unmask states
remained stable beyond the rollback deadline. Disabled sampling counters and
the state file stayed fixed while the command listener remained live; ENABLE
resumed sampling. Earlier bridge testing captured movement and menu/heist
transitions. A subsequent cleanup-only correction passed offline regressions
and a fresh installed-runtime control/idle check; native failure injection was
not performed in the game.

These observations do not establish every weapon mode, positive first-aid item
identification, peer multiplayer behavior, or all game versions. Raw local
session traces and research files are not included in this repository.

Run the **26 offline core/adapter tests** independently:

```powershell
New-Item -ItemType Directory -Path .tools -Force | Out-Null
python -m pip install --target .tools/python -r requirements-dev.txt
python .\tools\Test-AgentBridge.py
```

The Lupa dependency is for the test runner only. Runtime Lua scripts need the
game's compatible UE4SS installation. Offline mocks validate protocol and
lifecycle behavior; changed native gameplay behavior still needs a live test.
