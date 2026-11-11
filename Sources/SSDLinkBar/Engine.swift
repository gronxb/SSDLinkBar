import Foundation
import Darwin

// MARK: - Constants

enum Config {
    static let home: String = {
        // Real home dir (app is not sandboxed).
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }()
    static let registryDir = home + "/.config/ssd-link-bar"
    static let registryFile = registryDir + "/links.json"
    static let configFile = registryDir + "/config.json"
    static let oldSuffix = ".ssdlinkbar-old"
    static let restoreSuffix = ".ssdlinkbar-restore"
    static let restoreHeadroom: Int64 = 5 * 1024 * 1024 * 1024
    static let moveHeadroom: Int64 = 1 * 1024 * 1024 * 1024
    static let sizeTimeout: TimeInterval = 180
}

// MARK: - Models

enum LinkStatus: String {
    case ok, broken, ssdMissing

    var label: String {
        switch self {
        case .ok: return "정상"
        case .broken: return "깨짐"
        case .ssdMissing: return "SSD 없음"
        }
    }
}

struct LinkInfo: Identifiable, Hashable {
    var id: String { path }
    let path: String        // absolute link path
    let rawDestination: String
    let target: String      // lexically resolved absolute target
    let status: LinkStatus

    var displayPath: String { Paths.tilde(path) }
}

struct VolumeSpace {
    let free: Int64
    let total: Int64
}

struct TreeStats: Equatable {
    var entries: Int = 0
    var bytes: Int64 = 0
    var errors: Int = 0
    var exceeded = false   // walk stopped early because bytes passed the limit
}

struct EngineError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

// MARK: - Path helpers

enum Paths {
    static func tilde(_ p: String) -> String {
        if p == Config.home { return "~" }
        if p.hasPrefix(Config.home + "/") { return "~" + p.dropFirst(Config.home.count) }
        return p
    }

    static func expand(_ p: String) -> String {
        if p == "~" { return Config.home }
        if p.hasPrefix("~/") { return Config.home + p.dropFirst(1) }
        return p
    }

    /// Lexical normalization (no symlink resolution, never touches the SSD tree).
    static func standardize(_ p: String) -> String {
        URL(fileURLWithPath: p).standardized.path
    }

    static func isUnder(_ p: String, _ root: String) -> Bool {
        p == root || p.hasPrefix(root + "/")
    }

    static func lstatInfo(_ p: String) -> stat? {
        var st = stat()
        return lstat(p, &st) == 0 ? st : nil
    }

