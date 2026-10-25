// The editor page of FleetView's file window.
//
// One EditorView for the whole window; each tab is an EditorState swapped into it, so a tab costs
// its text and its undo history, not a web content process. Swift owns everything that touches the
// disk or git — versions, conflicts, watching, saving. This page only edits text and draws it, and
// talks to Swift through `fvBridge`: `post(msg)` for messages (a Promise when Swift replies) and
// `fetchText(url)` for file contents, which arrive through the `fvfile:` scheme rather than through
// the message channel, so a 20 MB file is one response and not one serialised argument.

import {EditorState, Compartment, StateEffect, StateField, RangeSetBuilder, Transaction} from "@codemirror/state";
import {
  EditorView, keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter, drawSelection,
  highlightSpecialChars, Decoration, rectangularSelection, crosshairCursor, dropCursor,
} from "@codemirror/view";
import {defaultKeymap, history, historyKeymap, indentWithTab} from "@codemirror/commands";
import {searchKeymap, highlightSelectionMatches, openSearchPanel, setSearchQuery, SearchQuery, gotoLine} from "@codemirror/search";
import {syntaxHighlighting, HighlightStyle, bracketMatching, indentOnInput, foldGutter, foldKeymap, StreamLanguage} from "@codemirror/language";
import {tags as t, highlightTree} from "@lezer/highlight";
import {Chunk, MergeView, diff as textDiff} from "@codemirror/merge";
import MarkdownIt from "markdown-it";
import {markdown, markdownLanguage} from "@codemirror/lang-markdown";
import {javascript} from "@codemirror/lang-javascript";
import {python} from "@codemirror/lang-python";
import {json} from "@codemirror/lang-json";
import {html} from "@codemirror/lang-html";
import {css} from "@codemirror/lang-css";
import {yaml} from "@codemirror/lang-yaml";
import {xml} from "@codemirror/lang-xml";
import {rust} from "@codemirror/lang-rust";
import {go} from "@codemirror/lang-go";
import {cpp} from "@codemirror/lang-cpp";
import {java} from "@codemirror/lang-java";
import {sql} from "@codemirror/lang-sql";
import {swift} from "@codemirror/legacy-modes/mode/swift";
import {shell} from "@codemirror/legacy-modes/mode/shell";
import {toml} from "@codemirror/legacy-modes/mode/toml";
import {dockerFile} from "@codemirror/legacy-modes/mode/dockerfile";
import {properties} from "@codemirror/legacy-modes/mode/properties";
import {diff as diffMode} from "@codemirror/legacy-modes/mode/diff";
import {ruby} from "@codemirror/legacy-modes/mode/ruby";
import {lua} from "@codemirror/legacy-modes/mode/lua";

// ---------------------------------------------------------------- bridge

const bridge = window.fvBridge || {
  post(msg) {
    const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.fv;
    return h ? h.postMessage(msg) : Promise.resolve(null);
  },
  async fetchText(url) {
    const r = await fetch(url, {cache: "no-store"});
    const headers = {};
    r.headers.forEach((v, k) => { headers[k.toLowerCase()] = v; });
    return {ok: r.ok, status: r.status, text: await r.text(), headers};
  },
};
const post = (type, body = {}) => {
  try { return bridge.post({type, ...body}); } catch (e) { return Promise.resolve(null); }
};
const appURL = path => "fvfile://app/" + path;
const rawURL = abs => appURL("raw" + abs.split("/").map(encodeURIComponent).join("/"));

// ---------------------------------------------------------------- words

const WORDS = {
  zh: {
    outline: "大纲", noPreview: "没有内容", imageHint: "点图片在「适应窗口」和「实际大小」之间切换",
    compareTitle: "左边是磁盘上的版本，右边是你的。把需要的改动从左边拿过来，再保存右边。",
    saveMerged: "保存右边的结果", cancel: "取消", loading: "读取中…",
    phrases: {
      "Find": "查找", "Replace": "替换", "next": "下一个", "previous": "上一个", "all": "全部",
      "match case": "区分大小写", "regexp": "正则", "by word": "整词", "replace": "替换",
      "replace all": "全部替换", "close": "关闭", "Go to line": "跳到行", "go": "跳转",
      "current match": "当前匹配", "on line": "在行", "replaced $ matches": "替换了 $ 处",
      "replaced match on line $": "替换了第 $ 行的匹配", "folded code": "已折叠", "unfold": "展开",
      "to": "到", "Control character": "控制字符", "Revert this chunk": "还原这一块",
      "Accept": "接受", "Reject": "拒绝",
    },
  },
  en: {
    outline: "Outline", noPreview: "Nothing to show", imageHint: "Click the image to switch between fit and actual size",
    compareTitle: "Left is the version on disk, right is yours. Bring over what you need from the left, then save the right.",
    saveMerged: "Save the right side", cancel: "Cancel", loading: "Loading…",
    phrases: {},
  },
};
let words = WORDS.en;

// ---------------------------------------------------------------- languages

