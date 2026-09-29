import Foundation

// Shared text analysis for search (docs/commonplace.md "Analysis"): one
// pipeline produces the tokens the captured-search index and the query
// side both use, and the full-text index (a later slice) reuses it.
//
// - Tokens are runs of letters and digits; an internal `'`/`’` between two
//   letters stays inside the token ("don't" is one token).
// - The folded form is case- and diacritic-folded, loses a trailing 's,
//   and drops remaining apostrophes.
// - Stems are Porter2 (Snowball English) for all-ASCII-letter tokens; any
//   other token stems to its folded form.
// - `start16`/`end16` are UTF-16 offsets in the ORIGINAL text, so highlight
//   ranges always point at what the user sees.

/// One analyzed token: folded and stemmed forms for matching, plus its
/// half-open UTF-16 range in the original text.
struct AnalyzedToken: Sendable, Equatable {
    var folded: String
    var stem: String
    var start16: Int
    var end16: Int
}

enum TextAnalyzer {
    /// Tokenizes `text`, folding and stemming each token.
    static func tokens(_ text: String) -> [AnalyzedToken] {
        let characters = Array(text)
        var tokens: [AnalyzedToken] = []
        var raw = ""
        var start16 = 0
        var utf16 = 0
        var index = 0

        while index < characters.count {
            let character = characters[index]
            var isTokenCharacter = character.isLetter || character.isNumber
            if !isTokenCharacter, character == "'" || character == "’" {
                // An apostrophe survives only between two letters.
                isTokenCharacter =
                    !raw.isEmpty && raw.last?.isLetter == true
                    && index + 1 < characters.count && characters[index + 1].isLetter
            }
            if isTokenCharacter {
                if raw.isEmpty { start16 = utf16 }
                raw.append(character)
            } else if !raw.isEmpty {
                tokens.append(analyze(raw, start16: start16, end16: utf16))
                raw = ""
            }
            utf16 += character.utf16.count
            index += 1
        }
        if !raw.isEmpty {
            tokens.append(analyze(raw, start16: start16, end16: utf16))
        }
        return tokens
    }

    /// Analyzes a single query word; `nil` when it contains no token.
    static func analyzeTerm(_ raw: String) -> AnalyzedToken? {
        tokens(raw).first
    }

    /// Folds and stems a raw token string per the shared pipeline.
    private static func analyze(_ raw: String, start16: Int, end16: Int) -> AnalyzedToken {
        var folded = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if folded.hasSuffix("'s") || folded.hasSuffix("’s") {
            folded = String(folded.dropLast(2))
        }
        folded.removeAll { $0 == "'" || $0 == "’" }
        let stem =
            !folded.isEmpty && folded.allSatisfy({ $0.isASCII && $0.isLetter })
            ? Porter2.stem(folded)
            : folded
        return AnalyzedToken(folded: folded, stem: stem, start16: start16, end16: end16)
    }
}

/// The Snowball English (Porter2) stemmer for lowercase ASCII input —
/// the published algorithm including the exceptional forms, the R1
/// exceptional prefixes, and the step-1b invariant words. Verified against
/// the official sample vocabulary (voc.txt/output.txt).
enum Porter2 {
    /// Words of two letters or fewer, and the listed exceptions, are
    /// returned unchanged.
    static func stem(_ word: String) -> String {
        if let mapped = exceptional[word] { return mapped }
        if invariant.contains(word) { return word }
        var w = Array(word)
        guard w.count > 2 else { return word }

        // Prelude: drop one leading apostrophe, then mark consonantal y as
        // Y (initial y, or y after a vowel) so only vocalic y counts.
        if w.first == "'" { w.removeFirst() }
        var yFound = false
        if w.first == "y" {
            w[0] = "Y"
            yFound = true
        }
        for i in 1..<w.count where w[i] == "y" && isVowel(w[i - 1]) {
            w[i] = "Y"
            yFound = true
        }

        let (p1, p2) = markRegions(w)

        step1a(&w)
        step1b(&w, p1: p1)
        step1c(&w)
        step2(&w, p1: p1)
        step3(&w, p1: p1, p2: p2)
        step4(&w, p2: p2)
        step5(&w, p1: p1, p2: p2)

        if yFound {
            for i in w.indices where w[i] == "Y" { w[i] = "y" }
        }
        return String(w)
    }

