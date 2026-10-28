# outlook-sync

For every day that has an event named **"S"** in your Exchange calendar, this
creates an **8-hour event titled "SB" in your Apple "Work" calendar** that starts when "S"
ends. A day only gets one if it also has a **"coverage"** event. Days without
"S" or coverage get nothing, and so do days with an event named **"off"**.

It keeps things in sync on every run:
- "S" moves or its end time changes → the Work event moves with it
- An "off" event is added for a day → that day's Work event is removed
- "S" is there but no coverage event yet → nothing is added until coverage shows up
- "S" is deleted → that day's Work event is removed on the next run that
  still can't find it (so a half-finished Exchange sync can't delete anything)
- Anything else in your Work calendar (events you made yourself) is never touched

Requires macOS with Xcode Command Line Tools (`xcode-select --install`).

Forgot a command? Run `~/.local/bin/outlook-sync --help`.

## Setup

1. **Build it.**
   ```bash
   chmod +x install.sh
   ./install.sh build
   ```

2. **Find your calendar names.**
   ```bash
   ~/.local/bin/outlook-sync --list-calendars
   ```
   The first run asks for calendar access (allow Full Access).

3. **Edit the config** at `~/.config/outlook-sync/config.json`:
   - `sourceCalendar` / `sourceAccount`: your Exchange calendar (often "Calendar" / "Exchange")
   - `targetCalendar` / `targetAccount`: your Work calendar (e.g. "Work" / "iCloud")

   Use the exact names from step 2. The account fields only matter if two
   calendars share a name. You can leave them out otherwise.

4. **Preview what it would create.**
   ```bash
   ~/.local/bin/outlook-sync --dry-run
   ```

5. **Run it for real, then schedule it.**
   ```bash
   ~/.local/bin/outlook-sync
   ./install.sh schedule          # once a day unless you change it (see below)
   ```
   When it runs on a schedule, macOS asks again whether to let *outlook-sync*
   access your calendars. Click Allow.

## Config options

| Key | Default | What it does |
|---|---|---|
| `triggerTitle` | `"S"` | Title of the Exchange event to look for (exact match, ignores case and spaces around it) |
| `offTitle` | `"off"` | Title of the Exchange event that marks a day off. Days it covers get no Work event |
| `coverageTitle` | `"coverage"` | Title of the Exchange event that must also be on an "S" day before SB is added |
| `eventTitle` | `"SB"` | Title of the event created in your Work calendar |
| `durationHours` | `8` | Length of the created event, up to 24 (`8.5` works too) |
| `location` | none | Optional location to put on the created event |
| `daysBack` / `daysAhead` | `7` / `21` | Which days to sync (0–365 back, 1–365 ahead) |

### When it runs

| Key | Default | What it does |
|---|---|---|
| `scheduleEveryDays` | `1` | Sync once every this many days (1–365) |

It doesn't run at login or startup. Instead, macOS starts it at the top of
every hour, and it checks `~/.config/outlook-sync/last-run`, the time of the
last successful sync. If it already synced within `scheduleEveryDays` (counting
calendar days, so `1` means once per day), it exits right away without
touching your calendars. So it syncs at the first hourly check of the day, or
the first one after the Mac wakes up. If a sync fails, the next hourly check
tries again.

Running `outlook-sync` by hand always syncs, and also counts as that day's
sync. Dry runs don't count. To force the next hourly check to sync, delete
`~/.config/outlook-sync/last-run`. Changes to `scheduleEveryDays` take effect
on the next check, no need to reschedule.

Removing an SB event after "S" or coverage disappears takes two syncs, so with
`3` that's up to 6 days.

Notes:
- The day an "S" event belongs to is the day it starts on. If a day somehow has
  two, the earliest one is used and the log shows a warning.
- All-day and canceled "S" events are ignored.
- "off" and "coverage" can be timed events, all-day events or span several
  days. They count no matter who made them. Both match the exact title,
  ignoring case and spaces around it.
- If coverage disappears from a day that already has SB, SB is removed the same
  way as when "S" disappears (on the next run that still can't find it).
- Only "S" events you made yourself count. Invites from other people named
  "S" are ignored.
- Apple Calendar can't see Outlook categories, so the script matches on the
  title "S", not on the "Start" category.

## Output

Each run ends with a list of every day it checked and what happened:
**green** = SB added or already there, **yellow** = SB moved, or "S" but no coverage yet, **red** = SB
removed, **magenta** = "S" or coverage is gone and SB will be removed next run if it's still
gone, **cyan** = off day, **gray** = no "S". Colors only show in a terminal. The
scheduled log is plain text, and setting `NO_COLOR=1` turns colors off.

## Troubleshooting

- **A day you expected is missing:** run
  `~/.local/bin/outlook-sync --dry-run --verbose`. It lists every Exchange event
  in the window and why it was used or skipped.

- **Log:** `~/Library/Logs/outlook-sync.log`
- **"No calendar access":** System Settings → Privacy & Security → Calendars →
  turn on outlook-sync (or Terminal, if you ran it from Terminal). If you rebuild
  the binary, you may need to allow it again.
- **Stop syncing:** `./install.sh unschedule`. Events already created stay in
  your Work calendar until you delete them.
