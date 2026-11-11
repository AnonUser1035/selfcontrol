#!/usr/bin/env python3
"""SelfControl MCP server.

Lets an AI agent (Codex, Claude, ...) protect your focus time by starting SelfControl blocks
of a fixed, pre-configured list of sites. By design it can only make things stricter:
there is no tool to stop, shorten or remove a block, and SelfControl itself refuses those
without your admin password.

Guardrails:
  - Only the sites in the config file can be blocked; the agent can't pick sites.
  - Each block / window is at most `max_block_minutes` (hard cap 240, which the SelfControl
    daemon also enforces for anything done without a password).
  - At most 8 windows per call.

Speaks MCP over stdio (newline-delimited JSON-RPC 2.0). Standard library only, Python 3.9+.

Config (JSON), default ~/.config/selfcontrol-mcp/config.json:
  {"sites": ["instagram.com", "x.com"], "max_block_minutes": 240}
"""

import datetime
import json
import os
import subprocess
import sys
import time

SERVER_NAME = "selfcontrol"
SERVER_VERSION = "1.0.0"
CLI = os.environ.get("SELFCONTROL_CLI", "/Applications/SelfControl.app/Contents/MacOS/selfcontrol-cli")
CONFIG_PATH = os.path.expanduser(os.environ.get("SELFCONTROL_MCP_CONFIG", "~/.config/selfcontrol-mcp/config.json"))

HARD_MAX_MINUTES = 240  # SCPasswordlessMaxMinutes in the app; longer blocks need the admin password
MIN_MINUTES = 5
MAX_WINDOWS_PER_CALL = 8
SUPPORTED_PROTOCOLS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

INSTRUCTIONS = (
    "Tools for protecting the user's focus time with SelfControl, a website blocker. "
    "A block cuts off the user's distracting sites (a fixed list they configured) until it ends. "
    "Blocks cannot be stopped, shortened or removed once created, by you or by the user, so only start "
    "or schedule them when the user asked for focus time or set it up as part of their routine, and use "
    "the durations they asked for. Call get_focus_status first to see what's already running or planned. "
    "If a block is already running, start_focus_block extends it instead of failing."
)


class ToolError(Exception):
    pass


def log(message):
    sys.stderr.write("[selfcontrol-mcp] %s\n" % message)
    sys.stderr.flush()


# ---------------------------------------------------------------- config / CLI

def load_config():
    try:
        with open(CONFIG_PATH) as f:
            config = json.load(f)
    except FileNotFoundError:
        raise ToolError("No config at %s. Create it with {\"sites\": [...]} listing the sites to block." % CONFIG_PATH)
    except ValueError as e:
        raise ToolError("Config at %s isn't valid JSON: %s" % (CONFIG_PATH, e))
    sites = [s.strip() for s in config.get("sites", []) if isinstance(s, str) and s.strip()]
    if not sites:
        raise ToolError("The config at %s has no sites to block." % CONFIG_PATH)
    max_minutes = config.get("max_block_minutes", HARD_MAX_MINUTES)
    if not isinstance(max_minutes, int) or max_minutes < MIN_MINUTES:
        max_minutes = HARD_MAX_MINUTES
    return {"sites": sites, "max_block_minutes": min(max_minutes, HARD_MAX_MINUTES)}


