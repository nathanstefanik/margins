import assert from "node:assert/strict";
import fs from "node:fs";
import ts from "typescript";

const source = fs.readFileSync(new URL("../src/keymaps.ts", import.meta.url), "utf8");
const javascript = ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.ESNext },
}).outputText;
const { Keymap } = await import(`data:text/javascript;base64,${Buffer.from(javascript).toString("base64")}`);
globalThis.HTMLElement = class {};

const calls = [];
let scrolls = 0;
const keymap = new Keymap({
  onLibrary: () => calls.push("library"),
  onImport: () => calls.push("import"),
  onExport: () => calls.push("export"),
  onSetRoot: () => calls.push("root"),
  onOpenBook: () => calls.push("open"),
  onScroll: () => scrolls++,
  onScrollTop: () => {},
  onScrollBottom: () => {},
  onNextChapter: () => {},
  onPrevChapter: () => {},
  onFocusNotes: () => {},
  onFocusReader: () => calls.push("focus-reader"),
  onSaveNote: () => {},
  onSearch: () => {},
  onCommand: () => {},
  onStatus: () => {},
});

keymap.setMode("library");
keymap.handleCommandKey({ key: "Enter", preventDefault() {} }, { value: "root" });
assert.deepEqual(calls, ["root"], "a cancelled :root should not focus the reader");
assert.equal(keymap.getMode(), "library", "a cancelled :root should preserve library mode");

calls.length = 0;
keymap.setMode("library");
keymap.handleCommandKey({ key: "Enter", preventDefault() {} }, { value: "q" });
assert.deepEqual(calls, ["library"], ":q should not force reader focus");
assert.equal(keymap.getMode(), "library", ":q should preserve library mode");

calls.length = 0;
keymap.setMode("reader");
keymap.handleKey({ key: ":", preventDefault() {} }, null);
keymap.handleCommandKey({ key: "Escape", preventDefault() {} }, { value: "" });
assert.deepEqual(calls, ["focus-reader"], "escaping command mode should restore reader focus");
assert.equal(keymap.getMode(), "reader", "escaping command mode should restore reader mode");

keymap.setMode("notes");
keymap.handleKey({ key: "j", preventDefault() {} }, { tagName: "TEXTAREA" });
assert.equal(scrolls, 0, "typing targets must not trigger reader shortcuts across realms");

console.log("keymap regression tests passed");
