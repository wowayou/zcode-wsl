#!/usr/bin/env bash
#
# zcode-wsl — install the official ZCode desktop app inside WSL2 and make it
# behave like a native Windows app (Start Menu entry, working OAuth login).
#
# This script downloads the official AppImage from Z.ai and only fixes the
# WSL-specific integration gaps. It does not patch, repackage or redistribute
# any part of ZCode.
#
# Usage:
#   ./install.sh                 # latest version, auto-detected
#   ./install.sh --version 3.11.2
#   ./install.sh --help
#
set -euo pipefail

# ---------------------------------------------------------------- defaults ---
FALLBACK_VERSION="3.11.2"     # used only if version detection fails
VERSION=""
INSTALL_DIR="$HOME/apps/zcode"
KEEP_APPIMAGE=0
SKIP_PROTOCOL=0
SKIP_SHORTCUT=0
SKIP_BROWSER=0

# Extra flags passed to the ZCode binary.
# Leave empty. In particular do NOT add --ozone-platform=wayland: under WSLg it
# renders correctly but swallows every mouse click, making the UI unusable.
ZCODE_FLAGS=""

DOWNLOAD_BASE="https://cdn-zcode.z.ai/zcode/electron/releases"
DOWNLOAD_PAGE="https://zcode.z.ai/en"

# ------------------------------------------------------------------- utils ---
c_reset=$'\033[0m'; c_bold=$'\033[1m'; c_dim=$'\033[2m'
c_red=$'\033[31m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_blue=$'\033[34m'

step()  { printf '%s==>%s %s%s\n' "$c_blue$c_bold" "$c_reset" "$c_bold" "$1$c_reset"; }
info()  { printf '    %s\n' "$1"; }
ok()    { printf '    %s✓%s %s\n' "$c_green" "$c_reset" "$1"; }
warn()  { printf '    %s!%s %s\n' "$c_yellow" "$c_reset" "$1"; }
die()   { printf '%serror:%s %s\n' "$c_red$c_bold" "$c_reset" "$1" >&2; exit 1; }

usage() {
  cat <<'USAGE'
zcode-wsl — install the official ZCode desktop app inside WSL2

Usage: ./install.sh [options]

Options:
  --version <x.y.z>   Install a specific version (default: auto-detect latest)
  --dir <path>        Install location (default: ~/apps/zcode)
  --keep-appimage     Keep the downloaded .AppImage after extracting (~190 MB)
  --skip-protocol     Do not register the zcode:// URL handler on Windows
  --skip-shortcut     Do not create the Windows Start Menu shortcut
  --skip-browser      Do not install wslu / change the default browser
                      (warning: OAuth sign-in will not work without it)
  -h, --help          Show this help

What it does:
  1. Downloads the official ZCode AppImage and extracts it (no root needed)
  2. Installs wslu so WSL can open your Windows browser  <- required for login
  3. Registers a zcode:// handler on Windows for the OAuth callback
  4. Adds a Start Menu shortcut that launches without a console window

Nothing is patched or repackaged: the app itself is the official build.
USAGE
}

# --------------------------------------------------------------- arg parse ---
while [ $# -gt 0 ]; do
  case "$1" in
    --version)        VERSION="${2:-}"; [ -n "$VERSION" ] || die "--version needs a value"; shift 2 ;;
    --dir)            INSTALL_DIR="${2:-}"; [ -n "$INSTALL_DIR" ] || die "--dir needs a value"; shift 2 ;;
    --keep-appimage)  KEEP_APPIMAGE=1; shift ;;
    --skip-protocol)  SKIP_PROTOCOL=1; shift ;;
    --skip-shortcut)  SKIP_SHORTCUT=1; shift ;;
    --skip-browser)   SKIP_BROWSER=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                die "unknown option: $1 (try --help)" ;;
  esac
done

APP_DIR="$INSTALL_DIR/app"

# " --flag --flag" when set, empty otherwise — keeps generated files tidy.
FLAGS_SP=""
[ -n "$ZCODE_FLAGS" ] && FLAGS_SP=" $ZCODE_FLAGS"

# --------------------------------------------------------------- preflight ---
step "Checking environment"

grep -qi microsoft /proc/version 2>/dev/null \
  || die "not running inside WSL — this installer is WSL-specific"

[ -n "${DISPLAY:-}" ] || die "\$DISPLAY is empty: WSLg is unavailable, so a GUI app cannot run.
       WSLg needs Windows 11, or Windows 10 22H2+ with an updated WSL.
       Try:  wsl --update   (from PowerShell), then restart WSL."

