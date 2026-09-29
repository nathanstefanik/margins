import Foundation
import Testing

@testable import MarginsCore

/// Vectors are a slice of the official Snowball English vocabulary
/// (snowballstem.org/algorithms/english), the exceptional-forms list, and
/// the words the step-1b invariants protect.
@Suite("Text analysis")
struct TextAnalysisTests {
    // MARK: Porter2

    @Test(
        "porter2 stems match the Snowball vectors",
        arguments: [
            ("consign", "consign"), ("consigned", "consign"), ("consigning", "consign"),
            ("consignment", "consign"), ("consist", "consist"), ("consisted", "consist"),
            ("consistency", "consist"), ("consistent", "consist"), ("consistently", "consist"),
            ("consisting", "consist"), ("consists", "consist"), ("consolation", "consol"),
            ("consolations", "consol"), ("consolatory", "consolatori"), ("console", "consol"),
            ("consoled", "consol"), ("consoles", "consol"), ("consolidate", "consolid"),
            ("consolidated", "consolid"), ("consolidating", "consolid"), ("consoling", "consol"),
            ("consolingly", "consol"), ("consols", "consol"), ("consonant", "conson"),
            ("consort", "consort"), ("consorted", "consort"), ("consorting", "consort"),
            ("conspicuous", "conspicu"), ("conspicuously", "conspicu"), ("conspiracy", "conspiraci"),
            ("conspirator", "conspir"), ("conspirators", "conspir"), ("conspire", "conspir"),
            ("conspired", "conspir"), ("conspiring", "conspir"), ("constable", "constabl"),
            ("constables", "constabl"), ("constance", "constanc"), ("constancy", "constanc"),
            ("constant", "constant"),
            ("knack", "knack"), ("knackeries", "knackeri"), ("knacks", "knack"), ("knag", "knag"),
            ("knave", "knave"), ("knaves", "knave"), ("knavish", "knavish"), ("kneaded", "knead"),
            ("kneading", "knead"), ("knee", "knee"), ("kneel", "kneel"), ("kneeled", "kneel"),
            ("kneeling", "kneel"), ("kneels", "kneel"), ("knees", "knee"), ("knell", "knell"),
            ("knelt", "knelt"), ("knew", "knew"), ("knick", "knick"), ("knif", "knif"),
            ("knife", "knife"), ("knight", "knight"), ("knightly", "knight"), ("knights", "knight"),
            ("knit", "knit"), ("knits", "knit"), ("knitted", "knit"), ("knitting", "knit"),
            ("knives", "knive"), ("knob", "knob"), ("knobs", "knob"), ("knock", "knock"),
            ("knocked", "knock"), ("knocker", "knocker"), ("knockers", "knocker"),
            ("knocking", "knock"), ("knocks", "knock"), ("knopp", "knopp"), ("knot", "knot"),
            ("knots", "knot"),
            ("caresses", "caress"), ("ponies", "poni"), ("ties", "tie"), ("cats", "cat"),
            ("agreed", "agre"), ("plastered", "plaster"), ("motoring", "motor"), ("sing", "sing"),
            ("hopping", "hop"), ("falling", "fall"), ("hissing", "hiss"), ("filing", "file"),
            ("happy", "happi"), ("deceive", "deceiv"), ("deceived", "deceiv"),
            ("deceiving", "deceiv"), ("deception", "decept"), ("generously", "generous"),
            // The exceptional-forms list (Snowball's exception1).
            ("skis", "ski"), ("skies", "sky"), ("dying", "die"), ("lying", "lie"),
            ("tying", "tie"), ("idly", "idl"), ("gently", "gentl"), ("ugly", "ugli"),
            ("early", "earli"), ("only", "onli"), ("singly", "singl"),
            // The invariant forms.
            ("sky", "sky"), ("news", "news"), ("howe", "howe"), ("atlas", "atlas"),
            ("cosmos", "cosmos"), ("bias", "bias"), ("andes", "andes"),
            // The step-1b invariants (checked where the suffix is handled).
            ("inning", "inning"), ("outing", "outing"), ("canning", "canning"),
            ("herring", "herring"), ("earring", "earring"), ("evening", "evening"),
            ("proceed", "proceed"), ("exceed", "exceed"), ("succeed", "succeed"),
            // Words of two letters or fewer are unchanged.
            ("is", "is"), ("as", "as"), ("be", "be"),
            // Snowball 3.x additions: -eed exceptions inside step 1b, and the
            // "past"/vocabulary-spacing region prefixes.
            ("deed", "deed"), ("feed", "feed"), ("agreement", "agreement"),
            ("pasted", "paste"), ("pasting", "paste"), ("paste", "paste"), ("past", "past"),
            // Longest-match semantics: step 2's among picks "entli", which
            // fails the R1 test, so the shorter "li" never applies.
            ("fluently", "fluentli"), ("statements", "statement"),
        ])
    func porter2Vector(word: String, stem: String) {
        #expect(Porter2.stem(word) == stem)
    }

