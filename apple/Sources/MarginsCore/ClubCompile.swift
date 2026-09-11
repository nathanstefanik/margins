import Foundation

// Turns a club plus every member's snapshot into the merged view and its
// markdown export. Pure: snapshots in, document out, no file I/O. The two
// rules that make the merged view worth reading live here:
//
// - Spoiler protection drops another member's content for the viewer's
//   current chapter and later, as counts, never as text.
// - Marks that overlap in CFI space cluster under one quoted passage, so the
//   group's agreement and dissent sit side by side.
public enum ClubMarks {
    /// Clusters member marks into passages. Two marks join when their CFI
    /// ranges overlap, or — for missing/unparsable CFIs — when their quotes
    /// normalize to the same text. Each cluster's position is its earliest
    /// mark, so passages read in book order.
    public static func cluster(_ marks: [ClubMark]) -> [ClubPassage] {
        guard !marks.isEmpty else { return [] }
        let ordered = sorted(marks)
        let ranges = ordered.map { $0.mark.cfi.flatMap(CFI.parse) }
        let quotes = ordered.map { normalizedQuote($0.mark.quote) }

        var parent = Array(ordered.indices)
        func find(_ index: Int) -> Int {
            var root = index
            while parent[root] != root { root = parent[root] }
            var node = index
            while parent[node] != root {
                let next = parent[node]
                parent[node] = root
                node = next
            }
            return root
        }
        func union(_ a: Int, _ b: Int) {
            let rootA = find(a), rootB = find(b)
            guard rootA != rootB else { return }
            parent[max(rootA, rootB)] = min(rootA, rootB)
        }

        for i in ordered.indices {
            for j in (i + 1)..<ordered.count {
                switch (ranges[i], ranges[j]) {
                case let (a?, b?):
                    // Both CFIs parsed: only real overlap clusters them.
                    if CFI.overlaps(a, b) { union(i, j) }
                case (nil, _), (_, nil):
                    // A missing or unparsable CFI falls back to quote
                    // matching; two parseable but disjoint ranges stay
                    // separate even when their quotes normalize identically.
                    if !quotes[i].isEmpty, quotes[i] == quotes[j] { union(i, j) }
                }
            }
        }

        var grouped: [Int: [Int]] = [:]
        for index in ordered.indices {
            grouped[find(index), default: []].append(index)
        }

        var clusters: [(rank: Int, passage: ClubPassage)] = []
        for indices in grouped.values {
            let members = indices.map { ordered[$0] }
            clusters.append(
                (
                    indices.min() ?? 0,
                    ClubPassage(
                        id: members.map(\.mark.id).sorted().joined(separator: "-"),
                        quote: longestQuote(members.map(\.mark.quote)),
                        cfi: members.compactMap(\.mark.cfi).first,
                        percent: members.compactMap(\.mark.percent).min(),
                        marks: members
                    )
                )
            )
        }
        return clusters.sorted { $0.rank < $1.rank }.map(\.passage)
    }

    /// Reading order (percent, then CFI, then id) — the same order chapter
    /// notes use for their marks.
    public static func sorted(_ marks: [ClubMark]) -> [ClubMark] {
        let order = Marks.sortedByReadingOrder(marks.map(\.mark)).map(\.id)
        var rank: [String: Int] = [:]
        for (index, id) in order.enumerated() { rank[id] = index }
        return marks.sorted { (rank[$0.mark.id] ?? 0) < (rank[$1.mark.id] ?? 0) }
    }

    /// The quote-match fallback: lowercase and collapse whitespace so two
    /// members who selected the same sentence with different CFI support
    /// still cluster.
    static func normalizedQuote(_ quote: String) -> String {
        quote.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func longestQuote(_ quotes: [String]) -> String {
        var best = ""
        for quote in quotes {
            let trimmed = String(quote.trimmed)
            if trimmed.count > best.count { best = trimmed }
        }
        return best
    }
}

/// One chapter's accumulating view while snapshots are merged. Not persisted;
/// only exists for the duration of `ClubCompile.compile`.
private struct ChapterAccumulator {
    var chapterKey: String
    var chapterIndex: Int
    var chapterTitle: String
    var contributions: [ClubContribution] = []
    var marks: [ClubMark] = []
    var hiddenMembers: Set<String> = []
    var hiddenContributions = 0
    var hiddenMarks = 0
}

public enum ClubCompile {
    // MARK: Snapshots

    /// Builds a member's snapshot from their locally compiled notes. The
    /// snapshot carries only chapters that have content — an empty note file
    /// contributes nothing to the group — and is always regenerable from the
    /// library tree, so it can be republished freely.
    public static func snapshot(
        _ compiled: CompiledNotes, memberId: String, displayName: String
    ) -> ClubMemberNotes {
        let chapters = compiled.chapters.filter {
            !$0.body.trimmed.isEmpty || !$0.marks.isEmpty
        }
        return ClubMemberNotes(
            memberId: memberId,
            displayName: displayName,
            bookId: compiled.bookId,
            bookTitle: compiled.bookTitle,
            bookAuthor: compiled.bookAuthor,
            chapterCount: compiled.chapterCount,
            updatedAt: compiled.lastUpdatedAt ?? RFC3339.now(),
            chapters: chapters
        )
    }

