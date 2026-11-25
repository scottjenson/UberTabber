import Foundation

/// Ranks entries against typed or spoken text. An entry's names (the tile
/// label, the start of a window title, the app name) count far more than the
/// rest of its title, so "projects" finds the Finder window "Projects" before
/// the tab "Stitch - Projects". Recency only breaks ties.
enum Matcher {
    /// Every word typed or spoken appears somewhere: enough to stay in a typed filter.
    static let allWordsMatch = 200

    static func rank(_ entry: Entry, _ query: String) -> Int {
        let q = words(query)
        // Speech splits compound names ("uber tabber" for UberTabber), so also try them joined.
        return q.count > 1 ? max(rank(entry, q), rank(entry, [q.joined()])) : rank(entry, q)
    }

    private static func rank(_ entry: Entry, _ q: [String]) -> Int {
        guard !q.isEmpty else { return 0 }
        let names = entry.names.map(words).filter { !$0.isEmpty }
        let nameWords = names.flatMap { $0 }
        let allWords = nameWords + words(entry.rest)
        func found(_ word: String, in pool: [String]) -> Bool { pool.contains { matches(word, $0) } }

        // 1. The query is a whole name.
        if names.contains(where: { $0.count == q.count && zip(q, $0).allSatisfy(same) }) { return 500 }
        // 2. A name starts with the query (the last word may be unfinished).
        if names.contains(where: { name in
            name.count >= q.count && q.indices.allSatisfy { i in
                i == q.count - 1 ? matches(q[i], name[i]) : same(q[i], name[i])
            }
        }) { return 400 }
        // 3. Every word is in the names, in any order.
        if q.allSatisfy({ found($0, in: nameWords) }) { return 300 }
        // 4. Every word is somewhere (rest of the title, domain).
        if q.allSatisfy({ found($0, in: allWords) }) { return allWordsMatch }
        // 5. Some words match (voice only; speech adds stray words). Words in a
        // name count double. Skip "a", "to", ….
        let useful = q.filter { $0.count >= 3 }
        return useful.filter { found($0, in: nameWords) }.count * 20
            + useful.filter { !found($0, in: nameWords) && found($0, in: allWords) }.count * 10
    }

    /// Typing: keep entries where every word matches, best first, then by recency.
    static func filter(_ entries: [Entry], _ query: String) -> [Entry] {
        let ranks = entries.map { rank($0, query) }
        let kept = entries.indices.filter { ranks[$0] >= allWordsMatch }
        let ordered = kept.sorted { a, b in ranks[a] != ranks[b] ? ranks[a] > ranks[b] : a < b }
        return ordered.map { entries[$0] }
    }

    /// Voice: index of the best match, if anything matches at all.
    static func best(_ entries: [Entry], _ spoken: String) -> Int? {
        let ranks = entries.map { rank($0, spoken) }
        guard let top = ranks.max(), top > 0 else { return nil }
        return ranks.firstIndex(of: top)
    }

    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// The same word, allowing a plural ending ("project" / "projects").
    private static func same(_ a: String, _ b: String) -> Bool {
        a == b || a + "s" == b || b + "s" == a || a + "es" == b || b + "es" == a
    }

    /// A query word matches the start of a title word ("proj" → "projects"),
    /// never the middle ("art" doesn't match "start").
    private static func matches(_ query: String, _ word: String) -> Bool {
        word.hasPrefix(query) || same(query, word)
    }
}
