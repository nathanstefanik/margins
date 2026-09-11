import Foundation

/// Time-ordered, 10-character Crockford-base32 ids shared by marks and
/// clubs: millisecond clock since a custom epoch, with 10 bits of
/// per-millisecond randomness. Callers retry on the (unlikely) collision
/// with an existing id, so uniqueness holds without coordination.
public enum CoreID {
    private static let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")
    /// 2020-01-01T00:00:00Z; 40 bits of milliseconds reach ~2054.
    private static let epochMilliseconds = 1_577_836_800_000

    public static func newID() -> String {
        let now = Date().timeIntervalSince1970
        let milliseconds = max(Int((now * 1000).rounded(.down)), epochMilliseconds)
            - epochMilliseconds
        var value = UInt64(milliseconds) << 10 | UInt64(randomTenBits(at: now))
        var id = [Character](repeating: "0", count: 10)
        for position in id.indices.reversed() {
            id[position] = alphabet[Int(value & 31)]
            value >>= 5
        }
        return String(id)
    }

    /// Small non-crypto random source for id suffixes: nanos mixed by a
    /// splitmix-style step. Adequate — collisions are retried by callers.
    private static func randomTenBits(at now: TimeInterval) -> UInt32 {
        let nanos = UInt64((now - now.rounded(.down)) * 1_000_000_000)
        var z = (nanos << 13) ^ UInt64(UInt32(bitPattern: ProcessInfo.processInfo.processIdentifier))
        z = (z ^ (z >> 30)) &* 0xbf58_476d_8ce4_e809
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return UInt32((z ^ (z >> 31)) & 0x3ff)
    }
}
