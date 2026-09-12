# zcode-wsl

Run the official [ZCode](https://zcode.z.ai) desktop app inside WSL2, and have it behave like a normal Windows app: a Start Menu entry that launches without a console window, and a sign-in flow that actually completes.

ZCode ships Windows, macOS and Linux builds. The Linux build runs fine under WSLg — but three things break silently, and this installer fixes exactly those three. Nothing is patched, repackaged or redistributed: the app is the official AppImage, downloaded from Z.ai at install time.

## Why you need this

Install the Linux AppImage in WSL by hand and you hit, in order:

| Symptom | Cause |
| --- | --- |
| `dlopen(): error loading libfuse.so.2` | Ubuntu 24.04 ships fuse3; AppImages self-mount with libfuse2 |
| Sign-in hangs forever on *Waiting for Z.ai authentication…* | WSL has no browser, so `xdg-open` fails silently and the login page never opens |
| Nothing in the Start Menu | WSLg's `.desktop` mirroring is unreliable and often skips apps |

The middle one is the real trap: the app looks broken, but it is patiently waiting for a browser tab that never appeared.

## Install

```bash
git clone https://github.com/<you>/zcode-wsl.git
cd zcode-wsl
./install.sh
```

Takes a few minutes, mostly the ~190 MB download. You'll be asked for your sudo password once, to install `wslu`.

Then: **Start Menu → ZCode (WSL)**. Click sign-in, authorise in the browser tab that opens, and the app picks it up on its own.

### Options

```
--version <x.y.z>   Install a specific version (default: auto-detect latest)
--dir <path>        Install location (default: ~/apps/zcode)
--keep-appimage     Keep the downloaded .AppImage after extracting (~190 MB)
--skip-protocol     Don't register the zcode:// URL handler on Windows
--skip-shortcut     Don't create the Start Menu shortcut
--skip-browser      Don't install wslu (sign-in will not work)
```

Re-running `install.sh` upgrades in place. Your settings, sessions and credentials live in `~/.zcode/` and are left alone.

## Requirements

- WSL2 with WSLg — Windows 11, or Windows 10 22H2+ after a `wsl --update`. Check with `echo $DISPLAY`; it should print `:0`.
- x86_64 or aarch64.
- A Debian/Ubuntu, Fedora, openSUSE or Arch based distro (for the `wslu` step).

## What it changes

Four things, all reversible with `./uninstall.sh`:

**In WSL**
- `~/apps/zcode/app/` — the extracted official app
- `~/.local/share/applications/zcode.desktop` — desktop entry, declares the `zcode://` scheme
- `wslu` installed, and `wslview` set as the default browser so `xdg-open` reaches Windows

**On Windows** (current user only, no admin needed)
- `%LOCALAPPDATA%\zcode-wsl\` — a launcher (`launch.vbs`) and a URL router (`router.ps1`)
- `HKCU\Software\Classes\zcode` — routes `zcode://` links to the router
- Start Menu → *ZCode (WSL)*

### If you also run ZCode for Windows

Both keep working. The installer detects the Windows copy and generates a router that sends each `zcode://` callback to whichever copy is actually running — the WSL one when it's open, the Windows one otherwise. The Windows app's own Start Menu entry and registration are untouched; the new entry is named *ZCode (WSL)* so the two never collide.

Sign in to one at a time, though. With both open, callbacks go to the WSL copy.

## Uninstall

```bash
./uninstall.sh              # removes the app and all integration
./uninstall.sh --purge      # also deletes ~/.zcode (settings, sessions, logins)
```

`wslu` is left installed — it's a generally useful package, and other tools may rely on it.

## Known WSLg quirks

**The minimise button does nothing.** ZCode draws its own title bar, and under WSLg those custom buttons don't reach the window manager. Use `Win`+`Down`, or click the taskbar icon. Maximise and close work normally.

**Don't add `--ozone-platform=wayland`.** It's the obvious fix for the above — the window gains real Windows decorations and looks right. It also swallows every mouse click, leaving the UI unusable. The installer deliberately passes no Ozone flags.

**A `drmGetDevices2()` error on startup** is normal: WSLg has no GPU node to enumerate, and rendering falls back to software.

## How sign-in works

Worth knowing if you're debugging it:

1. The app opens `https://chat.z.ai/api/oauth/authorize` — via `xdg-open`, hence `wslu`
2. You authorise in the browser
3. Two things then race, and either one completes the login:
   - the app polls Z.ai every 2 seconds (`oauth.pollPendingOAuth`) and notices on its own
   - the browser redirects to `zcode://oauth/callback`, which Windows hands to the router

Polling alone is usually enough, which is why `--skip-protocol` still leaves sign-in working. The handler is registered anyway, because other in-app links (payment, workspace) use the same scheme.

## Troubleshooting

**Sign-in still hangs.** Check the browser handoff: `xdg-open https://example.com` should open a Windows tab. If not, `xdg-settings set default-web-browser wslview.desktop`.

**No Start Menu entry.** Re-run `./install.sh`, or launch `%LOCALAPPDATA%\zcode-wsl\launch.vbs` directly to confirm the launcher itself works.

**Window won't render / stays blank.** Try `~/apps/zcode/app/zcode --disable-gpu`.

**Logs.** `~/.zcode/v2/logs/` — one file per day, and quite readable.

## Licence

This installer is MIT licensed. ZCode itself is Z.ai's proprietary software, downloaded from their CDN at install time and subject to their terms. This project is not affiliated with or endorsed by Z.ai.
