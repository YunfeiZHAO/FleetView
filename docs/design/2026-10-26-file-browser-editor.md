# A file window on the desktop: browse, read and edit a project's files

2026-10-26. The desktop counterpart of the web dashboard's 📁 browser, at the size a desk allows.

## What it is

Each project on the board gets a 📁 button in its header. It opens one window per project: a file
tree on the left, tabs and an editor on the right. Markdown reads rendered or as source; code is
highlighted; any UTF-8 text file can be edited and saved, and the lines that differ from git's HEAD
are tinted while you type. The same window opens from a card's menu at the card's working directory,
and from the sidebar's project heading.

There is no linting, no language server and no build integration. It is a reader that can write.

## Decisions

**The desktop writes files itself; the web does not gain anything.** The window reads and writes the
disk in-process and hands text to its web view through a custom URL scheme, never through the
embedded HTTP server. The web `/save` stays Markdown-only — its comment says why: an edit to a script
from a phone is one an agent should be making. So the LAN can do exactly what it could before.

**No size cap on the desktop.** `/read` returns a 512 KB prefix because a phone should not pay for a
200 MB log opened by accident. On the desktop the editor only draws the lines on screen, so the whole
file is loaded; what scales with size is the work done per keystroke, and that is what is cut back:

| size | highlighting | lines changed vs HEAD |
|---|---|---|
| ≤ 2 MB | yes | recomputed 200 ms after typing stops |
| 2–20 MB | yes | recomputed 1 s after typing stops, capped at 200 ms of work |
| > 20 MB | no | no |
| any line > 10 000 chars | no | as above |

Above 100 MB the window asks before opening. A file with a NUL in its first 8 KB is binary and is
not opened as text; invalid UTF-8 and files that mix CRLF with LF open read-only — saving either would
rewrite bytes the user never touched.

**The window stays out of the agents' way.** Several agents usually work in the same repository, and
they commit. Two measured facts shape every git call:

- Porcelain `git diff` rewrites `.git/index` even with `--no-optional-locks` — verified on git 2.50.1:
  `git --no-optional-locks diff HEAD -- f` and `diff --quiet` both wrote it. While it holds
  `index.lock`, an agent's `git commit` fails. (A race of 150 commits against a plain `git status`
  loop failed 31 of them; with `status --no-optional-locks`, none.)
- `status --no-optional-locks`, `diff-index`, `diff-files`, `diff-tree`, `cat-file`, `ls-files`,
  `check-ignore`, `rev-parse`, `grep` and `log` write nothing.

So every git call is `git --no-optional-locks -c core.fsmonitor=false -C <dir> …` with
`GIT_OPTIONAL_LOCKS=0`, from the allow-list above, through one binary resolved once (`xcrun --find
git`; the `/usr/bin/git` shim costs ~10 ms a call), at utility QoS, with a 10 s timeout. `status`
runs at most once at a time per repository, two git processes at most across the app, never while
`index.lock` exists, and never while the window cannot be seen.

**HEAD is read through the filters.** The tint compares the editor with what HEAD would check out,
which is `cat-file --filters`, not `git show`: with `eol=crlf`, `ident`, a smudge filter or an LFS
pointer, the raw blob differs from the file on every line while git itself reports no change. The blob
is found with `rev-parse HEAD:./<name>` run from the file's own directory, which is also what makes a
file inside a submodule resolve. It is cached by object id and fetched again only when HEAD or a ref
moves — which, in a worktree, happens in the main repository's git directory, outside the project.