case "$(uname -m)" in
  x86_64)  ARCH="x64" ;;
  aarch64) ARCH="arm64" ;;
  *) die "unsupported architecture: $(uname -m) (ZCode ships x64 and arm64 only)" ;;
esac

DISTRO="${WSL_DISTRO_NAME:-}"
[ -n "$DISTRO" ] || die "\$WSL_DISTRO_NAME is empty — cannot tell Windows which distro to launch"

for c in curl; do
  command -v "$c" >/dev/null || die "missing required command: $c"
done

# cmd.exe complains when the cwd is a UNC path, so always call it from /mnt/c
win_env() { (cd /mnt/c && cmd.exe /c "echo %$1%" 2>/dev/null | tr -d '\r\n'); }

WIN_LOCALAPPDATA="$(win_env LOCALAPPDATA)"
[ -n "$WIN_LOCALAPPDATA" ] || die "could not read %LOCALAPPDATA% — is interop with Windows enabled?"
WIN_HELPER_WIN="$WIN_LOCALAPPDATA\\zcode-wsl"
WIN_HELPER_DIR="$(wslpath -u "$WIN_HELPER_WIN")"

ok "WSL distro: $DISTRO"
ok "architecture: $ARCH"

# ----------------------------------------------------------- resolve version --
if [ -z "$VERSION" ]; then
  step "Resolving latest version"
  VERSION="$(curl -fsSL --max-time 20 "$DOWNLOAD_PAGE" 2>/dev/null \
    | grep -oE 'releases/[0-9]+\.[0-9]+\.[0-9]+/linux-' \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
    | sort -V | tail -1 || true)"
  if [ -n "$VERSION" ]; then
    ok "latest is $VERSION"
  else
    VERSION="$FALLBACK_VERSION"
    warn "could not read the download page, falling back to $VERSION"
    warn "pass --version <x.y.z> to choose explicitly"
  fi
fi

APPIMAGE="ZCode-${VERSION}-linux-${ARCH}.AppImage"
URL="$DOWNLOAD_BASE/${VERSION}/linux-${ARCH}/${APPIMAGE}"

# ------------------------------------------------------------ 1. app itself --
step "1/5  Downloading and extracting ZCode $VERSION"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

if [ -s "$APPIMAGE" ]; then
  info "reusing existing download: $APPIMAGE"
else
  info "$URL"
  curl -fL --progress-bar -o "$APPIMAGE.part" "$URL" \
    || die "download failed — check the version number and your network"
  mv "$APPIMAGE.part" "$APPIMAGE"
fi

# Sanity-check what we downloaded before trusting it as an executable.
[ "$(stat -c%s "$APPIMAGE")" -gt 50000000 ] \
  || die "$APPIMAGE looks too small to be a real build — delete it and retry"
head -c 4 "$APPIMAGE" | grep -q $'\x7fELF' \
  || die "$APPIMAGE is not an ELF binary (the download may be an error page)"

chmod +x "$APPIMAGE"

# Ubuntu 24.04 ships fuse3 only, while AppImages need libfuse2 to self-mount.
# Extracting sidesteps that and needs no root at all.
info "extracting (AppImages need libfuse2 to run directly; extracting avoids it)"
rm -rf squashfs-root
"./$APPIMAGE" --appimage-extract >/dev/null \
  || die "extraction failed — the AppImage may be corrupt"

rm -rf "$APP_DIR"
mv squashfs-root "$APP_DIR"
[ -x "$APP_DIR/zcode" ] || die "extracted tree has no zcode binary at $APP_DIR/zcode"

if [ "$KEEP_APPIMAGE" -eq 0 ]; then
  rm -f "$APPIMAGE"
  info "removed the .AppImage (pass --keep-appimage to keep it)"
fi
ok "installed to $APP_DIR"

# --------------------------------------------------------------- 2. browser --
# The single most common failure: WSL has no browser, so xdg-open fails silently
# and the OAuth login page never opens. The app then waits forever on
# "Waiting for Z.ai authentication...".
step "2/5  Making WSL able to open your Windows browser"
if [ "$SKIP_BROWSER" -eq 1 ]; then
  warn "skipped on request — OAuth sign-in will not work"
elif command -v wslview >/dev/null 2>&1; then
  ok "wslu already installed"