    static func isSymlink(_ p: String) -> Bool {
        guard let st = lstatInfo(p) else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    static func isDirectoryNoFollow(_ p: String) -> Bool {
        guard let st = lstatInfo(p) else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    static func existsNoFollow(_ p: String) -> Bool { lstatInfo(p) != nil }
}

// MARK: - External volume selection

/// The external volume everything is mirrored to. Stored in ~/.config/ssd-link-bar/config.json as
/// {"volume": "/Volumes/<name>"}. When unset and exactly one suitable volume is mounted, it is picked and saved.
enum Volume {
    private struct File: Codable { var volume: String? }

    static func normalize(_ p: String) -> String {
        var s = Paths.standardize(Paths.expand(p.trimmingCharacters(in: .whitespacesAndNewlines)))
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// The configured volume path, without touching mounted volumes.
    static func configured() -> String? {
        guard let d = FileManager.default.contents(atPath: Config.configFile),
              let f = try? JSONDecoder().decode(File.self, from: d),
              let v = f.volume, !v.isEmpty else { return nil }
        return normalize(v)
    }

    static func save(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: Config.registryDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try enc.encode(File(volume: normalize(path))).write(to: URL(fileURLWithPath: Config.configFile), options: .atomic)
    }

    /// Validates and saves a user-chosen volume. Must be a mounted volume under /Volumes.
    static func set(_ input: String) throws -> String {
        let p = normalize(input)
        guard p.hasPrefix("/Volumes/"), (p as NSString).pathComponents.count == 3 else {
            throw EngineError("/Volumes/<이름> 형식의 볼륨 경로여야 합니다: \(p)")
        }
        guard Disk.mountPoint(of: p) == p else { throw EngineError("마운트된 볼륨이 아닙니다: \(p)") }
        try save(p)
        return p
    }

    /// Mounted local, writable, non-root volumes under /Volumes (candidates for auto-pick / the picker).
    static func candidates() -> [String] {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeIsRootFileSystemKey,
                                      .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        var out: [String] = []
        for u in urls {
            let p = normalize(u.path)
            guard p.hasPrefix("/Volumes/"), (p as NSString).pathComponents.count == 3,
                  let v = try? u.resourceValues(forKeys: Set(keys)),
                  v.volumeIsLocal == true, v.volumeIsReadOnly != true,
                  v.volumeIsRootFileSystem != true, v.volumeIsBrowsable != false,
                  Disk.mountPoint(of: p) == p,
                  access(p, W_OK) == 0 else { continue }
            out.append(p)
        }
        return out.sorted()
    }

    /// Configured volume, or the single mounted candidate (which is then saved). nil = user must choose.
    static func resolve() -> String? {
        if let c = configured() { return c }
        let cands = candidates()
        guard cands.count == 1 else { return nil }
        try? save(cands[0])
        return cands[0]
    }

    static func name(_ path: String?) -> String {
        guard let p = path else { return "SSD" }
        return (p as NSString).lastPathComponent
    }
}

// MARK: - Disk

enum Disk {
    static func mountPoint(of path: String) -> String? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        return withUnsafePointer(to: &s.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    static func isMounted(_ root: String?) -> Bool {
        guard let root else { return false }
        return mountPoint(of: root) == root
    }

    static func space(_ path: String) -> VolumeSpace? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        let bs = Int64(s.f_bsize)
        return VolumeSpace(free: Int64(s.f_bavail) * bs, total: Int64(s.f_blocks) * bs)
    }

    static func internalSpace() -> VolumeSpace? { space("/") }
    static func ssdSpace(_ root: String?) -> VolumeSpace? {
        guard let root, isMounted(root) else { return nil }
        return space(root)
    }

    static func format(_ b: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: b)
    }
}

// MARK: - Registry

enum Registry {
    static func load() -> [String] {
        guard let data = FileManager.default.contents(atPath: Config.registryFile),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr.map(Paths.expand)
    }

    static func save(_ paths: [String]) {
        try? FileManager.default.createDirectory(atPath: Config.registryDir, withIntermediateDirectories: true)
        let uniq = Array(NSOrderedSet(array: paths.map(Paths.tilde))) as? [String] ?? []
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? enc.encode(uniq) {
            try? data.write(to: URL(fileURLWithPath: Config.registryFile), options: .atomic)
        }
    }

    static func add(_ p: String) {
        var cur = load()
        if !cur.contains(p) { cur.append(p) }
        save(cur)
    }

    static func remove(_ p: String) {
        save(load().filter { $0 != p })
    }
}

// MARK: - Discovery

enum Discovery {
    static var scanRoots: [String] {
        let h = Config.home
        return [h, h + "/Library", h + "/Library/Developer", h + "/Library/Caches",
                h + "/Library/Application Support", h + "/.android", h + "/.android/avd"]
    }

    /// Inspect a single path; returns LinkInfo if it is a symlink whose target lies under the volume root.
    static func inspect(_ path: String, root: String?, ssdMounted: Bool) -> LinkInfo? {
        guard let root, Paths.isSymlink(path),
              let raw = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return nil }
        let abs = raw.hasPrefix("/") ? raw : (path as NSString).deletingLastPathComponent + "/" + raw
        let target = Paths.standardize(abs)
        guard Paths.isUnder(target, root) else { return nil }
        let status: LinkStatus
        if !ssdMounted {
            status = .ssdMissing
        } else if Paths.existsNoFollow(target) {
            status = .ok
        } else {
            status = .broken
        }
        return LinkInfo(path: path, rawDestination: raw, target: target, status: status)
    }

    static func discover(root: String?) -> [LinkInfo] {
        guard let root else { return [] }
        let mounted = Disk.isMounted(root)
        var candidates: [String] = []
        let fm = FileManager.default
        for root in scanRoots {
            guard Paths.existsNoFollow(root) else { continue }
            if Paths.isSymlink(root) {
                // e.g. ~/.android itself moved: list it, never descend.
                candidates.append(root)
                continue
            }
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for n in names { candidates.append(root + "/" + n) }
        }
        candidates.append(contentsOf: Registry.load())

        var seen = Set<String>()
        var out: [LinkInfo] = []
        for c in candidates {
            let p = Paths.standardize(c)
            guard !seen.contains(p) else { continue }
            seen.insert(p)
            if let info = inspect(p, root: root, ssdMounted: mounted) { out.append(info) }
        }
        return out.sorted { $0.displayPath.localizedStandardCompare($1.displayPath) == .orderedAscending }
    }
}

// MARK: - Tree walking / sizing

enum Tree {
    /// Walks without following symlinks. Counts every entry below root, sums regular file logical sizes.
    static func stats(_ root: String, byteLimit: Int64? = nil, cancel: (() -> Bool)? = nil) -> TreeStats {
        var st = TreeStats()
        guard let rootStat = Paths.lstatInfo(root) else { st.errors = 1; return st }
        if (rootStat.st_mode & S_IFMT) != S_IFDIR {
            if (rootStat.st_mode & S_IFMT) == S_IFREG { st.bytes = Int64(rootStat.st_size) }
            return st
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .fileResourceTypeKey]
        var errs = 0
        guard let en = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys, options: [],
            errorHandler: { _, _ in errs += 1; return true }) else { st.errors = 1; return st }
        for case let url as URL in en {
            if let c = cancel, c() { break }
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.fileResourceType == .socket { continue }  // sockets can't be copied; owners recreate them
            st.entries += 1
            if let v, v.isRegularFile == true {
                st.bytes += Int64(v.fileSize ?? 0)
                if let lim = byteLimit, st.bytes > lim { st.exceeded = true; break }
            }
        }
        st.errors += errs
        return st
    }

