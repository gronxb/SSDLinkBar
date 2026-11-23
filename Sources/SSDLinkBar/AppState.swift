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
    @Published private(set) var usage = UsageSnapshot()
    @Published private(set) var scanningUsage = false
    @Published private(set) var ssdEntries: [SSDEntry] = []
    private var remeasured: Set<String> = []
    private let scanProcess = ProcessBox()

    var volumeName: String { Volume.name(volume) }

    /// Rebuilds the usage list. Lists the volume root and stats each top-level entry, so it runs only when
    /// its inputs change, never from a view body.
    private func rebuildEntries() {
        ssdEntries = Inventory.entries(snapshot: usage, links: links, remeasured: scanningUsage ? remeasured : nil)
    }

    /// Size of a link target from the last volume scan, when the target is a top-level folder of the volume.
    func snapshotSize(_ target: String) -> Int64? { usage.sizes[target] }

    /// Re-measure the whole volume with du. Only ever started by the user: on a large volume this walks every inode.
    func scanUsage() {
        guard !scanningUsage, let root = volume, Disk.isMounted(root) else { return }
        scanningUsage = true
        remeasured = []
        rebuildEntries()
        let before = usage   // restored if the scan is stopped or fails, so a partial walk never replaces good data
        let box = scanProcess
        Task.detached(priority: .background) {
            let r = Inventory.scan(root: root, box: box) { path, bytes in
                Task { @MainActor in
                    guard self.scanningUsage, self.volume == root else { return }
                    self.usage.sizes[path] = bytes; self.remeasured.insert(path)
                    self.rebuildEntries()
                }
            }
            await MainActor.run {
                self.scanningUsage = false
                defer { self.rebuildEntries() }
                guard self.volume == root else { return }   // volume changed while scanning: discard
                guard r.ok else { self.usage = before; return }   // stopped, unplugged or du failed: keep last result
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

    func cancelScan() { scanProcess.terminate() }

    /// Switch to another volume root: reset per-volume state and reload its cached usage.
    private func applyVolume(_ root: String?) {
        guard root != volume else { return }
        scanProcess.terminate()
        volume = root
        usage = Inventory.loadCache(root: root)
        sizes = [:]
        remeasured = []
        rebuildEntries()
    }

    /// Called from the picker shown when no volume is configured.
    func chooseVolume(_ path: String) {
        do {
            applyVolume(try Volume.set(path))
            refresh()
        } catch {
            alert("볼륨을 설정할 수 없습니다", error.localizedDescription)
        }
    }
    @Published var loginEnabled = false
    @Published var loginStatusText = ""

    private var observers: [NSObjectProtocol] = []
    private var refreshing = false
    private var refreshPending = false
    private var sigterm: DispatchSourceSignal?

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
        // No polling timer: mount/unmount/wake notifications and opening the panel are the only refresh triggers.
        // Never leave a du walking the volume after the app goes away (quit, or `pkill` from build.sh).
        let box = scanProcess
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in box.terminate() })
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { box.terminate(); exit(0) }
        term.resume()
        sigterm = term
        updateLoginStatus()
        applyVolume(Volume.resolve())
        refresh()
    }

    func refresh() {
        guard !refreshing else { refreshPending = true; return }
        refreshing = true
        Task.detached(priority: .userInitiated) {
            let root = Volume.resolve()   // re-read each time so `ssdlink volume` changes are picked up
            let candidates = root == nil ? Volume.candidates() : []
            let mounted = Disk.isMounted(root)
            let links = Discovery.discover(root: root)
            let i = Disk.internalSpace()
            let s = Disk.ssdSpace(root)
            await MainActor.run {
                self.applyVolume(root)
                // Assign only what changed so an idle refresh does not republish and redraw everything.
                if self.volumeCandidates != candidates { self.volumeCandidates = candidates }
                if self.ssdMounted != mounted { self.ssdMounted = mounted }
                if self.internalSpace != i { self.internalSpace = i }
                if self.ssdSpace != s { self.ssdSpace = s }
                if self.links != links { self.links = links }
                self.rebuildEntries()
                self.refreshing = false
                if self.refreshPending { self.refreshPending = false; self.refresh() }
            }
        }
    }

    // MARK: Sizes

    /// Measures one link target with du. Only on request: targets can be hundreds of GB.
    func computeSize(_ link: LinkInfo) {
        let key = link.target
        if sizes[key] == .computing { return }
        guard link.status == .ok else { return }
        sizes[key] = .computing
        Task.detached(priority: .background) {
            let result = Tree.duSize(key, qos: .background)
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
