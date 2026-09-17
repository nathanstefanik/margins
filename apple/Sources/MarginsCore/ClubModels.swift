import Foundation

// Private book-club domain: one club is one book, a roster of members with
// roles, and one derived notes snapshot per member. Clubs are shared through
// CloudKit (docs/book-clubs-plan.md); this file is pure data — no I/O, no
// transport — so the merge, spoiler, and clustering rules stay testable
// without an iCloud account.
//
// Privacy rule: members never see another member's raw note files. What
// crosses the wire is `ClubMemberNotes`, a snapshot derived from the local
// compiled notes; what UIs render is `ClubNotes`, the merged view.

// MARK: - Roster

/// The local user's club identity: the stable member id plus the name shown
/// to other members.
public struct ClubIdentity: Sendable, Equatable, Hashable {
    public var memberId: String
    public var displayName: String?

    public init(memberId: String, displayName: String? = nil) {
        self.memberId = memberId
        self.displayName = displayName
    }
}

public enum ClubRole: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case admin
    case member
}

/// One person in a club. `id` is stable for the member's lifetime: CloudKit
/// participants use their user record name; local-only members use the same
/// 10-character Crockford id idiom as marks.
public struct ClubMember: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
    public var role: ClubRole
    public var joinedAt: Date

    public init(id: String, displayName: String, role: ClubRole, joinedAt: Date) {
        self.id = id
        self.displayName = displayName
        self.role = role
        self.joinedAt = joinedAt
    }

    public var isAdmin: Bool { role == .admin }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case role
        case joinedAt = "joined_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        role = try container.decode(ClubRole.self, forKey: .role)
        joinedAt = try container.decodeDate(forKey: .joinedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(role, forKey: .role)
        try container.encodeDate(joinedAt, forKey: .joinedAt)
    }
}

/// A private club reading exactly one book. The club does not outlive the
/// book: there is no reading list, no season, no persistence of notes into a
/// next book.
public struct Club: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// 10-character Crockford base32, same idiom as mark ids.
    public var id: String
    public var name: String
    /// Content-hash book id; every member imports the same EPUB.
    public var bookId: String
    public var bookTitle: String
    public var bookAuthor: String
    /// Four-character join code. A human handle, not a secret: the shared
    /// club record is the authority, and joining is still gated on accepting
    /// the CloudKit share.
    public var inviteCode: String
    public var createdAt: Date
    /// CloudKit share owner; delete-for-everyone. Roster `admin` can move.
    public var ownerMemberId: String
    public var members: [ClubMember]

    public init(
        id: String,
        name: String,
        bookId: String,
        bookTitle: String,
        bookAuthor: String,
        inviteCode: String,
        createdAt: Date,
        ownerMemberId: String,
        members: [ClubMember]
    ) {
        self.id = id
        self.name = name
        self.bookId = bookId
        self.bookTitle = bookTitle
        self.bookAuthor = bookAuthor
        self.inviteCode = inviteCode
        self.createdAt = createdAt
        self.ownerMemberId = ownerMemberId
        self.members = members
    }

    /// Roster order for display and deterministic output: admins first, then
    /// join order, then name and id.
    public var roster: [ClubMember] {
        members.sorted { a, b in
            if a.role != b.role { return a.role == .admin }
            if a.joinedAt != b.joinedAt { return a.joinedAt < b.joinedAt }
            if a.displayName != b.displayName { return a.displayName < b.displayName }
            return a.id < b.id
        }
    }

    public func member(id: String) -> ClubMember? {
        members.first { $0.id == id }
    }

    public func isAdmin(_ memberId: String) -> Bool {
        member(id: memberId)?.role == .admin
    }

    public func isOwner(_ memberId: String) -> Bool {
        ownerMemberId == memberId
    }

    public var admin: ClubMember? {
        members.first { $0.role == .admin }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name
        case bookId = "book_id"
        case bookTitle = "book_title"
        case bookAuthor = "book_author"
        case inviteCode = "invite_code"
        case createdAt = "created_at"
        case ownerMemberId = "owner_member_id"
        case members
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        bookId = try container.decode(String.self, forKey: .bookId)
        bookTitle = try container.decode(String.self, forKey: .bookTitle)
        bookAuthor = try container.decode(String.self, forKey: .bookAuthor)
        inviteCode = try container.decode(String.self, forKey: .inviteCode)
        createdAt = try container.decodeDate(forKey: .createdAt)
        members = try container.decode([ClubMember].self, forKey: .members)
        ownerMemberId = try container.decodeIfPresent(String.self, forKey: .ownerMemberId)
            ?? members.first(where: \.isAdmin)?.id
            ?? members.first?.id
            ?? ""
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(bookId, forKey: .bookId)
        try container.encode(bookTitle, forKey: .bookTitle)
        try container.encode(bookAuthor, forKey: .bookAuthor)
        try container.encode(inviteCode, forKey: .inviteCode)
        try container.encodeDate(createdAt, forKey: .createdAt)
        try container.encode(ownerMemberId, forKey: .ownerMemberId)
        try container.encode(members, forKey: .members)
    }
}