const stream = mode => () => StreamLanguage.define(mode);
const LANGS = {
  markdown: () => markdown({base: markdownLanguage, codeLanguages: info => languageFor(info)}),
  javascript: () => javascript(), jsx: () => javascript({jsx: true}),
  typescript: () => javascript({typescript: true}), tsx: () => javascript({typescript: true, jsx: true}),
  python: () => python(), json: () => json(), html: () => html(), css: () => css(), yaml: () => yaml(),
  xml: () => xml(), rust: () => rust(), go: () => go(), cpp: () => cpp(), java: () => java(), sql: () => sql(),
  swift: stream(swift), shell: stream(shell), toml: stream(toml), dockerfile: stream(dockerFile),
  properties: stream(properties), diff: stream(diffMode), ruby: stream(ruby), lua: stream(lua),
};
// Fence names in Markdown, mapped onto the ids above.
const ALIAS = {
  js: "javascript", mjs: "javascript", cjs: "javascript", ts: "typescript", py: "python", sh: "shell",
  bash: "shell", zsh: "shell", console: "shell", yml: "yaml", rs: "rust", golang: "go", c: "cpp",
  "c++": "cpp", h: "cpp", hpp: "cpp", objc: "cpp", ini: "properties", conf: "properties",
  docker: "dockerfile", md: "markdown", patch: "diff", rb: "ruby", htm: "html", svg: "xml", plist: "xml",
};
const supportCache = new Map();
function supportFor(id) {
  id = ALIAS[id] || id;
  if (!LANGS[id]) return null;
  if (!supportCache.has(id)) supportCache.set(id, LANGS[id]());
  return supportCache.get(id);
}
function languageFor(info) {
  const s = supportFor((info || "").trim().toLowerCase().split(/\s/)[0]);
  return s ? (s.language || s) : null;
}

// ---------------------------------------------------------------- look

const highlight = HighlightStyle.define([
  {tag: [t.keyword, t.controlKeyword, t.operatorKeyword, t.definitionKeyword, t.moduleKeyword, t.modifier, t.self], color: "var(--hk)"},
  {tag: [t.string, t.special(t.string), t.regexp, t.character, t.inserted], color: "var(--hs)"},
  {tag: [t.comment, t.lineComment, t.blockComment, t.docComment], color: "var(--hc)", fontStyle: "italic"},
  {tag: [t.number, t.bool, t.null, t.atom, t.unit], color: "var(--hn)"},
  {tag: [t.typeName, t.className, t.namespace, t.standard(t.typeName)], color: "var(--ht)"},
  {tag: [t.function(t.variableName), t.function(t.propertyName), t.macroName], color: "var(--hf)"},
  {tag: [t.propertyName, t.attributeName, t.labelName], color: "var(--hp)"},
  {tag: [t.meta, t.annotation, t.processingInstruction, t.attributeValue], color: "var(--ha)"},
  {tag: t.tagName, color: "var(--hk)"},
  {tag: t.heading, color: "var(--hk)", fontWeight: "600"},
  {tag: [t.link, t.url], color: "var(--hf)", textDecoration: "underline"},
  {tag: t.strong, fontWeight: "600"},
  {tag: t.emphasis, fontStyle: "italic"},
  {tag: t.strikethrough, textDecoration: "line-through"},
  {tag: [t.invalid, t.deleted], color: "var(--err)"},
]);

const theme = EditorView.theme({
  "&": {height: "100%", color: "var(--text)", backgroundColor: "var(--bg)", fontSize: "var(--fs)"},
  ".cm-scroller": {fontFamily: "var(--mono)", lineHeight: "1.6"},
  ".cm-content": {caretColor: "var(--accent)", padding: "6px 0 40vh"},
  ".cm-cursor, .cm-dropCursor": {borderLeftColor: "var(--accent)", borderLeftWidth: "2px"},
  "&.cm-focused .cm-selectionBackground, .cm-selectionBackground, ::selection": {backgroundColor: "var(--sel) !important"},
  ".cm-gutters": {backgroundColor: "var(--bg)", color: "var(--gutter)", border: "none"},
  ".cm-lineNumbers .cm-gutterElement": {padding: "0 12px 0 14px", minWidth: "36px"},
  ".cm-activeLine": {backgroundColor: "var(--activeLine)"},
  ".cm-activeLineGutter": {backgroundColor: "transparent", color: "var(--text)"},
  ".cm-foldGutter .cm-gutterElement": {color: "var(--gutter)"},
  ".cm-panels": {backgroundColor: "var(--panel)", color: "var(--text)", borderColor: "var(--stroke)"},
  ".cm-panels.cm-panels-top": {borderBottom: "1px solid var(--stroke)"},
  ".cm-panel input, .cm-panel button, .cm-textfield": {fontFamily: "inherit", fontSize: "12px"},
  ".cm-textfield": {backgroundColor: "var(--bg)", color: "var(--text)", border: "1px solid var(--stroke)", borderRadius: "6px", padding: "3px 6px"},
  ".cm-button": {backgroundImage: "none", backgroundColor: "var(--high)", color: "var(--text)", border: "none", borderRadius: "6px", padding: "3px 10px"},
  ".cm-searchMatch": {backgroundColor: "var(--match)"},
  ".cm-searchMatch.cm-searchMatch-selected": {backgroundColor: "var(--matchCur)", color: "var(--onMatchCur)"},
  ".cm-selectionMatch": {backgroundColor: "var(--selMatch)"},
  ".cm-matchingBracket, &.cm-focused .cm-matchingBracket": {backgroundColor: "var(--selMatch)", outline: "none"},
  ".cm-foldPlaceholder": {backgroundColor: "var(--high)", border: "none", color: "var(--sub)"},
  ".cm-tooltip": {backgroundColor: "var(--panel)", border: "1px solid var(--stroke)", color: "var(--text)"},
  ".cm-fv-changed": {backgroundColor: "var(--tint)"},
  ".cm-fv-added": {backgroundColor: "var(--tintAdd)"},
  ".cm-fv-deletedAbove": {boxShadow: "inset 0 2px 0 var(--del)"},
  ".cm-fv-flash": {animation: "fvflash 6s ease-out"},
  ".cm-fv-goto": {animation: "fvgoto 1.8s ease-out"},
}, {dark: true});

// ---------------------------------------------------------------- per-tab state

/** tab id → {meta, state, savedDoc, dirty, scroll, mode, head, headLen, chunks, ...} */
const docs = new Map();
let active = null;
let view = null;
let previewTimer = 0;
const host = {};

