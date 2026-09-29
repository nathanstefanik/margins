import Foundation

// The per-device plain-file full-text index (docs/commonplace.md
// "Full-text search (plain-file index)"): one directory under the app
// data dir — never the library root, never the ubiquity container —
// excluded from backup and deletable at any time.
//
//   {data_dir}/text-index/
//     FORMAT                    # layout version; a mismatch wipes
//     stats.json                # {format, books, passages, tokens}
//     vocab.tsv                 # stem \t df, sorted by UTF-8 bytes
//     books/{book_id}/
//       manifest.json           # {format, extractor, book_id, …}
//       passages.jsonl          # {"k","n","t"} per line
//       terms.tsv               # stem \t p:tf,p:tf,… sorted by UTF-8 bytes
//
// Instance state lives on the CoreStore actor; `build` is a pure static
// function meant for Task.detached, and `commit` lands its staging dir.

/// One full-text hit before book/chapter titles are joined in.
struct ScoredPassage: Sendable, Equatable {
    var bookId: String
    var passageIndex: Int
    var chapterKey: String
    var passage: String
    var snippet: String
    var snippetRanges: [MatchRange]
    var score: Double
}

final class TextIndex {
    /// The on-disk layout version; a FORMAT mismatch wipes the index.
    static let format = 1

    private let dir: String
    private var booksDir: String { dir.appendingPathComponent("books") }
    private var formatPath: String { dir.appendingPathComponent("FORMAT") }
    private var vocabPath: String { dir.appendingPathComponent("vocab.tsv") }
    private var statsPath: String { dir.appendingPathComponent("stats.json") }

    private var prepared = false
    /// Book ids with a valid manifest on disk — the indexed set.
    private var indexedIds: Set<String> = []
    /// stem -> passage-frequency across every indexed book.
    private var vocab: [String: Int]?
    /// `vocab` keys in UTF-8 byte order, for prefix scans.
    private var sortedStems: [String]?
    private var stats: Stats?
    /// Per-book mapped `terms.tsv` and lazily-parsed `passages.jsonl`.
    private var bookData: [String: BookData] = [:]

    init(directory: String) {
        dir = directory
    }

    // MARK: Layout

    /// Creates the directory on first use, wipes it on a FORMAT mismatch,
    /// and heals a stats file that disagrees with the book dirs on disk.
    func ensure() throws {
        guard !prepared else { return }
        let onDisk = (try? Files.read(formatPath)).map { $0.trimmed }
        if Files.isDirectory(dir), onDisk != "\(Self.format)" {
            try? Files.remove(dir)
        }
        let fresh = !Files.isDirectory(dir)
        try Files.createDirectory(booksDir)
        if fresh || onDisk != "\(Self.format)" {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = URL(fileURLWithPath: dir, isDirectory: true)
            try? url.setResourceValues(values)
            try Files.write("\(Self.format)\n", to: formatPath)
        }
        try reconcile()
        prepared = true
    }

    /// Deletes the whole index; the next use rebuilds it.
    func reset() throws {
        try? Files.remove(dir)
        prepared = false
        indexedIds = []
        vocab = nil
        sortedStems = nil
        stats = nil
        bookData = [:]
    }

    /// stats.books must equal the dirs whose manifest decodes at the
    /// current format; otherwise vocab/stats are rebuilt from terms.tsv.
    private func reconcile() throws {
        for path in (try? Files.contents(ofDirectory: booksDir)) ?? []
        where (path as NSString).lastPathComponent.hasPrefix(".staging-") {
            try? Files.remove(path)
        }
        var manifests: [String: Manifest] = [:]
        for path in (try? Files.contents(ofDirectory: booksDir)) ?? [] {
            let name = (path as NSString).lastPathComponent
            guard !name.hasPrefix("."), Files.isDirectory(path) else { continue }
            let manifestPath = path.appendingPathComponent("manifest.json")
            guard let data = try? Files.readData(manifestPath),
                let manifest = try? MarginsJSON.decode(Manifest.self, from: data),
                manifest.format == Self.format
            else { continue }
            manifests[name] = manifest
        }
        indexedIds = Set(manifests.keys)
        let onDisk = (try? readStats())?.books.sorted()
        if onDisk != manifests.keys.sorted() {
            try rebuildVocabulary(manifests: manifests)
        }
    }

    /// Rebuilds vocab.tsv and stats.json from every book's terms.tsv.
    private func rebuildVocabulary(manifests: [String: Manifest]) throws {
        var vocab: [String: Int] = [:]
        for id in manifests.keys.sorted() {
            for (stem, df) in parseTerms(
                at: booksDir.appendingPathComponent(id).appendingPathComponent("terms.tsv"))
            {
                vocab[stem, default: 0] += df
            }
        }
        self.vocab = vocab
        sortedStems = nil
        stats = Stats(
            format: Self.format, books: manifests.keys.sorted(),
            passages: manifests.values.reduce(0) { $0 + $1.passages },
            tokens: manifests.values.reduce(0) { $0 + $1.tokens }
        )
        try write(vocabLines(vocab), to: vocabPath)
        try writeStats()
    }

