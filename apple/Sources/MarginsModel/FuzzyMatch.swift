import Foundation

/// Subsequence matching for the command palette: a query scores against a
/// candidate only when its characters appear in order. Matching folds case
/// and diacritics so "bronte" finds "Brontë". The score rewards the kinds
/// of matches people mean — prefixes, word starts, and consecutive runs —
/// and mildly penalizes gaps and long candidates.
public enum FuzzyMatch {
    /// Higher is better; `nil` when `query` is not a subsequence of
    /// `candidate`. An empty query scores 0 (it trivially matches).
    public static func score(_ query: String, in candidate: String) -> Int? {
        let needle = Array(Self.fold(query))
        if needle.isEmpty { return 0 }
        let hay = Array(Self.fold(candidate))
        if needle.count > hay.count { return nil }

        var score = 0
        var qi = 0
        var previous = -2
        for (index, character) in hay.enumerated() where qi < needle.count {
            guard character == needle[qi] else { continue }
            score += 10
            if index == 0 {
                score += 10  // prefix
            } else if isBoundary(hay, before: index) {
                score += 8  // word start
            }
            if index == previous + 1 {
                score += 6
            } else if previous >= 0 {
                score -= min(index - previous - 1, 4)
            }
            previous = index
            qi += 1
        }
        guard qi == needle.count else { return nil }
        return score - hay.count / 8
    }

    private static func fold(_ string: String) -> String {
        string.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    /// A word start: the first character, or one after a separator.
    private static func isBoundary(_ characters: [Character], before index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = characters[index - 1]
        return previous == " " || previous.isPunctuation
    }
}
