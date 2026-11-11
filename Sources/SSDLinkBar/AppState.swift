import Foundation
import AppKit
import ServiceManagement

enum SizeState: Equatable {
    case computing
    case done(Int64)
    case failed
}

@MainActor
final class AppState: ObservableObject {
    nonisolated static let normalIcon = "externaldrive.connected.to.line.below"
    nonisolated static let warningIcon = "externaldrive.badge.exclamationmark"

    @Published var links: [LinkInfo] = []
    @Published var volume: String?                 // configured external volume root (nil = not chosen yet)
    @Published var volumeCandidates: [String] = [] // shown in the picker only while `volume` is nil
    @Published var ssdMounted = false
    @Published var internalSpace: VolumeSpace?
    @Published var ssdSpace: VolumeSpace?
    @Published var sizes: [String: SizeState] = [:]   // keyed by target path
    @Published var busy = false
    @Published var progressPhase = ""
    @Published var progressFraction: Double?
    @Published var lastMessage: String?
    @Published var lastError: String?
    @Published var usage = UsageSnapshot()
    @Published var scanningUsage = false
    @Published var remeasured: Set<String> = []

    var ssdEntries: [SSDEntry] {
        Inventory.entries(snapshot: usage, links: links, remeasured: scanningUsage ? remeasured : nil)
    }

    var volumeName: String { Volume.name(volume) }

    /// Re-measure the whole volume with du (in the background). Skips if a recent complete scan exists unless forced.
    func scanUsage(force: Bool = false) {
        guard !scanningUsage, let root = volume, Disk.isMounted(root) else { return }
        if !force, usage.complete, let t = usage.scannedAt, Date().timeIntervalSince(t) < Inventory.rescanInterval { return }
        scanningUsage = true
        remeasured = []
        Task.detached(priority: .utility) {
            let r = Inventory.scan(root: root) { path, bytes in
                Task { @MainActor in
                    guard self.volume == root else { return }
                    self.usage.sizes[path] = bytes; self.remeasured.insert(path)
                }
            }
            await MainActor.run {
                self.scanningUsage = false
                guard self.volume == root else { return }   // volume changed while scanning: discard
                if let t = r.total { self.usage.rootTotal = t }
                self.usage.volume = root
                self.usage.scannedAt = Date()
                self.usage.complete = r.ok
                // drop folders that no longer exist
                let live = Set(Inventory.topLevelPaths(root))
                self.usage.sizes = self.usage.sizes.filter { live.contains($0.key) }
                Inventory.saveCache(self.usage)
            }
        }
    }

    /// Switch to another volume root: reset per-volume state and reload its cached usage.
    private func applyVolume(_ root: String?) {
        guard root != volume else { return }
        volume = root
        usage = Inventory.loadCache(root: root)
        sizes = [:]
        remeasured = []
    }

    /// Called from the picker shown when no volume is configured.
    func chooseVolume(_ path: String) {
        do {
            applyVolume(try Volume.set(path))
            refresh()
            scanUsage()
        } catch {
            alert("볼륨을 설정할 수 없습니다", error.localizedDescription)
        }
    }
    @Published var loginEnabled = false
    @Published var loginStatusText = ""

    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var refreshing = false

    var hasWarning: Bool {
        !ssdMounted || links.contains { $0.status != .ok }
    }