    /// The book ids with a valid manifest on disk.
    func indexedBookIds() -> Set<String> {
        indexedIds
    }

    /// True when the book's index exists at the current format, extractor
    /// version, and chapters version.
    func isCurrent(bookId: String, chaptersVersion: Int) -> Bool {
        let path = booksDir.appendingPathComponent(bookId)
            .appendingPathComponent("manifest.json")
        guard let data = try? Files.readData(path),
            let manifest = try? MarginsJSON.decode(Manifest.self, from: data)
        else { return false }
        return manifest.format == Self.format
            && manifest.extractor == TextExtractor.version
            && manifest.chaptersVersion == chaptersVersion
    }

    // MARK: Build / commit / remove

    /// Extracts a book's text into `stagingDir`. Pure file work — call it
    /// off the actor and land the result with `commit`.
    static func build(
        bookId: String, epubPath: String, meta: BookMeta, into stagingDir: String
    ) throws {
        let extracted = try TextExtractor.passages(
            epubPath: epubPath, chapters: meta.chapters)
        try Files.createDirectory(stagingDir)

        // Tokenization is the bulk of build time — a whole book is
        // ~400k token/stem passes — so it fans out across cores while
        // postings/JSONL merge stays serial (order-deterministic). The
        // buffer is fixed storage: each thread writes disjoint indices.
        var analyzed = [[AnalyzedToken]](repeating: [], count: extracted.count)
        analyzed.withUnsafeMutableBufferPointer { buffer in
            let shared = SharedBuffer(buffer)
            DispatchQueue.concurrentPerform(iterations: extracted.count) { index in
                shared[index] = TextAnalyzer.tokens(extracted[index].text)
            }
        }

        var postings: [String: [(passage: Int, tf: Int)]] = [:]
        var totalTokens = 0
        var jsonl = Data()
        for (index, passage) in extracted.enumerated() {
            let tokens = analyzed[index]
            totalTokens += tokens.count
            var counts: [String: Int] = [:]
            for token in tokens { counts[token.stem, default: 0] += 1 }
            for (stem, tf) in counts {
                postings[stem, default: []].append((index, tf))
            }
            jsonl.append(
                try lineJSON.encode(
                    PassageLine(k: passage.chapterKey, n: tokens.count, t: passage.text)))
            jsonl.append(0x0A)
        }
        try Files.writeData(
            jsonl, to: stagingDir.appendingPathComponent("passages.jsonl"))

        var terms = ""
        for stem in postings.keys.sorted(by: utf8Less) {
            // Postings were appended in passage order — p is ascending.
            terms +=
                stem + "\t"
                + postings[stem]!.map { "\($0.passage):\($0.tf)" }
                .joined(separator: ",") + "\n"
        }
        try Files.write(terms, to: stagingDir.appendingPathComponent("terms.tsv"))

        let manifest = Manifest(
            format: Self.format, extractor: TextExtractor.version, bookId: bookId,
            chaptersVersion: meta.chaptersVersion, passages: extracted.count,
            tokens: totalTokens, indexedAt: Date()
        )
        try Files.writeData(
            MarginsJSON.encode(manifest),
            to: stagingDir.appendingPathComponent("manifest.json"))
    }

    /// Lands a built staging dir as `books/{id}`: replaces any previous
    /// index of the book, merges its terms into vocab.tsv, refreshes
    /// stats.json, and drops the cached readers.
    func commit(stagingDir: String, bookId: String) throws {
        try ensure()
        if Files.isDirectory(booksDir.appendingPathComponent(bookId)) {
            try removeBookFiles(bookId)
        }
        let bookDir = booksDir.appendingPathComponent(bookId)
        try Files.rename(stagingDir, to: bookDir)

        var vocab = try loadVocab()
        for (stem, df) in parseTerms(at: bookDir.appendingPathComponent("terms.tsv")) {
            vocab[stem, default: 0] += df
        }
        self.vocab = vocab
        sortedStems = nil

        var stats = loadStats()
        let manifest = try MarginsJSON.decode(
            Manifest.self,
            from: Files.readData(bookDir.appendingPathComponent("manifest.json")))
        stats.books = Set(stats.books).union([bookId]).sorted()
        stats.passages += manifest.passages
        stats.tokens += manifest.tokens
        self.stats = stats

        indexedIds.insert(bookId)
        bookData[bookId] = nil
        try write(vocabLines(vocab), to: vocabPath)
        try writeStats()
    }