else
  info "installing wslu (needs sudo once)"
  if sudo -n true 2>/dev/null; then :; else
    info "${c_dim}sudo will ask for your password${c_reset}"
  fi
  if command -v apt-get >/dev/null; then
    sudo apt-get update -qq && sudo apt-get install -y wslu
  elif command -v dnf >/dev/null; then
    sudo dnf install -y wslu
  elif command -v zypper >/dev/null; then
    sudo zypper install -y wslu
  elif command -v pacman >/dev/null; then
    sudo pacman -S --noconfirm wslu
  else
    die "no supported package manager found — install wslu manually, then rerun"
  fi
fi

if [ "$SKIP_BROWSER" -eq 0 ] && command -v wslview >/dev/null 2>&1; then
  xdg-settings set default-web-browser wslview.desktop 2>/dev/null || true
  xdg-mime default wslview.desktop x-scheme-handler/http x-scheme-handler/https 2>/dev/null || true
  if xdg-open https://example.com >/dev/null 2>&1; then
    ok "browser handoff works (a test tab just opened in Windows)"
  else
    warn "xdg-open still fails; sign-in may not work"
  fi
fi

# -------------------------------------------------------- 3. desktop entry ---
step "3/5  Adding the Linux desktop entry"
mkdir -p "$HOME/.local/share/applications" "$HOME/.local/share/icons"
[ -f "$APP_DIR/zcode.png" ] && cp -f "$APP_DIR/zcode.png" "$HOME/.local/share/icons/zcode.png"
cat > "$HOME/.local/share/applications/zcode.desktop" <<EOF
[Desktop Entry]
Name=ZCode
Comment=ZCode Desktop App
Exec="$APP_DIR/zcode"$FLAGS_SP %U
Terminal=false
Type=Application
Icon=zcode
Categories=Development;
MimeType=x-scheme-handler/zcode;
StartupWMClass=ZCode
EOF
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
ok "zcode.desktop written"

# ------------------------------------------------------------- 4. protocol ---
# After you authorise in the browser, Z.ai redirects to zcode://oauth/callback.
# That scheme is only known inside WSL, so Windows drops it. Registering a
# forwarder on the Windows side closes the loop.
#
# If ZCode for Windows is also installed, this router keeps it working: the
# callback goes to whichever copy is actually running.
step "4/5  Registering the zcode:// handler on Windows"
if [ "$SKIP_PROTOCOL" -eq 1 ]; then
  warn "skipped on request"
else
  mkdir -p "$WIN_HELPER_DIR"

  WIN_ZCODE_EXE=""
  for p in /mnt/*/Users/*/AppData/Local/Programs/ZCode/ZCode.exe; do
    [ -f "$p" ] && { WIN_ZCODE_EXE="$(wslpath -w "$p")"; break; }
  done

  {
    printf '# Routes zcode:// links. Generated by zcode-wsl.\n'
    printf 'param([string]$Url)\n\n'
    printf '$wslRunning = $false\n'
    printf 'try {\n'
    printf "  \$n = & wsl.exe -d %s -- pgrep -c -f '%s/zcode' 2>\$null\n" "$DISTRO" "$APP_DIR"
    printf '  if ($LASTEXITCODE -eq 0 -and [int]$n -gt 0) { $wslRunning = $true }\n'
    printf '} catch {}\n\n'
    if [ -n "$WIN_ZCODE_EXE" ]; then
      printf '# ZCode for Windows was detected at install time; it keeps handling\n'
      printf '# callbacks whenever the WSL copy is not the one running.\n'
      printf '$winExe = "%s"\n\n' "$WIN_ZCODE_EXE"
      printf 'if (-not $wslRunning -and (Test-Path $winExe)) {\n'
      printf '  & $winExe $Url\n'
      printf '} else {\n'
      printf '  & wsl.exe -d %s -- %s/zcode%s $Url\n' "$DISTRO" "$APP_DIR" "$FLAGS_SP"
      printf '}\n'
    else
      printf '& wsl.exe -d %s -- %s/zcode%s $Url\n' "$DISTRO" "$APP_DIR" "$FLAGS_SP"
    fi
  } > "$WIN_HELPER_DIR/router.ps1"

  ROUTER_WIN="$WIN_HELPER_WIN\\router.ps1"
  ROUTER_ESC="${ROUTER_WIN//\\/\\\\}"
  REG_FILE="$WIN_HELPER_DIR/zcode-protocol.reg"
  {
    printf 'Windows Registry Editor Version 5.00\r\n\r\n'
    printf '[HKEY_CURRENT_USER\\Software\\Classes\\zcode]\r\n'
    printf '@="URL:ZCode Protocol"\r\n'
    printf '"URL Protocol"=""\r\n\r\n'
    printf '[HKEY_CURRENT_USER\\Software\\Classes\\zcode\\shell\\open\\command]\r\n'
    printf '@="powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \\"%s\\" \\"%%1\\""\r\n' "$ROUTER_ESC"
  } > "$REG_FILE"

  if reg.exe import "$(wslpath -w "$REG_FILE")" >/dev/null 2>&1; then
    ok "zcode:// routed through $ROUTER_WIN"
    [ -n "$WIN_ZCODE_EXE" ] && info "ZCode for Windows detected — it still receives callbacks when the WSL copy is closed"
  else
    warn "registry import failed; sign-in may still work via polling"
    info "to retry by hand:  reg.exe import '$(wslpath -w "$REG_FILE")'"
  fi
