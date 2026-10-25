import Darwin
import Foundation

/// Writing a file back without changing anything about it that the user did not change.
///
/// `Data.write(.atomic)` — what the web `/save` used — gets four things wrong for an editor working
/// beside agents, all measured on macOS 26 / APFS: it replaces a symlink with a regular file (the
/// link's target then silently diverges), it breaks hard links, it drops extended attributes and the
/// creation date, and it writes its temporary file *inside the project*, where an agent's
/// `git add -A` can catch it mid-write. And between reading the version and writing, an agent can
/// write the same file; last writer wins, and neither side knows.
///
/// So: check the version, write the new bytes to a file outside the project with the original's
/// mode, ACL and extended attributes (not its mtime — tools that check "changed since I read it"
/// must see this save), check again, and swap the two with `RENAME_SWAP`. The file swapped out is
/// read back: if it is not the version checked, an agent wrote in between, and the swap is undone.
/// Hard-linked files, files owned by someone else and files in directories this user cannot create
/// in are written in place instead, keeping their inode.
public enum FileSave {
    /// Enough to recognise our own write when the file watcher reports it.
    public struct Fingerprint: Equatable, Sendable {
        public let dev: UInt64
        public let ino: UInt64
        public let size: Int64
        public let mtimeNs: Int64
    }

    public enum Outcome: Equatable, Sendable {
        case saved(version: String, fingerprint: Fingerprint?)
        /// The file is not the version the save was based on. `current` is the version now on disk
        /// (nil when it could not be read, or is being written right now).
        case conflict(current: String?)
        case failed(String)
    }