    // MARK: Analyzer

    @Test("an apostrophe between letters stays inside the token and folds away")
    func apostrophes() {
        let dont = TextAnalyzer.tokens("Don't")
        #expect(dont.map(\.folded) == ["dont"])

        let possessive = TextAnalyzer.tokens("Alyosha's")
        #expect(possessive.map(\.folded) == ["alyosha"])

        // A curly apostrophe is the same token.
        #expect(TextAnalyzer.tokens("don’t").map(\.folded) == ["dont"])
        // A trailing/leading apostrophe is not inside a token.
        #expect(TextAnalyzer.tokens("'tis").map(\.folded) == ["tis"])
    }

    @Test("folding is case- and diacritic-insensitive")
    func folding() {
        #expect(TextAnalyzer.tokens("café").map(\.folded) == ["cafe"])
        #expect(TextAnalyzer.tokens("STRAßE").map(\.folded) == ["strasse"])

        let naive = TextAnalyzer.tokens("Naïve")
        #expect(naive.map(\.folded) == ["naive"])
        // All-ASCII folded → stemmed.
        #expect(naive.map(\.stem) == ["naiv"])
    }

    @Test("non-ASCII tokens stem to their folded form")
    func nonASCIIStemsToFolded() {
        let tokens = TextAnalyzer.tokens("Ивана и Zoë")
        // "Zoë" folds to ASCII "zoe" → stemmed like a normal word;
        // Cyrillic tokens keep the folded form as their stem.
        #expect(tokens.map(\.folded) == ["ивана", "и", "zoe"])
        #expect(tokens[0].stem == tokens[0].folded)
        #expect(tokens[1].stem == tokens[1].folded)
    }

    @Test("token ranges are UTF-16 offsets into the original text")
    func utf16Ranges() {
        // 📚 is two UTF-16 units; é could be one character or two scalars.
        let text = "📚 café bar"
        let tokens = TextAnalyzer.tokens(text)
        #expect(tokens.count == 2)
        let units = Array(text.utf16)
        #expect(
            String(decoding: units[tokens[0].start16..<tokens[0].end16], as: UTF16.self)
                == "café")
        #expect(
            String(decoding: units[tokens[1].start16..<tokens[1].end16], as: UTF16.self)
                == "bar")
        #expect(tokens[0].start16 == 3)

        let mixed = TextAnalyzer.tokens("x🎉y zz")
        #expect(mixed.map(\.folded) == ["x", "y", "zz"])
        #expect(mixed[2].start16 == 5)
    }

    @Test("analyzeTerm applies the same pipeline to a query word")
    func analyzeTerm() {
        #expect(TextAnalyzer.analyzeTerm("Deceiving")?.folded == "deceiving")
        #expect(TextAnalyzer.analyzeTerm("Deceiving")?.stem == "deceiv")
        #expect(TextAnalyzer.analyzeTerm("it's")?.folded == "it")
        #expect(TextAnalyzer.analyzeTerm("—") == nil)
    }

    // MARK: Edit distance

    @Test("OSA distance: transposition, classic example, limit pruning")
    func osa() {
        #expect(EditDistance.osa("decieve", "deceive", limit: 2) == 1)
        #expect(EditDistance.osa("kitten", "sitting", limit: 3) == 3)
        #expect(EditDistance.osa("kitten", "sitting", limit: 2) == nil)
        #expect(EditDistance.osa("book", "book", limit: 0) == 0)
        #expect(EditDistance.osa("", "abc", limit: 3) == 3)
        // Length difference beyond the limit prunes before any DP.
        #expect(EditDistance.osa("a", "abcdef", limit: 2) == nil)
        // OSA, not full Damerau: the transposed substring can't be edited twice.
        #expect(EditDistance.osa("ca", "abc", limit: 3) == 3)
    }
}
