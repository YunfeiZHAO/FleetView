import Darwin
import FleetViewFiles
import Foundation

/// A scratch directory per test, removed afterwards.
class FileTestCase: XCTestCase {
    var dir = ""

    override func setUp() {
        dir = NSTemporaryDirectory() + "fv-files-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        dir = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
    }

    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    func write(_ name: String, _ bytes: [UInt8]) -> String {
        let p = dir + "/" + name
        FileManager.default.createFile(atPath: p, contents: Data(bytes))
        return p
    }

    func write(_ name: String, _ text: String) -> String { write(name, Array(text.utf8)) }

    func read(_ path: String) -> Data { FileManager.default.contents(atPath: path) ?? Data() }
}

final class FileTextTests: FileTestCase {
    func testLFRoundTripsUnchanged() throws {
        let bytes = Data("a\nb\nno final newline".utf8)
        let d = try XCTUnwrap(FileText.decode(bytes))
        XCTAssertEqual(d.eol, .lf)
        XCTAssertNil(d.readOnlyReason)
        XCTAssertEqual(FileText.encode(d.text, eol: d.eol, bom: d.bom), bytes)
    }

    func testCRLFIsLFInsideAndCRLFOnDisk() throws {
        let bytes = Data("one\r\ntwo\r\n".utf8)
        let d = try XCTUnwrap(FileText.decode(bytes))
        XCTAssertEqual(d.eol, .crlf)
        XCTAssertEqual(d.text, "one\ntwo\n")
        XCTAssertEqual(FileText.encode(d.text, eol: .crlf, bom: false), bytes)
        XCTAssertEqual(FileText.encode("one\ntwo\nthree\n", eol: .crlf, bom: false), Data("one\r\ntwo\r\nthree\r\n".utf8))
    }

    func testBOMIsStrippedAndRestored() throws {
        let bytes = Data([0xEF, 0xBB, 0xBF] + Array("hi\n".utf8))
        let d = try XCTUnwrap(FileText.decode(bytes))
        XCTAssertTrue(d.bom)
        XCTAssertEqual(d.text, "hi\n")
        XCTAssertEqual(FileText.encode(d.text, eol: d.eol, bom: d.bom), bytes)
    }

    func testMixedLineEndingsAreReadOnly() throws {
        XCTAssertEqual(FileText.decode(Data("a\r\nb\n".utf8))?.readOnlyReason, .mixedLineEndings)
        XCTAssertEqual(FileText.decode(Data("a\rb\n".utf8))?.readOnlyReason, .mixedLineEndings)
        XCTAssertEqual(FileText.decode(Data("a\r\nb\n".utf8))?.text, "a\nb\n")
    }

    func testWhatCannotRoundTripIsReadOnly() throws {
        // Two BOMs: decoding drops both, encoding restores one.
        let bytes = Data([0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF] + Array("hi\n".utf8))
        XCTAssertEqual(FileText.decode(bytes)?.readOnlyReason, .notRoundTrip)
    }

    func testInvalidUTF8HasNoText() {
        XCTAssertNil(FileText.decode(Data([0x61, 0xFF, 0xFE, 0x62])))
    }

    func testBinaryIsANulInTheFirst8K() {
        XCTAssertTrue(FileText.isBinary(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])))
        XCTAssertFalse(FileText.isBinary(Data("plain text".utf8)))
        XCTAssertFalse(FileText.isBinary(Data(repeating: 0x61, count: 9000) + Data([0])))
    }

    func testLongLines() {
        XCTAssertTrue(FileText.hasLongLine(String(repeating: "x", count: 10_001)))
        XCTAssertFalse(FileText.hasLongLine(String(repeating: String(repeating: "x", count: 100) + "\n", count: 500)))
    }
}

final class FileSaveTests: FileTestCase {
    private func version(_ p: String) -> String { FileText.version(read(p)) }

    func testSavesWhenTheBaseMatches() {
        let p = write("a.txt", "old\n")
        let out = FileSave.save(Data("new\n".utf8), to: p, base: version(p), force: false)
        guard case .saved(let v, let fp) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(String(decoding: read(p), as: UTF8.self), "new\n")
        XCTAssertEqual(v, FileText.version(Data("new\n".utf8)))
        XCTAssertEqual(fp, FileSave.fingerprint(path: p), "the fingerprint is the file now on disk")
    }

