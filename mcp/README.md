# SelfControl MCP server

Lets an AI agent (Codex, Claude Code, ...) manage your focus time with SelfControl blocks: start one now,
plan blocks on any day, add weekly schedules, and move or cancel planned blocks while they're far enough away.

## Tools

| Tool | What it does |
| --- | --- |
| `get_focus_status` | Whether a block is running, everything planned for the next 7 days and every weekly schedule (with IDs and whether each can still be changed), the focus site list and limits. |
| `start_focus_block(minutes, reason?)` | Block your focus sites from now for 5–240 minutes. If a block is already running it's extended. |
| `schedule_focus_blocks(blocks, day?, reason?)` | Plan up to 20 one-off blocks on any days up to 30 days ahead, e.g. `[{"date": "fri", "start": "10:00", "end": "12:00"}, {"date": "2026-11-20", "start": "14:00", "end": "16:30"}]`. They start on their own, even if no agent is running, and are deleted once over. |
| `add_weekly_focus_schedule(days, start, end, name?)` | A window that repeats every week, e.g. `mon-fri 09:00-12:00`. |
| `change_focus_block(id, date?, days?, start?, end?, name?)` | Move or retime a planned block or weekly schedule, including ones you made in the app. |
| `cancel_focus_block(id, date?, whole_schedule?)` | Cancel a one-off block, skip one day of a weekly schedule, or delete a whole weekly schedule. |

`date` takes `today`, `tomorrow`, a weekday (`fri`: the next one, today included; `next fri`: a week after that) or `YYYY-MM-DD`.

## Guardrails

- **Fixed site list.** The agent can only block the sites in the config file, never sites it picks.
- **Short windows.** At most 240 minutes per block or window (lower it with `max_block_minutes`), and
  nothing more than `max_days_ahead` days out (default 30).
- **12-hour lock.** A block that's running, or starts within 12 hours, can't be cancelled, shortened, moved
  or skipped. Further out it can. You can't talk your way out of a block at the last minute, even through
  the agent.
- **Never asks for your password.** Anything that would need it fails instead. The SelfControl daemon
  enforces the same rules for the app and CLI, so the agent can't do anything you couldn't do yourself
  without your password.

## Setup

1. Install this fork of SelfControl (see the main README) and run `selfcontrol-cli install-helper` once
   (and again after each update), which asks for your admin password.
2. Create `~/.config/selfcontrol-mcp/config.json`:

   ```json
   {"sites": ["instagram.com", "x.com", "reddit.com", "youtube.com"], "max_block_minutes": 240, "max_days_ahead": 30}
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
