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
  onNotesPage: () => {
    calls.push("notes-page");
    keymap.setMode("notesPage"); // mirrors App.openNotesPage
  },
  onNotesPageRestore: () => calls.push("notes-page-restore"),
  onNotesClose: () => calls.push("notes-close"),
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

// N opens the notes page from the reader; Esc on the page closes it.
calls.length = 0;
keymap.setMode("reader");
keymap.handleKey({ key: "N", preventDefault() {} }, null);
assert.deepEqual(calls, ["notes-page"], "N in reader mode should open the notes page");

keymap.setMode("reader");
keymap.handleKey({ key: "n", preventDefault() {} }, null);
assert.deepEqual(calls, ["notes-page"], "lowercase n must not open the notes page");

calls.length = 0;
keymap.setMode("notesPage");
keymap.handleKey({ key: "Escape", preventDefault() {} }, null);
assert.deepEqual(calls, ["notes-close"], "Esc on the notes page should return to the reader");

calls.length = 0;
keymap.setMode("reader");
keymap.handleCommandKey({ key: "Enter", preventDefault() {} }, { value: "notes" });
assert.deepEqual(calls, ["notes-page"], ":notes should open the notes page");
assert.equal(keymap.getMode(), "notesPage", ":notes should switch to the notes page mode");

calls.length = 0;
keymap.setMode("library");
keymap.handleKey({ key: "N", preventDefault() {} }, null);
assert.deepEqual(calls, [], "N must not open the notes page from the library");

console.log("keymap regression tests passed");
