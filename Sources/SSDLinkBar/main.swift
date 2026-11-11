import Foundation
import AppKit

// CLI mode: `ssdlink <command>` (installed as ~/.local/bin/ssdlink -> app binary).
// With no recognised command the menu bar app starts (GUI = viewer + same actions).

let cliArgs = Array(CommandLine.arguments.dropFirst())
let isTTY = isatty(STDIN_FILENO) != 0

func cliProgress(_ phase: String, _ frac: Double?) {
    if let f = frac { FileHandle.standardError.write("\r\(phase) \(Int(f * 100))%   ".data(using: .utf8)!) }
    else { FileHandle.standardError.write("\n\(phase)".data(using: .utf8)!) }
}

func ask(_ prompt: String, yes: Bool) -> Bool {
    if yes { return true }
    guard isTTY else {
        print("확인이 필요합니다. 비대화형 환경에서는 -y 를 붙이세요.")
        return false
    }
    print(prompt + " [y/N] ", terminator: "")
    let a = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    return a == "y" || a == "yes"
}

func usage() {
    print("""
    ssdlink — 내장 디스크 → 외장 볼륨(\(Volume.configured() ?? "미설정")) 심볼릭 링크 관리

    사용법:
      ssdlink                        메뉴 막대 앱 실행 (GUI)
      ssdlink list                   SSD를 가리키는 링크 목록과 디스크 여유 공간
      ssdlink add <폴더> [-y]        폴더를 SSD로 옮기고 링크로 교체 (복사→검증→링크→원본 삭제)
      ssdlink restore <링크> [-y]    SSD의 폴더를 내장으로 되돌리고 링크 제거
      ssdlink register <링크>        이미 만든 링크를 레지스트리에 등록 (스캔 범위 밖일 때)
      ssdlink unregister <링크>      레지스트리에서 제거 (파일은 건드리지 않음)
      ssdlink size <링크|경로>       대상 크기 (du, \(Int(Config.sizeTimeout))초 제한)
      ssdlink volume [/Volumes/이름] 외장 볼륨 경로 표시 / 설정

    설정: \(Paths.tilde(Config.configFile))
    레지스트리: \(Paths.tilde(Config.registryFile))
    """)
}

func runCLI(_ args: [String]) -> Int32? {
    guard var cmd = args.first else { return nil }
    if cmd.hasPrefix("--") { cmd = String(cmd.dropFirst(2)) }   // --list etc. still accepted
    let rest = args.dropFirst().filter { $0 != "-y" && $0 != "--yes" }
    let yes = args.contains("-y") || args.contains("--yes")
    let arg = rest.first.map(Paths.expand)
    let root = Volume.resolve()

    switch cmd {
    case "list", "ls":
        let i = Disk.internalSpace()
        print("내장 /: \(i.map { Disk.format($0.free) } ?? "?") 남음 / \(i.map { Disk.format($0.total) } ?? "?")")
        if let root {
            if let s = Disk.ssdSpace(root) {
                print("\(Volume.name(root)) \(root): \(Disk.format(s.free)) 남음 / \(Disk.format(s.total))")
            } else {
                print("\(Volume.name(root)) \(root): 연결 안 됨")
            }
        } else {
            print("외장 볼륨 미설정: ssdlink volume /Volumes/<이름>")
        }
        if args.contains("--check-symbols") {
            for sym in [AppState.normalIcon, AppState.warningIcon] {
                print("symbol \(sym): \(NSImage(systemSymbolName: sym, accessibilityDescription: nil) != nil ? "ok" : "MISSING")")
            }
        }
        let links = Discovery.discover(root: root)
        print("링크 \(links.count)개")
        for l in links {
            print("\(l.status.label)\t\(l.displayPath) -> \(l.target)")
        }
        return 0

    case "size":
        guard var p = arg else { usage(); return 2 }
        if let info = Discovery.inspect(p, root: root, ssdMounted: Disk.isMounted(root)) { p = info.target }
        if let b = Tree.duSize(p) { print("\(Disk.format(b))\t\(p)"); return 0 }
        print("시간 초과 또는 실패"); return 1

    case "add", "move":
        guard let p = arg else { usage(); return 2 }
        do {
            let src = Paths.standardize(p)
            print("크기 확인 중…")
            let pre = try Operations.precheckMove(src)
            print("\(Paths.tilde(src)) → \(pre.target)\n크기: \(Disk.format(pre.stats.bytes)) (\(pre.stats.entries)개 항목)")
            guard ask("\(Volume.name(root))(으)로 옮길까요?", yes: yes) else { print("취소됨"); return 1 }
            let t = try Operations.moveToSSD(src, progress: cliProgress)
            print("\n완료: \(Paths.tilde(src)) -> \(t)")
            return 0
        } catch {
            print("\n오류: \(error.localizedDescription)")
            return 1
        }

    case "restore":
        guard let p = arg else { usage(); return 2 }
        do {
            let link = Paths.standardize(p)
            print("크기 확인 중…")
            let pre = try Operations.precheckRestore(link)
            let free = Disk.internalSpace().map { Disk.format($0.free) } ?? "?"
            print("\(Paths.tilde(link)) ← \(pre.target)\n크기: \(Disk.format(pre.stats.bytes)) (\(pre.stats.entries)개 항목), 내장 여유: \(free)")
            guard ask("내장 디스크로 되돌릴까요?", yes: yes) else { print("취소됨"); return 1 }
            try Operations.restoreToInternal(link, progress: cliProgress)
            print("\n완료: \(Paths.tilde(link)) 은(는) 이제 실제 폴더입니다")
            return 0
        } catch {
            print("\n오류: \(error.localizedDescription)")
            return 1
        }

    case "register":
        guard let p = arg else { usage(); return 2 }
        let link = Paths.standardize(p)
        guard Discovery.inspect(link, root: root, ssdMounted: Disk.isMounted(root)) != nil else {
            print("오류: \(Paths.tilde(link)) 은(는) \(Volume.name(root))을(를) 가리키는 심볼릭 링크가 아닙니다"); return 1
        }
        Registry.add(link)
        print("등록됨: \(Paths.tilde(link))")
        return 0

    case "unregister":
        guard let p = arg else { usage(); return 2 }
        Registry.remove(Paths.standardize(p))
        print("레지스트리에서 제거됨: \(Paths.tilde(p))")
        return 0

    case "volume":
        if let p = rest.first {
            do {
                let v = try Volume.set(p)
                print(v)
                return 0
            } catch {
                print("오류: \(error.localizedDescription)")
                return 1
            }
        }
        if let root { print(root); return 0 }
        let cands = Volume.candidates()
        FileHandle.standardError.write("외장 볼륨 미설정. 선택: ssdlink volume <경로>\n".data(using: .utf8)!)
        for c in cands { FileHandle.standardError.write("  \(c)\n".data(using: .utf8)!) }
        return 1

    case "help", "-h":
        usage(); return 0

    default:
        return nil // unknown (e.g. -psn_ from LaunchServices) -> launch GUI
    }
}

if let code = runCLI(cliArgs) { exit(code) }

SSDLinkBarApp.main()
