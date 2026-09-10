import Testing
import MarginsModel

@Suite("KeyHelp")
@MainActor
struct KeyHelpTests {
    /// Every key the keymap handles in a mode must appear in that mode's
    /// help group — the sheet is generated from the keymap definitions and
    /// this test keeps it honest.
    @Test("the cheat sheet covers every bound key in each mode")
    func sheetCoversEveryBoundKey() {
        // Keys the keymap could bind: letters, digits, and named keys.
        var candidateKeys: Set<String> = []
        for value in UInt32(97)...UInt32(122) { // a…z
            candidateKeys.insert(String(Unicode.Scalar(value)!))
        }
        for value in UInt32(65)...UInt32(90) { // A…Z
            candidateKeys.insert(String(Unicode.Scalar(value)!))
        }
        for value in UInt32(48)...UInt32(57) { // 0…9
            candidateKeys.insert(String(Unicode.Scalar(value)!))
        }
        candidateKeys.formUnion([
            " ", "Enter", "Escape", "ArrowLeft", "ArrowRight", "ArrowUp",
            "ArrowDown", "PageUp", "PageDown", "/", "?", "g", "G", "-",
        ])

        for (mode, groupName) in [(ReaderKeymapMode.library, "Library"), (ReaderKeymapMode.reader, "Reader")] {
            let groups = ReaderKeymap.helpGroups()
            let group = groups.first { $0.name == groupName }
            #expect(group != nil, "missing help group for \(groupName)")

            let keymap = ReaderKeymap(mode: mode)
            var bound: Set<String> = []
            for key in candidateKeys.sorted() {
                // A first press can start a chord (g g) — follow through.
                let first = keymap.handle(ReaderKeyEvent(key: key), now: 0)
                let second = keymap.handle(ReaderKeyEvent(key: key), now: 0.5)
                if !first.isEmpty || !second.isEmpty {
                    bound.insert(key)
                }
            }

            let sheetKeys = Set(group?.allKeys ?? [])
            let missing = bound.subtracting(sheetKeys)
            #expect(
                missing.isEmpty,
                "\(groupName) help sheet is missing bound keys: \(missing.sorted())"
            )
        }
    }

    @Test("the sheet groups the mouse-era and menu shortcuts too")
    func sheetIncludesGlobalShortcuts() {
        let global = ReaderKeymap.helpGroups().first { $0.name == "Global" }
        let keys = Set(global?.allKeys ?? [])
        #expect(keys.contains("⌘O"))
        #expect(keys.contains("⌘="))
        #expect(keys.contains("⌘0"))
    }
}
