#!/usr/bin/env python3
"""SelfControl MCP server.

Lets an AI agent (Codex, Claude, ...) manage the user's focus time with SelfControl blocks
of a fixed, pre-configured list of sites: start a block now, plan blocks on any day, add weekly
focus schedules, and move or cancel planned blocks while they're far enough away.

Guardrails (the SelfControl daemon enforces the same rules, so they hold no matter who asks):
  - Only the sites in the config file can be blocked; the agent can't pick sites.
  - Each block / window is at most `max_block_minutes` (hard cap 240).
  - Running blocks, and blocks starting within 12 hours, can't be cancelled, shortened or moved.
    Further out they can. Nothing here ever asks for the admin password: anything that would
    need it fails instead.
  - Blocks can be planned at most `max_days_ahead` days ahead (default 30).

Speaks MCP over stdio (newline-delimited JSON-RPC 2.0). Standard library only, Python 3.9+.

Config (JSON), default ~/.config/selfcontrol-mcp/config.json:
  {"sites": ["instagram.com", "x.com"], "max_block_minutes": 240, "max_days_ahead": 30}
"""

import datetime
import json
import os
import subprocess
import sys
import time

SERVER_NAME = "selfcontrol"
SERVER_VERSION = "1.1.0"
CLI = os.environ.get("SELFCONTROL_CLI", "/Applications/SelfControl.app/Contents/MacOS/selfcontrol-cli")
CONFIG_PATH = os.path.expanduser(os.environ.get("SELFCONTROL_MCP_CONFIG", "~/.config/selfcontrol-mcp/config.json"))

HARD_MAX_MINUTES = 240  # SCPasswordlessMaxMinutes in the app; longer blocks need the admin password
MIN_MINUTES = 5
DEFAULT_DAYS_AHEAD = 30
HARD_MAX_DAYS_AHEAD = 90
MAX_BLOCKS_PER_CALL = 20
NOTICE_HOURS = 12  # SCScheduleChangeNoticeMinutes / 60; the CLI reports the real value
SUPPORTED_PROTOCOLS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
WEEKDAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