fi

# ------------------------------------------------------------- 5. shortcut ---
# WSLg is supposed to mirror .desktop files into the Start Menu, but it is
# unreliable and often skips apps. Creating the shortcut directly always works.
step "5/5  Creating the Windows Start Menu shortcut"
if [ "$SKIP_SHORTCUT" -eq 1 ]; then
  warn "skipped on request"
else
  mkdir -p "$WIN_HELPER_DIR"

  # wsl.exe would flash a console window; wscript running this VBS does not.
  {
    printf "' Launches ZCode inside WSL without flashing a console window.\r\n"
    printf "' Generated by zcode-wsl.\r\n"
    printf 'Set sh = CreateObject("WScript.Shell")\r\n'
    printf 'sh.Run "wsl.exe -d %s -- %s/zcode%s", 0, False\r\n' "$DISTRO" "$APP_DIR" "$FLAGS_SP"
  } > "$WIN_HELPER_DIR/launch.vbs"

  ICON_WIN=""
  if [ -f "$APP_DIR/zcode.png" ] && command -v convert >/dev/null 2>&1; then
    convert "$APP_DIR/zcode.png" -define icon:auto-resize=256,64,48,32,16 \
      "$WIN_HELPER_DIR/zcode.ico" 2>/dev/null && ICON_WIN="$WIN_HELPER_WIN\\zcode.ico"
  fi
  if [ -z "$ICON_WIN" ]; then
    for p in /mnt/*/Users/*/AppData/Local/Programs/ZCode/ZCode.exe; do
      [ -f "$p" ] && { ICON_WIN="$(wslpath -w "$p"),0"; break; }
    done
  fi

  # Build the shortcut from a script file rather than an inline -Command, to
  # keep Windows/PowerShell quoting out of the picture.
  MK="$WIN_HELPER_DIR/mkshortcut.ps1"
  {
    printf '$w = New-Object -ComObject WScript.Shell\n'
    printf "\$p = Join-Path \$w.SpecialFolders('Programs') 'ZCode (WSL).lnk'\n"
    printf '$s = $w.CreateShortcut($p)\n'
    printf '$s.TargetPath = Join-Path $env:WINDIR "system32\\wscript.exe"\n'
    printf '$s.Arguments = %s\n' "'\"$WIN_HELPER_WIN\\launch.vbs\"'"
    [ -n "$ICON_WIN" ] && printf '$s.IconLocation = "%s"\n' "$ICON_WIN"
    printf '$s.Description = "ZCode running inside WSL (%s)"\n' "$DISTRO"
    printf '$s.Save()\n'
    printf 'Write-Output $p\n'
  } > "$MK"

  SHORTCUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$MK")" 2>/dev/null | tr -d '\r' | tail -1 || true)"
  if [ -n "$SHORTCUT" ]; then
    ok "Start Menu entry: ZCode (WSL)"
  else
    warn "could not create the shortcut; launch with $APP_DIR/zcode instead"
  fi
fi

# ----------------------------------------------------------------- summary ---
cat <<EOF

${c_green}${c_bold}Done.${c_reset}  ZCode $VERSION is installed.

  ${c_bold}Launch${c_reset}        Start Menu → "ZCode (WSL)"
  ${c_bold}Or${c_reset}            $APP_DIR/zcode
  ${c_bold}Your data${c_reset}     ~/.zcode/        (settings, sessions, credentials)
  ${c_bold}Uninstall${c_reset}     ./uninstall.sh

${c_bold}Signing in${c_reset}
  Click sign-in and your Windows browser opens the Z.ai page. Authorise there
  and the app picks it up on its own — nothing to paste back.

${c_bold}Known WSLg quirk${c_reset}
  ZCode draws its own title bar, and its minimise button does nothing under
  WSLg. Use Win+Down, or click the taskbar icon, instead.
EOF