const readOnlyC = new Compartment(), langC = new Compartment(), wrapC = new Compartment(), phraseC = new Compartment();

// Lines changed against HEAD, and lines an outside reload just touched.
const setDiffDeco = StateEffect.define();
const diffField = StateField.define({
  create: () => Decoration.none,
  update(deco, tr) {
    for (const e of tr.effects) if (e.is(setDiffDeco)) return e.value;
    return deco.map(tr.changes);
  },
  provide: f => EditorView.decorations.from(f),
});
const setFlash = StateEffect.define();
const flashField = StateField.define({
  create: () => Decoration.none,
  update(deco, tr) {
    for (const e of tr.effects) if (e.is(setFlash)) return e.value;
    return deco.map(tr.changes);
  },
  provide: f => EditorView.decorations.from(f),
});

const changedLine = Decoration.line({class: "cm-fv-changed"});
const addedLine = Decoration.line({class: "cm-fv-added"});
const deletedAbove = Decoration.line({class: "cm-fv-deletedAbove"});
const flashLine = Decoration.line({class: "cm-fv-flash"});
const gotoLineDeco = Decoration.line({class: "cm-fv-goto"});

/** How much work a document of this size may cost per edit. */
function tier(len) {
  if (len <= 2_000_000) return {diff: true, wait: 200, budget: 100};
  if (len <= 20_000_000) return {diff: true, wait: 1000, budget: 200};
  return {diff: false};
}

function lineDecos(doc, ranges, deco) {
  const b = new RangeSetBuilder();
  for (const [from, to] of ranges) {
    let pos = Math.min(from, doc.length);
    // A range ending at a line's start stops on the line before it: an inserted "…\n" must not
    // light up the untouched line that follows.
    let end = Math.min(to, doc.length);
    if (end > pos && doc.lineAt(end).from === end) end -= 1;
    for (;;) {
      const line = doc.lineAt(pos);
      b.add(line.from, line.from, deco);
      if (line.to >= end || line.number >= doc.lines) break;
      pos = line.to + 1;
    }
  }
  return b.finish();
}

function chunkDecos(doc, chunks) {
  const b = new RangeSetBuilder();
  for (const c of chunks) {
    if (c.fromB === c.toB) {
      const line = doc.lineAt(Math.min(c.fromB, doc.length));
      b.add(line.from, line.from, deletedAbove);
      continue;
    }
    const deco = c.fromA === c.toA ? addedLine : changedLine;
    let pos = c.fromB;
    const end = Math.min(c.endB, doc.length);
    for (;;) {
      const line = doc.lineAt(pos);
      b.add(line.from, line.from, deco);
      if (line.to >= end || line.number >= doc.lines) break;
      pos = line.to + 1;
    }
  }
  return b.finish();
}

function chunkStats(d, chunks) {
  let added = 0, changed = 0, deleted = 0;
  for (const c of chunks) {
    const linesB = c.fromB === c.toB ? 0 : d.state.doc.lineAt(Math.min(c.endB, d.state.doc.length)).number - d.state.doc.lineAt(c.fromB).number + 1;
    const linesA = c.fromA === c.toA ? 0 : d.head.lineAt(Math.min(c.endA, d.head.length)).number - d.head.lineAt(c.fromA).number + 1;
    if (!linesA) added += linesB;
    else if (!linesB) deleted += linesA;
    else { changed += Math.min(linesA, linesB); if (linesB > linesA) added += linesB - linesA; else deleted += linesA - linesB; }
  }
  return {added, changed, deleted};
}

function scheduleDiff(d) {
  clearTimeout(d.diffTimer);
  if (!d.head || !d.tier.diff) return;
  d.diffTimer = setTimeout(() => computeDiff(d), d.tier.wait);
}

function computeDiff(d) {
  if (!d.head || !d.state) return;
  const state = d.id === active ? view.state : d.state;
  const chunks = Chunk.build(d.head, state.doc, {scanLimit: 20000, timeout: d.tier.budget});
  d.chunks = chunks;
  const effects = setDiffDeco.of(chunkDecos(state.doc, chunks));
  if (d.id === active) view.dispatch({effects});
  else d.state = d.state.update({effects}).state;
  const s = chunkStats({state, head: d.head}, chunks);
  post("diffStats", {tab: d.id, ...s});
  if (d.id === active && d.mode === "preview") renderPreviewSoon(d, 0);
}

// ---------------------------------------------------------------- editor setup

function baseExtensions(d) {
  const big = d.meta.length > 20_000_000 || d.meta.longLine;
  const support = big ? null : supportFor(d.meta.lang);
  return [
    lineNumbers(), foldGutter(), highlightActiveLineGutter(), highlightSpecialChars(), history(),
    drawSelection(), dropCursor(), indentOnInput(), bracketMatching(), rectangularSelection(),
    crosshairCursor(), highlightActiveLine(), highlightSelectionMatches(),
    syntaxHighlighting(highlight), theme, diffField, flashField,
    langC.of(support || []),
    readOnlyC.of(EditorState.readOnly.of(!!d.meta.readOnly)),
    wrapC.of(d.wrap ? EditorView.lineWrapping : []),
    phraseC.of(EditorState.phrases.of(words.phrases)),
    keymap.of([
      {key: "Mod-s", run: () => { save(d.id); return true; }, preventDefault: true},
      {key: "Mod-p", run: () => { post("key", {name: "quickOpen"}); return true; }, preventDefault: true},
      {key: "Mod-Shift-f", run: () => { post("key", {name: "searchFiles"}); return true; }, preventDefault: true},
      {key: "Mod-w", run: () => { post("key", {name: "closeTab"}); return true; }, preventDefault: true},
      {key: "Ctrl--", run: () => { post("key", {name: "back"}); return true; }, preventDefault: true},
      {key: "Ctrl-Shift--", run: () => { post("key", {name: "forward"}); return true; }, preventDefault: true},
      {key: "Ctrl-g", run: gotoLine, preventDefault: true},
      ...defaultKeymap, ...historyKeymap, ...searchKeymap, ...foldKeymap, indentWithTab,
    ]),
    EditorView.updateListener.of(u => onUpdate(d, u)),
  ];
}