// MARK: - Snapshots

/// One member's derived notes for the club's book: what a member publishes
/// for the group and what syncs through CloudKit. It is rebuilt from the
/// local compiled notes at any time, so it is never the source of truth —
/// deleting it loses nothing.
public struct ClubMemberNotes: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var memberId: String
    public var displayName: String
    public var bookId: String
    public var bookTitle: String
    public var bookAuthor: String
    /// Spine length of the member's edition, for the merged stats line.
    public var chapterCount: Int
    public var updatedAt: Date
    /// Chapters with content, in spine order. Note-less chapters are omitted.
    public var chapters: [CompiledChapter]

    public init(
        memberId: String,
        displayName: String,
        bookId: String,
        bookTitle: String,
        bookAuthor: String,
        chapterCount: Int,
        updatedAt: Date,
        chapters: [CompiledChapter]
    ) {
        self.memberId = memberId
        self.displayName = displayName
        self.bookId = bookId
        self.bookTitle = bookTitle
        self.bookAuthor = bookAuthor
        self.chapterCount = chapterCount
        self.updatedAt = updatedAt
        self.chapters = chapters
    }

    public var id: String { memberId }

    private enum CodingKeys: String, CodingKey {
        case memberId = "member_id"
        case displayName = "display_name"
        case bookId = "book_id"
        case bookTitle = "book_title"
        case bookAuthor = "book_author"
        case chapterCount = "chapter_count"
        case updatedAt = "updated_at"
        case chapters
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        memberId = try container.decode(String.self, forKey: .memberId)
        displayName = try container.decode(String.self, forKey: .displayName)
        bookId = try container.decode(String.self, forKey: .bookId)
        bookTitle = try container.decode(String.self, forKey: .bookTitle)
        bookAuthor = try container.decode(String.self, forKey: .bookAuthor)
        chapterCount = try container.decode(Int.self, forKey: .chapterCount)
        updatedAt = try container.decodeDate(forKey: .updatedAt)
        chapters = try container.decode([CompiledChapter].self, forKey: .chapters)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(memberId, forKey: .memberId)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(bookId, forKey: .bookId)
        try container.encode(bookTitle, forKey: .bookTitle)
        try container.encode(bookAuthor, forKey: .bookAuthor)
        try container.encode(chapterCount, forKey: .chapterCount)
        try container.encodeDate(updatedAt, forKey: .updatedAt)
        try container.encode(chapters, forKey: .chapters)
    }
}

// MARK: - Spoiler protection

/// User setting, on by default: another member's notes are hidden for the
/// chapter the reader is currently in and every later chapter. The reader's
/// own notes are never hidden. `nil` position (never opened) hides all other
/// members' content.
public struct SpoilerPolicy: Codable, Sendable, Equatable, Hashable {
    public var isEnabled: Bool

    public init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }

    public static let `default` = SpoilerPolicy()
    public static let off = SpoilerPolicy(isEnabled: false)
}

// MARK: - Merged view

/// A mark as the merged view sees it: the member who took it plus the mark.
public struct ClubMark: Sendable, Equatable, Hashable, Identifiable {
    public var memberId: String
    public var displayName: String
    public var isSelf: Bool
    public var mark: Mark

    public init(memberId: String, displayName: String, isSelf: Bool, mark: Mark) {
        self.memberId = memberId
        self.displayName = displayName
        self.isSelf = isSelf
        self.mark = mark
    }

    public var id: String { mark.id }
}

/// One quoted passage with every member's mark that lands on it. The quote is
/// rendered once; the notes stack under it, so agreement and dissent are
/// visible instead of scattered.
public struct ClubPassage: Sendable, Equatable, Hashable, Identifiable {
    /// Stable across recompiles: the member mark ids, sorted and joined.
    public var id: String
    /// The longest member quote for the cluster; empty when the cluster is
    /// made of page-anchored marks with no quote.
    public var quote: String
    public var cfi: String?
    /// Whole-book percent of the earliest mark in the cluster, when known.
    public var percent: Double?
    /// The members' marks, in reading order.
    public var marks: [ClubMark]

    public init(
        id: String, quote: String, cfi: String? = nil, percent: Double? = nil,
        marks: [ClubMark]
    ) {
        self.id = id
        self.quote = quote
        self.cfi = cfi
        self.percent = percent
        self.marks = marks
    }
}

/// One member's long-form chapter note as the merged view sees it.
public struct ClubContribution: Sendable, Equatable, Hashable, Identifiable {
    public var memberId: String
    public var displayName: String
    public var isSelf: Bool
    public var body: String
    public var wordCount: Int
    public var updatedAt: Date?

    public init(
        memberId: String, displayName: String, isSelf: Bool, body: String,
        wordCount: Int, updatedAt: Date? = nil
    ) {
        self.memberId = memberId
        self.displayName = displayName
        self.isSelf = isSelf
        self.body = body
        self.wordCount = wordCount
        self.updatedAt = updatedAt
    }

