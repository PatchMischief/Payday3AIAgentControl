---
name: payday3-playtest
description: Troubleshoot PAYDAY 3 UE4SS mods in this project through AgentBridge telemetry, logs, and bounded game commands. Use for live stats, mask/unmask/fire smoke tests, and runtime enable/disable checks.
---

# PAYDAY 3 playtesting

Use this project's AgentBridge and [bridge guide](../../../docs/AGENTBRIDGE.md).
The project root is three directories above this skill folder. For this user's
troubleshooting workflow, use logs and game commands; do not inspect the screen
or use Windows keyboard automation unless the user requests that method.

## Proven workflow

AgentBridge 0.2.0 was tested on 2026-10-06 with PAYDAY 3 Steam build 25617818
and UE4SS 3.0.1 Beta #0, commit 0290beda. It read CAR-4/S40 ammo, health,
armor, consumables, and shock grenades in a solo/private heist. The command
sequence `MASK_UP → UNMASK → MASK_UP → FIRE_ONCE → UNMASK` completed through
the real UnmaskAgain request/apply/ack path. The S40 consumed one round, 12→11,
and released input. Both unmask results remained stable beyond the rollback
deadline. The disabled listener stayed live without native sampling or
periodic state writes, and ENABLE resumed sampling. Earlier 0.1.0 captures
established movement and menu/heist/menu transitions. See the guide and local
`.research/agentbridge-validation` records for hashes, ACKs, logs, and scope.

These observations do not establish every weapon mode, positive first-aid
inventory identification, multiplayer peer behavior, or an FPS benchmark.
Unknown native values remain `null` with reasons. Recheck game/runtime versions
after updates. A capability flag means the preflight permits an attempt; its
completed assertion establishes whether that attempt succeeded.

## Run a test

- Locate the installation and recheck permissions. The tested root is
  `C:\Program Files (x86)\Steam\steamapps\common\PAYDAY3`; data lives in
  `PAYDAY3\Binaries\Win64\ue4ss\Mods\AgentBridge\bridge`. The loader log is
  `PAYDAY3\Binaries\Win64\ue4ss\UE4SS.log`.
- Use `tools/AgentBridge-Client.py ping`, then `stats` for an explicit sample.
  The bridge starts disabled. `enable` begins continuous sampling; `disable`
  stops it. Disabled telemetry is intentionally frozen, so `status` alone
  cannot prove liveness. A fresh matching PING ACK can. SNAPSHOT while disabled
  takes one sample and leaves continuous sampling off.
- Establish the user's intended solo/private heist and an unpaused local pawn
  before mutations. If paused, ask the user to resume; the bridge has no unpause
  command. Telemetry does not prove lobby privacy. Capture baseline
  health, armor, each weapon's loaded/reserve ammo, and carried items. Keep raw
  native values and unknown reasons instead of converting unknowns to zero.
- Run authorized `mask-up`, `unmask`, and `fire-once` commands with **at least
  five seconds between gameplay actions**. Use one command writer at a time.
  Match each ACK's session, ID, sequence, command, status, and `completed` result;
  save the assertion state associated with its `state_seq`. Dispatch or RPC
  submission alone is not success. Do not retry a timed-out action blindly.
- MASK_UP/UNMASK exercise the installed UnmaskAgain endpoint, not an alternate
  direct tag/RPC workaround. Record its nonce, casing flag/tag count, heist state,
  and host/local acknowledgement logs. After UNMASK, wait beyond the 6.5-second
  host rollback deadline and sample again. Alarm/Assault refusal is a recorded
  condition to investigate; do not bypass the mod's Stealth/Search restriction.
- FIRE_ONCE sends one immediate game ability press/release pulse. Verify exactly
  one magazine round was consumed and input was released. The tested S40 result
  does not prove target hits or behavior for every weapon. The adapter refuses
  burst/charged/unknown firing configurations and requires known loaded ammo.
- Review `events.jsonl` and the target mod's logs for errors and state changes,
  then disable sampling. To prove idle suspension, compare PING counters and
  state-file modification time across at least ten seconds without commands:
  sample/game-thread/queued-callback counts stay fixed while control polls grow.
  ENABLE should resume fresh samples; leave the bridge disabled after testing.

Use `observe --seconds 15 --out <new-evidence-file.jsonl>` for bounded changing
telemetry captures, at most 60 seconds each. Use a working Python interpreter;
the guide records the bundled one used when Store aliases were inaccessible.
Place `--bridge-path` before the client action to select another installation.

## Change or install

If source and installed scripts match and the bridge is healthy, use it. For
authorized updates, run `tools/Install-AgentBridge.ps1 -WhatIf`, then install
with PAYDAY 3 closed. `-WithUnmaskAgainEndpoint` adds the inspected 0.5.4
integration with backups. Code updates need a restart; runtime enable/disable
does not. Recheck hashes and the current session after installation.

Run `tools/Test-AgentBridge.py` for code changes and verify changed behavior
in the game. Native reads/actions belong on the game thread with fresh validated
objects and at most one queued bridge callback. In this runtime, missing native
members return null UObject userdata that must never be called. FName is callable
userdata; a function-only constructor guard is incorrect. LoopAsync cancellation
uses a true return, and ModRef:GetModPath is absent. Verify APIs against the
installed runtime rather than assuming development documentation applies.

Keep reusable protocol mechanics in the client/adapter and detailed evidence
in the guide and project-local validation directory. Update this skill from
observed game behavior; offline mocks alone do not establish in-game success.
