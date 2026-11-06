import Foundation
import MarginsCore
import Testing

@testable import MarginsModel

/// The identity token lives under `NSKeyedArchiveRootObjectKey` in the
/// archive — `decodeObject()` alone reads nothing — so matching is
/// exercised through the round-trip rather than a live iCloud token.
@Suite("ICloudRemote")
struct ICloudRemoteTests {
    @Test("an archived token matches itself")
    func roundTrip() throws {
        let token = NSUUID() as NSObject
        let archived = try #require(ICloudRemote.archive(token))
        #expect(ICloudRemote.token(archived, matches: token))
    }

    @Test("a different token does not match")
    func differentToken() throws {
        let stored = try #require(ICloudRemote.archive(NSUUID() as NSObject))
        #expect(!ICloudRemote.token(stored, matches: NSUUID() as NSObject))
    }

    @Test("garbage input does not match")
    func garbage() throws {
        #expect(!ICloudRemote.token("not-base64!!!", matches: NSUUID() as NSObject))
        #expect(!ICloudRemote.token("", matches: NSUUID() as NSObject))
        #expect(!ICloudRemote.token("aGk=", matches: NSUUID() as NSObject))
    }
}
