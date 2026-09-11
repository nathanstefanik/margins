import Foundation

// Four-character invite codes. The code is a human handle, not a secret: it
// is looked up against the shared club record and joining is still gated on
// accepting the CloudKit share (docs/book-clubs-plan.md). The alphabet is
// Crockford base32, so the characters a person misreads — I, L, O, U — are
// either excluded or mapped on input.
public enum ClubCode {
    public static let length = 4
    public static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// A fresh code. Collisions across clubs are resolved by the store when
    /// the code is published (docs/book-clubs-plan.md, phase 3).
    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }

    /// Normalizes typed input: case-insensitive, `I`/`L` read as `1`, `O` as
    /// `0`, whitespace and dashes ignored. Returns `nil` unless exactly four
    /// alphabet characters remain.
    public static func normalize(_ raw: String) -> String? {
        var normalized = ""
        for character in raw.uppercased() {
            switch character {
            case "I", "L":
                normalized.append("1")
            case "O":
                normalized.append("0")
            default:
                guard alphabet.contains(character) else {
                    if character.isWhitespace || character == "-" { continue }
                    return nil
                }
                normalized.append(character)
            }
        }
        guard normalized.count == length else { return nil }
        return normalized
    }

    public static func isValid(_ raw: String) -> Bool {
        normalize(raw) != nil
    }
}
