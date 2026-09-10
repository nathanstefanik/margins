//! Dumps `serde_yaml::to_string` for the scalar shapes a chapter title can
//! take, so the Swift frontmatter codec can be pinned against real output
//! rather than a reading of the YAML spec (docs/apple-only-plan.md Phase 2
//! step 3). The table it prints is baked into
//! `apple/Tests/MarginsCoreTests/FrontmatterTests.swift`. Temporary;
//! deleted with the crates in step 7.
//!
//!     cargo run -p margins-core --example probe_yaml

fn main() {
    let cases = [
        "Introduction", "The Market", "A Title: With / Punctuation!", "003", "123", "0", "1.5",
        "true", "false", "null", "~", "yes", "no", "on", "off", "Null", "TRUE",
        "", " leading", "trailing ", "-dash", "- dash", "?q", ":colon", ",comma", "[bracket",
        "]bracket", "{brace", "}brace", "#hash", "&amp", "*star", "!bang", "|pipe", ">gt",
        "'quote", "\"dquote", "%pct", "@at", "`tick", "a: b", "a:b", "a #c", "a#c", "ends:",
        "multi\nline", "tab\there", "epubcfi(/6/6!/4/2/1:0)", "OEBPS/chapter1.xhtml",
        "2026-08-29T12:00:00Z", "2026-08-29", "12:30", "e5", "0x1f", "0o17", ".inf", ".nan",
        "Café — naïve 中文 📚", "hello world", "Chapter II. He Gets Rid Of His Eldest Son",
        "  ", "\ttab-start", "a  b", "-", "--", "5e3", "+3", "1_000",
    ];
    for case in cases {
        let yaml = serde_yaml::to_string(&serde_yaml::Value::String(case.to_string())).unwrap();
        println!("{:?}\t=>\t{:?}", case, yaml);
    }
}