    // MARK: Word shape

    /// A Snowball vowel: a e i o u y. (Marked Y is a consonant.)
    private static func isVowel(_ c: Character) -> Bool {
        "aeiouy".contains(c)
    }

    /// R1/R2 start positions. R1 follows the first non-vowel after a vowel,
    /// except for the exceptional prefixes where it follows the prefix; R2
    /// is the same measure inside R1.
    private static func markRegions(_ w: [Character]) -> (p1: Int, p2: Int) {
        var p1 = w.count
        if let prefix = exceptionalPrefixes.first(where: { w.starts(with: $0) }) {
            p1 = prefix.count
        } else {
            p1 = regionStart(w, from: 0)
        }
        return (p1, regionStart(w, from: p1))
    }

    /// `gopast v gopast non-v`: the index after the first non-vowel that
    /// follows a vowel, or the word's end.
    private static func regionStart(_ w: [Character], from start: Int) -> Int {
        var i = start
        while i < w.count, !isVowel(w[i]) { i += 1 }
        if i < w.count { i += 1 }
        while i < w.count, isVowel(w[i]) { i += 1 }
        if i < w.count { i += 1 }
        return i
    }

    /// A word ends in a short syllable when it ends consonant + vowel +
    /// consonant-other-than-w/x/Y, or is vowel + consonant, or ends "past".
    private static func endsInShortSyllable(_ w: [Character]) -> Bool {
        if w.count >= 3 {
            let a = w[w.count - 3]
            let b = w[w.count - 2]
            let c = w[w.count - 1]
            if !isVowel(a) && isVowel(b) && !isVowel(c) && c != "w" && c != "x" && c != "Y" {
                return true
            }
        }
        if w.count == 2, isVowel(w[0]), !isVowel(w[1]) { return true }
        return ends(w, "past")
    }

    /// "Short" = ends in a short syllable and R1 is null (`p1` at the end).
    private static func isShort(_ w: [Character], p1: Int) -> Bool {
        w.count == p1 && endsInShortSyllable(w)
    }

    private static func ends(_ w: [Character], _ suffix: String) -> Bool {
        let s = Array(suffix)
        return w.count >= s.count && w.suffix(s.count).elementsEqual(s)
    }

    private static func endsInDouble(_ w: [Character]) -> Bool {
        w.count >= 2 && doubles.contains(String(w.suffix(2)))
    }

    // MARK: Steps

    /// Step 0 + 1a: trailing apostrophes, then the plural/ies rules.
    private static func step1a(_ w: inout [Character]) {
        if ends(w, "'s'") {
            w.removeLast(3)
        } else if ends(w, "'s") || ends(w, "'") {
            w.removeLast(ends(w, "'s") ? 2 : 1)
        }

        if ends(w, "sses") {
            w.removeLast(2)  // sses -> ss
        } else if ends(w, "ied") || ends(w, "ies") {
            let before = w.count - 3
            w.removeLast(3)
            w.append(contentsOf: before > 1 ? "i" : "ie")
        } else if ends(w, "us") || ends(w, "ss") {
            // Invariant endings.
        } else if ends(w, "s") {
            // Delete s only when a vowel occurs strictly before the letter
            // that precedes it ("gas"/"this" keep s; "gaps"/"kiwis" lose it).
            if w.count > 2, w[..<(w.count - 2)].contains(where: isVowel) {
                w.removeLast()
            }
        }
    }

