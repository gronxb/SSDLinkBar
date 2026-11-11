import Foundation

// MARK: - SSD usage inventory
//
// Accounts for everything on the external volume, not only symlink targets, so the totals add up to what the volume reports.
// One `du -k -d 1 -x` pass over the SSD root: inside a single du run every inode is counted once, so pnpm-style
// hardlinks shared between top-level folders are not double counted.

enum EntryKind: String, Codable {
    case linked     // a symlink on the internal disk points at it (or inside it)
    case unlinked   // nothing on the internal disk points here
    case system     // macOS volume bookkeeping (Spotlight, fseventsd, Trash…)

    var label: String {
        switch self {
        case .linked: return "링크됨"
        case .unlinked: return "링크 없음"
        case .system: return "시스템"
        }
    }
}

struct SSDEntry: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let bytes: Int64?       // nil = not measured yet
    let kind: EntryKind
    let stale: Bool         // number is from an older scan, or the folder changed after it was measured
}

struct UsageSnapshot: Codable {
    var volume: String?                // volume root this snapshot belongs to
    var sizes: [String: Int64] = [:]   // top-level path -> allocated bytes
    var rootTotal: Int64?              // du total for the SSD root (includes loose files)
    var scannedAt: Date?
    var complete = false
}

enum Inventory {
    static let systemNames: Set<String> = [".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100",
                                           ".Trashes", ".TemporaryItems", ".DS_Store"]
    static let cacheFile = Config.registryDir + "/ssd-usage.json"
    static let rescanInterval: TimeInterval = 30 * 60

    /// Cached snapshot for `root`; empty when the cache belongs to another volume.
    static func loadCache(root: String?) -> UsageSnapshot {
        guard let root else { return UsageSnapshot() }
        guard let d = FileManager.default.contents(atPath: cacheFile),
              var s = try? JSONDecoder().decode(UsageSnapshot.self, from: d) else { return UsageSnapshot(volume: root) }
        if let v = s.volume {
            if v != root { return UsageSnapshot(volume: root) }
        } else {
            // cache written before per-volume keying: keep it only if every path is on this volume
            guard s.sizes.keys.allSatisfy({ Paths.isUnder($0, root) }) else { return UsageSnapshot(volume: root) }
            s.volume = root
        }
        return s
    }

    static func saveCache(_ s: UsageSnapshot) {
        try? FileManager.default.createDirectory(atPath: Config.registryDir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: URL(fileURLWithPath: cacheFile), options: .atomic) }
    }

    static func topLevelPaths(_ root: String?) -> [String] {
        guard let root else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return names.map { root + "/" + $0 }
    }

    static func classify(_ path: String, links: [LinkInfo]) -> EntryKind {
        let name = (path as NSString).lastPathComponent
        if systemNames.contains(name) { return .system }
        for l in links where l.target == path || l.target.hasPrefix(path + "/") { return .linked }
        return .unlinked
    }

    /// Overall staleness: never scanned, last scan incomplete, or older than the rescan interval.
    static func isStale(_ s: UsageSnapshot) -> Bool {
        guard s.complete, let t = s.scannedAt else { return true }
        return Date().timeIntervalSince(t) > rescanInterval
    }

    static func modified(_ p: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date
    }

    /// `remeasured`: paths measured in the scan currently running (nil when no scan is running).
    static func entries(snapshot: UsageSnapshot, links: [LinkInfo], remeasured: Set<String>?) -> [SSDEntry] {
        let overall = isStale(snapshot)
        return topLevelPaths(snapshot.volume).map { p in
            let bytes = snapshot.sizes[p]
            var stale: Bool
            if let r = remeasured {
                stale = !r.contains(p)                       // scan in progress: not reached yet
            } else {
                stale = overall || bytes == nil
                // folder's own entries added/removed after the scan finished
                if !stale, let t = snapshot.scannedAt, let m = modified(p), m > t { stale = true }
            }
            return SSDEntry(name: (p as NSString).lastPathComponent, path: p,
                            bytes: bytes, kind: classify(p, links: links), stale: stale)
        }
        .sorted { ($0.bytes ?? -1) > ($1.bytes ?? -1) }
    }

    /// Runs du over the volume root and reports each finished top-level folder as it comes in.
    /// Blocking; call from a background task.
    static func scan(root: String, onEntry: @escaping (String, Int64) -> Void) -> (total: Int64?, ok: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        p.arguments = ["-k", "-x", "-d", "1", root]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice   // unreadable system folders just get skipped
        guard (try? p.run()) != nil else { return (nil, false) }

        var buffer = Data()
        var total: Int64?
        let h = out.fileHandleForReading
        while true {
            let chunk = h.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                let parts = line.split(separator: "\t", maxSplits: 1)
                guard parts.count == 2, let kb = Int64(parts[0]) else { continue }
                let path = String(parts[1])
                if path == root { total = kb * 1024 } else { onEntry(path, kb * 1024) }
            }
        }
        p.waitUntilExit()
        return (total, total != nil)
    }
}