    public static func fingerprint(of st: stat) -> Fingerprint {
        Fingerprint(dev: UInt64(bitPattern: Int64(st.st_dev)), ino: UInt64(st.st_ino), size: Int64(st.st_size),
                    mtimeNs: Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec))
    }

    public static func fingerprint(path: String) -> Fingerprint? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return fingerprint(of: st)
    }

    /// Write `bytes` to `path`, provided the file on disk is still `base` (unless `force`).
    ///
    /// `allowInPlace: false` refuses the cases that would be written in place — a hard-linked file
    /// above all, whose other name can be anywhere. The web's /save passes it: a link made inside a
    /// project to a file outside it must not let the LAN write that file.
    public static func save(_ bytes: Data, to path: String, base: String?, force: Bool,
                            allowInPlace: Bool = true) -> Outcome {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var st0 = stat()
        guard lstat(real, &st0) == 0 else { return .failed("no such file") }
        guard (st0.st_mode & S_IFMT) == S_IFREG else { return .failed("not a regular file") }
        guard let current = FileManager.default.contents(atPath: real) else { return .failed("could not read it") }
        let currentVersion = FileText.version(current)
        if !force && base != currentVersion { return .conflict(current: currentVersion) }

        // Changed within the last second: look once more. A size or time that moves under us means an
        // agent is writing it right now, and that is a conflict, not a race to win.
        if Date().timeIntervalSince1970 - seconds(st0.st_mtimespec) < 1 {
            usleep(150_000)
            var st1 = stat()
            guard lstat(real, &st1) == 0 else { return .conflict(current: nil) }
            if st1.st_size != st0.st_size || !same(st1.st_mtimespec, st0.st_mtimespec) {
                return force ? .failed("the file is being written right now") : .conflict(current: nil)
            }
        }

        let dir = (real as NSString).deletingLastPathComponent
        let inPlace = st0.st_nlink > 1 || st0.st_uid != getuid() || access(dir, W_OK) != 0
        if inPlace && !allowInPlace { return .failed("hard-linked or not replaceable here") }
        if !inPlace {
            switch swapWrite(bytes, real: real, st0: st0, checked: currentVersion, force: force) {
            case .done(let fp): return .saved(version: FileText.version(bytes), fingerprint: fp)
            case .conflict(let now): return .conflict(current: now)
            case .failed(let why): return .failed(why)
            case .fallBack: break
            }
            if !allowInPlace { return .failed("could not replace it") }
        }
        return inPlaceWrite(bytes, real: real, st0: st0, checked: currentVersion, force: force)
    }

    private enum SwapResult { case done(Fingerprint?), conflict(String?), failed(String), fallBack }

    private static func swapWrite(_ bytes: Data, real: String, st0: stat, checked: String, force: Bool) -> SwapResult {
        let fm = FileManager.default
        // The volume's item-replacement directory: same volume (so the swap is a rename), and not in
        // the project.
        guard let tmpDir = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                       appropriateFor: URL(fileURLWithPath: real), create: true) else { return .fallBack }
        // Removed afterwards — unless it ends up holding the only copy of an agent's write.
        var keepTmp = false
        defer { if !keepTmp { try? fm.removeItem(at: tmpDir) } }
        let tmp = tmpDir.appendingPathComponent((real as NSString).lastPathComponent).path

        let fd = open(tmp, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .fallBack }
        guard writeAll(fd, bytes) else { close(fd); return .failed("could not write it: \(String(cString: strerror(errno)))") }
        _ = fchmod(fd, st0.st_mode & 0o7777)
        _ = fchown(fd, uid_t.max, st0.st_gid)                 // the group, where this user may set it
        // ACL and extended attributes, and not COPYFILE_STAT: the mtime has to move.
        _ = copyfile(real, tmp, nil, copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR))
        let born = Date(timeIntervalSince1970: seconds(st0.st_birthtimespec))
        try? fm.setAttributes([.creationDate: born], ofItemAtPath: tmp)
        _ = fsync(fd)
        var stT = stat()
        _ = fstat(fd, &stT)
        close(fd)

        // Still the file that was checked? (An agent may have written between the check and now.)
        var st2 = stat()
        guard lstat(real, &st2) == 0 else { return .conflict(nil) }
        if !force && (st2.st_ino != st0.st_ino || st2.st_size != st0.st_size
                      || !same(st2.st_mtimespec, st0.st_mtimespec) || !same(st2.st_ctimespec, st0.st_ctimespec)) {
            return .conflict(nil)
        }

        if renamex_np(tmp, real, UInt32(RENAME_SWAP)) != 0 {
            let e = errno
            if e == ENOTSUP || e == EINVAL || e == EXDEV {
                // No swap on this volume: a plain rename, the original's content already verified above.
                guard rename(tmp, real) == 0 else { return .fallBack }
                return .done(fingerprint(of: stT))
            }
            return (e == EACCES || e == EPERM) ? .fallBack : .failed("could not replace it: \(String(cString: strerror(e)))")
        }
        // `tmp` now holds what was at `real` an instant ago. If that is not what was checked, an agent
        // wrote in between: put its version back.
        if !force, let old = fm.contents(atPath: tmp), FileText.version(old) != checked {
            guard renamex_np(tmp, real, UInt32(RENAME_SWAP)) == 0 else {
                // Could not put the agent's version back: it is in `tmp` and nowhere else. Keep it.
                keepTmp = true
                return .failed("an agent wrote the file while saving and it could not be put back; its version is at \(tmp)")
            }
            return .conflict(FileText.version(old))
        }
        return .done(fingerprint(of: stT))
    }

    private static func inPlaceWrite(_ bytes: Data, real: String, st0: stat, checked: String, force: Bool) -> Outcome {
        let fd = open(real, O_WRONLY | O_CLOEXEC)
        guard fd >= 0 else { return .failed("could not open it for writing: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_ino == st0.st_ino else { return .conflict(current: nil) }
        if !force, let now = FileManager.default.contents(atPath: real), FileText.version(now) != checked {
            return .conflict(current: FileText.version(now))
        }
        guard ftruncate(fd, 0) == 0, writeAll(fd, bytes) else {
            return .failed("could not write it: \(String(cString: strerror(errno)))")
        }
        _ = fsync(fd)
        var stW = stat()
        _ = fstat(fd, &stW)
        return .saved(version: FileText.version(bytes), fingerprint: fingerprint(of: stW))
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Bool in
            guard var base = p.baseAddress else { return true }
            var left = p.count
            while left > 0 {
                let n = write(fd, base, left)
                if n < 0 { if errno == EINTR { continue }; return false }
                left -= n
                base = base.advanced(by: n)
            }
            return true
        }
    }

    private static func seconds(_ t: timespec) -> Double { Double(t.tv_sec) + Double(t.tv_nsec) / 1e9 }
    private static func same(_ a: timespec, _ b: timespec) -> Bool { a.tv_sec == b.tv_sec && a.tv_nsec == b.tv_nsec }
}
