# AgentBridge project

Use `.agents/skills/payday3-playtest/SKILL.md` for PAYDAY 3 playtests and
`docs/AGENTBRIDGE.md` for implementation and runtime constraints.

- Troubleshoot through bridge commands, telemetry, and logs. Use screen or
  Windows input automation only when the user requests that method.
- Use the user's intended solo/private heist and wait at least five seconds
  between gameplay actions. Ask the user to resume a paused game before actions.
- Require matching completion acknowledgements and observed state assertions;
  dispatch alone does not establish success. Inspect timeouts before retrying.
- Keep sampling disabled outside active tests. Runtime enable/disable does not
  require a restart; installing changed Lua files requires the game closed.
- Recheck the game installation, permissions, and actual runtime APIs before
  deployment. Run `tools/Test-AgentBridge.py` for relevant code changes and verify
  changed native behavior in the game. Offline tests alone do not prove it.
- Record versions and evidence before expanding the skill's proven capabilities.
  Keep local traces, generated runtime paths, dependencies, and game assets out
  of commits.