def run_cli(args, timeout=60):
    if not os.path.exists(CLI):
        raise ToolError("SelfControl CLI not found at %s. Is SelfControl installed?" % CLI)
    try:
        proc = subprocess.run([CLI] + args, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise ToolError("SelfControl didn't respond in %d seconds. If a password prompt appeared, "
                        "the SelfControl helper needs to be (re)installed once by the user." % timeout)
    if proc.returncode != 0:
        # the CLI prints user-facing errors as "Error: ..." lines; the rest of stderr is debug logging
        errors = [line for line in proc.stderr.splitlines() if line.startswith("Error:") or line.startswith("Cancelled")]
        raise ToolError("\n".join(errors) or ("selfcontrol-cli failed (exit %d)" % proc.returncode))
    return proc.stdout


def get_status():
    try:
        return json.loads(run_cli(["status", "--json"], timeout=20))
    except ValueError:
        raise ToolError("Couldn't read SelfControl's status.")


# ---------------------------------------------------------------- formatting

def parse_iso(value):
    if not value:
        return None
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone().replace(tzinfo=None)


def fmt_time(dt):
    return dt.strftime("%-I:%M %p")


def parse_hhmm(value, field):
    try:
        hours, minutes = value.strip().split(":")
        hours, minutes = int(hours), int(minutes)
    except (ValueError, AttributeError):
        raise ToolError("%s must be a 24-hour time like 14:30, got %r" % (field, value))
    if not (0 <= hours <= 23 and 0 <= minutes <= 59):
        raise ToolError("%s must be a 24-hour time like 14:30, got %r" % (field, value))
    return hours * 60 + minutes


def sites_phrase(n):
    return "%d site%s" % (n, "" if n == 1 else "s")


def block_name(reason):
    reason = (reason or "").strip().replace("\n", " ")
    return ("Codex: " + reason)[:60] if reason else "Codex focus"


def summarize_status(status, config):
    now = datetime.datetime.now()
    lines = []
    if status.get("blockRunning"):
        ends = parse_iso(status.get("blockEndsAt"))
        sites = len(status.get("activeBlocklist") or [])
        if ends:
            left = max(0, int(round((ends - now).total_seconds() / 60)))
            lines.append("A block is running until %s (%d min left), blocking %s." % (fmt_time(ends), left, sites_phrase(sites)))
        else:
            lines.append("A block is running, blocking %s." % sites_phrase(sites))
    else:
        lines.append("No block is running.")

    today = []
    for s in status.get("schedules", []):
        if not s.get("enabled"):
            continue
        label = s.get("name") or s.get("days")
        if s.get("active"):
            today.append("now until %s (%s)" % (fmt_time(parse_iso(s["activeUntil"])), label))
        elif s.get("nextStart"):
            start = parse_iso(s["nextStart"])
            if start.date() == now.date():
                today.append("%s (%s)" % (s["time"], label))
    lines.append("Scheduled for today: " + ("; ".join(today) if today else "nothing else."))
    lines.append("Focus blocks cover %s: %s." % (sites_phrase(len(config["sites"])), ", ".join(config["sites"])))
    lines.append("Limits: %d to %d minutes per block, up to %d windows per call. Blocks can't be stopped early."
                 % (MIN_MINUTES, config["max_block_minutes"], MAX_WINDOWS_PER_CALL))
    return "\n".join(lines)


# ---------------------------------------------------------------- tools

def tool_get_focus_status(args):
    config = load_config()
    status = get_status()
    return summarize_status(status, config), {
        "blockRunning": status.get("blockRunning"),
        "blockEndsAt": status.get("blockEndsAt"),
        "secondsRemaining": status.get("secondsRemaining"),
        "schedules": status.get("schedules", []),
        "focusSites": config["sites"],
        "maxBlockMinutes": config["max_block_minutes"],
    }


def add_one_off(date_str, windows, config, reason):
    spec = ",".join("%02d:%02d-%02d:%02d" % (s // 60, s % 60, e // 60, e % 60) for s, e in windows)
    out = run_cli(["schedule", "add", "--date", date_str, "--windows", spec,
                   "--sites", ",".join(config["sites"]), "--name", block_name(reason), "--json"], timeout=120)
    try:
        return json.loads(out)
    except ValueError:
        return []


def tool_start_focus_block(args):
    config = load_config()
    minutes = args.get("minutes")
    if not isinstance(minutes, int) or isinstance(minutes, bool):
        raise ToolError("minutes must be a whole number")
    if not MIN_MINUTES <= minutes <= config["max_block_minutes"]:
        raise ToolError("minutes must be between %d and %d" % (MIN_MINUTES, config["max_block_minutes"]))

    start = datetime.datetime.now().replace(second=0, microsecond=0)
    end = start + datetime.timedelta(minutes=minutes)
    start_min = start.hour * 60 + start.minute
    end_min = end.hour * 60 + end.minute
    add_one_off(start.strftime("%Y-%m-%d"), [(start_min, end_min)], config, args.get("reason"))

    # the daemon starts (or extends) the block as soon as the schedule is saved; confirm it
    status = None
    for _ in range(10):
        status = get_status()
        ends = parse_iso(status.get("blockEndsAt"))
        if status.get("blockRunning") and ends and ends >= end - datetime.timedelta(seconds=1):
            break
        time.sleep(0.5)
    ends = parse_iso(status.get("blockEndsAt")) if status else None
    if not (status and status.get("blockRunning")):
        raise ToolError("Saved the focus block, but SelfControl hasn't started it yet. Check get_focus_status in a minute.")
    text = "Focus block on: %s blocked until %s." % (sites_phrase(len(config["sites"])), fmt_time(ends or end))
    if ends and ends > end + datetime.timedelta(minutes=1):
        text += " (An existing block already runs until then; the focus sites were added to it.)"
    return text, {"blockRunning": True, "blockEndsAt": status.get("blockEndsAt"), "sites": config["sites"]}


def tool_schedule_focus_blocks(args):
    config = load_config()
    blocks = args.get("blocks")
    day = args.get("day", "today")
    if day not in ("today", "tomorrow"):
        raise ToolError("day must be 'today' or 'tomorrow'")
    if not isinstance(blocks, list) or not blocks:
        raise ToolError("blocks must be a non-empty list of {start, end}")
    if len(blocks) > MAX_WINDOWS_PER_CALL:
        raise ToolError("at most %d blocks per call" % MAX_WINDOWS_PER_CALL)

    now = datetime.datetime.now()
    base = now.date() + datetime.timedelta(days=1 if day == "tomorrow" else 0)
    windows, described = [], []
    for i, block in enumerate(blocks):
        if not isinstance(block, dict):
            raise ToolError("blocks[%d] must be an object with start and end" % i)
        start_min = parse_hhmm(block.get("start"), "blocks[%d].start" % i)
        end_min = parse_hhmm(block.get("end"), "blocks[%d].end" % i)
        length = (end_min - start_min) % (24 * 60)
        if not MIN_MINUTES <= length <= config["max_block_minutes"]:
            raise ToolError("blocks[%d] is %d minutes; each block must be %d to %d minutes"
                            % (i, length, MIN_MINUTES, config["max_block_minutes"]))
        start_dt = datetime.datetime.combine(base, datetime.time(start_min // 60, start_min % 60))
        end_dt = start_dt + datetime.timedelta(minutes=length)
        if end_dt <= now:
            raise ToolError("blocks[%d] (%s-%s) has already ended" % (i, block["start"], block["end"]))
        windows.append((start_min, end_min))
        described.append("%s - %s%s" % (fmt_time(start_dt), fmt_time(end_dt), " (starts now)" if start_dt <= now else ""))

    created = add_one_off(base.strftime("%Y-%m-%d"), windows, config, args.get("reason"))
    text = "Scheduled %d focus block%s %s, each blocking %s:\n  %s" % (
        len(windows), "" if len(windows) == 1 else "s", day, sites_phrase(len(config["sites"])), "\n  ".join(described))
    return text, {"day": day, "created": created}


TOOLS = [
    {
        "name": "get_focus_status",
        "title": "Get focus status",
        "description": "Whether a SelfControl block is running and when it ends, what focus blocks are scheduled "
                       "today, which sites focus blocks cover, and the limits. Call this before starting or "
                       "scheduling blocks.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        "annotations": {"readOnlyHint": True, "openWorldHint": False},
        "handler": tool_get_focus_status,
    },
    {
        "name": "start_focus_block",
        "title": "Start a focus block now",
        "description": "Block the user's distracting sites starting now, for the given number of minutes. "
                       "If a block is already running and ends sooner, it's extended. Cannot be undone or "
                       "shortened once started.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "minutes": {"type": "integer", "minimum": MIN_MINUTES, "maximum": HARD_MAX_MINUTES,
                            "description": "How long to block, in minutes."},
                "reason": {"type": "string", "description": "Short label, e.g. the task being focused on."},
            },
            "required": ["minutes"],
            "additionalProperties": False,
        },
        "annotations": {"readOnlyHint": False, "destructiveHint": False, "idempotentHint": False, "openWorldHint": False},
        "handler": tool_start_focus_block,
    },
    {
        "name": "schedule_focus_blocks",
        "title": "Schedule focus blocks for today or tomorrow",
        "description": "Plan one or more focus blocks later today (or tomorrow), e.g. to protect deep-work "
                       "time across the day. Each block starts automatically at its start time, even if no "
                       "agent is running. Times are local, 24-hour HH:MM; an end before the start means it "
                       "runs past midnight. Scheduled blocks cannot be removed or shortened by the agent.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "blocks": {
                    "type": "array",
                    "minItems": 1,
                    "maxItems": MAX_WINDOWS_PER_CALL,
                    "items": {
                        "type": "object",
                        "properties": {
                            "start": {"type": "string", "pattern": "^\\d{1,2}:\\d{2}$", "description": "Start time, HH:MM (24h)."},
                            "end": {"type": "string", "pattern": "^\\d{1,2}:\\d{2}$", "description": "End time, HH:MM (24h)."},
                        },
                        "required": ["start", "end"],
                        "additionalProperties": False,
                    },
                },
                "day": {"type": "string", "enum": ["today", "tomorrow"], "default": "today"},
                "reason": {"type": "string", "description": "Short label, e.g. 'deep work'."},
            },
            "required": ["blocks"],
            "additionalProperties": False,
        },
        "annotations": {"readOnlyHint": False, "destructiveHint": False, "idempotentHint": False, "openWorldHint": False},
        "handler": tool_schedule_focus_blocks,
    },
]
TOOLS_BY_NAME = {t["name"]: t for t in TOOLS}