**Never walk a project.** `code_sense` holds about eight million files that are neither tracked nor
ignored; `status -uall` there takes 42–57 s and prints 284 MB. The tree reads one directory when it is
expanded (at most 3000 entries, the web's cap). ⌘P searches `git ls-files` — tracked files, 11 ms for
7 788 in that repository — plus the names of untracked directories, unexpanded. Search runs
`git grep` over tracked files. A folder that is not a repository is walked with a hard limit and a
list of directories that are never entered (`node_modules`, `.venv`, `.build`, …).

**Saving does not change anything it was not asked to.** `Data.write(.atomic)` replaces a symlink with
a regular file, breaks hard links, drops extended attributes and leaves a temporary file inside the
project while it writes — where an agent's `git add -A` can pick it up. The save instead:

1. resolves the path, requires a regular file inside the project, and compares its SHA-256 with the
   version the editor opened; a mismatch is a conflict, not an overwrite;
2. if the file changed in the last second, looks again 150 ms later — a size or mtime change means an
   agent is writing it right now, which is a conflict too;
3. writes the new bytes to a file in the volume's item-replacement directory (outside the project),
   gives it the original's mode, ACL, extended attributes and creation date — not its mtime, which
   must move so tools that check "changed since I read it" see the save — and syncs it;
4. checks once more that the original has not changed, then swaps the two with
   `renamex_np(RENAME_SWAP)`, and reads the file it swapped out: if that is not the version checked in
   step 1, an agent wrote in between, so it swaps back and reports a conflict;
5. falls back to an in-place write (same inode) for a hard-linked file, a file owned by someone else,
   or a directory it cannot create files in.

The web `/save` goes through the same code, keeping its Markdown-only rule and its 409.

**Line endings and BOMs survive.** The editor only ever sees LF. A CRLF file is converted on the way
in and back on the way out; a BOM is noted, stripped and restored. A missing final newline stays
missing. Nothing trims whitespace.

**Disk changes while you edit.** A file nobody is editing is reloaded when it changes on disk, keeping
the scroll position, and the reload is an undoable edit — so an agent's `git checkout -- file` over
something you just saved is one ⌘Z away. A file with unsaved edits is never reloaded: a banner says the
disk changed and offers *Use disk version*, *Compare* and *Overwrite*. Unsaved text is mirrored to
`~/.fleetview/editor-recovery/` a second after typing stops (15 s above 2 MB, 60 s above 20 MB), so a
crashed web view or a forced quit does not take it; quitting, closing the window and the self-update
handoff all ask first.

**Which version a save is checked against.** Swift keeps, per tab, the version (SHA-256) the editor
holds; a save is refused as a conflict when the disk is not that version. The page reads a file two
ways: `doc/` for a first read — nothing else is in the tab, so the version moves at once — and `disk/`
for a reload, *Use disk version* and *Compare*, which move nothing: the page answers `applied` with the
version it took, and only then is it the base. A reload whose read is overtaken by typing stops and
shows the banner instead. *Overwrite* replaces the version the banner was about, and a merge from
*Compare* the version its left side showed — a write by an agent after either is a conflict again, not
lost. Restored edits (from a crash or an earlier session) keep the version they were made against, so
a save over a newer disk version is a conflict too. Saves of one tab run one at a time.

**Who changed it.** Claude's `PreToolUse` hook already forwards every tool call's input; `Write`,
`Edit`, `MultiEdit` and `NotebookEdit` name the file. Codex's `apply_patch` names files in its
`*** Update File:` headers. Those paths feed a small ring buffer per project that the window's "recently
changed" list reads. Transcripts are not scanned for this; a file changed through a shell command is
shown without an author rather than guessed.

## Resource budget

Measured on 2026-10-26 with the method in the perf baseline (`ps` cputime over 60 s, `footprint`):

| | budget |
|---|---|
| no file window open | nothing: no git process, no web content process, no watcher |
| window open, covered or minimised | ≤ 0.3 % of a core; no git; changes only remembered |
| editing, an agent writing beside you | app ≤ 2 %, git ≤ 3 % of a core |
| after closing | web content process gone within 10 s, footprint back within 10 MB |

What keeps it there: one WKWebView per window, tabs switching editor states inside it; one FSEvents
stream per window, directory-level, 0.5 s latency, with `.git/objects`, `.build`, `node_modules` and
similar excluded; a vnode source per open tab for exact change, rename and delete; git status driven by
those events with a 1.5 s trailing debounce and a minimum interval that grows with how long the last
one took; window state in its own model object, never in `AppState`.

## Review, 2026-10-26

Three reviews of the finished implementation (races, resource cost, UI). What they changed, besides
the save protocol above:

- Only regular files are opened, read, served or watched — opening a FIFO blocks. A file whose bytes
  would not come back unchanged (two BOMs) is read-only, and so is one a reload finds read-only.
- The web's `/save` refuses hard-linked files (`allowInPlace: false`): a link inside a project would
  otherwise let the LAN write the file's other name.
- "Open with default app" is not offered for programs, scripts and bundles, where it means *run*.
- "Reference in card" quotes for its reader and refuses a path with a control character.
- Cost: a tab out of sight is only marked and checked when shown; a listing out of sight is dropped;
  each folder is read at most once a second and `check-ignore` is skipped when its names did not
  change; HEAD is compared as files before `rev-parse`; `status` takes the project as a pathspec; the
  file index is fetched once at a time; typing redraws only the status bar.

One claim did not reproduce: that `copyfile(ACL|XATTR)` fails on a temp file already `fchmod`ed to
0444. On macOS 26 / APFS it returns 0 and the mode stays 0444; a test (`a read-only mode survives`)
now holds that.

## Architecture

- `Sources/FleetViewFiles/` — a Foundation-only target, tested by `FleetViewAuditTests`: text probing
  and round-tripping, the save procedure, the read-only git runner and its parsers, the quick-open
  matcher, and the tool-call path extractor.
- `Sources/FleetView/Files/` — the window: controller, SwiftUI shell (tree, tabs, toolbar, banners,
  status bar), the web view with its `fvfile:` scheme handler and message bridge, the watcher.
- `Editor/` — the editor page: CodeMirror 6 and markdown-it, bundled by esbuild into `Editor/dist/`,
  which is committed so neither `swift build` nor `package_app.sh` needs Node. `package_app.sh` copies
  it into the app's Resources and refuses to package without it.

## Phases

1. A read-only viewer: window, lazy tree with git markers, tabs, highlighting, Markdown preview,
   images, reload on change, the three entry points, "reference in card".
2. Editing: save, conflicts, recovery, prompts on close, quit and update; the web `/save` on the
   shared save code.
3. The tint against HEAD.
4. Quick open, search in files, back and forward.
5. Recently changed files and who changed them.

History and compare views (the 提交 / 对比 pages of the earlier git mockup) came next: see
[the file window's history](2026-10-26-file-window-history.md).
