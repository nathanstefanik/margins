import Foundation

// Rust `str` semantics the port leans on. Swift has near equivalents, but
// the gaps are exactly where a faithful port goes wrong: `split(separator:)`
// yields a trailing empty slice where `str::lines()` yields none, and
// Foundation trims whole `CharacterSet`s with no one-sided variant.

extension StringProtocol where SubSequence == Substring {
    /// `str::lines()`: splits on `\n`, drops a trailing `\r` from each line,
    /// and yields no final empty line for a trailing newline. `""` has no
    /// lines at all; `"\n"` has one empty line.
    var lines: [Substring] {
        if isEmpty { return [] }
        var split = self[...].split(separator: "\n", omittingEmptySubsequences: false)
        if split.last?.isEmpty == true { split.removeLast() }
        return split.map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
    }

    /// `str::trim()` — Unicode `White_Space` from both ends.
    var trimmed: Substring {
        trimmedStart.trimmedEnd
    }

    /// `str::trim_start()`
    var trimmedStart: Substring {
        var start = startIndex
        while start < endIndex, self[start].isWhitespace {
            start = index(after: start)
        }
        return self[start...]
    }

    /// `str::trim_end()`
    var trimmedEnd: Substring {
        var end = endIndex
        while end > startIndex {
            let previous = index(before: end)
            guard self[previous].isWhitespace else { break }
            end = previous
        }
        return self[startIndex..<end]
    }

    /// `str::strip_prefix()` — the remainder, or `nil` when the prefix is
    /// absent. Distinguishing "absent" from "present but empty remainder" is
    /// what the mark-comment parser keys off.
    func strippingPrefix(_ prefix: String) -> Substring? {
        guard hasPrefix(prefix) else { return nil }
        return self[index(startIndex, offsetBy: prefix.count)...]
    }

    /// `str::strip_suffix()`
    func strippingSuffix(_ suffix: String) -> Substring? {
        guard hasSuffix(suffix) else { return nil }
        return self[startIndex..<index(endIndex, offsetBy: -suffix.count)]
    }
}
