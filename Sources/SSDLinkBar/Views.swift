import SwiftUI
import AppKit

struct SSDLinkBarApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(state)
        } label: {
            Image(systemName: state.iconName)
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var pathInput = ""

    private func submit() {
        state.moveTyped(pathInput)
        pathInput = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            linkList
            Divider()
            UsageSection()
            if state.busy { progressView }
            if let err = state.lastError {
                Label(err, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let msg = state.lastMessage {
                Text(msg).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 460)
        .onAppear {
            state.refresh()
            state.updateLoginStatus()
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("SSD 링크").font(.headline)
            }
            SpaceRow(title: "내장 디스크 (/)", icon: "internaldrive", space: state.internalSpace, missingText: "확인 불가")
            if state.volume == nil {
                volumePicker
            } else if state.ssdMounted {
                SpaceRow(title: state.volumeName, icon: "externaldrive", space: state.ssdSpace, missingText: "확인 불가")
            } else {
                Label("\(state.volumeName) 연결 안 됨", systemImage: "externaldrive.badge.xmark")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
    }

    /// Only shown while no volume is configured and auto-pick could not decide (zero or several candidates).
    @ViewBuilder
    private var volumePicker: some View {
        if state.volumeCandidates.isEmpty {
            Label("외장 볼륨을 연결하세요", systemImage: "externaldrive.badge.questionmark")
                .foregroundStyle(.orange)
                .font(.callout)
        } else {
            Picker("외장 볼륨", selection: Binding<String>(
                get: { "" },
                set: { if !$0.isEmpty { state.chooseVolume($0) } }
            )) {
                Text("선택…").tag("")
                ForEach(state.volumeCandidates, id: \.self) { v in
                    Text((v as NSString).lastPathComponent).tag(v)
                }
            }
            .pickerStyle(.menu)
            .font(.callout)
        }
    }

    // MARK: List

    private var linkList: some View {
        Group {
            if state.links.isEmpty {
                Text("\(state.volumeName)을(를) 가리키는 링크가 없습니다.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(state.links) { link in
                            LinkRow(link: link)
                        }
                    }
                }
                // ScrollView has no intrinsic height inside a MenuBarExtra window, so give it an explicit one.
                .frame(height: min(CGFloat(state.links.count) * 72, 400))
            }
        }
    }

    private var progressView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.progressPhase).font(.caption)
            if let f = state.progressFraction {
                ProgressView(value: f)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("~/.cache/some-tool", text: $pathInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(submit)
                Button("SSD로 옮기고 링크", action: submit)
                    .disabled(state.busy || !state.ssdMounted || pathInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack {
                Toggle("로그인 시 실행", isOn: Binding(
                    get: { state.loginEnabled },
                    set: { state.setLogin($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                Spacer()
                Button("종료") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            if !state.loginStatusText.isEmpty {
                Text(state.loginStatusText).font(.caption2).foregroundStyle(.orange)
            }
        }
    }
}

struct SpaceRow: View {
    let title: String
    let icon: String
    let space: VolumeSpace?
    let missingText: String

    var body: some View {
        HStack {
            Label(title, systemImage: icon).font(.callout)
            Spacer()
            if let s = space {
                Text("\(Disk.format(s.free)) 남음 / \(Disk.format(s.total))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(s.free < 20_000_000_000 ? .red : .secondary)
            } else {
                Text(missingText).foregroundStyle(.secondary)
            }
        }
        if let s = space, s.total > 0 {
            ProgressView(value: Double(s.total - s.free), total: Double(s.total))
                .tint(Double(s.free) / Double(s.total) < 0.1 ? .red : .accentColor)
        }
    }
}

struct LinkRow: View {
    @EnvironmentObject var state: AppState
    let link: LinkInfo

    private var statusColor: Color {
        switch link.status {
        case .ok: return .green
        case .broken: return .red
        case .ssdMissing: return .orange
        }
    }

    private var sizeText: some View {
        Group {
            switch state.sizes[link.target] {
            case .none:
                Text("").onAppear { if link.status == .ok { state.computeSize(link) } }
            case .computing:
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("계산 중…").font(.caption).foregroundStyle(.secondary)
                }
            case .done(let b):
                Text(Disk.format(b)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            case .failed:
                Text("크기 확인 불가").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(link.displayPath).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(link.status.label).font(.caption).foregroundStyle(statusColor)
                }
                HStack {
                    Text("→ \(link.target)").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    sizeText
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }
}


// MARK: - Volume usage (everything on the external volume, linked or not)

struct UsageSection: View {
    @EnvironmentObject var state: AppState

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "M/d HH:mm"; return f
    }()

    static func ago(_ t: Date) -> String {
        let m = Int(Date().timeIntervalSince(t) / 60)
        if m < 1 { return "방금" }
        if m < 60 { return "\(m)분 전" }
        if m < 60 * 24 { return "\(m / 60)시간 전" }
        return "\(m / 1440)일 전"
    }

    private func sum(_ k: EntryKind, _ es: [SSDEntry]) -> Int64 {
        es.filter { $0.kind == k }.reduce(0) { $0 + ($1.bytes ?? 0) }
    }

    var body: some View {
        let es = state.ssdEntries
        let linked = sum(.linked, es), unlinked = sum(.unlinked, es), system = sum(.system, es)
        let measured = linked + unlinked + system
        let loose = max(0, (state.usage.rootTotal ?? measured) - measured)
        let used = state.ssdSpace.map { $0.total - $0.free }
        let orphans = es.filter { $0.kind == .unlinked }
        let staleCount = es.filter(\.stale).count

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(state.volumeName) 사용 내역").font(.headline)
                Spacer()
                if state.scanningUsage {
                    ProgressView().controlSize(.mini)
                    Text("측정 중…").font(.caption).foregroundStyle(.secondary)
                } else if let t = state.usage.scannedAt {
                    let stale = Inventory.isStale(state.usage)
                    Text("측정 \(Self.timeFmt.string(from: t)) · \(Self.ago(t))\(state.usage.complete ? "" : " · 일부만")")
                        .font(.caption).foregroundStyle(.secondary)
                    if stale { StaleBadge() }
                } else {
                    StaleBadge(text: "측정 전")
                }
            }
            if !state.ssdMounted {
                Text("\(state.volumeName)이(가) 연결되어 있지 않습니다.").font(.caption).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                    row("링크됨", linked, .green)
                    row("링크 없음", unlinked, .orange)
                    row("시스템", system, .gray)
                    row("최상위 파일", loose, .gray)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        Text("합계").font(.caption.bold())
                        Text(Disk.format(measured + loose)).font(.caption.monospacedDigit().bold())
                            .gridColumnAlignment(.trailing)
                        if let u = used {
                            Text("볼륨 사용량 \(Disk.format(u))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if staleCount > 0 && !Inventory.isStale(state.usage) {
                    Text("\(staleCount)개 폴더가 측정 후 바뀜 · 다음 측정 때 갱신").font(.caption2).foregroundStyle(.orange)
                }
                if !orphans.isEmpty {
                    Text("링크 없는 폴더 (\(orphans.count))").font(.caption.bold()).padding(.top, 4)
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(orphans) { e in
                                HStack {
                                    Circle().fill(.orange).frame(width: 6, height: 6)
                                    Text(e.name).font(.system(.caption, design: .monospaced))
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    if e.stale { StaleBadge(text: e.bytes == nil ? "측정 전" : "오래됨") }
                                    Text(e.bytes.map { Disk.format($0) } ?? "…")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(e.stale ? .orange : .secondary)
                                }
                            }
                        }
                    }
                    .frame(height: min(CGFloat(orphans.count) * 18, 180))
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ title: String, _ bytes: Int64, _ color: Color) -> some View {
        GridRow {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title).font(.caption)
            }
            Text(Disk.format(bytes)).font(.caption.monospacedDigit()).gridColumnAlignment(.trailing)
            Color.clear.frame(height: 1)
        }
    }
}


struct StaleBadge: View {
    var text = "오래됨"
    var body: some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.orange.opacity(0.18)))
            .foregroundStyle(.orange)
    }
}
