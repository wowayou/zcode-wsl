# zcode-wsl

Run the official [ZCode](https://zcode.z.ai) desktop app inside WSL2, and have it behave like a normal Windows app: a Start Menu entry that launches without a console window, and a sign-in flow that actually completes.

ZCode ships a Linux build that runs fine under WSLg — but three things break silently, and this installer fixes exactly those three. **Nothing is patched, repackaged or redistributed.** The app is the official AppImage, downloaded from Z.ai's own CDN at install time.

```bash
git clone https://github.com/wowayou/zcode-wsl.git
cd zcode-wsl
./install.sh --plan     # see exactly what it would do
./install.sh            # do it
```

Then: **Start Menu → ZCode (WSL)**. Click sign-in, authorise in the browser tab that opens, done.

---

## Why you need this

Install the Linux AppImage in WSL by hand and you hit, in order:

| Symptom | Cause |
| --- | --- |
| `dlopen(): error loading libfuse.so.2` | Ubuntu 24.04 ships fuse3; AppImages self-mount with libfuse2 |
| Sign-in hangs forever on *Waiting for Z.ai authentication…* | WSL has no browser, so `xdg-open` fails silently and the login page never opens |
| Nothing in the Start Menu | WSLg's `.desktop` mirroring is unreliable and often skips apps |

The middle one is the real trap: the app looks broken, but it is patiently waiting for a browser tab that never appeared. That one cost hours to diagnose, which is why this repo exists.

## Requirements

- WSL2 **with WSLg** — Windows 11, or Windows 10 22H2+ after a `wsl --update`. Check with `echo $DISPLAY`; it should print `:0`.
- x86_64 or aarch64.
- A distro with `apt`, `dnf`, `zypper` or `pacman` (only for the one-time `wslu` install).
- `curl`. Everything else is already in WSL.

## Options

```
--plan               Print the full plan and exit. Changes nothing.
--version <x.y.z>    Install a specific version (default: newest found)
--sha256 <hex>       Require the download to match this checksum
--dir <path>         Install location (default: ~/apps/zcode)
--keep-appimage      Keep the ~190 MB .AppImage after extracting
--skip-protocol      Don't register the zcode:// handler on Windows
--skip-shortcut      Don't create the Start Menu shortcut
--skip-browser       Don't install wslu (sign-in will not work)
--force              Reinstall even if that version is already installed
```

Re-running `install.sh` upgrades in place: same version is a no-op (`--force` overrides), newer version replaces the app directory. Your settings, sessions and credentials live in `~/.zcode/` and are never touched.

If ZCode is running, the installer stops and asks you to quit it first — replacing the files under a running instance leaves it half-broken.

---

## What it changes

Everything below is printed by `--plan` before anything happens, and removed by `./uninstall.sh`.

**In WSL**

| Path | What |
| --- | --- |
| `~/apps/zcode/app/` | the extracted official app |
| `~/.local/share/applications/zcode.desktop` | desktop entry, declares the `zcode://` scheme |
| `~/.local/share/icons/zcode.png` | icon |
| `wslu` package | so `xdg-open` can reach your Windows browser |

**On Windows** — current user only (`HKCU`), no admin, no `Program Files`:

| Path | What |
| --- | --- |
| `%LOCALAPPDATA%\zcode-wsl\` | `launch.vbs`, `router.ps1`, and a backup of any previous handler |
| `HKCU\Software\Classes\zcode` | routes `zcode://` links to `router.ps1` |
| Start Menu → *ZCode (WSL)* | shortcut |

**Never touched:** `~/.zcode/` (your data), ZCode for Windows, system directories, anything needing root on the Windows side.

### If you also run ZCode for Windows

Both keep working. The installer detects the Windows copy and generates a router that sends each `zcode://` callback to whichever copy is actually running — the WSL one when it's open, the Windows one otherwise. The Windows app's own Start Menu entry is untouched, and the new entry is named *ZCode (WSL)* so the two never collide.

Before overwriting the `zcode://` registration, the installer exports whatever was there into `previous-handler.reg`, and `uninstall.sh` puts it back. So uninstalling zcode-wsl restores the Windows app's own registration rather than leaving it broken.

Sign in to one at a time, though. With both open, callbacks go to the WSL copy.

---

## Safety and what this script will not do

The whole thing is two shell scripts you can read in fifteen minutes. Still, it touches your Windows registry, so here is the honest accounting.

**It does not**
- run anything as root on the Windows side, or write outside `HKCU` and `%LOCALAPPDATA%`
- send telemetry, analytics or any data anywhere — the only network access is downloading the AppImage from `cdn-zcode.z.ai` and reading the public download page
- pipe a remote script into a shell — clone the repo, read it, then run it
- modify, patch or repackage ZCode; it extracts the official AppImage as published
- touch `~/.zcode/`, so your login and history survive upgrades and uninstalls
- delete anything it did not create, except the install directory it owns

**It does**
- ask for `sudo` once, only to install `wslu` from your distro's package manager
- write to `HKCU\Software\Classes\zcode` (after backing up what was there)
- verify every download: HTTP status, file size, ELF magic bytes, and an optional `--sha256` you supply
- print a sha256 of what it downloaded, so you can pin it on other machines
- refuse to continue on anything it cannot verify, rather than guessing

**Supply chain, stated plainly.** This installer trusts `cdn-zcode.z.ai` to serve a genuine ZCode build. Z.ai publishes no checksums or signatures for the Linux AppImage, so there is nothing to verify against — the same trust you extend by downloading it from their site yourself. What the script adds is `--sha256`: install once, note the printed checksum, then pin it on every other machine so they all get provably identical bytes.

**Reviewing before you run.** `--plan` resolves the version, prints every path it would write, and exits without changing anything. Do that first.

---

## Compatibility: what happens when Z.ai changes things

Version discovery reads a public web page, which is inherently fragile. It is written so that a redesign degrades into an inconvenience, never a dead end.

**Finding the version** — four independent patterns are tried against the download page, newest match first:

1. `releases/<ver>/linux-<arch>/` — today's layout
2. `ZCode-<ver>-linux-<arch>.AppImage` — the filename anywhere on the page
3. `releases/<ver>/` — any versioned release directory
4. any bare `x.y.z` on the page — last resort

**Then it verifies.** Every candidate is checked with an HTTP request before being accepted, so a version scraped out of unrelated page text is discarded rather than downloaded. Two URL layouts are tried per version, because Z.ai changed theirs at 3.3.6:

```
<base>/<ver>/linux-<arch>/ZCode-<ver>-linux-<arch>.AppImage    # 3.3.6 and later
<base>/<ver>/ZCode-<ver>-linux-<arch>.AppImage                 # 3.3.5 and earlier
```

**If everything fails,** it falls back to a pinned known-good version (`PINNED_VERSION` at the top of `install.sh`), and if even that is gone it stops with the exact command to work around it:

```bash
./install.sh --version 3.12.0
```

So `--version` is the permanent escape hatch: **any future release can be installed even if discovery breaks entirely.** The integration steps — extraction, browser handoff, protocol routing, shortcut — don't depend on the version at all.

### What would actually break it

| If Z.ai… | Effect | Fix |
| --- | --- | --- |
| redesigns the download page | discovery falls back to pinned version | `--version <new>` |
| moves the CDN host | download fails with a clear error | edit `DOWNLOAD_BASE`, or open an issue |
| changes the URL layout again | both known layouts fail | add a line to `appimage_urls_for()` |
| stops shipping Linux builds | nothing to install | none — this repo becomes obsolete |
| renames the binary inside the AppImage | install aborts before touching anything | update the `$APP_DIR/zcode` check |
| changes the callback scheme from `zcode://` | protocol routing is dead weight, sign-in still works via polling | update the scheme in step 4 |

Sign-in has redundancy by design: the app *polls* Z.ai every two seconds in addition to waiting for the `zcode://` callback. Either path completes the login, which is why `--skip-protocol` still leaves sign-in working.

### Keeping this repo alive

If a new ZCode release breaks something:

1. `./install.sh --plan` — the failure is usually obvious right there
2. `./install.sh --version <known-good>` — unblock yourself immediately
3. Bump `PINNED_VERSION` in `install.sh` when a newer version is confirmed good
4. Open an issue with the `--plan` output

---

## Known WSLg quirks

**The minimise button does nothing.** ZCode draws its own title bar, and under WSLg those custom buttons don't reach the window manager. Use `Win`+`Down`, or click the taskbar icon. Maximise and close work normally.

**Don't add `--ozone-platform=wayland`.** It's the obvious fix for the above, and it half-works: the window gains real Windows decorations and looks correct. It also swallows *every mouse click*, leaving the UI completely unusable. This was tested and reverted; the installer deliberately passes no Ozone flags. `ZCODE_FLAGS` at the top of `install.sh` is where flags would go, and it is empty on purpose.

**A `drmGetDevices2()` error on startup** is normal: WSLg has no GPU node to enumerate, so rendering falls back to software.

## Troubleshooting

**Sign-in hangs on *Waiting for Z.ai authentication…*** — the browser handoff is broken. Test it:

```bash
xdg-open https://example.com          # should open a tab in Windows
xdg-settings set default-web-browser wslview.desktop
```

**No Start Menu entry.** Re-run `./install.sh`, or run `%LOCALAPPDATA%\zcode-wsl\launch.vbs` directly to check the launcher itself.

**Window blank or won't render.** `~/apps/zcode/app/zcode --disable-gpu`

**`zcode://` links do nothing.** Confirm the registration:

```bash
reg.exe query 'HKCU\Software\Classes\zcode\shell\open\command' /ve
```

**Logs.** `~/.zcode/v2/logs/` — one file per day, and quite readable. The sign-in flow logs every step.

## Uninstall

```bash
./uninstall.sh              # removes the app and all integration
./uninstall.sh --purge      # also deletes ~/.zcode (settings, sessions, logins)
```

Restores any previous `zcode://` handler, leaves `wslu` installed (other tools use it), and by default keeps your data.

## Contributing

Issues and PRs welcome, especially:

- other WSL distros (only Ubuntu 24.04 is tested end-to-end)
- aarch64 — the code paths exist but are untested
- a new ZCode release that breaks discovery

Please include `./install.sh --plan` output and your `wsl --version`.

Keep the scope tight: this repo fixes WSL integration gaps and nothing else. It should never patch, bundle or vendor any part of ZCode.

## Licence

This installer is MIT licensed — see [LICENSE](LICENSE).

ZCode itself is Z.ai's proprietary software, downloaded from their CDN at install time and subject to [their terms](https://zcode.z.ai). This project is not affiliated with, endorsed by, or supported by Z.ai. It contains no ZCode code.
