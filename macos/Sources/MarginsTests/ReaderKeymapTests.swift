import Testing
import MarginsModel

@Suite("ReaderKeymap")
@MainActor
struct ReaderKeymapTests {
    @Test("gg scrolls to top")
    func ggScrollsToTop() {
        let keymap = ReaderKeymap(mode: .reader)
        #expect(keymap.handle(ReaderKeyEvent(key: "g"), now: 0).isEmpty)
        #expect(keymap.handle(ReaderKeyEvent(key: "g"), now: 0.2) == [.scrollTop])
    }

    @Test("pending g expires after the timeout")
    func pendingGExpires() {
        let keymap = ReaderKeymap(mode: .reader)
        #expect(keymap.handle(ReaderKeyEvent(key: "g"), now: 0).isEmpty)
        #expect(keymap.pendingG)
        // After the timeout the chord is discarded; this g starts a fresh one.
        #expect(keymap.handle(ReaderKeyEvent(key: "g"), now: 1.5).isEmpty)
        #expect(keymap.handle(ReaderKeyEvent(key: "g"), now: 1.6) == [.scrollTop])
    }

    @Test("another key cancels the pending chord")
    func otherKeyCancelsChord() {
        let keymap = ReaderKeymap(mode: .reader)
        #expect(keymap.handle(ReaderKeyEvent(key: "g"), now: 0).isEmpty)
        #expect(keymap.handle(ReaderKeyEvent(key: "x"), now: 0.1).isEmpty)
        // Fresh chord, not a completed one.
        #expect(keymap.handle(ReaderKeyEvent(key: "g"), now: 0.2).isEmpty)
    }

    @Test("G scrolls to bottom")
    func uppercaseGScrollsToBottom() {
        let keymap = ReaderKeymap(mode: .reader)
        #expect(keymap.handle(ReaderKeyEvent(key: "G", shift: true), now: 0) == [.scrollBottom])
    }

    @Test("reader mode: j/k scroll and n/p change chapter")
    func readerModeKeys() {
        let keymap = ReaderKeymap(mode: .reader)
        #expect(keymap.handle(ReaderKeyEvent(key: "j"), now: 0) == [.scroll(delta: 80)])
        #expect(keymap.handle(ReaderKeyEvent(key: "k"), now: 0) == [.scroll(delta: -80)])
        #expect(keymap.handle(ReaderKeyEvent(key: "n"), now: 0) == [.nextChapter])
        #expect(keymap.handle(ReaderKeyEvent(key: "p"), now: 0) == [.previousChapter])
    }

    @Test("reader mode: arrows, space, and page keys page through the book")
    func readerModePageKeys() {
        let keymap = ReaderKeymap(mode: .reader)
        #expect(keymap.handle(ReaderKeyEvent(key: "ArrowRight"), now: 0) == [.scroll(delta: 80)])
        #expect(keymap.handle(ReaderKeyEvent(key: " "), now: 0) == [.scroll(delta: 80)])
        #expect(keymap.handle(ReaderKeyEvent(key: "PageDown"), now: 0) == [.scroll(delta: 80)])
        #expect(keymap.handle(ReaderKeyEvent(key: "ArrowLeft"), now: 0) == [.scroll(delta: -80)])
        #expect(keymap.handle(ReaderKeyEvent(key: "PageUp"), now: 0) == [.scroll(delta: -80)])
    }

    @Test("library mode: arrows and space stay native")
    func libraryModePageKeysPassthrough() {
        let keymap = ReaderKeymap(mode: .library)
        #expect(keymap.handle(ReaderKeyEvent(key: "ArrowRight"), now: 0).isEmpty)
        #expect(keymap.handle(ReaderKeyEvent(key: "ArrowLeft"), now: 0).isEmpty)
        #expect(keymap.handle(ReaderKeyEvent(key: " "), now: 0).isEmpty)
        #expect(keymap.handle(ReaderKeyEvent(key: "PageDown"), now: 0).isEmpty)
        #expect(keymap.handle(ReaderKeyEvent(key: "PageUp"), now: 0).isEmpty)
    }

    @Test("library mode: j/k move the selection, Enter opens, Enter is inert in reader mode")
    func libraryModeKeys() {
        let keymap = ReaderKeymap(mode: .library)
        #expect(keymap.handle(ReaderKeyEvent(key: "j"), now: 0) == [.moveLibrarySelection(delta: 1)])
        #expect(keymap.handle(ReaderKeyEvent(key: "k"), now: 0) == [.moveLibrarySelection(delta: -1)])
        #expect(keymap.handle(ReaderKeyEvent(key: "Enter"), now: 0) == [.openSelectedBook])

        keymap.setMode(.reader)
        #expect(keymap.handle(ReaderKeyEvent(key: "Enter"), now: 0).isEmpty)
    }

    @Test("i, /, l, Escape, and o map to their actions")
    func miscKeys() {
        let keymap = ReaderKeymap(mode: .reader)
        #expect(keymap.handle(ReaderKeyEvent(key: "i"), now: 0) == [.focusNotes])
        #expect(keymap.handle(ReaderKeyEvent(key: "/"), now: 0) == [.search])
        #expect(keymap.handle(ReaderKeyEvent(key: "l"), now: 0) == [.backToLibrary])
        #expect(keymap.handle(ReaderKeyEvent(key: "Escape"), now: 0) == [.backToLibrary])
        #expect(keymap.handle(ReaderKeyEvent(key: "o"), now: 0) == [.importBook])
    }

    @Test("ctrl and meta combos are ignored so menus keep working")
    func modifierCombosAreIgnored() {
        let keymap = ReaderKeymap(mode: .reader)
        #expect(keymap.handle(ReaderKeyEvent(key: "g", ctrl: true), now: 0).isEmpty)
        #expect(keymap.handle(ReaderKeyEvent(key: "j", meta: true), now: 0).isEmpty)
        #expect(!keymap.pendingG)
    }
}