INSTRUCTIONS = (
    "Tools for managing the user's focus time with SelfControl, a website blocker. A block cuts off the "
    "user's distracting sites (a fixed list they configured) until it ends. Call get_focus_status first: it "
    "lists what's running and planned, with IDs. You can start a block now, plan blocks on any day up to a "
    "few weeks ahead, add weekly schedules, and move, skip or cancel planned blocks. A block that's running "
    "or starts within 12 hours is locked: nobody can cancel, shorten or move it without the user's admin "
    "password, and these tools never ask for it. Only start, change or cancel blocks when the user asked "
    "for it (directly or as part of a routine they set up), and use the times they asked for."
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
    days_ahead = config.get("max_days_ahead", DEFAULT_DAYS_AHEAD)
    if not isinstance(days_ahead, int) or days_ahead < 0:
        days_ahead = DEFAULT_DAYS_AHEAD
    return {"sites": sites, "max_block_minutes": min(max_minutes, HARD_MAX_MINUTES),
            "max_days_ahead": min(days_ahead, HARD_MAX_DAYS_AHEAD)}


def run_cli(args, timeout=60):
    if not os.path.exists(CLI):
        raise ToolError("SelfControl CLI not found at %s. Is SelfControl installed?" % CLI)
    try:
        proc = subprocess.run([CLI] + args, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise ToolError("SelfControl didn't respond in %d seconds." % timeout)
    if proc.returncode != 0:
        # the CLI prints user-facing errors as "Error: ..." lines; the rest of stderr is debug logging
        errors = [line[len("Error: "):] if line.startswith("Error: ") else line
                  for line in proc.stderr.splitlines() if line.startswith("Error:") or line.startswith("Cancelled")]
        message = "\n".join(errors) or ("selfcontrol-cli failed (exit %d)" % proc.returncode)
        if "needs your admin password" in message:
            message += (" Blocks lock %d hours before they start, so this can't be done from here. The user can "
                        "still do it in SelfControl > Schedules with their admin password." % NOTICE_HOURS)
        raise ToolError(message)
    return proc.stdout


def run_schedule_cli(args):
    """Schedule changes never prompt for a password: anything that would need it fails instead."""
    out = run_cli(["schedule"] + args + ["--no-password", "--json"])
    try:
        return json.loads(out)
    except ValueError:
        return []


def get_status():
    global NOTICE_HOURS
    try:
        status = json.loads(run_cli(["status", "--json"], timeout=20))
    except ValueError:
        raise ToolError("Couldn't read SelfControl's status.")
    if isinstance(status.get("changeNoticeMinutes"), int):
        NOTICE_HOURS = status["changeNoticeMinutes"] // 60
    return status


def find_schedule(status, query):
    if not isinstance(query, str) or len(query.strip()) < 4:
        raise ToolError("id must be a block ID from get_focus_status (at least the first 4 characters)")
    query = query.strip().lower()
    matches = [s for s in status.get("schedules", []) if s.get("id", "").lower().startswith(query)]
    if not matches:
        raise ToolError("No focus block or schedule has ID %s. Call get_focus_status for current IDs "
                        "(one-off blocks disappear once they're over)." % query)
    if len(matches) > 1:
        raise ToolError("ID %s matches more than one block; use more of it." % query)
    return matches[0]


# ---------------------------------------------------------------- parsing / formatting

def parse_iso(value):
    if not value:
        return None
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone().replace(tzinfo=None)


def parse_hhmm(value, field):
    try:
        hours, minutes = value.strip().split(":")
        hours, minutes = int(hours), int(minutes)
    except (ValueError, AttributeError):
        raise ToolError("%s must be a 24-hour time like 14:30, got %r" % (field, value))
    if not (0 <= hours <= 23 and 0 <= minutes <= 59):
        raise ToolError("%s must be a 24-hour time like 14:30, got %r" % (field, value))
    return hours * 60 + minutes


def hhmm(minute):
    return "%02d:%02d" % (minute // 60, minute % 60)


def window_length(start_min, end_min):
    return (end_min - start_min) % (24 * 60)


def parse_day(value, field, config, now=None):
    """'today', 'tomorrow', a weekday ('fri', 'friday': the next one, today included; 'next fri': a week later
    if today is Friday) or YYYY-MM-DD. Returns a date within the planning horizon."""
    now = now or datetime.datetime.now()
    today = now.date()
    if not isinstance(value, str) or not value.strip():
        raise ToolError("%s must be today, tomorrow, a weekday or YYYY-MM-DD" % field)
    text = value.strip().lower()
    day = None
    if text == "today":
        day = today
    elif text == "tomorrow":
        day = today + datetime.timedelta(days=1)
    else:
        try:
            day = datetime.date.fromisoformat(text)
        except ValueError:
            is_next = text.startswith("next ")
            name = text[5:].strip() if is_next else text
            matches = [i for i, w in enumerate(WEEKDAYS) if len(name) >= 2 and w.startswith(name)]
            if len(matches) != 1:
                raise ToolError("%s must be today, tomorrow, a weekday or YYYY-MM-DD, got %r" % (field, value))
            offset = (matches[0] - today.weekday()) % 7
            if offset == 0 and is_next:
                offset = 7
            day = today + datetime.timedelta(days=offset)
    if day < today - datetime.timedelta(days=1):
        raise ToolError("%s (%s) is in the past" % (field, day.isoformat()))
    if day > today + datetime.timedelta(days=config["max_days_ahead"]):
        raise ToolError("%s (%s) is too far ahead; blocks can be planned up to %d days out"
                        % (field, day.isoformat(), config["max_days_ahead"]))
    return day


def fmt_time(dt):
    return dt.strftime("%-I:%M %p")


def fmt_day(d, today=None):
    today = today or datetime.date.today()
    if d == today:
        return "today"
    if d == today + datetime.timedelta(days=1):
        return "tomorrow"
    return d.strftime("%a %b %-d")


def fmt_when(dt):
    return "%s %s" % (fmt_day(dt.date()), fmt_time(dt))


def sites_phrase(n):
    return "%d site%s" % (n, "" if n == 1 else "s")


def plural(n, word):
    return "%d %s%s" % (n, word, "" if n == 1 else "s")


def block_name(reason, default="Codex focus"):
    reason = (reason or "").strip().replace("\n", " ")
    return ("Codex: " + reason)[:60] if reason else default


def short_id(schedule_id):
    return (schedule_id or "")[:8].lower()


def schedule_label(s):
    return s.get("name") or ("%s %s" % (s.get("days", ""), s.get("time", ""))).strip()


def window_lock_note(start, end, now):
    if start <= now < end:
        return "running now, locked"
    locks_at = start - datetime.timedelta(hours=NOTICE_HOURS)
    if locks_at <= now:
        return "locked (starts within %d h)" % NOTICE_HOURS
    return "can change until %s" % fmt_when(locks_at)


def upcoming_windows(status, days, now):
    """(start, end, schedule) for every enabled schedule's windows in the next `days` days, soonest first."""
    horizon = now + datetime.timedelta(days=days)
    rows = []
    for s in status.get("schedules", []):
        if not s.get("enabled"):
            continue
        for w in s.get("upcomingWindows", []):
            start, end = parse_iso(w.get("start")), parse_iso(w.get("end"))
            if start and end and end > now and start < horizon:
                rows.append((start, end, s))
    rows.sort(key=lambda r: r[0])
    return rows


def summarize_status(status, config):
    now = datetime.datetime.now()
    lines = []
    if status.get("blockRunning"):
        ends = parse_iso(status.get("blockEndsAt"))
        sites = len(status.get("activeBlocklist") or [])
        if ends:
            left = max(0, int(round((ends - now).total_seconds() / 60)))
            lines.append("A block is running until %s (%d min left), blocking %s." % (fmt_when(ends), left, sites_phrase(sites)))
        else:
            lines.append("A block is running, blocking %s." % sites_phrase(sites))
    else:
        lines.append("No block is running.")

    rows = upcoming_windows(status, 7, now)
    lines.append("")
    lines.append("Planned for the next 7 days:" if rows else "Nothing planned for the next 7 days.")
    for start, end, s in rows:
        kind = "one-off" if s.get("oneOff") else "weekly"
        lines.append("  %s, %s-%s: %s (id %s, %s; %s)" % (
            fmt_day(start.date()), fmt_time(start), fmt_time(end), schedule_label(s), short_id(s.get("id")), kind,
            window_lock_note(start, end, now)))

    weekly = [s for s in status.get("schedules", []) if not s.get("oneOff")]
    if weekly:
        lines.append("")
        lines.append("Weekly schedules:")
        for s in weekly:
            extra = []
            if not s.get("enabled"):
                extra.append("off")
            if s.get("skipDates"):
                extra.append("skipping " + ", ".join(s["skipDates"]))
            lines.append("  %s: %s %s, %s (id %s%s)" % (
                schedule_label(s), s.get("days"), s.get("time"), sites_phrase(s.get("siteCount", 0)),
                short_id(s.get("id")), "; " + "; ".join(extra) if extra else ""))

    later = [s for s in status.get("schedules", []) if s.get("oneOff") and s.get("enabled")
             and s.get("nextStart") and parse_iso(s["nextStart"]) > now + datetime.timedelta(days=7)]
    if later:
        lines.append("")
        lines.append("Also planned later: " + "; ".join(
            "%s %s (id %s)" % (fmt_day(parse_iso(s["nextStart"]).date()), s.get("time"), short_id(s.get("id"))) for s in later))

    lines.append("")
    lines.append("Focus blocks cover %s: %s." % (sites_phrase(len(config["sites"])), ", ".join(config["sites"])))
    lines.append("Rules: each block %d-%d minutes, planned up to %d days ahead. Running blocks and blocks starting "
                 "within %d hours are locked; anything further out can be moved, skipped or cancelled."
                 % (MIN_MINUTES, config["max_block_minutes"], config["max_days_ahead"], NOTICE_HOURS))
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
        "maxDaysAhead": config["max_days_ahead"],
        "lockHoursBeforeStart": NOTICE_HOURS,
    }


def add_one_off(date_str, windows, config, reason):
    spec = ",".join("%s-%s" % (hhmm(s), hhmm(e)) for s, e in windows)
    return run_schedule_cli(["add", "--date", date_str, "--windows", spec,
                             "--sites", ",".join(config["sites"]), "--name", block_name(reason)])


def tool_start_focus_block(args):
    config = load_config()
    minutes = args.get("minutes")
    if not isinstance(minutes, int) or isinstance(minutes, bool):
        raise ToolError("minutes must be a whole number")
    if not MIN_MINUTES <= minutes <= config["max_block_minutes"]:
        raise ToolError("minutes must be between %d and %d" % (MIN_MINUTES, config["max_block_minutes"]))

    start = datetime.datetime.now().replace(second=0, microsecond=0)
    end = start + datetime.timedelta(minutes=minutes)
    add_one_off(start.strftime("%Y-%m-%d"), [(start.hour * 60 + start.minute, end.hour * 60 + end.minute)], config, args.get("reason"))

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
    default_day = args.get("day", "today")
    if not isinstance(blocks, list) or not blocks:
        raise ToolError("blocks must be a non-empty list of {date, start, end}")
    if len(blocks) > MAX_BLOCKS_PER_CALL:
        raise ToolError("at most %d blocks per call" % MAX_BLOCKS_PER_CALL)

    now = datetime.datetime.now()
    by_date = {}  # date -> [(start_min, end_min, description)], in the order given
    for i, block in enumerate(blocks):
        if not isinstance(block, dict):
            raise ToolError("blocks[%d] must be an object with date, start and end" % i)
        day = parse_day(block.get("date", default_day), "blocks[%d].date" % i, config, now)
        start_min = parse_hhmm(block.get("start"), "blocks[%d].start" % i)
        end_min = parse_hhmm(block.get("end"), "blocks[%d].end" % i)
        length = window_length(start_min, end_min)
        if not MIN_MINUTES <= length <= config["max_block_minutes"]:
            raise ToolError("blocks[%d] is %d minutes; each block must be %d to %d minutes"
                            % (i, length, MIN_MINUTES, config["max_block_minutes"]))
        start_dt = datetime.datetime.combine(day, datetime.time(start_min // 60, start_min % 60))
        end_dt = start_dt + datetime.timedelta(minutes=length)
        if end_dt <= now:
            raise ToolError("blocks[%d] (%s %s-%s) has already ended" % (i, day.isoformat(), block["start"], block["end"]))
        desc = "%s, %s-%s%s" % (fmt_day(day), fmt_time(start_dt), fmt_time(end_dt), " (starts now)" if start_dt <= now else "")
        by_date.setdefault(day, []).append((start_min, end_min, desc))

    created, done = [], []
    for day, windows in sorted(by_date.items()):
        try:
            created += add_one_off(day.isoformat(), [(s, e) for s, e, _ in windows], config, args.get("reason"))
        except ToolError as e:
            if done:
                raise ToolError("Scheduled %s, but %s failed: %s" % ("; ".join(done), fmt_day(day), e))
            raise
        done += [d for _, _, d in windows]

    text = "Scheduled %s, each blocking %s:\n  %s\nThey start on their own. Each can be moved or cancelled until %d hours before it starts." % (
        plural(len(done), "focus block"), sites_phrase(len(config["sites"])), "\n  ".join(done), NOTICE_HOURS)
    return text, {"created": created}


def tool_add_weekly_focus_schedule(args):
    config = load_config()
    days = args.get("days")
    if not isinstance(days, str) or not days.strip():
        raise ToolError("days must be text like 'mon-fri', 'weekends', 'daily' or 'mon,wed,fri'")
    start_min = parse_hhmm(args.get("start"), "start")
    end_min = parse_hhmm(args.get("end"), "end")
    length = window_length(start_min, end_min)
    if not MIN_MINUTES <= length <= config["max_block_minutes"]:
        raise ToolError("the window is %d minutes; it must be %d to %d minutes" % (length, MIN_MINUTES, config["max_block_minutes"]))
    created = run_schedule_cli(["add", "--days", days.strip(), "--start", hhmm(start_min), "--end", hhmm(end_min),
                                "--sites", ",".join(config["sites"]), "--name", block_name(args.get("name"), "Codex weekly focus")])
    s = created[0] if created else {}
    nxt = parse_iso(s.get("nextStart"))
    text = "Added weekly focus schedule %s: %s %s, blocking %s (id %s).%s" % (
        schedule_label(s), s.get("days"), s.get("time"), sites_phrase(len(config["sites"])), short_id(s.get("id")),
        (" Next: %s." % fmt_when(nxt)) if nxt else "")
    return text, {"created": created}


def tool_change_focus_block(args):
    config = load_config()
    status = get_status()
    s = find_schedule(status, args.get("id"))
    date_arg, days_arg = args.get("date"), args.get("days")
    if date_arg is not None and days_arg is not None:
        raise ToolError("give date (to make it a one-off on that day) or days (weekly), not both")

    old_start = parse_hhmm(s.get("start"), "start")
    old_end = parse_hhmm(s.get("end"), "end")
    new_start = parse_hhmm(args["start"], "start") if args.get("start") is not None else old_start
    new_end = parse_hhmm(args["end"], "end") if args.get("end") is not None else old_end
    old_len, new_len = window_length(old_start, old_end), window_length(new_start, new_end)
    if new_len < MIN_MINUTES:
        raise ToolError("the new window is %d minutes; it must be at least %d" % (new_len, MIN_MINUTES))
    if new_len > config["max_block_minutes"] and new_len > old_len:
        raise ToolError("the new window is %d minutes; blocks can be lengthened to at most %d minutes"
                        % (new_len, config["max_block_minutes"]))

    cli_args = ["edit", s["id"]]
    if date_arg is not None:
        cli_args += ["--date", parse_day(date_arg, "date", config).isoformat()]
    if days_arg is not None:
        if not isinstance(days_arg, str) or not days_arg.strip():
            raise ToolError("days must be text like 'mon-fri' or 'mon,wed,fri'")
        cli_args += ["--days", days_arg.strip()]
    if new_start != old_start:
        cli_args += ["--start", hhmm(new_start)]
    if new_end != old_end:
        cli_args += ["--end", hhmm(new_end)]
    if args.get("name") is not None:
        cli_args += ["--name", str(args["name"])[:60]]
    if len(cli_args) == 2:
        raise ToolError("nothing to change: give date, days, start, end or name")

    changed = run_schedule_cli(cli_args)
    c = changed[0] if changed else {}
    nxt = parse_iso(c.get("nextStart"))
    text = "Changed %s: now %s %s.%s" % (schedule_label(c or s), c.get("days"), c.get("time"),
                                        (" Next: %s." % fmt_when(nxt)) if nxt else "")
    return text, {"changed": changed}


def tool_cancel_focus_block(args):
    load_config()
    status = get_status()
    s = find_schedule(status, args.get("id"))
    date_arg = args.get("date")
    label = schedule_label(s)

    if s.get("oneOff"):
        if date_arg is not None and parse_day(date_arg, "date", {"max_days_ahead": HARD_MAX_DAYS_AHEAD * 5}).isoformat() != s.get("date"):
            raise ToolError("%s is a one-off block on %s, not %s" % (label, s.get("date"), date_arg))
        run_schedule_cli(["remove", s["id"]])
        return "Cancelled %s (%s %s)." % (label, s.get("days"), s.get("time")), {"removed": s["id"]}

    if date_arg is not None:
        day = parse_day(date_arg, "date", {"max_days_ahead": 366})
        run_schedule_cli(["skip", s["id"], "--date", day.isoformat()])
        return "Skipping %s on %s. It runs as usual on its other days." % (label, fmt_day(day)), {"skipped": s["id"], "date": day.isoformat()}

    if args.get("whole_schedule") is not True:
        raise ToolError("%s is a weekly schedule (%s %s). Pass date to skip one day, or whole_schedule: true "
                        "to delete the whole schedule (only if the user asked for that)." % (label, s.get("days"), s.get("time")))
    run_schedule_cli(["remove", s["id"]])
    return "Deleted the weekly schedule %s (%s %s)." % (label, s.get("days"), s.get("time")), {"removed": s["id"]}


DAY_DESCRIPTION = "today, tomorrow, a weekday (mon, friday: the next one, today included; 'next fri' for the week after) or YYYY-MM-DD."
TIME_PATTERN = "^\\d{1,2}:\\d{2}$"
WRITE_HINTS = {"readOnlyHint": False, "destructiveHint": False, "idempotentHint": False, "openWorldHint": False}

TOOLS = [
    {
        "name": "get_focus_status",
        "title": "Get focus status",
        "description": "Whether a SelfControl block is running, every planned focus block for the next 7 days and "
                       "weekly schedule (with IDs and whether each can still be changed), which sites focus blocks "
                       "cover, and the limits. Call this before starting, planning or changing blocks.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        "annotations": {"readOnlyHint": True, "openWorldHint": False},
        "handler": tool_get_focus_status,
    },
    {
        "name": "start_focus_block",
        "title": "Start a focus block now",
        "description": "Block the user's distracting sites starting now, for the given number of minutes. "
                       "If a block is already running and ends sooner, it's extended. Can't be stopped or "
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
        "annotations": WRITE_HINTS,
        "handler": tool_start_focus_block,
    },
    {
        "name": "schedule_focus_blocks",
        "title": "Plan focus blocks on any day",
        "description": "Plan one-off focus blocks on any days up to a few weeks ahead, e.g. a week of deep-work "
                       "sessions. Each block starts on its own at its start time, even if no agent is running, "
                       "and is deleted once it's over. Times are local, 24-hour HH:MM; an end before the start "
                       "means it runs past midnight. Blocks can be moved or cancelled until 12 hours before they start.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "blocks": {
                    "type": "array",
                    "minItems": 1,
                    "maxItems": MAX_BLOCKS_PER_CALL,
                    "items": {
                        "type": "object",
                        "properties": {
                            "date": {"type": "string", "description": "Day of the block: " + DAY_DESCRIPTION + " Defaults to `day`."},
                            "start": {"type": "string", "pattern": TIME_PATTERN, "description": "Start time, HH:MM (24h)."},
                            "end": {"type": "string", "pattern": TIME_PATTERN, "description": "End time, HH:MM (24h)."},
                        },
                        "required": ["start", "end"],
                        "additionalProperties": False,
                    },
                },
                "day": {"type": "string", "default": "today", "description": "Day for blocks without their own date: " + DAY_DESCRIPTION},
                "reason": {"type": "string", "description": "Short label, e.g. 'deep work'."},
            },
            "required": ["blocks"],
            "additionalProperties": False,
        },
        "annotations": WRITE_HINTS,
        "handler": tool_schedule_focus_blocks,
    },
    {
        "name": "add_weekly_focus_schedule",
        "title": "Add a weekly focus schedule",
        "description": "Add a recurring focus window that repeats every week, e.g. weekdays 09:00-12:00. Starts "
                       "on its own each time. Use schedule_focus_blocks instead for one-off days.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "days": {"type": "string", "description": "Days it starts on: mon-fri, weekdays, weekends, daily, mon,wed,fri, ..."},
                "start": {"type": "string", "pattern": TIME_PATTERN, "description": "Start time, HH:MM (24h)."},
                "end": {"type": "string", "pattern": TIME_PATTERN, "description": "End time, HH:MM (24h)."},
                "name": {"type": "string", "description": "Short label, e.g. 'morning deep work'."},
            },
            "required": ["days", "start", "end"],
            "additionalProperties": False,
        },
        "annotations": WRITE_HINTS,
        "handler": tool_add_weekly_focus_schedule,
    },
    {
        "name": "change_focus_block",
        "title": "Move or retime a focus block or weekly schedule",
        "description": "Change when a planned block or weekly schedule runs: its day (date for a one-off, days "
                       "for weekly), start and/or end time, or name. Works on the user's own schedules too. Only "
                       "possible while whatever it takes away is more than 12 hours out (a running block, or one "
                       "starting within 12 hours, is locked), and it can't make a window longer than the limit.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "id": {"type": "string", "description": "Block or schedule ID from get_focus_status."},
                "date": {"type": "string", "description": "Move it to this day (makes it a one-off): " + DAY_DESCRIPTION},
                "days": {"type": "string", "description": "Make it weekly on these days: mon-fri, weekends, mon,wed,fri, ..."},
                "start": {"type": "string", "pattern": TIME_PATTERN, "description": "New start time, HH:MM (24h)."},
                "end": {"type": "string", "pattern": TIME_PATTERN, "description": "New end time, HH:MM (24h)."},
                "name": {"type": "string", "description": "New label."},
            },
            "required": ["id"],
            "additionalProperties": False,
        },
        "annotations": dict(WRITE_HINTS, destructiveHint=True),
        "handler": tool_change_focus_block,
    },
    {
        "name": "cancel_focus_block",
        "title": "Cancel a focus block or skip a day",
        "description": "Cancel a planned one-off block, skip one day of a weekly schedule (pass date), or delete a "
                       "whole weekly schedule (whole_schedule: true, only if the user asked). Only possible more "
                       "than 12 hours before the affected block starts; running blocks can't be cancelled.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "id": {"type": "string", "description": "Block or schedule ID from get_focus_status."},
                "date": {"type": "string", "description": "For a weekly schedule: the day to skip. " + DAY_DESCRIPTION},
                "whole_schedule": {"type": "boolean", "description": "Delete the entire weekly schedule instead of one day."},
            },
            "required": ["id"],
            "additionalProperties": False,
        },
        "annotations": dict(WRITE_HINTS, destructiveHint=True),
        "handler": tool_cancel_focus_block,
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