function onUpdate(d, u) {
  if (d.id !== active) return;
  if (u.docChanged) {
    const doc = u.state.doc;
    const clean = doc === d.savedDoc || (doc.length === d.savedDoc.length && doc.eq(d.savedDoc));
    setDirty(d, !clean);
    scheduleDiff(d);
    if (d.dirty) scheduleSnapshot(d);
  }
  if (u.selectionSet || u.docChanged) reportCursor(d, u.state);
}

let cursorTimer = 0;
function reportCursor(d, state) {
  clearTimeout(cursorTimer);
  cursorTimer = setTimeout(() => {
    const head = state.selection.main.head, line = state.doc.lineAt(head);
    post("cursor", {tab: d.id, line: line.number, col: head - line.from + 1, lines: state.doc.lines});
  }, 120);
}

function setDirty(d, dirty) {
  if (d.dirty === dirty) return;
  d.dirty = dirty;
  post("dirty", {tab: d.id, dirty});
  if (!dirty) { clearTimeout(d.snapTimer); d.snapped = null; }
}

// Unsaved text is mirrored to Swift once typing pauses, so a crashed page or a forced quit loses at
// most the last second. Larger documents wait longer: each mirror is a full copy.
function scheduleSnapshot(d) {
  clearTimeout(d.snapTimer);
  const wait = (d.id === active ? view.state.doc.length : 0) > 2_000_000 ? 5000 : 1000;
  d.snapTimer = setTimeout(() => {
    const doc = d.id === active ? view.state.doc : d.state.doc;
    if (!d.dirty || doc === d.snapped) return;
    d.snapped = doc;
    post("snapshot", {tab: d.id, text: doc.toString()});
  }, wait);
}

// ---------------------------------------------------------------- loading

async function load(d) {
  const r = await bridge.fetchText(appURL("doc/" + encodeURIComponent(d.id)));
  if (!r.ok) {
    let info = {kind: "error", title: r.text || String(r.status)};
    try { info = JSON.parse(r.text); } catch (e) {}
    d.info = info;
    return false;
  }
  d.meta.readOnly = d.meta.readOnly || !!r.headers["x-fv-readonly"];
  d.meta.readOnlyReason = r.headers["x-fv-readonly"] || d.meta.readOnlyReason || "";
  d.meta.length = r.text.length;
  d.meta.longLine = hasLongLine(r.text);
  d.tier = tier(r.text.length);
  d.state = EditorState.create({doc: r.text, extensions: baseExtensions(d)});
  d.savedDoc = d.state.doc;
  d.dirty = false;
  d.info = null;
  return true;
}

function hasLongLine(text) {
  let start = 0;
  for (;;) {
    const nl = text.indexOf("\n", start);
    const end = nl < 0 ? text.length : nl;
    if (end - start > 10000) return true;
    if (nl < 0) return false;
    start = nl + 1;
  }
}

async function loadHead(d) {
  if (!d.tier || !d.tier.diff) return;
  const r = await bridge.fetchText(appURL("head/" + encodeURIComponent(d.id)));
  if (!docs.has(d.id)) return;
  d.head = r.ok ? EditorState.create({doc: r.text}).doc : null;
  if (!d.head) {
    d.chunks = [];
    const effects = setDiffDeco.of(Decoration.none);
    if (d.id === active && d.state) view.dispatch({effects}); else if (d.state) d.state = d.state.update({effects}).state;
    post("diffStats", {tab: d.id, added: 0, changed: 0, deleted: 0, none: true});
    return;
  }
  computeDiff(d);
}

// ---------------------------------------------------------------- showing a tab

function stash() {
  const d = docs.get(active);
  if (!d || !d.state) return;
  d.state = view.state;
  d.scroll = view.scrollDOM.scrollTop;
  if (d.mode === "preview") d.previewScroll = host.preview.scrollTop;
}

function display(which) {
  // A view that was hidden measured nothing; line heights and the gutter are only right once it
  // measures again while visible.
  if (which === "cm" && host.cm.style.display === "none") requestAnimationFrame(() => view.requestMeasure());
  host.cm.style.display = which === "cm" ? "" : "none";
  host.preview.style.display = which === "preview" ? "" : "none";
  host.info.style.display = which === "info" ? "" : "none";
}

function showDoc(d) {
  if (d.info) { renderInfo(d.info); display("info"); return; }
  if (!d.state) { renderInfo({kind: "loading", title: words.loading}); display("info"); return; }
  view.setState(d.state);
  if (d.mode === "preview") {
    display("preview");
    renderPreview(d);
    host.preview.scrollTop = d.previewScroll || 0;
  } else {
    display("cm");
    requestAnimationFrame(() => { view.scrollDOM.scrollTop = d.scroll || 0; });
  }
  reportCursor(d, view.state);
}

// Clean tabs out of sight give their editor state back when there are many of them, or they are
// large; switching back reads the file again. Dirty tabs keep everything.
function evict() {
  const idle = [...docs.values()].filter(d => d.id !== active && d.state && !d.dirty && d.kind === "text");
  let total = idle.reduce((n, d) => n + d.state.doc.length, 0);
  idle.sort((a, b) => (a.seen || 0) - (b.seen || 0));
  while (idle.length > 8 || (idle.length && total > 50_000_000)) {
    const d = idle.shift();
    total -= d.state.doc.length;
    d.state = null; d.savedDoc = null; d.head = null; d.chunks = null; d.preview = null;
  }
}

