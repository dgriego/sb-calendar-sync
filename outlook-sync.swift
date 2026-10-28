// outlook-sync — for every day that has an "S" event in your Exchange
// calendar, create an 8-hour event in your Apple "Work" calendar that starts
// when "S" ends. A day only counts if it also has a "coverage" event. Days
// without "S" or coverage, or with an "off" event, get no event.
//
// Usage:
//   outlook-sync --list-calendars        show calendar names + accounts
//   outlook-sync --dry-run               show what would change, change nothing
//   outlook-sync --dry-run --verbose     also list every Exchange event and why it was used or skipped
//   outlook-sync                         sync
//   outlook-sync --config /path/to.json  use a different config file
//   outlook-sync --help                  show all commands
//
// Each event the script creates is tagged with an "outlook-sync://" URL, so
// it only updates or deletes its own events. If "S" moves, the Work event
// moves with it; if "S" is deleted, the Work event for that day is removed
// once "S" has been missing for two runs in a row.
// Anything else in the Work calendar is left alone.

import EventKit
import Foundation

// MARK: - Config

struct Config: Codable {
    var sourceCalendar: String
    var sourceAccount: String?
    var targetCalendar: String
    var targetAccount: String?
    var triggerTitle: String?      // default "S"
    var offTitle: String?          // default "off"
    var coverageTitle: String?     // default "coverage"
    var eventTitle: String?        // default "SB"
    var durationHours: Double?     // default 8
    var location: String?
    var daysBack: Int?             // default 7
    var daysAhead: Int?            // default 21
    var scheduleEveryDays: Int?    // default 1, for scheduled runs
}

// Colors only in an interactive terminal, so the launchd log stays plain.
// Set NO_COLOR to turn them off.
let useColor = isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

enum Color: String {
    case red = "31", green = "32", yellow = "33", magenta = "35", cyan = "36", bold = "1", dim = "2"
}

func paint(_ text: String, _ color: Color) -> String {
    useColor ? "\u{1B}[\(color.rawValue)m\(text)\u{1B}[0m" : text
}

/// Used when a setting is left out of the config.
enum Default {
    static let triggerTitle = "S"
    static let offTitle = "off"
    static let coverageTitle = "coverage"
    static let eventTitle = "SB"
    static let durationHours = 8.0
    static let daysBack = 7
    static let daysAhead = 21
    static let scheduleEveryDays = 1
}

func log(_ message: String, _ color: Color? = nil) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("\(paint("[\(ts)]", .dim)) \(color.map { paint(message, $0) } ?? message)")
}

func fail(_ message: String) -> Never {
    log("ERROR: \(message)", .red)
    exit(1)
}

// MARK: - Args

let args = Array(CommandLine.arguments.dropFirst())
let dryRun = args.contains("--dry-run")
let listOnly = args.contains("--list-calendars")
let verbose = args.contains("--verbose")
let scheduled = args.contains("--scheduled")   // passed by launchd, see install.sh
var configPath = NSString(string: "~/.config/outlook-sync/config.json").expandingTildeInPath
if let i = args.firstIndex(of: "--config"), i + 1 < args.count {
    configPath = NSString(string: args[i + 1]).expandingTildeInPath
}

let helpText = """
\(paint("outlook-sync", .bold)) — for every day with an "S" in Exchange, add an "SB" event to your Work calendar

\(paint("Commands", .bold))
  outlook-sync                         sync now (counts as today's scheduled sync)
  outlook-sync --dry-run               show what would change, change nothing
  outlook-sync --dry-run --verbose     also list every Exchange event and why it was used or skipped
  outlook-sync --list-calendars        show calendar names + accounts (for the config)
  outlook-sync --show-config           show your settings, last sync and whether it's scheduled
  outlook-sync --config /path/to.json  use a different config file
  outlook-sync --help                  show this help

\(paint("Scheduling", .bold)) (run from the repo folder)
  ./install.sh build                   rebuild after changing the code
  ./install.sh schedule                sync once every scheduleEveryDays (config), checked hourly
  ./install.sh unschedule              stop the scheduled runs
  ./install.sh reset-config            replace your config with the example (backs up the old one)

\(paint("Files", .bold))
  Config    ~/.config/outlook-sync/config.json
  Log       ~/Library/Logs/outlook-sync.log
  Last run  ~/.config/outlook-sync/last-run   (delete it to make the next scheduled check sync)

\(paint("Colors", .bold))
  \(paint("green", .green)) added or already there   \(paint("yellow", .yellow)) moved   \(paint("red", .red)) removed
  \(paint("yellow", .yellow)) also: "S" but no coverage yet, not added
  \(paint("magenta", .magenta)) "S" or coverage gone, removed next run if still gone   \(paint("cyan", .cyan)) off day   \(paint("gray", .dim)) no "S"
"""