    /// Removes one book's index: subtracts its terms from the vocabulary,
    /// updates stats, and deletes `books/{id}`.
    func remove(bookId: String) throws {
        try ensure()
        try removeBookFiles(bookId)
    }

    private func removeBookFiles(_ bookId: String) throws {
        let bookDir = booksDir.appendingPathComponent(bookId)
        guard Files.isDirectory(bookDir) else { return }
        var vocab = try loadVocab()
        for (stem, df) in parseTerms(at: bookDir.appendingPathComponent("terms.tsv")) {
            guard let current = vocab[stem] else { continue }
            if current > df {
                vocab[stem] = current - df
            } else {
                vocab.removeValue(forKey: stem)
            }
        }
        self.vocab = vocab
        sortedStems = nil

        var stats = loadStats()
        let manifest = try? MarginsJSON.decode(
            Manifest.self,
            from: Files.readData(bookDir.appendingPathComponent("manifest.json")))
        stats.books.removeAll { $0 == bookId }
        stats.passages -= manifest?.passages ?? 0
        stats.tokens -= manifest?.tokens ?? 0
        self.stats = stats

        indexedIds.remove(bookId)
        bookData[bookId] = nil
        try Files.remove(bookDir)
        try write(vocabLines(vocab), to: vocabPath)
        try writeStats()
    }

    // MARK: Query

    /// One expanded stem: its query weight, its corpus document
    /// frequency, and whether it is too common to generate candidates
    /// (`heavy` — its contribution is recounted in the proximity pass).
    private struct Expansion {
        var stem: String
        var weight: Double
        var df: Int
        var heavy: Bool
    }