    /// Step 1b: eed/eedly, then ed/edly/ing/ingly with the invariant -ing
    /// words and the non-vowel+y+ing → ie special case.
    private static func step1b(_ w: inout [Character], p1: Int) {
        if ends(w, "eed") || ends(w, "eedly") {
            let length = ends(w, "eedly") ? 5 : 3
            let start = w.count - length
            guard start >= p1 else { return }
            // proceed, exceed, succeed keep their -eed.
            let before = String(w[..<start])
            guard before != "proc", before != "exc", before != "succ" else { return }
            w.removeLast(length)
            w.append(contentsOf: "ee")
            return
        }

        let suffix: String
        if ends(w, "edly") {
            suffix = "edly"
        } else if ends(w, "ingly") {
            suffix = "ingly"
        } else if ends(w, "ed") {
            suffix = "ed"
        } else if ends(w, "ing") {
            suffix = "ing"
        } else {
            return
        }

        let before = Array(w[..<(w.count - suffix.count)])
        if suffix == "ing" {
            // dying/lying/tying/vying -> die/lie/tie/vie
            if before.count == 2, before[1] == "y", !isVowel(before[0]) {
                w.removeLast(4)
                w.append(contentsOf: "ie")
                return
            }
            // inning, outing, canning, herring, earring, evening stay whole.
            if ["inn", "out", "cann", "herr", "earr", "even"].contains(String(before)) {
                return
            }
        }

        guard before.contains(where: isVowel) else { return }
        w.removeLast(suffix.count)

        if ends(w, "at") || ends(w, "bl") || ends(w, "iz") {
            w.append("e")
        } else if endsInDouble(w) {
            // A double preceded by exactly "a", "e", or "o" keeps both
            // letters (add, egg, off); otherwise undouble.
            let prefix = w[..<(w.count - 2)]
            if !(prefix.count == 1 && "aeo".contains(prefix[0])) {
                w.removeLast()
            }
        } else if isShort(w, p1: p1) {
            w.append("e")
        }
    }

    /// Step 1c: final y/Y -> i when preceded by a non-first-letter
    /// consonant (cry -> cri; by, say unchanged).
    private static func step1c(_ w: inout [Character]) {
        guard w.count >= 3, w[w.count - 1] == "y" || w[w.count - 1] == "Y",
            !isVowel(w[w.count - 2])
        else { return }
        w[w.count - 1] = "i"
    }

    /// The longest `candidates` suffix of `w`, or `nil`. Among semantics:
    /// one candidate is selected by length, and a failed action does not
    /// fall through to a shorter one.
    private static func longestSuffix(_ w: [Character], _ candidates: [String]) -> String? {
        candidates.filter { ends(w, $0) }.max(by: { $0.count < $1.count })
    }

    /// Step 2: suffix replacements inside R1.
    private static func step2(_ w: inout [Character], p1: Int) {
        let rules: [(String, String)] = [
            ("ational", "ate"), ("tional", "tion"), ("enci", "ence"), ("anci", "ance"),
            ("abli", "able"), ("entli", "ent"), ("izer", "ize"), ("ization", "ize"),
            ("ation", "ate"), ("ator", "ate"),
            ("alism", "al"), ("aliti", "al"), ("alli", "al"),
            ("fulness", "ful"), ("ousli", "ous"), ("ousness", "ous"),
            ("iveness", "ive"), ("iviti", "ive"),
            ("biliti", "ble"), ("bli", "ble"),
            ("ogist", "og"), ("ogi", "og"), ("fulli", "ful"), ("lessli", "less"),
            ("li", ""),
        ]
        guard let suffix = longestSuffix(w, rules.map(\.0)),
            w.count - suffix.count >= p1
        else { return }
        // Conditioned rules: ogi -> og only after l; li deletes only after a
        // valid li-ending.
        if suffix == "ogi" {
            guard w.count >= 4, w[w.count - 4] == "l" else { return }
        } else if suffix == "li" {
            guard w.count >= 3, validLI.contains(w[w.count - 3]) else { return }
        }
        w.removeLast(suffix.count)
        w.append(contentsOf: rules.first { $0.0 == suffix }!.1)
    }

