# SelfControl MCP server

Lets an AI agent (Codex, Claude Code, ...) protect your focus time by starting SelfControl blocks.
It can only make blocking stricter: there's no tool to stop, shorten or remove a block.

## Tools

| Tool | What it does |
| --- | --- |
| `get_focus_status` | Whether a block is running and when it ends, today's scheduled focus blocks, the focus site list and limits. |
| `start_focus_block(minutes, reason?)` | Block your focus sites from now for 5–240 minutes. If a block is already running it's extended. |
| `schedule_focus_blocks(blocks, day?, reason?)` | Plan up to 8 blocks for today or tomorrow, e.g. `[{"start": "10:00", "end": "12:00"}, {"start": "14:00", "end": "16:30"}]`. They start on their own, even if no agent is running, and are deleted once over. |

## Guardrails

- **Fixed site list.** The agent can only block the sites in the config file, never sites it picks.
- **Short blocks only.** At most 240 minutes per block or window (lower it with `max_block_minutes`).
  The SelfControl daemon enforces the same cap: anything longer, and anything that loosens a block or
  schedule, still needs your admin password, so a confused agent or a prompt injection can't lock you
  out of something for days.
- **No undo tool.** Blocks and scheduled focus blocks can't be removed by the agent. You can remove a
  scheduled block that hasn't started yet in SelfControl → Schedules… (needs your password).

## Setup

1. Install this fork of SelfControl (see the main README) and start one block or schedule from the app or
   CLI, so the helper gets installed. That's the one time it needs your password.
2. Create `~/.config/selfcontrol-mcp/config.json`:

   ```json
   {"sites": ["instagram.com", "x.com", "reddit.com", "youtube.com"], "max_block_minutes": 240}
   ```

3. Register the server (Python 3.9+, standard library only):

   ```sh
   codex mcp add selfcontrol -- /usr/bin/python3 /path/to/selfcontrol/mcp/selfcontrol_mcp.py
   # or Claude Code:
   claude mcp add selfcontrol -- /usr/bin/python3 /path/to/selfcontrol/mcp/selfcontrol_mcp.py
   ```

Environment overrides: `SELFCONTROL_MCP_CONFIG` (config path), `SELFCONTROL_CLI` (path to `selfcontrol-cli`).

The server runs locally and talks to SelfControl on this Mac, so it works with local agents (Codex CLI,
IDE extension and desktop app, Claude Code) but not with cloud-hosted agent tasks.