// ---------------------------------------------------------------- Markdown preview

const mdit = new MarkdownIt({html: false, linkify: false, typographer: false});
const escapeHTML = s => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

function highlightCode(code, info) {
  const lang = languageFor(info);
  if (!lang || code.length > 200_000) return escapeHTML(code);
  let out = "", pos = 0;
  try {
    const tree = lang.parser.parse(code);
    highlightTree(tree, highlight, (from, to, cls) => {
      if (from > pos) out += escapeHTML(code.slice(pos, from));
      out += `<span class="${cls}">${escapeHTML(code.slice(from, to))}</span>`;
      pos = to;
    });
  } catch (e) { return escapeHTML(code); }
  return out + escapeHTML(code.slice(pos));
}

function slug(text, seen) {
  let s = text.toLowerCase().trim().replace(/[^\p{L}\p{N}\s-]/gu, "").replace(/\s+/g, "-") || "section";
  if (seen.has(s)) { let n = 1; while (seen.has(`${s}-${n}`)) n++; s = `${s}-${n}`; }
  seen.add(s);
  return s;
}

function resolvePath(dir, href) {
  let p = href;
  try { p = decodeURIComponent(href); } catch (e) {}
  const parts = (p.startsWith("/") ? p : dir + "/" + p).split("/");
  const out = [];
  for (const s of parts) { if (!s || s === ".") continue; if (s === "..") out.pop(); else out.push(s); }
  return "/" + out.join("/");
}

mdit.core.ruler.push("fv_lines", state => {
  for (const tok of state.tokens) {
    if (tok.map && tok.nesting !== -1 && tok.block) {
      tok.attrSet("data-l0", String(tok.map[0] + 1));
      tok.attrSet("data-l1", String(tok.map[1]));
    }
  }
});
mdit.renderer.rules.fence = (tokens, i) => {
  const tok = tokens[i];
  const [l0, l1] = tok.map ? [tok.map[0] + 1, tok.map[1]] : [0, 0];
  return `<pre data-l0="${l0}" data-l1="${l1}"><code>${highlightCode(tok.content, tok.info)}</code></pre>\n`;
};
mdit.renderer.rules.code_block = mdit.renderer.rules.fence;
const defaultLinkOpen = mdit.renderer.rules.link_open || ((tokens, i, opts, env, self) => self.renderToken(tokens, i, opts));
mdit.renderer.rules.link_open = (tokens, i, opts, env, self) => {
  const tok = tokens[i];
  tok.attrSet("data-href", tok.attrGet("href") || "");
  tok.attrSet("href", "#");
  return defaultLinkOpen(tokens, i, opts, env, self);
};
mdit.renderer.rules.image = (tokens, i, opts, env) => {
  const tok = tokens[i];
  let src = tok.attrGet("src") || "";
  if (!/^(https?:|data:)/.test(src)) src = rawURL(resolvePath(env.dir, src.split("#")[0]));
  const alt = escapeHTML(tok.content || "");
  return `<img src="${escapeHTML(src)}" alt="${alt}">`;
};
mdit.renderer.rules.heading_open = (tokens, i, opts, env, self) => {
  const tok = tokens[i];
  const text = tokens[i + 1] ? tokens[i + 1].content : "";
  const id = slug(text, env.seen);
  tok.attrSet("id", id);
  if (tok.tag <= "h4") env.toc.push({level: Number(tok.tag[1]), text, id});
  return self.renderToken(tokens, i, opts);
};

function renderPreviewSoon(d, wait = 300) {
  clearTimeout(previewTimer);
  previewTimer = setTimeout(() => { if (d.id === active && d.mode === "preview") renderPreview(d); }, wait);
}

function renderPreview(d) {
  const doc = d.id === active ? view.state.doc : d.state.doc;
  if (!d.preview || d.preview.doc !== doc) {
    const env = {dir: d.meta.path.slice(0, d.meta.path.lastIndexOf("/")) || "/", toc: [], seen: new Set()};
    const html = mdit.render(doc.toString(), env);
    d.preview = {doc, html, toc: env.toc};
  }
  const keep = host.preview.scrollTop;
  host.article.innerHTML = d.preview.html || `<p class="empty">${words.noPreview}</p>`;
  host.toc.innerHTML = d.preview.toc.length > 1
    ? `<div class="toch">${words.outline}</div>` + d.preview.toc.map(h =>
        `<a class="l${h.level}" data-id="${escapeHTML(h.id)}">${escapeHTML(h.text)}</a>`).join("")
    : "";
  host.toc.style.display = d.preview.toc.length > 1 ? "" : "none";
  host.preview.scrollTop = keep;
  tintPreview(d);
  spy();
}

function tintPreview(d) {
  const changed = [], flashed = [];
  if (d.chunks && d.head) {
    const doc = d.id === active ? view.state.doc : d.state.doc;
    for (const c of d.chunks) {
      if (c.fromB === c.toB) continue;
      changed.push([doc.lineAt(c.fromB).number, doc.lineAt(Math.min(c.endB, doc.length)).number]);
    }
  }
  if (d.flashLines) flashed.push(...d.flashLines);
  for (const el of host.article.querySelectorAll("[data-l0]")) {
    const a = +el.dataset.l0, z = +el.dataset.l1;
    if (el.querySelector("[data-l0]") && el.tagName !== "PRE") continue;   // tint the innermost block
    if (changed.some(([x, y]) => x <= z && y >= a)) el.classList.add("fv-changed");
    if (flashed.some(n => n >= a && n <= z)) el.classList.add("fv-flash");
  }
}

