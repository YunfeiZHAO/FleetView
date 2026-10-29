import Foundation

/// Card names are unique — across the board and the drawer of removed cards, ignoring case.
///
/// The name is how a card is found again: ⌘K, the drawer, `project-manager`. On 2026-10-30, 53
/// names were each held by more than one card, 144 rows between them — `FleetView-2` eight times,
/// because the default number counted the cards open *now* and started again from 1 once a
/// project's cards had been removed, and a duplicate or fork of `X` was always `X ⑂`. Looking a
/// card up by name meant guessing between identical rows.
///
/// A name that is taken gets the time after it. A time rather than a counter, because it means
/// something on its own: which of two `tasks` you want is usually "the one from Tuesday night".
enum TerminalNames {

    /// What two names are compared by. Case-folded because search is: two names that one query
    /// cannot tell apart are the same name for the purpose of finding a card.
    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// `name` when nothing holds it, else `name · MM-dd HH:mm` — with seconds, then a count, only
    /// when that is taken too, because several cards made in one go (a cluster restored, a batch
    /// from the web) land in the same minute.
    static func unique(_ name: String, at date: Date, taken: Set<String>) -> String {
        if !taken.contains(key(name)) { return name }
        // Trimmed before the time goes on: `tasks ` would otherwise become `tasks  · …`, a name
        // that compares as different and reads as the same.
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let minute = "\(base) · \(stamp(date, "MM-dd HH:mm"))"
        if !taken.contains(key(minute)) { return minute }
        let second = "\(base) · \(stamp(date, "MM-dd HH:mm:ss"))"
        var candidate = second
        var n = 2
        while taken.contains(key(candidate)) { candidate = "\(second) #\(n)"; n += 1 }
        return candidate
    }

    /// One card's hold on a name, and the time its name gets if it has to give the name up.
    struct Claim {
        let id: UUID
        let name: String
        let since: Date
    }

    /// The names that already clash, resolved: the first claim to a name keeps it and every later
    /// one gets its time. Aligned with `claims`; nil where a name stays as it is.
    ///
    /// The same id twice is one card listed in two places (on the board and still in the drawer),
    /// not a clash.
    static func deduplicated(_ claims: [Claim]) -> [String?] {
        var taken = Set(claims.map { key($0.name) })
        var holder: [String: UUID] = [:]
        return claims.map { c in
            let k = key(c.name)
            guard let first = holder[k] else { holder[k] = c.id; return nil }
            if first == c.id { return nil }
            let name = unique(c.name, at: c.since, taken: taken)
            taken.insert(key(name))
            holder[key(name)] = c.id
            return name
        }
    }

    /// `n` for a default name, `<project>-<n>`; nil for any other name.
    static func defaultNumber(_ name: String, project: String) -> Int? {
        let prefix = project + "-"
        guard name.hasPrefix(prefix), let n = Int(name.dropFirst(prefix.count)), n > 0 else { return nil }
        return n
    }

    private static func stamp(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: date)
    }
}