    /// Runs the spec's six-step query over every indexed book in
    /// `bookIds`, returning the best `limit` scored passages.
    ///
    /// Postings of ultra-common stems (> 25% of passages) are never read:
    /// they cannot generate candidates — a passage only becomes one via a
    /// rarer term — and their contribution is recounted token-by-token in
    /// the proximity pass over the top 200.
    func search(query raw: String, bookIds: Set<String>, limit: Int) throws
        -> [ScoredPassage]
    {
        try ensure()
        let terms = TextAnalyzer.tokens(raw)
        var seen: Set<String> = []
        let queryTerms = terms.filter { seen.insert($0.stem).inserted }
        guard !queryTerms.isEmpty else { return [] }

        let vocabulary = try loadVocab()
        let stems = loadSortedStems()
        let stats = loadStats()
        let totalDocs = max(stats.passages, 1)
        let avgdl = max(Double(stats.tokens) / Double(totalDocs), 1e-9)
        let noPrefixExpansion = raw.last?.isWhitespace == true

        let cutoff = totalDocs / 4
        var expansions: [[Expansion]] = queryTerms.enumerated().map {
            position, term in
            expand(
                term, last: position == queryTerms.count - 1,
                prefixOK: !noPrefixExpansion, vocab: vocabulary, stems: stems,
                cutoff: cutoff)
        }
        // If every expansion is heavy the query would produce nothing at
        // all — force the least-common term back into candidate duty.
        if expansions.allSatisfy({ $0.allSatisfy(\.heavy) }),
            let rarest = expansions.indices.min(by: { i, j in
                expansions[i].map(\.df).min() ?? .max
                    < expansions[j].map(\.df).min() ?? .max
            })
        {
            for index in expansions[rarest].indices {
                expansions[rarest][index].heavy = false
            }
        }

        struct Candidate {
            var score: Double
            var matched: Set<Int>
        }
        var scored: [(bookId: String, passage: Int, hit: Candidate)] = []
        for bookId in indexedIds.intersection(bookIds).sorted() {
            guard let termsData = try termsData(bookId) else { continue }
            // passage -> [(term index, tf, idf * expansion weight)]
            var candidates: [Int: [(term: Int, tf: Int, w: Double)]] = [:]
            for (termIndex, expansions) in expansions.enumerated() {
                for expansion in expansions where !expansion.heavy && expansion.df > 0 {
                    guard
                        let postings = postings(
                            of: expansion.stem, in: termsData)
                    else { continue }
                    let idf = Self.idf(df: expansion.df, docs: totalDocs)
                    for posting in postings {
                        candidates[posting.passage, default: []].append(
                            (termIndex, posting.tf, expansion.weight * idf))
                    }
                }
            }
            guard !candidates.isEmpty else { continue }
            let lineIndex = try passageLineIndex(bookId)
            for (passageIndex, entries) in candidates {
                guard passageIndex < lineIndex.count else { continue }
                let dl = Double(lineIndex[passageIndex].n)
                var score = 0.0
                for entry in entries {
                    score += entry.w * Self.tfNorm(tf: entry.tf, dl: dl, avgdl: avgdl)
                }
                scored.append(
                    (
                        bookId, passageIndex,
                        Candidate(score: score, matched: Set(entries.map(\.term)))
                    ))
            }
        }

        // Proximity on the top 200: line decode + tokenize fan out
        // across cores (the pre-pass warms the per-book readers, so the
        // parallel pass only reads dictionaries), then merge back into
        // the caches serially.
        scored.sort { $0.hit.score > $1.hit.score }
        let top = Array(scored.prefix(200))
        for bookId in Set(top.map(\.bookId)) {
            _ = try? passageLines(bookId)
            _ = try? passageLineIndex(bookId)
        }
        var prepped = [PassageLine?](repeating: nil, count: top.count)
        var prepTokens = [[AnalyzedToken]](repeating: [], count: top.count)
        // Snapshot the cache reads the closure needs (no `self` capture)
        // and write results through fixed storage at disjoint indices —
        // mutating the arrays' captured vars concurrently would race.
        let topLines = top.map { bookData[$0.bookId]?.lines }
        let topIndexes = top.map { bookData[$0.bookId]?.lineIndex }
        prepped.withUnsafeMutableBufferPointer { preppedBuffer in
            prepTokens.withUnsafeMutableBufferPointer { tokensBuffer in
                let sharedPrepped = SharedBuffer(preppedBuffer)
                let sharedTokens = SharedBuffer(tokensBuffer)
                DispatchQueue.concurrentPerform(iterations: top.count) { i in
                    let candidate = top[i]
                    guard let data = topLines[i],
                        let lineIndex = topIndexes[i],
                        candidate.passage < lineIndex.count,
                        let line = try? MarginsJSON.decode(
                            PassageLine.self,
                            from: data.subdata(
                                in: lineIndex[candidate.passage].start..<lineIndex[candidate.passage].end))
                    else { return }
                    sharedPrepped[i] = line
                    sharedTokens[i] = TextAnalyzer.tokens(line.t)
                }
            }
        }
        for (i, line) in prepped.enumerated() {
            guard let line else { continue }
            let candidate = top[i]
            bookData[candidate.bookId]?.decoded[candidate.passage] = line
            bookData[candidate.bookId]?.tokenized[candidate.passage] = prepTokens[i]
        }

        let totalTerms = queryTerms.count
        let required = totalTerms <= 2 ? totalTerms : Int(ceil(0.6 * Double(totalTerms)))
        var ranked: [(passage: ScoredPassage, matched: Set<Int>)] = []
        for candidate in top {
            let line = try passage(candidate.bookId, at: candidate.passage)
            let passage = line.t
            let tokens = try tokens(candidate.bookId, at: candidate.passage)
            var matched = candidate.hit.matched
            var score = candidate.hit.score
            let dl = Double(line.n)

            // Heavy stems the candidate pass skipped still count toward
            // matched terms and score.
            var counts: [String: Int]?
            for (termIndex, expansions) in expansions.enumerated() {
                for expansion in expansions where expansion.heavy {
                    if counts == nil {
                        counts = [:]
                        for token in tokens { counts![token.stem, default: 0] += 1 }
                    }
                    guard let tf = counts![expansion.stem], tf > 0 else { continue }
                    matched.insert(termIndex)
                    score +=
                        expansion.weight * Self.idf(df: expansion.df, docs: totalDocs)
                        * Self.tfNorm(tf: tf, dl: dl, avgdl: avgdl)
                }
            }
            guard matched.count >= required else { continue }
            let coverage = Double(matched.count) / Double(totalTerms)
            score *= coverage * coverage

            let window = proximityWindow(
                tokens: tokens, matched: matched, expansions: expansions)
            var windowStart16 =
                tokens.first { token in
                    matched.contains { term in
                        expansions[term].contains { $0.stem == token.stem }
                    }
                }?.start16 ?? 0
            if let window {
                let m = matched.count
                if m >= 2 {
                    let w = window.hi - window.lo + 1
                    score *= 1 + 0.5 * Double(m) / Double(w)
                    if w == m,
                        coversInOrder(
                            tokens: tokens, lo: window.lo, hi: window.hi,
                            matched: matched, expansions: expansions)
                    {
                        score *= 2.0
                    }
                }
                windowStart16 = tokens[window.lo].start16
            }
            let (snippet, ranges) = makeSnippet(
                passage: passage, tokens: tokens, windowStart16: windowStart16,
                expansions: expansions)
            ranked.append(
                (
                    ScoredPassage(
                        bookId: candidate.bookId,
                        passageIndex: candidate.passage,
                        chapterKey: line.k,
                        passage: passage,
                        snippet: snippet,
                        snippetRanges: ranges,
                        score: score),
                    matched
                ))
        }
        ranked.sort { lhs, rhs in
            if lhs.passage.score != rhs.passage.score {
                return lhs.passage.score > rhs.passage.score
            }
            if lhs.passage.passageIndex != rhs.passage.passageIndex {
                return lhs.passage.passageIndex < rhs.passage.passageIndex
            }
            return lhs.passage.bookId < rhs.passage.bookId
        }
        // The caller applies `limit` after joining titles for the final
        // tie-break; the pool beyond the top 200 never had a proximity
        // pass anyway.
        return ranked.prefix(200).map(\.passage)
    }