    func testAChangedFileIsAConflictAndIsLeftAlone() {
        let p = write("a.txt", "old\n")
        let base = version(p)
        _ = write("a.txt", "an agent wrote this\n")
        let out = FileSave.save(Data("mine\n".utf8), to: p, base: base, force: false)
        XCTAssertEqual(out, .conflict(current: version(p)))
        XCTAssertEqual(String(decoding: read(p), as: UTF8.self), "an agent wrote this\n")
    }

    func testForceOverwrites() {
        let p = write("a.txt", "theirs\n")
        guard case .saved = FileSave.save(Data("mine\n".utf8), to: p, base: "stale", force: true) else {
            return XCTFail("force should save")
        }
        XCTAssertEqual(String(decoding: read(p), as: UTF8.self), "mine\n")
    }

    func testPermissionsSurvive() throws {
        let p = write("run.sh", "#!/bin/sh\n")
        chmod(p, 0o755)
        _ = FileSave.save(Data("#!/bin/sh\necho hi\n".utf8), to: p, base: version(p), force: false)
        let attrs = try FileManager.default.attributesOfItem(atPath: p)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }

    func testASymlinkStaysASymlink() throws {
        let target = write("AGENTS.md", "rules\n")
        let link = dir + "/CLAUDE.md"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "AGENTS.md")
        guard case .saved = FileSave.save(Data("rules, edited\n".utf8), to: link, base: version(link), force: false) else {
            return XCTFail("save through a link")
        }
        let type = try FileManager.default.attributesOfItem(atPath: link)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeSymbolicLink, "the link must not be replaced by a file")
        XCTAssertEqual(String(decoding: read(target), as: UTF8.self), "rules, edited\n")
    }

    func testAHardLinkIsWrittenInPlace() throws {
        let a = write("a.txt", "one\n")
        let b = dir + "/b.txt"
        XCTAssertEqual(link(a, b), 0)
        _ = FileSave.save(Data("two\n".utf8), to: a, base: version(a), force: false)
        XCTAssertEqual(String(decoding: read(b), as: UTF8.self), "two\n", "both names still share the content")
    }

    func testExtendedAttributesSurvive() {
        let p = write("tagged.txt", "x\n")
        let value = Array("kept".utf8)
        XCTAssertEqual(setxattr(p, "com.fleetview.test", value, value.count, 0, 0), 0)
        _ = FileSave.save(Data("y\n".utf8), to: p, base: version(p), force: false)
        var buf = [UInt8](repeating: 0, count: 16)
        let n = getxattr(p, "com.fleetview.test", &buf, buf.count, 0, 0)
        XCTAssertEqual(n, value.count)
        XCTAssertEqual(Array(buf.prefix(max(0, n))), value)
    }

    func testNothingIsLeftBesideTheFile() throws {
        let p = write("a.txt", "x\n")
        let before = try FileManager.default.contentsOfDirectory(atPath: dir).sorted()
        _ = FileSave.save(Data(repeating: 0x61, count: 2_000_000), to: p, base: version(p), force: false)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir).sorted(), before)
    }

    func testTheModificationTimeMoves() throws {
        let p = write("a.txt", "x\n")
        let past = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: p)
        _ = FileSave.save(Data("y\n".utf8), to: p, base: version(p), force: false)
        let m = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: p)[.modificationDate] as? Date)
        XCTAssertGreaterThan(m.timeIntervalSince(past), 3000, "tools that check 'changed since I read it' must see the save")
    }

    func testTheWebRefusesAHardLink() {
        let a = write("note.md", "one\n")
        let outside = dir + "/outside.txt"
        XCTAssertEqual(link(a, outside), 0)
        guard case .failed = FileSave.save(Data("two\n".utf8), to: a, base: version(a), force: false, allowInPlace: false) else {
            return XCTFail("a hard-linked file must not be written in place for the web")
        }
        XCTAssertEqual(String(decoding: read(outside), as: UTF8.self), "one\n")
    }

    func testReadOnlyModeSurvives() throws {
        let p = write("ro.txt", "x\n")
        chmod(p, 0o444)
        _ = FileSave.save(Data("y\n".utf8), to: p, base: version(p), force: false)
        let attrs = try FileManager.default.attributesOfItem(atPath: p)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o444)
        XCTAssertEqual(String(decoding: read(p), as: UTF8.self), "y\n")
    }

    func testAMissingFileFails() {
        guard case .failed = FileSave.save(Data("x".utf8), to: dir + "/nope", base: nil, force: true) else {
            return XCTFail("expected failure")
        }
    }
}

