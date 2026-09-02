import assert from "node:assert/strict";
import fs from "node:fs";
import ts from "typescript";

const source = fs
  .readFileSync(new URL("../src/reader.ts", import.meta.url), "utf8")
  .replace('import ePub, { Book, Rendition } from "epubjs";', "const ePub = globalThis.__testEpub;");
const javascript = ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.ESNext },
}).outputText;

const listeners = new Map();
const rendition = {
  on(type, listener) {
    listeners.set(type, listener);
  },
  off(type, listener) {
    if (listeners.get(type) === listener) {
      listeners.delete(type);
    }
  },
  async display() {},
  destroy() {},
};

globalThis.__testEpub = () => ({
  ready: Promise.resolve(),
  renderTo() {
    return rendition;
  },
  destroy() {},
});

const { EpubReader } = await import(
  `data:text/javascript;base64,${Buffer.from(javascript).toString("base64")}`,
);
const forwarded = [];
const reader = new EpubReader(
  { innerHTML: "", querySelector: () => null, scrollBy() {} },
  () => {},
  (event) => forwarded.push(event),
);

await reader.open(new Uint8Array(), [
  { key: "001", index: 0, title: "Chapter", href: "chapter.xhtml" },
]);
listeners.get("keydown")?.({ key: "j" });

assert.equal(forwarded.length, 1, "EPUB keydown events must reach the app keymap");
assert.equal(forwarded[0].key, "j");

reader.destroy();
assert.equal(listeners.has("keydown"), false, "reader keydown listener must be cleaned up");

console.log("reader keymap regression test passed");