    // MARK: Term expansion

    /// One term's expansion set: its own stem (1.0), indexed stems with
    /// the same prefix for a trailing short word (0.8), and — when the
    /// stem is absent from the vocabulary — OSA-neighbour stems (0.6).
    /// Stems above `cutoff` df are marked heavy: too common to walk
    /// postings for.
    private func expand(
        _ term: AnalyzedToken, last: Bool, prefixOK: Bool,
        vocab: [String: Int], stems: [String], cutoff: Int
    ) -> [Expansion] {
        var merged: [String: Double] = [term.stem: 1.0]
        if last, prefixOK, term.folded.count >= 3 {
            for stem in stemsWithPrefix(term.stem, in: stems) where stem != term.stem {
                merged[stem] = max(merged[stem] ?? 0, 0.8)
            }
        }
        if vocab[term.stem] == nil {
            for stem in typoAlternates(of: term.stem, in: stems) {
                merged[stem] = max(merged[stem] ?? 0, 0.6)
            }
        }
        return merged.map { stem, weight in
            let df = vocab[stem] ?? 0
            return Expansion(
                stem: stem, weight: weight, df: df, heavy: df > cutoff)
        }
    }

    /// Vocabulary stems sharing a prefix — a lower-bound binary search
    /// plus a forward scan.
    private func stemsWithPrefix(_ prefix: String, in stems: [String]) -> [String] {
        var lo = 0
        var hi = stems.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if Self.utf8Less(stems[mid], prefix) {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        var found: [String] = []
        while lo < stems.count, stems[lo].hasPrefix(prefix) {
            found.append(stems[lo])
            lo += 1
        }
        return found
    }

    /// The up-to-ten closest vocabulary stems within OSA distance 1
    /// (4–7 chars) or 2 (8+); shorter terms never expand.
    private func typoAlternates(of stem: String, in stems: [String]) -> [String] {
        guard stem.count >= 4 else { return [] }
        let limit = stem.count >= 8 ? 2 : 1
        return
            stems
            .compactMap { candidate -> (String, Int)? in
                guard candidate != stem,
                    let distance = EditDistance.osa(stem, candidate, limit: limit)
                else { return nil }
                return (candidate, distance)
            }
            .sorted { lhs, rhs in
                lhs.1 != rhs.1 ? lhs.1 < rhs.1 : Self.utf8Less(lhs.0, rhs.0)
            }
            .prefix(10)
            .map(\.0)
    }

    // MARK: BM25 / proximity / snippet

    private static let k1 = 1.2
    private static let b = 0.75

    private static func idf(df: Int, docs: Int) -> Double {
        log(1.0 + (Double(docs) - Double(df) + 0.5) / (Double(df) + 0.5))
    }

    private static func tfNorm(tf: Int, dl: Double, avgdl: Double) -> Double {
        let tf = Double(tf)
        return tf * (k1 + 1) / (tf + k1 * (1 - b + b * dl / avgdl))
    }

    /// The smallest token window covering at least one token per matched
    /// term — `(lo, hi)` token indices, inclusive.
    private func proximityWindow(
        tokens: [AnalyzedToken], matched: Set<Int>,
        expansions: [[Expansion]]
    ) -> (lo: Int, hi: Int)? {
        guard matched.count >= 2 else { return nil }
        let labels = tokens.map { token -> Set<Int> in
            var covered: Set<Int> = []
            for term in matched
            where expansions[term].contains(where: { $0.stem == token.stem }) {
                covered.insert(term)
            }
            return covered
        }
        var counts: [Int: Int] = [:]
        var have = 0
        var best: (lo: Int, hi: Int)?
        var lo = 0
        for hi in tokens.indices {
            for term in labels[hi] {
                counts[term, default: 0] += 1
                if counts[term] == 1 { have += 1 }
            }
            while have == matched.count {
                if best == nil || hi - lo < best!.hi - best!.lo {
                    best = (lo, hi)
                }
                for term in labels[lo] {
                    counts[term]! -= 1
                    if counts[term] == 0 { have -= 1 }
                }
                lo += 1
            }
        }
        return best
    }

    /// Whether the window's tokens can be assigned one distinct matched
    /// term each, in query order — the contiguous-phrase bonus.
    private func coversInOrder(
        tokens: [AnalyzedToken], lo: Int, hi: Int, matched: Set<Int>,
        expansions: [[Expansion]]
    ) -> Bool {
        let wanted = matched.sorted()
        var next = 0
        for index in lo...hi {
            guard next < wanted.count else { break }
            if expansions[wanted[next]].contains(where: { $0.stem == tokens[index].stem }) {
                next += 1
            }
        }
        return next == wanted.count
    }

    /// The display slice: ~40 chars before the window start … ~160 chars
    /// after, ellipsized at cut ends, with the matched-token ranges
    /// rebased into the snippet's UTF-16 coordinates. Reuses the tokens
    /// already computed for proximity.
    private func makeSnippet(
        passage: String, tokens: [AnalyzedToken], windowStart16: Int,
        expansions: [[Expansion]]
    ) -> (String, [MatchRange]) {
        let utf16 = passage.utf16
        let windowStart = utf16.index(
            utf16.startIndex, offsetBy: min(windowStart16, utf16.count))
        let charsBefore = 40
        let start =
            utf16.index(windowStart, offsetBy: -charsBefore, limitedBy: utf16.startIndex)
            ?? utf16.startIndex
        let charsAfter = 160
        let end =
            utf16.index(windowStart, offsetBy: charsAfter, limitedBy: utf16.endIndex)
            ?? utf16.endIndex
        let prefix = start > utf16.startIndex
        let snippet =
            (prefix ? "…" : "")
            + String(utf16[start..<end])!
            + (end < utf16.endIndex ? "…" : "")
        let offset = utf16.distance(from: utf16.startIndex, to: start)
        let length = utf16.distance(from: start, to: end)
        let ellipsis = prefix ? 1 : 0

        let stems = Set(expansions.flatMap { $0.map(\.stem) })
        var ranges: [MatchRange] = []
        for token in tokens {
            guard stems.contains(token.stem),
                token.start16 >= offset,
                token.end16 <= offset + length
            else { continue }
            ranges.append(
                MatchRange(
                    start: token.start16 - offset + ellipsis,
                    end: token.end16 - offset + ellipsis))
        }
        return (snippet, ranges)
    }

    // MARK: On-disk readers

    private struct BookData {
        var terms: Data?
        var lines: Data?
        /// Per-passage `(token count, byte start, byte end)` into `lines`.
        var lineIndex: [(n: Int, start: Int, end: Int)]?
        var decoded: [Int: PassageLine] = [:]
        /// Analyzed tokens per decoded passage — repeat queries (a user
        /// typing) re-tokenize the same hits otherwise.
        var tokenized: [Int: [AnalyzedToken]] = [:]
    }

    /// The memory-mapped terms.tsv for a book — nil when unreadable.
    private func termsData(_ bookId: String) throws -> Data? {
        if let cached = bookData[bookId]?.terms { return cached }
        let path = booksDir.appendingPathComponent(bookId)
            .appendingPathComponent("terms.tsv")
        guard
            let data = try? Data(
                contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        else { return nil }
        var entry = bookData[bookId] ?? BookData()
        entry.terms = data
        bookData[bookId] = entry
        return data
    }

    /// The memory-mapped passages.jsonl for a book — nil when unreadable.
    private func passageLines(_ bookId: String) throws -> Data? {
        if let cached = bookData[bookId]?.lines { return cached }
        let path = booksDir.appendingPathComponent(bookId)
            .appendingPathComponent("passages.jsonl")
        guard
            let data = try? Data(
                contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        else { return nil }
        var entry = bookData[bookId] ?? BookData()
        entry.lines = data
        bookData[bookId] = entry
        return data
    }

    /// One byte scan of passages.jsonl, cached: every line's token count
    /// (`"n":`, parsed straight off the bytes — JSON decoding every line
    /// just to score them was the old hot spot) plus its byte range so a
    /// hit's full line is decoded only when needed.
    private func passageLineIndex(_ bookId: String) throws -> [(n: Int, start: Int, end: Int)] {
        if let cached = bookData[bookId]?.lineIndex { return cached }
        guard let data = try passageLines(bookId) else {
            throw CoreError.io("io error: could not read passages.jsonl")
        }
        let index: [(Int, Int, Int)] = data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var result: [(Int, Int, Int)] = []
            var start = 0
            var i = 0
            while i < bytes.count {
                if bytes[i] == 0x0A {
                    if i > start {
                        result.append((tokenCount(bytes, at: start), start, i))
                    }
                    start = i + 1
                }
                i += 1
            }
            if start < bytes.count {
                result.append((tokenCount(bytes, at: start), start, bytes.count))
            }
            return result
        }
        var entry = bookData[bookId] ?? BookData()
        entry.lineIndex = index
        bookData[bookId] = entry
        return index
    }

    /// The line's `"n":` field, scanned from the first ~64 bytes — the
    /// writer emits `{"k":…,"n":…,"t":…}` so it is always early.
    private func tokenCount(_ bytes: UnsafeBufferPointer<UInt8>, at start: Int) -> Int {
        var i = start
        let limit = min(start + 64, bytes.count - 3)
        while i < limit {
            if bytes[i] == 0x22, bytes[i + 1] == 0x6E, bytes[i + 2] == 0x22,
                bytes[i + 3] == 0x3A
            {  // "n":
                var n = 0
                var j = i + 4
                while j < bytes.count, bytes[j] >= 0x30, bytes[j] <= 0x39 {
                    n = n * 10 + Int(bytes[j] - 0x30)
                    j += 1
                }
                return n
            }
            i += 1
        }
        return 0
    }

    /// One decoded passage line — decoded lazily, cached per line.
    private func passage(_ bookId: String, at index: Int) throws -> PassageLine {
        if let cached = bookData[bookId]?.decoded[index] { return cached }
        let lineIndex = try passageLineIndex(bookId)
        guard index < lineIndex.count, let data = try passageLines(bookId)
        else { throw CoreError.io("io error: could not read passages.jsonl") }
        let span = lineIndex[index]
        let line = try MarginsJSON.decode(
            PassageLine.self, from: data.subdata(in: span.start..<span.end))
        bookData[bookId]?.decoded[index] = line
        return line
    }

    /// The passage's analyzed tokens, cached next to its decoded line.
    private func tokens(_ bookId: String, at index: Int) throws -> [AnalyzedToken] {
        if let cached = bookData[bookId]?.tokenized[index] { return cached }
        let line = try passage(bookId, at: index)
        let tokens = TextAnalyzer.tokens(line.t)
        bookData[bookId]?.tokenized[index] = tokens
        return tokens
    }

    /// Reads a stem's posting list by binary-searching the mapped lines:
    /// seek mid, back up to the line start, compare the stem prefix.
    private func postings(of stem: String, in data: Data) -> [(passage: Int, tf: Int)]? {
        data.withUnsafeBytes { raw -> [(passage: Int, tf: Int)]? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var lo = 0
            var hi = bytes.count
            while lo < hi {
                let mid = (lo + hi) / 2
                var start = mid
                while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
                if compareLine(bytes, at: start, to: stem) < 0 {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
            guard lo < bytes.count else { return nil }
            var start = lo
            while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
            guard compareLine(bytes, at: start, to: stem) == 0 else { return nil }
            return parsePostings(bytes, at: start)
        }
    }

    /// Compares the stem field of the line at `offset` against `stem` in
    /// UTF-8 byte order.
    private func compareLine(
        _ bytes: UnsafeBufferPointer<UInt8>, at offset: Int, to stem: String
    ) -> Int {
        let stemBytes = [UInt8](stem.utf8)
        var i = offset
        var j = 0
        while i < bytes.count, bytes[i] != 0x09, bytes[i] != 0x0A, j < stemBytes.count {
            if bytes[i] != stemBytes[j] {
                return bytes[i] < stemBytes[j] ? -1 : 1
            }
            i += 1
            j += 1
        }
        if j == stemBytes.count, i < bytes.count, bytes[i] == 0x09 { return 0 }
        if j == stemBytes.count { return 1 }
        return -1
    }

    /// Parses `p:tf,p:tf,…` from the line at `offset`.
    private func parsePostings(
        _ bytes: UnsafeBufferPointer<UInt8>, at offset: Int
    ) -> [(passage: Int, tf: Int)] {
        var postings: [(Int, Int)] = []
        var i = offset
        while i < bytes.count, bytes[i] != 0x09 { i += 1 }
        i += 1
        var number = 0
        var passage = 0
        var inTf = false
        while i < bytes.count, bytes[i] != 0x0A {
            let byte = bytes[i]
            if byte == 0x3A {  // ':'
                passage = number
                number = 0
                inTf = true
            } else if byte == 0x2C {  // ','
                postings.append((passage, number))
                number = 0
                inTf = false
            } else if byte >= 0x30, byte <= 0x39 {
                number = number * 10 + Int(byte - 0x30)
            }
            i += 1
        }
        if inTf { postings.append((passage, number)) }
        return postings
    }

    // MARK: Files

    private static func utf8Less(_ a: String, _ b: String) -> Bool {
        a.utf8.lexicographicallyPrecedes(b.utf8)
    }

    private func vocabLines(_ vocab: [String: Int]) -> String {
        vocab.keys.sorted(by: Self.utf8Less)
            .map { "\($0)\t\(vocab[$0]!)" }
            .joined(separator: "\n")
            + "\n"
    }

    /// Stem -> df pairs from a terms.tsv posting file.
    private func parseTerms(at path: String) -> [(stem: String, df: Int)] {
        guard let text = try? Files.read(path) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let tab = line.firstIndex(of: "\t") ?? line.endIndex
            let stem = String(line[..<tab])
            guard tab < line.endIndex else { return nil }
            let df = line[line.index(after: tab)...].split(separator: ",").count
            return (stem, df)
        }
    }

    private func loadVocab() throws -> [String: Int] {
        if let vocab { return vocab }
        var map: [String: Int] = [:]
        if let text = try? Files.read(vocabPath) {
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "\t")
                if parts.count == 2, let df = Int(parts[1]) {
                    map[String(parts[0])] = df
                }
            }
        }
        vocab = map
        return map
    }

    private func loadSortedStems() -> [String] {
        if let sortedStems { return sortedStems }
        let sorted = (vocab ?? [:]).keys.sorted(by: Self.utf8Less)
        sortedStems = sorted
        return sorted
    }

    private func loadStats() -> Stats {
        if let stats { return stats }
        let stats =
            (try? readStats())
            ?? Stats(format: Self.format, books: [], passages: 0, tokens: 0)
        self.stats = stats
        return stats
    }

    private func readStats() throws -> Stats {
        try MarginsJSON.decode(Stats.self, from: Files.readData(statsPath))
    }

    /// Writes via a temp file + rename, so a crash never leaves a torn
    /// index file behind. `moveItem` refuses to replace, so the old file
    /// goes first — a crash in between just forces the next reconcile.
    private func write(_ text: String, to path: String) throws {
        let temp = path + ".tmp"
        try Files.write(text, to: temp)
        try? Files.remove(path)
        try Files.rename(temp, to: path)
    }

    private func writeStats() throws {
        guard let stats else { return }
        let temp = statsPath + ".tmp"
        try Files.writeData(MarginsJSON.encode(stats), to: temp)
        try? Files.remove(statsPath)
        try Files.rename(temp, to: statsPath)
    }

    /// passages.jsonl is single-line-per-doc, so it cannot use the
    /// pretty-printed shared encoder.
    private static let lineJSON: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    // MARK: On-disk models

    struct Manifest: Codable {
        var format: Int
        var extractor: Int
        var bookId: String
        var chaptersVersion: Int
        var passages: Int
        var tokens: Int
        var indexedAt: Date

        private enum CodingKeys: String, CodingKey {
            case format, extractor
            case bookId = "book_id"
            case chaptersVersion = "chapters_version"
            case passages, tokens
            case indexedAt = "indexed_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            format = try container.decode(Int.self, forKey: .format)
            extractor = try container.decode(Int.self, forKey: .extractor)
            bookId = try container.decode(String.self, forKey: .bookId)
            chaptersVersion = try container.decode(Int.self, forKey: .chaptersVersion)
            passages = try container.decode(Int.self, forKey: .passages)
            tokens = try container.decode(Int.self, forKey: .tokens)
            indexedAt = try container.decodeDate(forKey: .indexedAt)
        }

        init(
            format: Int, extractor: Int, bookId: String, chaptersVersion: Int,
            passages: Int, tokens: Int, indexedAt: Date
        ) {
            self.format = format
            self.extractor = extractor
            self.bookId = bookId
            self.chaptersVersion = chaptersVersion
            self.passages = passages
            self.tokens = tokens
            self.indexedAt = indexedAt
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(format, forKey: .format)
            try container.encode(extractor, forKey: .extractor)
            try container.encode(bookId, forKey: .bookId)
            try container.encode(chaptersVersion, forKey: .chaptersVersion)
            try container.encode(passages, forKey: .passages)
            try container.encode(tokens, forKey: .tokens)
            try container.encodeDate(indexedAt, forKey: .indexedAt)
        }
    }

    struct Stats: Codable {
        var format: Int
        var books: [String]
        var passages: Int
        var tokens: Int
    }

    /// A fixed-storage buffer a `concurrentPerform` closure writes through:
    /// safe only because every iteration touches a disjoint index and the
    /// storage outlives the parallel section.
    private struct SharedBuffer<Element>: @unchecked Sendable {
        let buffer: UnsafeMutableBufferPointer<Element>

        init(_ buffer: UnsafeMutableBufferPointer<Element>) {
            self.buffer = buffer
        }

        subscript(index: Int) -> Element {
            nonmutating get { buffer[index] }
            nonmutating set { buffer[index] = newValue }
        }
    }

    struct PassageLine: Codable {
        var k: String
        var n: Int
        var t: String
    }
}