    /// Step 3: suffix replacements inside R1; -ative deletes only in R2.
    private static func step3(_ w: inout [Character], p1: Int, p2: Int) {
        let rules: [(String, String)] = [
            ("ational", "ate"), ("tional", "tion"), ("alize", "al"),
            ("icate", "ic"), ("iciti", "ic"), ("ical", "ic"),
            ("ful", ""), ("ness", ""), ("ative", ""),
        ]
        guard let suffix = longestSuffix(w, rules.map(\.0)),
            w.count - suffix.count >= p1
        else { return }
        if suffix == "ative", w.count - suffix.count < p2 { return }
        w.removeLast(suffix.count)
        w.append(contentsOf: rules.first { $0.0 == suffix }!.1)
    }

    /// Step 4: suffix deletion inside R2; -ion only after s or t.
    private static func step4(_ w: inout [Character], p2: Int) {
        let suffixes = [
            "al", "ance", "ence", "er", "ic", "able", "ible", "ant", "ement",
            "ment", "ent", "ism", "ate", "iti", "ous", "ive", "ize", "ion",
        ]
        guard let suffix = longestSuffix(w, suffixes),
            w.count - suffix.count >= p2
        else { return }
        if suffix == "ion" {
            guard w.count >= 4, w[w.count - 4] == "s" || w[w.count - 4] == "t"
            else { return }
        }
        w.removeLast(suffix.count)
    }

    /// Step 5: final e deletes in R2, or in R1 when not preceded by a short
    /// syllable; final l deletes in R2 after another l.
    private static func step5(_ w: inout [Character], p1: Int, p2: Int) {
        if ends(w, "e") {
            let start = w.count - 1
            if start >= p2 || (start >= p1 && !endsInShortSyllable(Array(w.dropLast()))) {
                w.removeLast()
            }
        } else if ends(w, "l"), w.count - 1 >= p2, w.count >= 2, w[w.count - 2] == "l" {
            w.removeLast()
        }
    }

    // MARK: Tables

    /// exception1: whole-word remappings applied before stemming.
    private static let exceptional: [String: String] = [
        "skis": "ski", "skies": "sky",
        "idly": "idl", "gently": "gentl", "ugly": "ugli",
        "early": "earli", "only": "onli", "singly": "singl",
    ]

    /// exception1 invariants: returned unchanged.
    private static let invariant: Set<String> = [
        "sky", "news", "howe", "atlas", "cosmos", "bias", "andes",
    ]

    /// Words beginning with one of these set R1 after the prefix.
    private static let exceptionalPrefixes: [[Character]] = [
        "gener", "commun", "arsen", "past", "univers", "later", "emerg", "organ", "inter",
    ].map(Array.init)

    private static let doubles: Set<String> = [
        "bb", "dd", "ff", "gg", "mm", "nn", "pp", "rr", "tt",
    ]

    private static let validLI: Set<Character> = ["c", "d", "e", "g", "h", "k", "m", "n", "r", "t"]
}

/// Optimal string alignment distance (Levenshtein plus adjacent
/// transposition at cost 1), bounded: `nil` when the distance exceeds
/// `limit`, with the computation pruned to the reachable band.
enum EditDistance {
    static func osa(_ a: String, _ b: String, limit: Int) -> Int? {
        let x = Array(a)
        let y = Array(b)
        let m = x.count
        let n = y.count
        guard limit >= 0, abs(m - n) <= limit else { return nil }
        guard m > 0, n > 0 else { return max(m, n) <= limit ? max(m, n) : nil }

        let far = limit + 1  // out-of-band sentinel: any value > limit
        var prevprev = [Int](repeating: far, count: n + 1)
        var prev = (0...n).map { $0 <= limit ? $0 : far }
        var curr = [Int](repeating: far, count: n + 1)

        for i in 1...m {
            let lo = max(1, i - limit)
            let hi = min(n, i + limit)
            if lo > hi { return nil }
            curr[0] = i <= limit ? i : far
            var rowMin = far
            for j in lo...hi {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                var d = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] {
                    d = min(d, prevprev[j - 2] + 1)
                }
                curr[j] = d
                rowMin = min(rowMin, d)
            }
            if rowMin > limit { return nil }
            prevprev = prev
            prev = curr
            curr = [Int](repeating: far, count: n + 1)
        }
        return prev[n] <= limit ? prev[n] : nil
    }
}
