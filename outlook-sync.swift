// outlook-sync — for every day that has an "S" event in your Exchange
// calendar, create an 8-hour event in your Apple "Work" calendar that starts
// when "S" ends. Days without "S" get no event.
//
// Usage:
//   outlook-sync --list-calendars        show calendar names + accounts
//   outlook-sync --dry-run               show what would change, change nothing
//   outlook-sync                         sync
//   outlook-sync --config /path/to.json  use a different config file
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
    var eventTitle: String?        // default "SB"
    var durationHours: Double?     // default 8
    var location: String?
    var daysBack: Int?             // default 7
    var daysAhead: Int?            // default 60
}

func log(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("[\(ts)] \(message)")
}

func fail(_ message: String) -> Never {
    log("ERROR: \(message)")
    exit(1)
}

// MARK: - Args

let args = Array(CommandLine.arguments.dropFirst())
let dryRun = args.contains("--dry-run")
let listOnly = args.contains("--list-calendars")
var configPath = NSString(string: "~/.config/outlook-sync/config.json").expandingTildeInPath
if let i = args.firstIndex(of: "--config"), i + 1 < args.count {
    configPath = NSString(string: args[i + 1]).expandingTildeInPath
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

let triggerTitle = (cfg.triggerTitle ?? "S").trimmingCharacters(in: .whitespaces).lowercased()
let eventTitle = cfg.eventTitle ?? "SB"
let duration = (cfg.durationHours ?? 8) * 3600
let eventLocation = cfg.location.flatMap { $0.isEmpty ? nil : $0 }
let daysBack = cfg.daysBack ?? 7
let daysAhead = cfg.daysAhead ?? 60

guard !triggerTitle.isEmpty else { fail("triggerTitle can't be empty.") }
guard duration > 0, duration <= 24 * 3600 else { fail("durationHours must be more than 0 and at most 24.") }
guard (0...365).contains(daysBack) else { fail("daysBack must be between 0 and 365.") }
guard (1...365).contains(daysAhead) else { fail("daysAhead must be between 1 and 365.") }

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

func isTrigger(_ ev: EKEvent) -> Bool {
    guard !ev.isAllDay, ev.status != .canceled else { return false }
    // Only events you made yourself. Invites from others always have an
    // organizer who isn't you; your own events have no organizer or you.
    if let organizer = ev.organizer, !organizer.isCurrentUser { return false }
    return (ev.title ?? "").trimmingCharacters(in: .whitespaces).lowercased() == triggerTitle
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

let cal = Calendar.current
let now = Date()
let windowStart = cal.date(byAdding: .day, value: -daysBack, to: cal.startOfDay(for: now))!
let windowEnd = cal.date(byAdding: .day, value: daysAhead, to: cal.startOfDay(for: now))!

let srcEvents = store.events(matching: store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: [source]))
// Look a little past the window on the Work side, since a shift that starts
// late on the last day runs into the next day.
let dstEvents = store.events(matching: store.predicateForEvents(
    withStart: windowStart, end: windowEnd.addingTimeInterval(duration), calendars: [target]))

// One "S" per day: the day is the day "S" starts on. If there are several,
// use the earliest one.
var triggers: [String: EKEvent] = [:]
for ev in srcEvents where isTrigger(ev) {
    guard ev.startDate >= windowStart, ev.startDate < windowEnd else { continue }
    let day = dayFormatter.string(from: ev.startDate)
    if let existing = triggers[day] {
        log("warning: more than one \"\(cfg.triggerTitle ?? "S")\" on \(day); using the earliest")
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

log("\(dryRun ? "DRY RUN — " : "")\(source.title) (\(source.source.title)) → \(target.title) (\(target.source.title)): \(triggers.count) day(s) with \"\(cfg.triggerTitle ?? "S")\"")

var created = 0, updated = 0, removed = 0

do {
    for day in triggers.keys.sorted() {
        let s = triggers[day]!
        if let d = existing[day] {
            var changed = apply(start: s.endDate, timeZone: s.timeZone, to: d)
            if isMarkedMissing(d.url) { d.url = markerURL(day: day); changed = true }
            if changed {
                if !dryRun { try store.save(d, span: .thisEvent, commit: false) }
                updated += 1
                log("update  \(day)  \(describe(d))")
            }
        } else {
            let d = EKEvent(eventStore: store)
            d.calendar = target
            d.url = markerURL(day: day)
            _ = apply(start: s.endDate, timeZone: s.timeZone, to: d)
            if !dryRun { try store.save(d, span: .thisEvent, commit: false) }
            created += 1
            log("create  \(day)  \(describe(d))")
        }
    }

    // Days where "S" disappeared: remove our event. Only for days inside the
    // window, only once "S" has been missing for two runs in a row, and never
    // if Exchange returned nothing at all (e.g. not synced yet), so a sync
    // hiccup can't wipe the Work calendar.
    let stale = existing.filter { day, ev in
        triggers[day] == nil
            && dayFormatter.date(from: day).map { $0 >= windowStart && $0 < windowEnd } == true
    }

    if srcEvents.isEmpty && !stale.isEmpty {
        log("Exchange returned no events; skipping deletions to be safe.")
    } else {
        for d in duplicates {
            log("remove  \(describe(d))  (duplicate)")
            if !dryRun { try store.remove(d, span: .thisEvent, commit: false) }
            removed += 1
        }
        for (day, d) in stale.sorted(by: { $0.key < $1.key }) {
            if isMarkedMissing(d.url) {
                log("remove  \(day)  \(describe(d))")
                if !dryRun { try store.remove(d, span: .thisEvent, commit: false) }
                removed += 1
            } else {
                log("missing \(day)  \"\(cfg.triggerTitle ?? "S")\" not found; will remove next run if still missing")
                d.url = markerURL(day: day, missing: true)
                if !dryRun { try store.save(d, span: .thisEvent, commit: false) }
            }
        }
    }

    if !dryRun { try store.commit() }
} catch {
    fail("Saving failed: \(error.localizedDescription)")
}

log("Done: \(created) created, \(updated) updated, \(removed) removed")