if args.contains("--help") || args.contains("-h") {
    print(helpText)
    exit(0)
}

// Stop on a mistyped option rather than doing a real sync (e.g. "--dryrun").
let knownArgs: Set<String> = ["--dry-run", "--list-calendars", "--verbose", "--config", "--scheduled", "--show-config"]
for (i, arg) in args.enumerated() where !knownArgs.contains(arg) && !(i > 0 && args[i - 1] == "--config") {
    print(paint("Unknown option: \(arg)", .red) + "\n")
    print(helpText)
    exit(1)
}

// MARK: - Show config

if args.contains("--show-config") {
    guard let data = FileManager.default.contents(atPath: configPath) else {
        fail("Config not found at \(configPath). Run ./install.sh build or ./install.sh reset-config.")
    }
    let c: Config
    do { c = try JSONDecoder().decode(Config.self, from: data) } catch { fail("Couldn't read config: \(error)") }

    func row(_ key: String, _ value: Any?, default fallback: Any? = nil) {
        let name = key.padding(toLength: 20, withPad: " ", startingAt: 0)
        if let value, "\(value)" != "" {
            print("  \(name)\(value)")
        } else if let fallback {
            print("  \(name)\(fallback)  \(paint("(default)", .dim))")
        } else {
            print("  \(name)\(paint("(none)", .dim))")
        }
    }
    print(paint("Config", .bold) + "  \(configPath)")
    row("sourceCalendar", c.sourceCalendar)
    row("sourceAccount", c.sourceAccount)
    row("targetCalendar", c.targetCalendar)
    row("targetAccount", c.targetAccount)
    row("triggerTitle", c.triggerTitle, default: Default.triggerTitle)
    row("coverageTitle", c.coverageTitle, default: Default.coverageTitle)
    row("offTitle", c.offTitle, default: Default.offTitle)
    row("eventTitle", c.eventTitle, default: Default.eventTitle)
    row("durationHours", c.durationHours.map { $0 == $0.rounded() ? "\(Int($0))" : "\($0)" }, default: Int(Default.durationHours))
    row("location", c.location)
    row("daysBack", c.daysBack, default: Default.daysBack)
    row("daysAhead", c.daysAhead, default: Default.daysAhead)
    row("scheduleEveryDays", c.scheduleEveryDays, default: Default.scheduleEveryDays)

    let lastRunPath = (configPath as NSString).deletingLastPathComponent + "/last-run"
    let shown = DateFormatter()
    shown.dateStyle = .medium
    shown.timeStyle = .short
    let last = (try? String(contentsOfFile: lastRunPath, encoding: .utf8))
        .flatMap { ISO8601DateFormatter().date(from: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    print("\n" + paint("Last sync", .bold) + "  \(last.map { shown.string(from: $0) } ?? "never")")

    let agent = NSString(string: "~/Library/LaunchAgents/com.daniel.outlook-sync.plist").expandingTildeInPath
    let days = c.scheduleEveryDays ?? Default.scheduleEveryDays
    print(paint("Schedule", .bold) + "   " + (FileManager.default.fileExists(atPath: agent)
        ? paint("on", .green) + " — once \(days == 1 ? "a day" : "every \(days) days"), checked hourly"
        : paint("off", .yellow) + " — run ./install.sh schedule to turn it on"))
    exit(0)
}

// MARK: - Once-per-day check

// launchd starts scheduled runs every hour. A scheduled run only syncs if the
// last real sync was at least scheduleEveryDays calendar days ago; otherwise
// it exits before touching the calendars. Manual runs always sync.
let lastRunPath = (configPath as NSString).deletingLastPathComponent + "/last-run"

func lastRunDate() -> Date? {
    guard let text = try? String(contentsOfFile: lastRunPath, encoding: .utf8) else { return nil }
    return ISO8601DateFormatter().date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
}

if scheduled, let last = lastRunDate() {
    let json = FileManager.default.contents(atPath: configPath)
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let everyDays = max((json?["scheduleEveryDays"] as? Int) ?? Default.scheduleEveryDays, 1)
    let cal = Calendar.current
    let elapsed = cal.dateComponents([.day], from: cal.startOfDay(for: last), to: cal.startOfDay(for: Date())).day ?? 0
    // A last run in the future (clock changed) doesn't block syncing.
    if elapsed >= 0 && elapsed < everyDays && last <= Date() { exit(0) }
}

// MARK: - Calendar access

final class Box { var granted = false }

func requestAccess(_ store: EKEventStore) -> Bool {
    let sema = DispatchSemaphore(value: 0)
    let box = Box()
    let done: (Bool, Error?) -> Void = { granted, error in
        box.granted = granted
        if let error { log("Access error: \(error.localizedDescription)") }
        sema.signal()
    }
    if #available(macOS 14.0, *) {
        store.requestFullAccessToEvents(completion: done)
    } else {
        store.requestAccess(to: .event, completion: done)
    }
    sema.wait()
    return box.granted
}

let store = EKEventStore()
guard requestAccess(store) else {
    fail("No calendar access. Allow it in System Settings → Privacy & Security → Calendars (Full Access), then run again.")
}
store.reset()

func sourceTypeName(_ t: EKSourceType) -> String {
    switch t {
    case .local: return "On My Mac"
    case .exchange: return "Exchange"
    case .calDAV: return "CalDAV/iCloud"
    case .mobileMe: return "iCloud (legacy)"
    case .subscribed: return "Subscribed"
    case .birthdays: return "Birthdays"
    @unknown default: return "Other"
    }
}

if listOnly {
    let cals = store.calendars(for: .event).sorted {
        ($0.source.title, $0.title) < ($1.source.title, $1.title)
    }
    print("Calendar name  —  account  [type]")
    for c in cals {
        let ro = c.allowsContentModifications ? "" : "  (read-only)"
        print("  \(c.title)  —  \(c.source.title)  [\(sourceTypeName(c.source.sourceType))]\(ro)")
    }
    exit(0)
}

// MARK: - Load config

guard let data = FileManager.default.contents(atPath: configPath) else {
    fail("Config not found at \(configPath)")
}
let cfg: Config
do {
    cfg = try JSONDecoder().decode(Config.self, from: data)
} catch {
    fail("Couldn't read config: \(error)")
}

func normalized(_ title: String?) -> String {
    (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

let triggerTitle = normalized(cfg.triggerTitle ?? Default.triggerTitle)
let offTitle = normalized(cfg.offTitle ?? Default.offTitle)
let coverageTitle = normalized(cfg.coverageTitle ?? Default.coverageTitle)
let eventTitle = cfg.eventTitle ?? Default.eventTitle
let duration = (cfg.durationHours ?? Default.durationHours) * 3600
let eventLocation = cfg.location.flatMap { $0.isEmpty ? nil : $0 }
let daysBack = cfg.daysBack ?? Default.daysBack
let daysAhead = cfg.daysAhead ?? Default.daysAhead

guard !triggerTitle.isEmpty else { fail("triggerTitle can't be empty.") }
guard !offTitle.isEmpty, offTitle != triggerTitle else { fail("offTitle can't be empty or the same as triggerTitle.") }
guard !coverageTitle.isEmpty, coverageTitle != triggerTitle, coverageTitle != offTitle else {
    fail("coverageTitle can't be empty or the same as triggerTitle or offTitle.")
}
guard duration > 0, duration <= 24 * 3600 else { fail("durationHours must be more than 0 and at most 24.") }
guard (0...365).contains(daysBack) else { fail("daysBack must be between 0 and 365.") }
guard (1...365).contains(daysAhead) else { fail("daysAhead must be between 1 and 365.") }
guard (1...365).contains(cfg.scheduleEveryDays ?? Default.scheduleEveryDays) else { fail("scheduleEveryDays must be between 1 and 365.") }

func findCalendar(name: String, account: String?, role: String) -> EKCalendar {
    let matches = store.calendars(for: .event).filter {
        $0.title == name && (account == nil || $0.source.title == account)
    }
    if matches.isEmpty {
        fail("\(role) calendar \"\(name)\"\(account.map { " in account \"\($0)\"" } ?? "") not found. Run with --list-calendars.")
    }
    if matches.count > 1 {
        let accts = matches.map { $0.source.title }.joined(separator: ", ")
        fail("More than one calendar is named \"\(name)\" (accounts: \(accts)). Set \(role.lowercased())Account in the config.")
    }
    return matches[0]
}

let source = findCalendar(name: cfg.sourceCalendar, account: cfg.sourceAccount, role: "Source")
let target = findCalendar(name: cfg.targetCalendar, account: cfg.targetAccount, role: "Target")
guard source.calendarIdentifier != target.calendarIdentifier else {
    fail("Source and target are the same calendar.")
}
guard target.allowsContentModifications else {
    fail("Target calendar \"\(target.title)\" is read-only.")
}

// MARK: - Helpers

let cal = Calendar.current

let markerScheme = "outlook-sync"

let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

/// `missing` records that "S" was gone on the last run, so the event is only
/// removed if it's still gone on the next one.
func markerURL(day: String, missing: Bool = false) -> URL? {
    var c = URLComponents()
    c.scheme = markerScheme
    c.host = "shift"
    c.queryItems = [URLQueryItem(name: "day", value: day)]
    if missing { c.queryItems?.append(URLQueryItem(name: "missing", value: "1")) }
    return c.url
}

func dayFromMarker(_ url: URL?) -> String? {
    guard let url, url.scheme == markerScheme, url.host == "shift",
          let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    return c.queryItems?.first(where: { $0.name == "day" })?.value
}

func isMarkedMissing(_ url: URL?) -> Bool {
    guard let url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
    return c.queryItems?.contains(where: { $0.name == "missing" }) == true
}

/// Why an event titled "S" doesn't count, or nil if it does.
func triggerSkipReason(_ ev: EKEvent) -> String? {
    if ev.isAllDay { return "all-day" }
    if ev.status == .canceled { return "canceled" }
    // Only events you made yourself. Invites from others always have an
    // organizer who isn't you; your own events have no organizer or you.
    if let organizer = ev.organizer, !organizer.isCurrentUser {
        return "invite from \(organizer.name ?? "someone else")"
    }
    return nil
}

func isTrigger(_ ev: EKEvent) -> Bool {
    normalized(ev.title) == triggerTitle && triggerSkipReason(ev) == nil
}

/// "off" events count whoever made them and can be all-day or span several days.
func isOff(_ ev: EKEvent) -> Bool {
    ev.status != .canceled && normalized(ev.title) == offTitle
}

/// "coverage" events count whoever made them and can be all-day or span several days.
func isCoverage(_ ev: EKEvent) -> Bool {
    ev.status != .canceled && normalized(ev.title) == coverageTitle
}

/// Every day an event touches, e.g. an all-day "off" from 11/12 to 11/15.
func days(of ev: EKEvent) -> [String] {
    var result: [String] = []
    var d = cal.startOfDay(for: ev.startDate)
    repeat {
        result.append(dayFormatter.string(from: d))
        d = cal.date(byAdding: .day, value: 1, to: d)!
    } while d < ev.endDate
    return result
}

/// Sets d to start at `start` and run for `duration`. Returns true if anything changed.
func apply(start: Date, timeZone: TimeZone?, to d: EKEvent) -> Bool {
    let end = start.addingTimeInterval(duration)
    var changed = false
    if d.title != eventTitle { d.title = eventTitle; changed = true }
    if d.isAllDay { d.isAllDay = false; changed = true }
    if d.startDate != start { d.startDate = start; changed = true }
    if d.endDate != end { d.endDate = end; changed = true }
    if (d.location.flatMap { $0.isEmpty ? nil : $0 }) != eventLocation { d.location = eventLocation; changed = true }
    if let tz = timeZone, d.timeZone?.identifier != tz.identifier { d.timeZone = tz; changed = true }
    return changed
}

let df = DateFormatter()
df.dateStyle = .short
df.timeStyle = .short
func describe(_ ev: EKEvent) -> String {
    "\"\(ev.title ?? "")\" \(df.string(from: ev.startDate)) – \(df.string(from: ev.endDate))"
}

// MARK: - Sync

let now = Date()
let windowStart = cal.date(byAdding: .day, value: -daysBack, to: cal.startOfDay(for: now))!
let windowEnd = cal.date(byAdding: .day, value: daysAhead, to: cal.startOfDay(for: now))!

let srcEvents = store.events(matching: store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: [source]))
// Look a little past the window on the Work side, since a shift that starts
// late on the last day runs into the next day.
let dstEvents = store.events(matching: store.predicateForEvents(
    withStart: windowStart, end: windowEnd.addingTimeInterval(duration), calendars: [target]))

var offDays = Set<String>()
for ev in srcEvents where isOff(ev) { offDays.formUnion(days(of: ev)) }
var coverageDays = Set<String>()
for ev in srcEvents where isCoverage(ev) { coverageDays.formUnion(days(of: ev)) }

if verbose {
    log("Exchange events from \(dayFormatter.string(from: windowStart)) up to \(dayFormatter.string(from: windowEnd)):")
    for ev in srcEvents.sorted(by: { $0.startDate < $1.startDate }) {
        let day = dayFormatter.string(from: ev.startDate)
        let verdict: String
        if isOff(ev) {
            verdict = "off day"
        } else if isCoverage(ev) {
            verdict = "coverage"
        } else if normalized(ev.title) != triggerTitle {
            verdict = "ignored (title isn't \"\(cfg.triggerTitle ?? Default.triggerTitle)\")"
        } else if let reason = triggerSkipReason(ev) {
            verdict = "skipped: \(reason)"
        } else if offDays.contains(day) {
            verdict = "skipped: day is off"
        } else if !coverageDays.contains(day) {
            verdict = "skipped: no \"\(cfg.coverageTitle ?? Default.coverageTitle)\" event that day"
        } else {
            verdict = "counts"
        }
        let color: Color = verdict == "counts" || verdict == "coverage" ? .green : verdict == "off day" ? .cyan
            : verdict.hasPrefix("ignored") ? .dim : .yellow
        print("  \(day)  \(describe(ev))\(ev.isAllDay ? " (all-day)" : "")  →  \(paint(verdict, color))")
    }
}

// One "S" per day: the day is the day "S" starts on. If there are several,
// use the earliest one. Days with an "off" event are skipped, and so are
// days with no "coverage" event yet.
var triggers: [String: EKEvent] = [:]
var noCoverageDays = Set<String>()
for ev in srcEvents where isTrigger(ev) {
    guard ev.startDate >= windowStart, ev.startDate < windowEnd else { continue }
    let day = dayFormatter.string(from: ev.startDate)
    if offDays.contains(day) { continue }
    if !coverageDays.contains(day) { noCoverageDays.insert(day); continue }
    if let existing = triggers[day] {
        log("warning: more than one \"\(cfg.triggerTitle ?? Default.triggerTitle)\" on \(day); using the earliest", .yellow)
        if ev.startDate < existing.startDate { triggers[day] = ev }
    } else {
        triggers[day] = ev
    }
}

var existing: [String: EKEvent] = [:]
var duplicates: [EKEvent] = []
for ev in dstEvents {
    guard let day = dayFromMarker(ev.url) else { continue } // not ours — never touched
    if existing[day] != nil { duplicates.append(ev) } else { existing[day] = ev }
}

log("\(dryRun ? "DRY RUN — " : "")\(source.title) (\(source.source.title)) → \(target.title) (\(target.source.title)): \(triggers.count) day(s) with \"\(cfg.triggerTitle ?? Default.triggerTitle)\"")

var created = 0, updated = 0, removed = 0

// What happened to each day, for the summary at the end.
var outcome: [String: (text: String, color: Color)] = [:]
func did(_ past: String, _ base: String) -> String { dryRun ? "would \(base)" : past }

let timeOnly = DateFormatter()
timeOnly.dateStyle = .none
timeOnly.timeStyle = .short
func span(_ ev: EKEvent) -> String {
    "\(ev.title ?? "") \(timeOnly.string(from: ev.startDate))–\(timeOnly.string(from: ev.endDate))"
}

do {
    for day in triggers.keys.sorted() {
        let s = triggers[day]!
        if let d = existing[day] {
            var changed = apply(start: s.endDate, timeZone: s.timeZone, to: d)
            if isMarkedMissing(d.url) { d.url = markerURL(day: day); changed = true }
            if changed {
                if !dryRun { try store.save(d, span: .thisEvent, commit: false) }
                updated += 1
                log("update  \(day)  \(describe(d))", .yellow)
                outcome[day] = ("\(did("updated", "update"))  \(span(d))", .yellow)
            } else {
                outcome[day] = ("already there  \(span(d))", .green)
            }
        } else {
            let d = EKEvent(eventStore: store)
            d.calendar = target
            d.url = markerURL(day: day)
            _ = apply(start: s.endDate, timeZone: s.timeZone, to: d)
            if !dryRun { try store.save(d, span: .thisEvent, commit: false) }
            created += 1
            log("create  \(day)  \(describe(d))", .green)
            outcome[day] = ("\(did("added", "add"))  \(span(d))", .green)
        }
    }

    // Days marked "off": remove our event right away. Seeing "off" is a
    // deliberate signal, not a sync hiccup, so there's no waiting.
    let offRemovals = existing.filter { day, _ in offDays.contains(day) }
    for (day, d) in offRemovals.sorted(by: { $0.key < $1.key }) {
        log("remove  \(day)  \(describe(d))  (day is off)", .red)
        outcome[day] = ("off — \(did("removed", "remove")) \(eventTitle)", .red)
        if !dryRun { try store.remove(d, span: .thisEvent, commit: false) }
        removed += 1
    }

    // Days where "S" disappeared: remove our event. Only for days inside the
    // window, only once "S" has been missing for two runs in a row, and never
    // if Exchange returned nothing at all (e.g. not synced yet), so a sync
    // hiccup can't wipe the Work calendar.
    let stale = existing.filter { day, ev in
        triggers[day] == nil && !offDays.contains(day)
            && dayFormatter.date(from: day).map { $0 >= windowStart && $0 < windowEnd } == true
    }

    if srcEvents.isEmpty && !stale.isEmpty {
        log("Exchange returned no events; skipping deletions to be safe.", .yellow)
        for day in stale.keys { outcome[day] = ("kept \(eventTitle) — Exchange returned nothing", .yellow) }
    } else {
        for d in duplicates {
            log("remove  \(describe(d))  (duplicate)", .red)
            if !dryRun { try store.remove(d, span: .thisEvent, commit: false) }
            removed += 1
        }
        for (day, d) in stale.sorted(by: { $0.key < $1.key }) {
            let why = noCoverageDays.contains(day) ? "no \(cfg.coverageTitle ?? Default.coverageTitle)" : "no \(cfg.triggerTitle ?? Default.triggerTitle)"
            if isMarkedMissing(d.url) {
                log("remove  \(day)  \(describe(d))  (\(why))", .red)
                outcome[day] = ("\(why) — \(did("removed", "remove")) \(eventTitle)", .red)
                if !dryRun { try store.remove(d, span: .thisEvent, commit: false) }
                removed += 1
            } else {
                log("missing \(day)  \(why); will remove next run if still missing", .magenta)
                outcome[day] = ("\(why) — \(eventTitle) removed next run if still gone", .magenta)
                d.url = markerURL(day: day, missing: true)
                if !dryRun { try store.save(d, span: .thisEvent, commit: false) }
            }
        }
    }

    if !dryRun {
        try store.commit()
        // Only after a successful sync, so a failed run is retried at the next hourly check.
        do {
            try ISO8601DateFormatter().string(from: Date()).write(toFile: lastRunPath, atomically: true, encoding: .utf8)
        } catch {
            log("warning: couldn't save the last-run time to \(lastRunPath): \(error.localizedDescription)", .yellow)
        }
    }
} catch {
    fail("Saving failed: \(error.localizedDescription)")
}

// Every day that was checked, oldest first.
let weekday = DateFormatter()
weekday.dateFormat = "EEE"
print(paint("Days checked:", .bold))
var day = windowStart
while day < windowEnd {
    let key = dayFormatter.string(from: day)
    let (text, color) = outcome[key]
        ?? (offDays.contains(key) ? ("off", .cyan)
            : noCoverageDays.contains(key) ? ("\(cfg.triggerTitle ?? Default.triggerTitle) but no \(cfg.coverageTitle ?? Default.coverageTitle) yet — not added", .yellow)
            : ("no \(cfg.triggerTitle ?? Default.triggerTitle)", .dim))
    let label = "\(weekday.string(from: day)) \(key)"
    print("  \(cal.isDateInToday(day) ? paint(label, .bold) : label)  \(paint(text, color))")
    day = cal.date(byAdding: .day, value: 1, to: day)!
}

log("\(dryRun ? "Dry run done, nothing changed. Would have" : "Done:") \(created) created, \(updated) updated, \(removed) removed", .bold)