    // MARK: Merging

    /// Merges every current member's snapshot into the viewer's document.
    /// Snapshots from members no longer on the roster are ignored; the
    /// viewer's own content is always visible; other members' content is
    /// hidden from the viewer's current chapter onward when `spoilerPolicy`
    /// is enabled, and reported as counts.
    public static func compile(
        club: Club,
        snapshots: [ClubMemberNotes],
        viewerId: String,
        viewerChapterIndex: Int?,
        spoilerPolicy: SpoilerPolicy = .default
    ) -> ClubNotes {
        let membersById = Dictionary(
            club.members.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let active = snapshots
            .filter { membersById[$0.memberId] != nil }
            .sorted { $0.memberId < $1.memberId }

        var byKey: [String: ChapterAccumulator] = [:]
        var chapterCount = 0
        var lastUpdatedAt: Date?

        for snapshot in active {
            guard let member = membersById[snapshot.memberId] else { continue }
            chapterCount = max(chapterCount, snapshot.chapterCount)
            lastUpdatedAt = later(lastUpdatedAt, snapshot.updatedAt)
            let isSelf = snapshot.memberId == viewerId

            for chapter in snapshot.chapters {
                let hasBody = !chapter.body.trimmed.isEmpty
                let hasMarks = !chapter.marks.isEmpty
                guard hasBody || hasMarks else { continue }

                let hidden = !isSelf && isHidden(
                    chapterIndex: chapter.chapterIndex,
                    viewerChapterIndex: viewerChapterIndex,
                    policy: spoilerPolicy
                )

                var accumulator = byKey[chapter.chapterKey] ?? ChapterAccumulator(
                    chapterKey: chapter.chapterKey,
                    chapterIndex: chapter.chapterIndex,
                    chapterTitle: chapter.chapterTitle
                )
                if hidden {
                    accumulator.hiddenMembers.insert(member.id)
                    if hasBody { accumulator.hiddenContributions += 1 }
                    accumulator.hiddenMarks += chapter.marks.count
                } else {
                    if hasBody {
                        accumulator.contributions.append(
                            ClubContribution(
                                memberId: member.id,
                                displayName: member.displayName,
                                isSelf: isSelf,
                                body: chapter.body,
                                wordCount: Notes.countWords(chapter.body),
                                updatedAt: chapter.updatedAt
                            )
                        )
                    }
                    accumulator.marks.append(
                        contentsOf: chapter.marks.map {
                            ClubMark(
                                memberId: member.id,
                                displayName: member.displayName,
                                isSelf: isSelf,
                                mark: $0
                            )
                        }
                    )
                }
                byKey[chapter.chapterKey] = accumulator
            }
        }

        let chapters = byKey.values
            .sorted { ($0.chapterIndex, $0.chapterKey) < ($1.chapterIndex, $1.chapterKey) }
            .map { accumulator in
                ClubChapter(
                    chapterKey: accumulator.chapterKey,
                    chapterIndex: accumulator.chapterIndex,
                    chapterTitle: accumulator.chapterTitle,
                    contributions: accumulator.contributions.sorted {
                        ($0.displayName, $0.memberId) < ($1.displayName, $1.memberId)
                    },
                    passages: ClubMarks.cluster(accumulator.marks),
                    othersHidden: !accumulator.hiddenMembers.isEmpty,
                    hiddenMemberCount: accumulator.hiddenMembers.count,
                    hiddenContributionCount: accumulator.hiddenContributions,
                    hiddenMarkCount: accumulator.hiddenMarks
                )
            }

        let totalWords = chapters.reduce(0) { total, chapter in
            total + chapter.contributions.reduce(0) { $0 + $1.wordCount }
        }
        if chapterCount == 0 {
            chapterCount = (chapters.map(\.chapterIndex).max() ?? -1) + 1
        }
        let snapshotTitle = active.first { !$0.bookTitle.isEmpty }
        let title = club.bookTitle.isEmpty
            ? (snapshotTitle?.bookTitle ?? "") : club.bookTitle
        let author = club.bookAuthor.isEmpty
            ? (snapshotTitle?.bookAuthor ?? "") : club.bookAuthor

        var notes = ClubNotes(
            clubId: club.id,
            clubName: club.name,
            bookId: club.bookId,
            bookTitle: title,
            bookAuthor: author,
            members: club.roster,
            chapters: chapters,
            chapterCount: chapterCount,
            chaptersWithNotes: chapters.count,
            totalWords: totalWords,
            lastUpdatedAt: lastUpdatedAt,
            spoilerProtected: spoilerPolicy.isEnabled,
            suggestedFilename: ""
        )
        notes.suggestedFilename = suggestedExportFilename(
            clubName: notes.clubName, bookTitle: notes.bookTitle
        )
        return notes
    }

    /// The spoiler rule: another member's content is hidden for the viewer's
    /// current chapter and every later one. No position means nothing has
    /// been read, so all other members' content is hidden.
    public static func isHidden(
        chapterIndex: Int, viewerChapterIndex: Int?, policy: SpoilerPolicy
    ) -> Bool {
        guard policy.isEnabled else { return false }
        guard let viewerChapterIndex else { return true }
        return chapterIndex >= viewerChapterIndex
    }

    // MARK: Export

    /// Renders the merged view as deterministic markdown: one quote per
    /// passage with each member's thought under it, long-form notes by
    /// member, and a spoiler placeholder instead of hidden content.
    public static func renderMarkdown(
        _ notes: ClubNotes, options: ClubExportOptions = .default
    ) -> String {
        var out = "# Club Notes — \(Compile.escapeMarkdown(notes.clubName))\n\n"
        out += "*\(Compile.escapeMarkdown(notes.bookTitle))"
        if !notes.bookAuthor.isEmpty {
            out += " — \(Compile.escapeMarkdown(notes.bookAuthor))"
        }
        out += "*"
        if options.includeStats {
            var parts = [
                "\(notes.members.count) members",
                "\(notes.chaptersWithNotes)/\(notes.chapterCount) chapters annotated",
                "\(notes.totalWords) words",
            ]
            if let updated = notes.lastUpdatedAt {
                parts.append("last updated \(Compile.formatDate(updated))")
            }
            out += " · \(parts.joined(separator: " · "))"
        }
        out += "\n\n"

        if notes.spoilerProtected {
            out += "> Spoiler protection is on: another member's notes are shown only for "
                + "chapters you have finished.\n\n"
        }
        guard !notes.chapters.isEmpty else { return out + "_No notes yet._\n" }

        if options.includeToc {
            out += "## Contents\n\n"
            var seen: [String: Int] = [:]
            for chapter in notes.chapters {
                let anchor = Compile.tocAnchor(
                    chapter.chapterIndex, chapter.chapterTitle, seen: &seen
                )
                out += "- [\(chapter.chapterIndex + 1). "
                    + "\(Compile.escapeMarkdown(chapter.chapterTitle))](#\(anchor))\n"
            }
            out += "\n"
        }

        for chapter in notes.chapters {
            out += "---\n\n"
            out += "## \(chapter.chapterIndex + 1). "
                + "\(Compile.escapeMarkdown(chapter.chapterTitle))\n"

            if chapter.othersHidden, options.includeHiddenPlaceholder {
                out += "\n\(hiddenPlaceholder(chapter))\n"
            }

            if options.includePassages, !chapter.passages.isEmpty {
                out += "\n### Passages\n"
                for passage in chapter.passages {
                    out += "\n"
                    if !passage.quote.isEmpty {
                        for line in passage.quote.lines {
                            out += "> \(line)\n"
                        }
                        out += "\n"
                    }
                    for entry in passage.marks {
                        out += renderMark(entry, options: options) + "\n"
                    }
                }
            }

            if options.includeLongForm, !chapter.contributions.isEmpty {
                out += "\n### Notes\n"
                for contribution in chapter.contributions {
                    out += "\n**\(Compile.escapeMarkdown(contribution.displayName))**\n\n"
                    out += demoted(contribution.body, options: options) + "\n"
                }
            }
        }
        return out
    }

    /// Shared default export name: `"{club} — {book} — club notes.md"`, with
    /// path-hostile characters stripped.
    public static func suggestedExportFilename(clubName: String, bookTitle: String) -> String {
        let club = Compile.sanitizeFilenameComponent(clubName)
        let book = Compile.sanitizeFilenameComponent(bookTitle)
        return "\(club.isEmpty ? "Book Club" : club) — "
            + "\(book.isEmpty ? "Notes" : book) — club notes.md"
    }

    // MARK: Rendering pieces

    private static func renderMark(_ entry: ClubMark, options: ClubExportOptions) -> String {
        let name = Compile.escapeMarkdown(entry.displayName)
        let body = demoted(entry.mark.body, options: options)
        if body.isEmpty {
            return "**\(name):**\n*(highlight)*"
        }
        return "**\(name):**\n\(body)"
    }

    private static func demoted(_ body: String, options: ClubExportOptions) -> String {
        var text = String(body.trimmed)
        if options.demoteHeadings { text = Compile.demoteHeadings(text) }
        return text
    }

    private static func hiddenPlaceholder(_ chapter: ClubChapter) -> String {
        let who = chapter.hiddenMemberCount == 1
            ? "1 other member's" : "\(chapter.hiddenMemberCount) other members'"
        return "_\(who) notes are hidden until you finish this chapter._"
    }

    private static func later(_ a: Date?, _ b: Date?) -> Date? {
        guard let a else { return b }
        guard let b else { return a }
        return max(a, b)
    }
}
