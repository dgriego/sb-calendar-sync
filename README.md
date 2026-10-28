# outlook-sync

For every day that has an event named **"S"** in your Exchange calendar, this
creates an **8-hour event titled "SB" in your Apple "Work" calendar** that starts when "S"
ends. Days without "S" get nothing.

It keeps things in sync on every run:
- "S" moves or its end time changes → the Work event moves with it
- "S" is deleted → that day's Work event is removed on the next run that
  still can't find it (so a half-finished Exchange sync can't delete anything)
- Anything else in your Work calendar (events you made yourself) is never touched

Requires macOS with Xcode Command Line Tools (`xcode-select --install`).

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
   ./install.sh schedule          # every 30 min; INTERVAL=900 for 15 min
   ```
   When it runs on a schedule, macOS asks again whether to let *outlook-sync*
   access your calendars. Click Allow.

## Config options

| Key | Default | What it does |
|---|---|---|
| `triggerTitle` | `"S"` | Title of the Exchange event to look for (exact match, ignores case and spaces around it) |
| `eventTitle` | `"SB"` | Title of the event created in your Work calendar |
| `durationHours` | `8` | Length of the created event, up to 24 (`8.5` works too) |
| `location` | none | Optional location to put on the created event |
| `daysBack` / `daysAhead` | `7` / `60` | Which days to sync (0–365 back, 1–365 ahead) |

Notes:
- The day an "S" event belongs to is the day it starts on. If a day somehow has
  two, the earliest one is used and the log shows a warning.
- All-day and canceled "S" events are ignored.
- Only "S" events you made yourself count. Invites from other people named
  "S" are ignored.
- Apple Calendar can't see Outlook categories, so the script matches on the
  title "S", not on the "Start" category.

## Troubleshooting

- **Log:** `~/Library/Logs/outlook-sync.log`
- **"No calendar access":** System Settings → Privacy & Security → Calendars →
  turn on outlook-sync (or Terminal, if you ran it from Terminal). If you rebuild
  the binary, you may need to allow it again.
- **Stop syncing:** `./install.sh unschedule`. Events already created stay in
  your Work calendar until you delete them.