function spy() {
  const links = host.toc.querySelectorAll("a");
  if (!links.length) return;
  const top = host.preview.getBoundingClientRect().top;
  let current = null;
  for (const h of host.article.querySelectorAll("h1[id],h2[id],h3[id],h4[id]")) {
    if (h.getBoundingClientRect().top - top <= 16) current = h.id; else break;
  }
  if (!current) current = links[0].dataset.id;
  for (const a of links) a.classList.toggle("on", a.dataset.id === current);
}

// ---------------------------------------------------------------- info panels and images

function renderInfo(info) {
  host.info.innerHTML = "";
  const box = document.createElement("div");
  if (info.kind === "image") {
    box.className = "imgview fit";
    const img = document.createElement("img");
    img.src = info.url;
    const cap = document.createElement("div");
    cap.className = "imgmeta";
    cap.textContent = info.detail || "";
    img.onload = () => { cap.textContent = `${img.naturalWidth} × ${img.naturalHeight}` + (info.detail ? ` · ${info.detail}` : ""); };
    img.title = words.imageHint;
    img.onclick = () => box.classList.toggle("fit");
    box.append(img, cap);
  } else {
    box.className = "infocard " + (info.kind || "");
    const h = document.createElement("h3");
    h.textContent = info.title || "";
    const p = document.createElement("p");
    p.textContent = info.detail || "";
    box.append(h, p);
    if (info.actions && info.actions.length) {
      const row = document.createElement("div");
      row.className = "actions";
      for (const a of info.actions) {
        const b = document.createElement("button");
        b.textContent = a.label;
        b.onclick = () => post("action", {tab: active, id: a.id});
        row.append(b);
      }
      box.append(row);
    }
  }
  host.info.append(box);
}

// ---------------------------------------------------------------- saving

async function save(id) {
  const d = docs.get(id);
  if (!d || !d.state || d.meta.readOnly) return;
  if (id === active) d.state = view.state;
  const doc = d.state.doc;
  if (!d.dirty) return;
  const reply = await post("save", {tab: id, text: doc.toString()});
  if (reply && reply.ok) markSaved(d, doc);
}

function markSaved(d, doc) {
  d.savedDoc = doc;
  const current = d.id === active ? view.state.doc : d.state.doc;
  setDirty(d, !(current === doc || (current.length === doc.length && current.eq(doc))));
}

// ---------------------------------------------------------------- compare and merge

let merge = null;
async function compare(id) {
  const d = docs.get(id);
  if (!d || !d.state) return;
  const r = await bridge.fetchText(appURL("disk/" + encodeURIComponent(id)));
  if (!r.ok) return;
  if (id === active) d.state = view.state;
  closeCompare();
  host.compare.style.display = "";
  host.compareText.textContent = words.compareTitle;
  host.compareSave.textContent = words.saveMerged;
  host.compareCancel.textContent = words.cancel;
  const support = supportFor(d.meta.lang);
  const ext = [lineNumbers(), syntaxHighlighting(highlight), theme, support || [], EditorState.phrases.of(words.phrases)];
  merge = new MergeView({
    a: {doc: r.text, extensions: [...ext, EditorState.readOnly.of(true)]},
    b: {doc: d.state.doc.toString(), extensions: ext},
    parent: host.compareBody,
    revertControls: "a-to-b",
    highlightChanges: true,
    gutter: true,
  });
  host.compareSave.onclick = async () => {
    const text = merge.b.state.doc.toString();
    const reply = await post("saveMerged", {tab: id, text});
    if (reply && reply.ok) {
      replaceText(d, text, true);
      closeCompare();
    }
  };
  host.compareCancel.onclick = closeCompare;
}

function closeCompare() {
  if (merge) { merge.destroy(); merge = null; }
  host.compare.style.display = "none";
  host.compareBody.innerHTML = "";
}

/** Replace a tab's whole text: the version on disk after a conflict, or a merged result. */
function replaceText(d, text, clean) {
  if (d.id === active) d.state = view.state;
  const tr = d.state.update({changes: {from: 0, to: d.state.doc.length, insert: text}, annotations: Transaction.userEvent.of("fv.replace")});
  d.state = tr.state;
  if (d.id === active) view.setState(d.state);
  if (clean) { d.savedDoc = d.state.doc; setDirty(d, false); }
  else setDirty(d, true);
  d.preview = null;
  scheduleDiff(d);
  if (d.id === active) showDoc(d);
}

// ---------------------------------------------------------------- reloading from disk

/** The file changed on disk and the tab has no unsaved edits: bring the new text in as one undoable
 *  edit, keep the view where it was, and light up the lines that changed. */