    public var id: String { memberId }
}

/// One chapter of the merged view: visible contributions, clustered passages,
/// and — when spoiler protection applied — counts of what was withheld.
public struct ClubChapter: Sendable, Equatable, Hashable, Identifiable {
    public var chapterKey: String
    public var chapterIndex: Int
    public var chapterTitle: String
    /// Visible long-form notes, sorted by `(displayName, memberId)`.
    public var contributions: [ClubContribution]
    /// Visible marks clustered by CFI overlap, in reading order.
    public var passages: [ClubPassage]
    /// True when at least one other member's content was withheld.
    public var othersHidden: Bool
    public var hiddenMemberCount: Int
    public var hiddenContributionCount: Int
    public var hiddenMarkCount: Int

    public init(
        chapterKey: String,
        chapterIndex: Int,
        chapterTitle: String,
        contributions: [ClubContribution] = [],
        passages: [ClubPassage] = [],
        othersHidden: Bool = false,
        hiddenMemberCount: Int = 0,
        hiddenContributionCount: Int = 0,
        hiddenMarkCount: Int = 0
    ) {
        self.chapterKey = chapterKey
        self.chapterIndex = chapterIndex
        self.chapterTitle = chapterTitle
        self.contributions = contributions
        self.passages = passages
        self.othersHidden = othersHidden
        self.hiddenMemberCount = hiddenMemberCount
        self.hiddenContributionCount = hiddenContributionCount
        self.hiddenMarkCount = hiddenMarkCount
    }

    public var id: String { chapterKey }

    public var hasVisibleContent: Bool { !contributions.isEmpty || !passages.isEmpty }
}

/// The club's whole book, merged for one viewer: one chapter section per
/// chapter anyone annotated, in spine order.
public struct ClubNotes: Sendable, Equatable, Hashable {
    public var clubId: String
    public var clubName: String
    public var bookId: String
    public var bookTitle: String
    public var bookAuthor: String
    public var members: [ClubMember]
    /// Chapters with at least one member's content, in spine order.
    public var chapters: [ClubChapter]
    /// Spine length reported by the members' editions.
    public var chapterCount: Int
    /// Chapters with content (the `chapters` count, hidden content included).
    public var chaptersWithNotes: Int
    /// Words across visible long-form contributions only.
    public var totalWords: Int
    public var lastUpdatedAt: Date?
    public var spoilerProtected: Bool
    public var suggestedFilename: String

    public init(
        clubId: String,
        clubName: String,
        bookId: String,
        bookTitle: String,
        bookAuthor: String,
        members: [ClubMember],
        chapters: [ClubChapter],
        chapterCount: Int,
        chaptersWithNotes: Int,
        totalWords: Int,
        lastUpdatedAt: Date? = nil,
        spoilerProtected: Bool,
        suggestedFilename: String
    ) {
        self.clubId = clubId
        self.clubName = clubName
        self.bookId = bookId
        self.bookTitle = bookTitle
        self.bookAuthor = bookAuthor
        self.members = members
        self.chapters = chapters
        self.chapterCount = chapterCount
        self.chaptersWithNotes = chaptersWithNotes
        self.totalWords = totalWords
        self.lastUpdatedAt = lastUpdatedAt
        self.spoilerProtected = spoilerProtected
        self.suggestedFilename = suggestedFilename
    }
}

/// Toggles for `ClubCompile.renderMarkdown`; mirrors `ExportOptions`.
public struct ClubExportOptions: Codable, Sendable, Equatable, Hashable {
    public var includeToc: Bool
    public var includeStats: Bool
    /// Render the italic placeholder for chapters with hidden content.
    public var includeHiddenPlaceholder: Bool
    /// Render the clustered-passage section.
    public var includePassages: Bool
    /// Render the long-form chapter-note section.
    public var includeLongForm: Bool
    /// Shift `#` headings inside note bodies down two levels.
    public var demoteHeadings: Bool

    public init(
        includeToc: Bool = true,
        includeStats: Bool = true,
        includeHiddenPlaceholder: Bool = true,
        includePassages: Bool = true,
        includeLongForm: Bool = true,
        demoteHeadings: Bool = true
    ) {
        self.includeToc = includeToc
        self.includeStats = includeStats
        self.includeHiddenPlaceholder = includeHiddenPlaceholder
        self.includePassages = includePassages
        self.includeLongForm = includeLongForm
        self.demoteHeadings = demoteHeadings
    }

    public static let `default` = ClubExportOptions()
    /// Passages only — the short read for running a meeting.
    public static let meetingBrief = ClubExportOptions(includeLongForm: false)

    private enum CodingKeys: String, CodingKey {
        case includeToc = "include_toc"
        case includeStats = "include_stats"
        case includeHiddenPlaceholder = "include_hidden_placeholder"
        case includePassages = "include_passages"
        case includeLongForm = "include_long_form"
        case demoteHeadings = "demote_headings"
    }
}