final class GitReaderTests: FileTestCase {
    private func git(_ args: String...) {
        let r = Subprocess.run("/usr/bin/git", ["-C", dir, "-c", "user.email=t@t", "-c", "user.name=t"] + args, timeout: 20)
        XCTAssertEqual(r.status, 0, "git \(args.joined(separator: " "))")
    }

    private func indexStamp() -> String {
        var st = stat()
        stat(dir + "/.git/index", &st)
        return "\(st.st_ino) \(st.st_mtimespec.tv_sec) \(st.st_mtimespec.tv_nsec)"
    }

    func testStatusParsesEveryKindOfRecord() {
        let raw = "1 .M N... 100644 100644 100644 aaa aaa src/a b.swift\u{0}"
            + "2 R. N... 100644 100644 100644 bbb bbb R100 new.txt\u{0}old.txt\u{0}"
            + "1 A. N... 000000 100644 100644 000 ccc added.md\u{0}"
            + "1 .D N... 100644 100644 000000 ddd ddd gone.txt\u{0}"
            + "? notes/\u{0}"
            + "u UU N... 100644 100644 100644 100644 e1 e2 e3 both.txt\u{0}"
        let e = GitStatus.parse(Data(raw.utf8))
        XCTAssertEqual(e.map(\.path), ["src/a b.swift", "new.txt", "added.md", "gone.txt", "notes/", "both.txt"])
        XCTAssertEqual(e.map(\.mark), [.modified, .renamed, .added, .deleted, .untracked, .conflicted])
        XCTAssertEqual(e[1].originalPath, "old.txt")
    }

    func testGrepOutputParses() {
        let raw = "Sources/A.swift\u{0}12\u{0}let x = 1\nREADME.md\u{0}3\u{0}x marks\n"
        let r = GrepResult.parse(Data(raw.utf8), maxHits: 1, truncated: false)
        XCTAssertEqual(r.hits, [GrepHit(path: "Sources/A.swift", line: 12, text: "let x = 1")])
        XCTAssertTrue(r.truncated)
    }

    func testReadingNeverTouchesTheIndex() {
        _ = write("a.txt", "one\n")
        git("init", "-q")
        git("add", ".")
        git("commit", "-qm", "init")
        _ = write("a.txt", "two\n")        // stat changes: a plain `git status` would rewrite the index
        sleep(1)
        let before = indexStamp()
        let g = GitReader.shared
        let repo = g.repo(at: dir)
        XCTAssertNotNil(repo)
        if let repo {
            XCTAssertEqual(g.status(repo)?.map(\.mark), [.modified])
            XCTAssertEqual(g.trackedFiles(repo), ["a.txt"])
            _ = g.grep("two", in: repo, under: nil, caseSensitive: false)
            _ = g.headBlob(file: dir + "/a.txt")
        }
        XCTAssertEqual(indexStamp(), before, "a read must not rewrite .git/index")
    }

    func testHeadIsReadAsItWouldBeCheckedOut() throws {
        try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        _ = write(".gitattributes", "*.txt text eol=crlf\n")
        _ = write("sub/x.txt", "a\r\nb\r\n")
        git("init", "-q")
        git("add", ".")
        git("commit", "-qm", "init")
        let file = dir + "/sub/x.txt"
        let blob = try XCTUnwrap(GitReader.shared.headBlob(file: file))
        XCTAssertEqual(blob.path, "sub/x.txt", "the path is from the top level even when asked from a subdirectory")
        let head = try XCTUnwrap(GitReader.shared.checkedOut(oid: blob.oid, path: blob.path, near: file))
        XCTAssertEqual(head, read(file), "HEAD through the filters equals the unchanged working file")
        XCTAssertNil(GitReader.shared.headBlob(file: write("new.txt", "x")), "untracked files have no HEAD blob")
    }

