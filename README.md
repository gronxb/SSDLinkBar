# SSDLinkBar

A small macOS menu bar app (and CLI) that moves big folders from your internal disk to an external SSD and leaves a symlink in their place.

- Lists every symlink on the internal disk that points to the external volume, with its status (OK / broken / volume missing) and size.
- Moves a folder you type (for example `~/.cache/some-tool`) to the volume and replaces it with a symlink, using one button.
- Shows what is on the volume: folders that something links to, folders nothing links to anymore, and system bookkeeping. Sizes come from one `du` pass and are cached, with a badge when a number is out of date.

## Why

Developer tools love to put gigabytes under your home folder: package caches, SDKs, emulator images, build caches. Moving those to an external SSD keeps the internal disk free, but most tools have no setting for where their data lives.

A symlink solves that. The program keeps reading and writing the same internal path (`~/.cache/some-tool`), and the data actually lives on the SSD.

It also fails in a useful way. When the SSD is unplugged, the link just points at nothing, so the tool errors out. It does not quietly recreate a fresh, empty folder on the internal disk and start filling it again behind your back. The menu bar icon turns into a warning so you notice.

## Requirements

- macOS 14 or later
- Swift toolchain (Xcode or the Command Line Tools)
- Apple silicon (`build.sh` builds for `arm64`)

## Build and install

```sh
./build.sh            # build, install to ~/Applications/SSDLinkBar.app, launch
./build.sh --no-launch
```

`build.sh` builds a release binary with SwiftPM, wraps it in an `.app` bundle (`LSUIElement`, so there is no Dock icon), signs it ad hoc, copies it to `~/Applications`, and links the CLI as `~/.local/bin/ssdlink`.

## Choosing the external volume

The volume is stored in `~/.config/ssd-link-bar/config.json`:

```json
{ "volume": "/Volumes/MySSD" }
```

If nothing is configured and exactly one writable external volume is mounted under `/Volumes`, it is picked and saved automatically. If there are several, the panel shows a picker of mounted volumes. You can always show or change it from the CLI:

```sh
ssdlink volume                  # print the configured volume
ssdlink volume /Volumes/MySSD   # set it (must be mounted)
```

A moved folder keeps its path relative to your home folder: `~/.cache/some-tool` goes to `/Volumes/MySSD/.cache/some-tool`.

## CLI

The CLI is the same binary as the app and uses the same engine.

```sh
ssdlink list                    # links to the volume, plus free space
ssdlink add <folder> [-y]       # move a folder to the volume and leave a symlink
ssdlink restore <link> [-y]     # copy it back to the internal disk and remove the link
ssdlink register <link>         # remember a link you made by hand (outside the scanned folders)
ssdlink unregister <link>       # forget it (files are not touched)
ssdlink size <link|path>        # du size of the target
ssdlink volume [path]           # show or set the external volume
```

Running `ssdlink` with no arguments starts the menu bar app.

Links are discovered by scanning a few common places (`~`, `~/Library`, `~/Library/Caches`, `~/Library/Application Support`, `~/Library/Developer`, `~/.android`, `~/.android/avd`) plus a registry in `~/.config/ssd-link-bar/links.json`, so links created elsewhere still show up.

## Safety model

Moving a folder runs these steps in order and stops at the first problem:

1. **Precheck.** It refuses to start when:
   - the volume is not mounted,
   - the folder is not a real directory on the internal disk under your home folder, or is a protected folder (`~/Library`, `~/Documents`, …),
   - a process has files open under it (checked with `lsof`; quit that app first),
   - the target path on the volume already exists,
   - the volume does not have room for the folder plus 1 GB.
2. **Copy** with `ditto`.
3. **Verify.** The copy must have the same number of entries and the same total byte count as the original. Sockets are ignored because they cannot be copied and their owners recreate them. If verification fails, the partial copy is removed and the original is untouched.
4. **Rename** the original to `<name>.ssdlinkbar-old`.
5. **Symlink** the original path to the copy. If this fails, the rename is undone.
6. **Delete** the renamed original.

Restoring works the same way in reverse (copy to a temporary sibling, verify, swap the link for the folder, delete the copy on the volume), and it needs the folder size plus 5 GB free on the internal disk.

## Limitations

- The app is signed ad hoc. Build it yourself; Gatekeeper will not accept a downloaded copy without extra steps.
- macOS 14+ only (`MenuBarExtra`, `SMAppService`).
- The UI and CLI messages are in Korean.
- One external volume at a time. Renaming the volume makes the links look missing until you set the new path with `ssdlink volume`.
- Not sandboxed: it needs to read and write your home folder and the volume.

## 한국어

SSDLinkBar는 홈 폴더의 큰 폴더를 외장 SSD로 옮기고, 원래 자리에 심볼릭 링크를 남기는 macOS 메뉴 막대 앱입니다.

- 프로그램은 계속 같은 내장 경로를 읽고 쓰지만, 실제 데이터는 SSD에 있어서 내장 디스크 공간이 확보됩니다.
- SSD를 뽑으면 링크가 깨질 뿐, 내장 디스크에 데이터가 몰래 새로 쌓이지 않습니다.
- 옮기기는 복사 → 검증(소켓 제외) → 원본 이름 변경 → 링크 생성 → 원본 삭제 순서로 진행합니다. 사용 중인 앱이 있거나, 공간이 부족하거나, 대상 경로가 이미 있으면 시작하지 않습니다.
- 외장 볼륨은 `~/.config/ssd-link-bar/config.json` 에 저장됩니다. 마운트된 외장 볼륨이 하나뿐이면 자동으로 선택되고, 여러 개면 패널에서 고릅니다. `ssdlink volume /Volumes/이름` 으로도 바꿀 수 있습니다.
- 설치: `./build.sh` (macOS 14 이상, 애드혹 서명)

## License

MIT