async function reload(id) {
  const d = docs.get(id);
  if (!d) return;
  if (!d.state) { if (id === active) { await load(d); showDoc(d); loadHead(d); } return; }
  if (id === active) d.state = view.state;
  const r = await bridge.fetchText(appURL("doc/" + encodeURIComponent(id)));
  if (!r.ok) { try { d.info = JSON.parse(r.text); } catch (e) { d.info = {kind: "error", title: r.text}; } if (id === active) showDoc(d); return; }
  const old = d.state.doc.toString(), text = r.text;
  if (old === text) { d.savedDoc = d.state.doc; setDirty(d, false); return; }
  let changes, flash = [];
  if (old.length + text.length <= 4_000_000) {
    changes = textDiff(old, text, {scanLimit: 20000, timeout: 150}).map(c => ({from: c.fromA, to: c.toA, insert: text.slice(c.fromB, c.toB)}));
  } else {
    changes = [{from: 0, to: old.length, insert: text}];
  }
  const keep = id === active ? view.scrollDOM.scrollTop : d.scroll;
  const tr = d.state.update({changes, annotations: Transaction.userEvent.of("fv.reload")});
  const doc = tr.state.doc;
  // Which lines to light up comes from a line-aligned diff: the character diff that built the
  // transaction can start an insertion after a line's indentation and so spill into the next line.
  if (!(changes.length === 1 && changes[0].from === 0 && changes[0].to === old.length)) {
    for (const c of Chunk.build(d.state.doc, doc, {scanLimit: 20000, timeout: 100})) {
      if (c.fromB < c.toB) flash.push([c.fromB, Math.min(c.endB, doc.length)]);
    }
  }
  let state = tr.state;
  if (flash.length) {
    state = state.update({effects: setFlash.of(lineDecos(doc, flash, flashLine))}).state;
    d.flashLines = flash.map(([a]) => doc.lineAt(a).number);
    clearTimeout(d.flashTimer);
    d.flashTimer = setTimeout(() => {
      d.flashLines = null;
      const effects = setFlash.of(Decoration.none);
      if (d.id === active && d.state) view.dispatch({effects}); else if (d.state) d.state = d.state.update({effects}).state;
    }, 6500);
  }
  d.state = state;
  d.savedDoc = d.state.doc;
  d.meta.length = text.length;
  d.tier = tier(text.length);
  d.preview = null;
  if (id === active) {
    view.setState(d.state);
    if (d.mode === "preview") renderPreview(d);
    requestAnimationFrame(() => { view.scrollDOM.scrollTop = keep; });
    reportCursor(d, view.state);         // setState fires no update: the status bar's line count would go stale
  } else {
    d.scroll = keep;
  }
  setDirty(d, false);
  scheduleDiff(d);
}

// ---------------------------------------------------------------- the API Swift calls

const api = {
  /** First call after the page loads: theme, language, font size. */
  init(opts) {
    words = WORDS[opts.lang] || WORDS.en;
    if (opts.lang === "zh") words.phrases = WORDS.zh.phrases;
    setTheme(opts.colors || {}, opts.fontSize);
    // Tabs opened before this (none, normally) keep the phrases they were made with.
    if (view) view.dispatch({effects: phraseC.reconfigure(EditorState.phrases.of(words.phrases))});
    return true;
  },
  setTheme(colors, fontSize) { setTheme(colors, fontSize); return true; },

  /** A tab: {path, lang, kind: text|image|info, readOnly, readOnlyReason, wrap, mode, info, line}. */
  async open(id, meta) {
    stash();
    let d = docs.get(id);
    if (!d) {
      d = {id, meta: {...meta}, kind: meta.kind || "text", mode: meta.mode || "source", wrap: !!meta.wrap, dirty: false};
      docs.set(id, d);
    }
    active = id;
    d.seen = Date.now();
    if (d.kind !== "text") { d.info = meta.info; showDoc(d); return {ok: true}; }
    if (!d.state && !d.info) {
      showDoc(d);
      const loaded = await load(d);
      if (active !== id) return {ok: loaded};
      showDoc(d);
      if (loaded) loadHead(d);
    } else {
      showDoc(d);
    }
    if (meta.line) api.goto(id, meta.line);
    if (meta.find) api.find(meta.find);
    evict();
    return {ok: !d.info, readOnly: !!d.meta.readOnly, reason: d.meta.readOnlyReason || ""};
  },
  async show(id) {
    if (!docs.has(id)) return {ok: false};
    stash();
    active = id;
    const d = docs.get(id);
    d.seen = Date.now();
    if (d.kind === "text" && !d.state && !d.info) {
      showDoc(d);
      await load(d);
      if (active !== id) return {ok: true};
      showDoc(d);
      loadHead(d);
    } else {
      showDoc(d);
    }
    evict();
    return {ok: true};
  },
  close(id) {
    const d = docs.get(id);
    if (d) { clearTimeout(d.diffTimer); clearTimeout(d.snapTimer); clearTimeout(d.flashTimer); }
    docs.delete(id);
    if (active === id) active = null;
    return true;
  },
  setMode(id, mode) {
    const d = docs.get(id);
    if (!d) return false;
    if (id === active) stash();
    d.mode = mode;
    if (id === active) showDoc(d);
    return true;
  },
  setWrap(id, on) {
    const d = docs.get(id);
    if (!d || !d.state) return false;
    d.wrap = on;
    const effects = wrapC.reconfigure(on ? EditorView.lineWrapping : []);
    if (id === active) view.dispatch({effects}); else d.state = d.state.update({effects}).state;
    return true;
  },
  setReadOnly(id, on) {
    const d = docs.get(id);
    if (!d) return false;
    d.meta.readOnly = on;
    if (!d.state) return true;
    const effects = readOnlyC.reconfigure(EditorState.readOnly.of(on));
    if (id === active) view.dispatch({effects}); else d.state = d.state.update({effects}).state;
    return true;
  },
  goto(id, line) {
    const d = docs.get(id);
    if (!d || id !== active || !d.state) return false;
    if (d.mode === "preview") {
      const all = [...host.article.querySelectorAll("[data-l0]")];
      // The innermost block holding the line, or — for a blank line between blocks — the next one.
      const el = all.filter(e => +e.dataset.l0 <= line && +e.dataset.l1 >= line).pop()
        || all.find(e => +e.dataset.l0 >= line);
      if (el) { el.scrollIntoView({block: "center"}); el.classList.remove("fv-goto"); void el.offsetWidth; el.classList.add("fv-goto"); }
      return true;
    }
    const doc = view.state.doc;
    const l = doc.line(Math.max(1, Math.min(line, doc.lines)));
    view.dispatch({
      selection: {anchor: l.from},
      effects: [EditorView.scrollIntoView(l.from, {y: "center"}), setFlash.of(lineDecos(doc, [[l.from, l.from]], gotoLineDeco))],
    });
    view.focus();
    return true;
  },
  gotoPrompt() { if (active && docs.get(active).mode !== "preview") gotoLine(view); return true; },
  find(query) {
    const d = docs.get(active);
    if (!d || !d.state) return false;
    if (d.mode === "preview") { stash(); d.mode = "source"; showDoc(d); post("mode", {tab: d.id, mode: "source"}); }
    openSearchPanel(view);
    if (query) view.dispatch({effects: setSearchQuery.of(new SearchQuery({search: query, caseSensitive: false}))});
    return true;
  },
  /** Text of the active or a given tab, for saving from Swift (quit, close). */
  text(id) {
    const d = docs.get(id);
    if (!d || !d.state) return null;
    return (id === active ? view.state.doc : d.state.doc).toString();
  },
  /** Every tab with unsaved edits, and its text. */
  dirtyTexts() {
    if (active && docs.get(active) && docs.get(active).state) docs.get(active).state = view.state;
    return [...docs.values()].filter(d => d.dirty && d.state).map(d => ({tab: d.id, text: d.state.doc.toString()}));
  },
  /** Swift saved this exact text for the tab. */
  markSaved(id, text) {
    const d = docs.get(id);
    if (!d || !d.state) return false;
    const doc = id === active ? view.state.doc : d.state.doc;
    if (doc.toString() === text) markSaved(d, doc);
    return true;
  },
  /** Throw the edits away and read the file again. */
  async discard(id) {
    const d = docs.get(id);
    if (!d) return false;
    d.state = null; d.savedDoc = null; d.preview = null;
    setDirty(d, false);
    if (id === active) { showDoc(d); await load(d); showDoc(d); loadHead(d); }
    return true;
  },
  reload,
  /** Recovered text from an earlier session, put in as unsaved edits. */
  async restore(id, text) {
    const d = docs.get(id);
    if (!d) return false;
    if (!d.state && !(await load(d))) return false;
    replaceText(d, text, false);
    scheduleSnapshot(d);
    return true;
  },
  /** Use the version on disk after a conflict. */
  async useDisk(id) {
    const d = docs.get(id);
    if (!d) return false;
    if (!d.state) { const ok = await load(d); if (id === active) showDoc(d); return ok; }
    const r = await bridge.fetchText(appURL("doc/" + encodeURIComponent(id)));
    if (!r.ok) return false;
    replaceText(d, r.text, true);
    return true;
  },
  compare,
  /** HEAD moved: fetch the baseline again. */
  headChanged(id) { const d = docs.get(id); if (d && d.state) loadHead(d); return true; },
  focus() { if (view) view.focus(); return true; },
  /** ⌘S from the window when the editor itself does not have focus. */
  saveActive() { if (active) save(active); return true; },
  stats() {
    return [...docs.values()].map(d => ({tab: d.id, path: d.meta.path, chars: d.state ? d.state.doc.length : 0, dirty: d.dirty}));
  },
};
window.fv = api;