    var iconName: String { hasWarning ? Self.warningIcon : Self.normalIcon }

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification, NSWorkspace.didWakeNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(); self?.scanUsage() }
        }
        updateLoginStatus()
        applyVolume(Volume.resolve())
        refresh()
        scanUsage()
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task.detached(priority: .userInitiated) {
            let root = Volume.resolve()   // re-read each time so `ssdlink volume` changes are picked up
            let candidates = root == nil ? Volume.candidates() : []
            let mounted = Disk.isMounted(root)
            let links = Discovery.discover(root: root)
            let i = Disk.internalSpace()
            let s = Disk.ssdSpace(root)
            await MainActor.run {
                let changed = root != self.volume
                self.applyVolume(root)
                self.volumeCandidates = candidates
                self.ssdMounted = mounted
                self.links = links
                self.internalSpace = i
                self.ssdSpace = s
                self.refreshing = false
                if changed { self.scanUsage() }
            }
        }
    }

    // MARK: Sizes

    func computeSize(_ link: LinkInfo, force: Bool = false) {
        let key = link.target
        if !force, let cur = sizes[key], cur != .failed { return }
        guard link.status == .ok else { return }
        sizes[key] = .computing
        Task.detached(priority: .utility) {
            let result = Tree.duSize(key)
            await MainActor.run {
                self.sizes[key] = result.map { .done($0) } ?? .failed
            }
        }
    }

    // MARK: Row actions

    func revealLink(_ l: LinkInfo) {
        NSWorkspace.shared.selectFile(l.path, inFileViewerRootedAtPath: "")
    }

    func openTarget(_ l: LinkInfo) {
        NSWorkspace.shared.open(URL(fileURLWithPath: l.target))
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    // MARK: Alerts

    private func alert(_ title: String, _ text: String, style: NSAlert.Style = .warning) {
        // Keep the failure visible in the panel too: a modal alert from a menu bar app can end up hidden.
        lastError = "\(title): \(text)"
        lastMessage = nil
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = style
        a.addButton(withTitle: "확인")
        a.runModal()
    }

    private func confirm(_ title: String, _ text: String, ok: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .warning
        a.addButton(withTitle: ok)
        a.addButton(withTitle: "취소")
        return a.runModal() == .alertFirstButtonReturn
    }

    private func setProgress(_ phase: String, _ frac: Double?) {
        progressPhase = phase
        progressFraction = frac
    }

    private nonisolated func progressHandler(_ owner: AppState) -> ProgressHandler {
        return { phase, frac in
            Task { @MainActor in owner.setProgress(phase, frac) }
        }
    }

    // MARK: Restore

    func restore(_ l: LinkInfo) {
        guard !busy else { return }
        busy = true
        lastMessage = nil
        lastError = nil
        setProgress("크기 확인 중…", nil)
        let path = l.path
        Task.detached(priority: .userInitiated) {
            let pre: Result<(target: String, stats: TreeStats), Error> = Result { try Operations.precheckRestore(path) }
            await MainActor.run {
                switch pre {
                case .failure(let e):
                    self.busy = false
                    self.setProgress("", nil)
                    self.alert("되돌릴 수 없습니다", e.localizedDescription)
                case .success(let p):
                    let free = self.internalSpace.map { Disk.format($0.free) } ?? "?"
                    let ok = self.confirm(
                        "내장 디스크로 되돌릴까요?",
                        "\(Paths.tilde(path))\n← \(p.target)\n\n크기: \(Disk.format(p.stats.bytes)) (\(p.stats.entries)개 항목)\n내장 디스크 여유: \(free)\n\n복사 → 검증 → 링크 교체 → \(self.volumeName) 원본 삭제 순으로 진행합니다.",
                        ok: "되돌리기")
                    if ok { self.runRestore(path) } else { self.busy = false; self.setProgress("", nil) }
                }
            }
        }
    }

    private func runRestore(_ path: String) {
        let handler = progressHandler(self)
        Task.detached(priority: .userInitiated) {
            let r = Result { try Operations.restoreToInternal(path, progress: handler) }
            await MainActor.run {
                self.busy = false
                self.setProgress("", nil)
                switch r {
                case .success: self.lastMessage = "되돌리기 완료: \(Paths.tilde(path))"
                case .failure(let e): self.alert("되돌리기 실패", e.localizedDescription)
                }
                self.refresh()
            }
        }
    }

    // MARK: Move

    /// Move the folder typed by the user (e.g. "~/.cache/some-tool") to the external volume and leave a symlink.
    func moveTyped(_ input: String) {
        guard !busy else { return }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        let source = Paths.standardize(Paths.expand(trimmed))

        busy = true
        lastMessage = nil
        lastError = nil
        setProgress("크기 확인 중…", nil)
        Task.detached(priority: .userInitiated) {
            let pre: Result<(target: String, stats: TreeStats), Error> = Result { try Operations.precheckMove(source) }
            await MainActor.run {
                switch pre {
                case .failure(let e):
                    self.busy = false
                    self.setProgress("", nil)
                    self.alert("옮길 수 없습니다", e.localizedDescription)
                case .success(let p):
                    let ok = self.confirm(
                        "\(self.volumeName)(으)로 옮길까요?",
                        "\(Paths.tilde(source))\n→ \(p.target)\n\n크기: \(Disk.format(p.stats.bytes)) (\(p.stats.entries)개 항목)\n\n복사 → 검증 → 원본 이름 변경 → 링크 생성 → 원본 삭제 순으로 진행합니다. 진행 중에는 해당 폴더를 사용하는 앱을 종료해 두세요.",
                        ok: "옮기기")
                    if ok { self.runMove(source) } else { self.busy = false; self.setProgress("", nil) }
                }
            }
        }
    }

    private func runMove(_ source: String) {
        let handler = progressHandler(self)
        Task.detached(priority: .userInitiated) {
            let r = Result { try Operations.moveToSSD(source, progress: handler) }
            await MainActor.run {
                self.busy = false
                self.setProgress("", nil)
                switch r {
                case .success(let t):
                    self.lastMessage = "옮기기 완료: \(Paths.tilde(source)) → \(t)"
                    self.scanUsage(force: true)
                case .failure(let e): self.alert("옮기기 실패", e.localizedDescription)
                }
                self.refresh()
            }
        }
    }

    // MARK: Login item

    func updateLoginStatus() {
        let st = SMAppService.mainApp.status
        loginEnabled = (st == .enabled)
        switch st {
        case .enabled: loginStatusText = ""
        case .requiresApproval: loginStatusText = "시스템 설정 > 로그인 항목에서 승인 필요"
        case .notFound: loginStatusText = ""
        case .notRegistered: loginStatusText = ""
        @unknown default: loginStatusText = ""
        }
    }

    func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            alert("로그인 항목 설정 실패", error.localizedDescription)
        }
        updateLoginStatus()
    }
}