    func testCheckIgnore() throws {
        _ = write(".gitignore", "build/\n*.log\n")
        try FileManager.default.createDirectory(atPath: dir + "/build", withIntermediateDirectories: true)
        git("init", "-q")
        let repo = try XCTUnwrap(GitReader.shared.repo(at: dir))
        XCTAssertEqual(GitReader.shared.ignored(["build", "src", "x.log"], in: repo), ["build", "x.log"])
    }
}

final class BlobCacheTests: XCTestCase {
    func testEvictsOldestPastTheBudget() {
        let c = BlobCache(limit: 100)
        c.put("a", Data(count: 20)); c.put("b", Data(count: 20)); c.put("c", Data(count: 20))
        _ = c.get("a")                                  // a is now the most recent
        c.put("d", Data(count: 20)); c.put("e", Data(count: 20)); c.put("f", Data(count: 20))
        XCTAssertNotNil(c.get("a"))
        XCTAssertNil(c.get("b"), "the least recently used goes first")
        XCTAssertEqual(c.count, 5)
    }

    func testAHugeBlobIsNotCached() {
        let c = BlobCache(limit: 100)
        c.put("big", Data(count: 60))
        XCTAssertNil(c.get("big"))
    }
}

final class FuzzyMatchTests: XCTestCase {
    func testPrefersTheFileName() {
        let paths = ["Sources/FleetView/Remote/WebDashboardPage.swift", "Sources/FleetView/State/AppState+Workspace.swift",
                     "Sources/FleetView/UI/TriggersPanel.swift"]
        XCTAssertEqual(FuzzyMatch.best("appws", in: paths).first?.path, "Sources/FleetView/State/AppState+Workspace.swift")
        XCTAssertEqual(FuzzyMatch.best("trig", in: paths).first?.path, "Sources/FleetView/UI/TriggersPanel.swift")
    }

    func testAllLettersInOrder() {
        XCTAssertNil(FuzzyMatch.match("zq", "Package.swift"))
        let m = FuzzyMatch.match("pkg", "Package.swift")
        XCTAssertEqual(m?.positions, [0, 3, 5])
    }
}

final class EditedPathsTests: XCTestCase {
    func testClaudeTools() {
        XCTAssertEqual(EditedPaths.paths(tool: "Edit", input: ["file_path": "/p/a.swift"], cwd: "/x"), ["/p/a.swift"])
        XCTAssertEqual(EditedPaths.paths(tool: "Write", input: ["file_path": "docs/b.md"], cwd: "/p"), ["/p/docs/b.md"])
        XCTAssertEqual(EditedPaths.paths(tool: "NotebookEdit", input: ["notebook_path": "/p/n.ipynb"], cwd: nil), ["/p/n.ipynb"])
        XCTAssertEqual(EditedPaths.paths(tool: "Bash", input: ["command": "echo hi > x"], cwd: "/p"), [])
    }

    func testCodexPatchHeaders() {
        let patch = "*** Begin Patch\n*** Update File: src/a.py\n@@\n-x\n+y\n*** Add File: /abs/new.py\n+z\n*** End Patch\n"
        XCTAssertEqual(EditedPaths.paths(tool: "apply_patch", input: ["command": ["apply_patch", patch]], cwd: "/repo"),
                       ["/repo/src/a.py", "/abs/new.py"])
    }
}

final class PathReferenceTests: XCTestCase {
    func testPlainPaths() {
        XCTAssertEqual(PathReference.text("Sources/App/main.swift", for: .claude), "@Sources/App/main.swift")
        XCTAssertEqual(PathReference.text("Sources/App/main.swift", for: .agent), "Sources/App/main.swift")
        XCTAssertEqual(PathReference.text("Sources/App/main.swift", for: .shell), "Sources/App/main.swift")
    }

    func testQuoting() {
        XCTAssertEqual(PathReference.text("docs/my notes.md", for: .claude), "\"docs/my notes.md\"")
        XCTAssertEqual(PathReference.text("it's $HOME `x`.md", for: .shell), "'it'\\''s $HOME `x`.md'")
        XCTAssertEqual(PathReference.text("a \"b\".md", for: .agent), "\"a \\\"b\\\".md\"")
    }

    func testControlCharactersAreRefused() {
        XCTAssertNil(PathReference.text("evil\nrm -rf ~.md", for: .shell))
        XCTAssertNil(PathReference.text("tab\there.md", for: .claude))
    }
}
