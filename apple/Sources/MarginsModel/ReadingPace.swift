import Foundation

/// How fast the reader is turning pages, learned from their own history.
///
/// The pace meter keeps a short window of seconds-per-turn samples; the
/// footer asks it for "…min left" only once enough turns have been seen
/// that the median means something. Samples persist in `UserDefaults`
/// (small JSON, per device — pace is a property of the device you're
/// holding), and are cleared whenever the typography changes because the
/// old rate no longer describes the new layout.
@MainActor
@Observable
public final class ReadingPace {
    /// The shortest believable turn interval (sub-two-second flips are
    /// skimming, not reading) and the longest believable one (beyond five
    /// minutes the turn is a break, not a pace).
    static let minInterval: TimeInterval = 2
    static let maxInterval: TimeInterval = 300
    /// The rolling sample window.
    static let maxSamples = 40
    /// Turns required before the estimate is shown at all.
    static let warmupSamples = 15

    /// Seconds per turn, oldest first.
    public private(set) var samples: [TimeInterval]

    /// The typography fingerprint the samples were recorded under. Set
    /// this from `preferences.typographyKey` whenever turns are recorded;
    /// a change discards the samples — the old rate described a different
    /// layout.
    public var typographyKey: String {
        didSet {
            guard typographyKey != oldValue else { return }
            samples = []
            previousTurnAt = nil
            save()
        }
    }

    /// The previous forward turn's timestamp; nil after a jump, a close,
    /// or a backgrounding so the interval can't span a break.
    private var previousTurnAt: Date?

    private let defaults: UserDefaults

    private static let defaultsKey = "reader.pace"

    /// - Parameter defaults: injection point for tests; pass a
    ///   `UserDefaults(suiteName:)` to keep suites isolated.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var storedSamples: [TimeInterval] = []
        var storedKey = ""
        if let data = defaults.data(forKey: Self.defaultsKey),
            let stored = try? JSONDecoder().decode(StoredPace.self, from: data)
        {
            storedSamples = stored.samples
            storedKey = stored.typographyKey ?? ""
        }
        // didSet doesn't run inside init, so the assignment can't clear.
        samples = storedSamples
        typographyKey = storedKey
    }

    /// Records a forward page turn. The interval since the previous turn
    /// becomes a sample only inside the believable bounds; the timestamp
    /// itself always advances so consecutive fast turns still count.
    public func recordTurn(at date: Date = Date()) {
        if let previous = previousTurnAt {
            let interval = date.timeIntervalSince(previous)
            if interval >= Self.minInterval && interval <= Self.maxInterval {
                samples.append(interval)
                if samples.count > Self.maxSamples {
                    samples.removeFirst(samples.count - Self.maxSamples)
                }
            }
        }
        previousTurnAt = date
        save()
    }

    /// A jump, a close, a backgrounding — anything that is not a page
    /// turn — resets the running interval so the next genuine turn isn't
    /// charged for time spent elsewhere.
    public func noteJump() {
        previousTurnAt = nil
    }

    /// Median seconds per turn, nil until enough samples have gathered
    /// for the estimate to mean something.
    public var secondsPerPage: TimeInterval? {
        guard samples.count >= Self.warmupSamples else { return nil }
        let sorted = samples.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }

    /// Estimated minutes for `pagesRemaining` — rounded up so the reader
    /// never sees "0 min" mid-chapter — nil until the pace is known.
    public func minutesLeft(pagesRemaining: Int) -> Int? {
        secondsPerPage.map { Int(ceil(Double(pagesRemaining) * $0 / 60)) }
    }

    /// The chapter-local estimate for the footers: "Last page" on the
    /// final page, "<1 min left in chapter" under a minute, nil while the
    /// pace is unknown (callers fall back to the page count).
    public func timeLeftText(for progress: ReaderProgress) -> String? {
        estimateText(for: progress, suffix: " in chapter")
    }

    /// The same estimate for the iOS resting footer, where the rail's
    /// width is a finger-width. nil until the pace is known.
    public func shortTimeLeftText(for progress: ReaderProgress) -> String? {
        estimateText(for: progress, suffix: "")
    }

    private func estimateText(for progress: ReaderProgress, suffix: String) -> String? {
        let remaining = max(progress.totalPages - (progress.endPage ?? progress.page), 0)
        if remaining == 0 {
            return "Last page"
        }
        guard let secondsPerPage else { return nil }
        let seconds = Double(remaining) * secondsPerPage
        if seconds < 60 {
            return "<1 min left\(suffix)"
        }
        return "~\(Int(ceil(seconds / 60))) min left\(suffix)"
    }

    private func save() {
        let stored = StoredPace(samples: samples, typographyKey: typographyKey)
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    private struct StoredPace: Codable {
        var samples: [TimeInterval]
        var typographyKey: String?
    }
}