# ---------------------------------------------------------------- JSON-RPC / MCP

def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def handle(message):
    method = message.get("method")
    msg_id = message.get("id")
    if method is None:
        return  # a response to something we never send; ignore
    if msg_id is None:
        return  # notifications (initialized, cancelled, ...) need no reply

    params = message.get("params") or {}
    if method == "initialize":
        requested = params.get("protocolVersion")
        version = requested if requested in SUPPORTED_PROTOCOLS else SUPPORTED_PROTOCOLS[0]
        result = {
            "protocolVersion": version,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            "instructions": INSTRUCTIONS,
        }
    elif method == "ping":
        result = {}
    elif method == "tools/list":
        result = {"tools": [{k: v for k, v in t.items() if k != "handler"} for t in TOOLS]}
    elif method == "tools/call":
        tool = TOOLS_BY_NAME.get(params.get("name"))
        if tool is None:
            send({"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32602, "message": "Unknown tool: %s" % params.get("name")}})
            return
        try:
            text, structured = tool["handler"](params.get("arguments") or {})
            result = {"content": [{"type": "text", "text": text}], "structuredContent": structured, "isError": False}
        except ToolError as e:
            result = {"content": [{"type": "text", "text": str(e)}], "isError": True}
        except Exception as e:  # never crash the server over one call
            log("tool %s failed: %r" % (params.get("name"), e))
            result = {"content": [{"type": "text", "text": "Unexpected error: %s" % e}], "isError": True}
    else:
        send({"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32601, "message": "Method not found: %s" % method}})
        return
    send({"jsonrpc": "2.0", "id": msg_id, "result": result})


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            send({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}})
            continue
        for item in (message if isinstance(message, list) else [message]):
            if isinstance(item, dict):
                handle(item)


if __name__ == "__main__":
    main()