    /// `du -sk` with timeout. Returns allocated bytes, or nil on timeout/failure.
    static func duSize(_ path: String, timeout: TimeInterval = Config.sizeTimeout) -> Int64? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        p.arguments = ["-sk", path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        // Drain stdout concurrently (output is tiny, but be safe).
        var data = Data()
        let reader = DispatchQueue(label: "du.reader")
        reader.async { data = out.fileHandleForReading.readDataToEndOfFile() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 2)
            return nil
        }
        reader.sync {}
        guard let s = String(data: data, encoding: .utf8),
              let kb = Int64(s.split(separator: "\t").first?.trimmingCharacters(in: .whitespaces) ?? "") else { return nil }
        return kb * 1024
    }
}

// MARK: - Operations

typealias ProgressHandler = (_ phase: String, _ fraction: Double?) -> Void

enum Operations {
    private static func ditto(_ src: String, _ dst: String, totalEntries: Int, progress: ProgressHandler) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-V", src, dst]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        var copied = 0
        var tail = Data()
        let lock = NSLock()
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            lock.lock()
            copied += d.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
            tail.append(d)
            if tail.count > 8192 { tail = tail.suffix(4096) }
            lock.unlock()
        }
        try p.run()
        while p.isRunning {
            Thread.sleep(forTimeInterval: 0.3)
            lock.lock(); let c = copied; lock.unlock()
            let frac = totalEntries > 0 ? min(1.0, Double(c) / Double(totalEntries + 1)) : nil
            progress("복사 중… (\(c)/\(totalEntries + 1))", frac)
        }
        err.fileHandleForReading.readabilityHandler = nil
        if p.terminationStatus != 0 {
            // ditto exits non-zero for uncopyable sockets. verify() (which ignores sockets) is the real check.
            lock.lock(); let msg = String(data: tail, encoding: .utf8) ?? ""; lock.unlock()
            let errs = msg.split(separator: "\n").filter { $0.hasPrefix("ditto:") && !$0.contains("Operation not supported on socket") }
            if !errs.isEmpty {
                throw EngineError("ditto 실패 (코드 \(p.terminationStatus)): \(errs.suffix(3).joined(separator: "\n"))")
            }
        }
    }

    private static func verify(_ a: TreeStats, _ b: TreeStats) throws {
        if b.errors > 0 { throw EngineError("검증 실패: 복사본을 읽는 중 오류 \(b.errors)건") }
        if a.entries != b.entries || a.bytes != b.bytes {
            throw EngineError("검증 실패: 원본 \(a.entries)개/\(a.bytes)B, 복사본 \(b.entries)개/\(b.bytes)B")
        }
    }

    /// <volume>/<path relative to home>
    static func mirroredTarget(for source: String, root: String) -> String {
        let rel = String(source.dropFirst(Config.home.count + 1))
        return root + "/" + rel
    }

    private static func mountedRoot() throws -> String {
        guard let root = Volume.resolve() else {
            throw EngineError("외장 볼륨이 설정되지 않았습니다. `ssdlink volume /Volumes/<이름>` 으로 지정하세요.")
        }
        guard Disk.isMounted(root) else { throw EngineError("\(Volume.name(root)) 이(가) 연결되어 있지 않습니다.") }
        return root
    }

    /// Checks done before asking the user. Returns (target, stats).
    static func precheckMove(_ sourceIn: String) throws -> (target: String, stats: TreeStats) {
        let source = Paths.standardize(sourceIn)
        let h = Config.home
        let root = try mountedRoot()
        guard source.hasPrefix(h + "/") else { throw EngineError("홈 폴더 아래의 폴더만 옮길 수 있습니다.") }
        let forbidden = [h + "/Library", h + "/Desktop", h + "/Documents", h + "/Downloads", h + "/.Trash",
                         h + "/Library/Caches", h + "/Library/Application Support", h + "/Library/Developer",
                         h + "/.config", h + "/.config/ssd-link-bar"]
        guard !forbidden.contains(source) else { throw EngineError("이 폴더는 옮길 수 없습니다: \(Paths.tilde(source))") }
        guard let st = Paths.lstatInfo(source) else { throw EngineError("폴더가 존재하지 않습니다.") }
        if (st.st_mode & S_IFMT) == S_IFLNK { throw EngineError("이미 심볼릭 링크입니다.") }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw EngineError("폴더가 아닙니다.") }
        guard let hs = Paths.lstatInfo(h), hs.st_dev == st.st_dev else {
            throw EngineError("내장 디스크에 있는 폴더가 아닙니다 (이미 다른 볼륨에 있음).")
        }
        if source.hasSuffix(Config.oldSuffix) || source.hasSuffix(Config.restoreSuffix) {
            throw EngineError("작업 중인 임시 폴더는 옮길 수 없습니다.")
        }
        let users = InUse.processes(under: source)
        if !users.isEmpty {
            throw EngineError("이 폴더를 사용 중인 앱이 있습니다. 종료 후 다시 시도하세요:\n" + users.prefix(6).joined(separator: ", "))
        }
        let target = mirroredTarget(for: source, root: root)
        if Paths.existsNoFollow(target) { throw EngineError("대상 경로가 이미 존재합니다: \(target)") }
        if Paths.existsNoFollow(source + Config.oldSuffix) { throw EngineError("\(Paths.tilde(source))\(Config.oldSuffix) 가 이미 있습니다.") }
        guard let ssd = Disk.ssdSpace(root) else { throw EngineError("SSD 공간을 확인할 수 없습니다.") }
        let stats = Tree.stats(source, byteLimit: max(0, ssd.free - Config.moveHeadroom))
        if stats.exceeded || ssd.free < stats.bytes + Config.moveHeadroom {
            throw EngineError("SSD 여유 공간 부족: 필요 \(stats.exceeded ? "> " : "")\(Disk.format(stats.bytes)) + 1GB, 여유 \(Disk.format(ssd.free))")
        }
        if stats.errors > 0 { throw EngineError("원본을 읽는 중 오류 \(stats.errors)건 (권한 확인 필요)") }
        return (target, stats)
    }

    /// copy -> verify -> rename original -> symlink -> delete old copy.
    @discardableResult
    static func moveToSSD(_ sourceIn: String, progress: ProgressHandler) throws -> String {
        let source = Paths.standardize(sourceIn)
        progress("확인 중…", nil)
        let (target, srcStats) = try precheckMove(source)
        let fm = FileManager.default
        try fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)

        do {
            try ditto(source, target, totalEntries: srcStats.entries, progress: progress)
            progress("검증 중…", nil)
            let dstStats = Tree.stats(target)
            try verify(srcStats, dstStats)
        } catch {
            // Only remove the partial copy we created. Original untouched.
            if Paths.existsNoFollow(target) { try? fm.removeItem(atPath: target) }
            throw error
        }

        let old = source + Config.oldSuffix
        progress("링크로 교체 중…", nil)
        try fm.moveItem(atPath: source, toPath: old)
        do {
            try fm.createSymbolicLink(atPath: source, withDestinationPath: target)
        } catch {
            try? fm.moveItem(atPath: old, toPath: source)
            throw EngineError("심볼릭 링크 생성 실패, 원본 복구됨: \(error.localizedDescription)")
        }
        Registry.add(source)
        progress("내장 디스크의 원본 삭제 중…", nil)
        do {
            try fm.removeItem(atPath: old)
        } catch {
            throw EngineError("이동은 완료됐지만 \(Paths.tilde(old)) 삭제 실패: \(error.localizedDescription)")
        }
        progress("완료", 1)
        return target
    }

    static func precheckRestore(_ linkIn: String) throws -> (target: String, stats: TreeStats) {
        let link = Paths.standardize(linkIn)
        let root = try mountedRoot()
        guard let info = Discovery.inspect(link, root: root, ssdMounted: true) else {
            throw EngineError("SSD를 가리키는 심볼릭 링크가 아닙니다.")
        }
        guard info.status == .ok else { throw EngineError("링크 대상이 없습니다 (깨진 링크).") }
        let tmp = link + Config.restoreSuffix
        if Paths.existsNoFollow(tmp) { throw EngineError("\(Paths.tilde(tmp)) 가 이미 있습니다.") }
        guard let space = Disk.internalSpace() else { throw EngineError("내장 디스크 공간을 확인할 수 없습니다.") }
        let stats = Tree.stats(info.target, byteLimit: max(0, space.free - Config.restoreHeadroom))
        if stats.exceeded || space.free < stats.bytes + Config.restoreHeadroom {
            throw EngineError("내장 디스크 여유 공간 부족: 필요 \(stats.exceeded ? "> " : "")\(Disk.format(stats.bytes)) + 5GB, 여유 \(Disk.format(space.free))")
        }
        if stats.errors > 0 { throw EngineError("SSD의 대상을 읽는 중 오류 \(stats.errors)건") }
        return (info.target, stats)
    }

    /// copy target -> sibling temp on internal disk -> verify -> unlink -> rename temp -> delete SSD copy.
    static func restoreToInternal(_ linkIn: String, progress: ProgressHandler) throws {
        let link = Paths.standardize(linkIn)
        progress("확인 중…", nil)
        let (target, srcStats) = try precheckRestore(link)
        let fm = FileManager.default
        let tmp = link + Config.restoreSuffix
        do {
            try ditto(target, tmp, totalEntries: srcStats.entries, progress: progress)
            progress("검증 중…", nil)
            try verify(srcStats, Tree.stats(tmp))
        } catch {
            if Paths.existsNoFollow(tmp) { try? fm.removeItem(atPath: tmp) }
            throw error
        }
        progress("링크를 실제 폴더로 교체 중…", nil)
        guard Paths.isSymlink(link) else { throw EngineError("링크가 사라졌습니다. \(Paths.tilde(tmp)) 에 복사본이 남아 있습니다.") }
        try fm.removeItem(atPath: link) // removes the link only
        do {
            try fm.moveItem(atPath: tmp, toPath: link)
        } catch {
            try? fm.createSymbolicLink(atPath: link, withDestinationPath: target)
            throw EngineError("이름 변경 실패, 링크 복구됨: \(error.localizedDescription)")
        }
        Registry.remove(link)
        progress("SSD의 원본 삭제 중…", nil)
        do {
            try fm.removeItem(atPath: target)
        } catch {
            throw EngineError("복원은 완료됐지만 SSD의 \(target) 삭제 실패: \(error.localizedDescription)")
        }
        progress("완료", 1)
    }
}


// MARK: - In-use check

enum InUse {
    /// Names of the user's processes that have a file (or cwd) open under `root`. One `lsof` pass, no recursion.
    static func processes(under root: String) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-n", "-P", "-w", "-u", NSUserName(), "-F", "cn"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        var cmd = ""
        var names = Set<String>()
        for line in text.split(separator: "\n") {
            if line.hasPrefix("c") { cmd = String(line.dropFirst()) }
            else if line.hasPrefix("n") {
                let path = String(line.dropFirst())
                if path == root || path.hasPrefix(prefix) { names.insert(cmd) }
            }
        }
        return names.sorted()
    }
}