function setTheme(colors, fontSize) {
  const root = document.documentElement.style;
  for (const [k, v] of Object.entries(colors)) {
    if (k === "scheme") { document.documentElement.style.colorScheme = v; continue; }
    root.setProperty("--" + k, v);
  }
  if (fontSize) root.setProperty("--fs", fontSize + "px");
  if (view) view.requestMeasure();
}

// ---------------------------------------------------------------- page wiring

function boot() {
  host.cm = document.getElementById("cm");
  host.preview = document.getElementById("preview");
  host.article = document.getElementById("article");
  host.toc = document.getElementById("toc");
  host.info = document.getElementById("info");
  host.compare = document.getElementById("compare");
  host.compareBody = document.getElementById("compareBody");
  host.compareText = document.getElementById("compareText");
  host.compareSave = document.getElementById("compareSave");
  host.compareCancel = document.getElementById("compareCancel");
  view = new EditorView({parent: host.cm, state: EditorState.create({doc: ""})});
  display("info");

  host.article.addEventListener("click", e => {
    const a = e.target.closest("a[data-href]");
    if (!a) return;
    e.preventDefault();
    const href = a.dataset.href;
    if (href.startsWith("#")) {
      const el = document.getElementById(decodeURIComponent(href.slice(1)));
      if (el) el.scrollIntoView({block: "start"});
      return;
    }
    const d = docs.get(active);
    post("link", {tab: active, href, from: d ? d.meta.path : ""});
  });
  host.toc.addEventListener("click", e => {
    const a = e.target.closest("a[data-id]");
    if (!a) return;
    const el = document.getElementById(a.dataset.id);
    if (el) el.scrollIntoView({block: "start"});
  });
  host.preview.addEventListener("scroll", () => requestAnimationFrame(spy), {passive: true});
  // A window that was covered or minimised gets no animation frames; measure again when it shows.
  document.addEventListener("visibilitychange", () => { if (!document.hidden && view) view.requestMeasure(); });

  // Keys that mean something to the window, when the editor itself does not have focus.
  document.addEventListener("keydown", e => {
    if (e.target.closest && e.target.closest(".cm-editor")) return;
    const mod = e.metaKey || e.ctrlKey;
    const k = e.key.toLowerCase();
    let name = null;
    if (mod && !e.shiftKey && k === "p") name = "quickOpen";
    else if (mod && e.shiftKey && k === "f") name = "searchFiles";
    else if (mod && !e.shiftKey && k === "w") name = "closeTab";
    else if (mod && !e.shiftKey && k === "s") { e.preventDefault(); if (active) save(active); return; }
    else if (mod && !e.shiftKey && k === "f") { e.preventDefault(); api.find(""); return; }
    if (name) { e.preventDefault(); post("key", {name}); }
  });
  post("ready");
}

if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot); else boot();
