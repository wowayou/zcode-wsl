#!/usr/bin/env bash
#
# zcode-wsl — install the official ZCode desktop app inside WSL2 and make it
# behave like a native Windows app.
#
# This script downloads the official AppImage published by Z.ai and fixes only
# the WSL-specific integration gaps. It does not patch, repackage, redistribute
# or bundle any part of ZCode, and it sends nothing anywhere.
#
# Everything it changes is listed by `./install.sh --plan`, and undone by
# `./uninstall.sh`.
#
# Usage:
#   ./install.sh                    # latest version, auto-detected
#   ./install.sh --plan             # show what would happen, change nothing
#   ./install.sh --version 3.11.2
#   ./install.sh --help
#
set -euo pipefail

# ---------------------------------------------------------------- constants ---

# Last version this installer was tested against. Used only when version
# discovery fails (offline, or Z.ai restructured their download page).
# See README → "Keeping this repo alive".
PINNED_VERSION="3.11.2"

DOWNLOAD_BASE="https://cdn-zcode.z.ai/zcode/electron/releases"
DOWNLOAD_PAGES="https://zcode.z.ai/en https://zcode.z.ai"

# Extra flags for the ZCode binary. Deliberately empty.
# Do NOT add --ozone-platform=wayland: under WSLg the window gains real Windows
# decorations and looks correct, but every mouse click is swallowed and the UI
# becomes unusable. See README → "Known WSLg quirks".
ZCODE_FLAGS=""

MIN_APPIMAGE_BYTES=50000000      # a real build is ~200 MB; anything less is an error page
NEED_FREE_MB=1200                # download + extraction + headroom

# ----------------------------------------------------------------- defaults ---
VERSION=""
INSTALL_DIR="$HOME/apps/zcode"
EXPECT_SHA256=""
KEEP_APPIMAGE=0
SKIP_PROTOCOL=0
SKIP_SHORTCUT=0
SKIP_BROWSER=0
FORCE=0
PLAN_ONLY=0
ASSUME_YES=0

# -------------------------------------------------------------------- utils ---
if [ -t 1 ]; then
  c_reset=$'\033[0m'; c_bold=$'\033[1m'; c_dim=$'\033[2m'
  c_red=$'\033[31m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_blue=$'\033[34m'
else
  c_reset=''; c_bold=''; c_dim=''; c_red=''; c_green=''; c_yellow=''; c_blue=''
fi

step() { printf '%s==>%s %s%s\n' "$c_blue$c_bold" "$c_reset" "$c_bold" "$1$c_reset"; }
info() { printf '    %s\n' "$1"; }
ok()   { printf '    %s✓%s %s\n' "$c_green" "$c_reset" "$1"; }
warn() { printf '    %s!%s %s\n' "$c_yellow" "$c_reset" "$1"; }
die()  { printf '\n%serror:%s %s\n' "$c_red$c_bold" "$c_reset" "$1" >&2; exit 1; }

# Progress bar for the five install stages. Block characters need a UTF-8
# locale; anything else gets ASCII so the bar never turns into mojibake.
TOTAL_STAGES=5
STAGE_NO=0
BAR_WIDTH=22
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *UTF-8*|*utf8*|*UTF8*) BAR_FULL='█'; BAR_EMPTY='░' ;;
  *)                     BAR_FULL='#'; BAR_EMPTY='-' ;;
esac

stage() {
  STAGE_NO=$((STAGE_NO + 1))
  local title="$1" filled i bar=''
  filled=$(( STAGE_NO * BAR_WIDTH / TOTAL_STAGES ))
  for ((i = 0; i < BAR_WIDTH; i++)); do
    if [ "$i" -lt "$filled" ]; then bar="$bar$BAR_FULL"; else bar="$bar$BAR_EMPTY"; fi
  done
  printf '\n%s%s%s %s%d/%d%s  %s%s%s\n' \
    "$c_blue" "$bar" "$c_reset" \
    "$c_dim" "$STAGE_NO" "$TOTAL_STAGES" "$c_reset" \
    "$c_bold" "$title" "$c_reset"
}

TMP_FILES=()
TMP_DIRS=()
cleanup() {
  local f d
  for f in ${TMP_FILES+"${TMP_FILES[@]}"}; do [ -n "$f" ] && rm -f "$f"; done
  for d in ${TMP_DIRS+"${TMP_DIRS[@]}"}; do [ -n "$d" ] && rm -rf "$d"; done
}
trap cleanup EXIT

confirm() {
  # confirm <prompt> ; returns 0 for yes
  [ "$ASSUME_YES" -eq 1 ] && return 0
  if [ ! -t 0 ]; then
    warn "not a terminal and --yes not given, assuming no"
    return 1
  fi
  printf '    %s [y/N] ' "$1"
  local reply; read -r reply
  case "$reply" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# Quote a string for embedding inside PowerShell single quotes.
ps1_squote() { printf "'%s'" "${1//\'/\'\'}"; }
# Quote a string for embedding inside a VBScript double-quoted literal.
vbs_dquote() { printf '""%s""' "${1//\"/\"\"}"; }

usage() {
  cat <<'USAGE'
zcode-wsl — install the official ZCode desktop app inside WSL2

Usage: ./install.sh [options]

Options:
  --version <x.y.z>   Install a specific version (default: auto-detect latest)
  --dir <path>        Install location (default: ~/apps/zcode)
  --sha256 <hex>      Verify the download against this checksum, and refuse to
                      continue if it differs
  --keep-appimage     Keep the downloaded .AppImage after extracting (~190 MB)
  --skip-protocol     Do not register the zcode:// URL handler on Windows
  --skip-shortcut     Do not create the Windows Start Menu shortcut
  --skip-browser      Do not touch the default browser
                      (warning: OAuth sign-in cannot complete without it)
  --force             Reinstall even if this version is already installed
  --plan              Print exactly what would be downloaded and changed,
                      then exit without changing anything
  -y, --yes           Assume yes for every prompt (for unattended runs)
  -h, --help          Show this help

What it fixes (and nothing else):
  1. AppImages need libfuse2, which Ubuntu 24.04 no longer ships
     -> extracts the AppImage instead of self-mounting it; no root needed
  2. WSL has no browser, so the OAuth sign-in page never opens
     -> installs wslu and points xdg-open at your Windows browser
  3. WSLg does not reliably mirror .desktop files into the Start Menu
     -> creates the shortcut on the Windows side directly

The app itself is the official build, downloaded from Z.ai at install time.
Nothing is patched or repackaged.
USAGE
}

# ---------------------------------------------------------------- arg parse ---
while [ $# -gt 0 ]; do
  case "$1" in
    --version)       VERSION="${2:-}";      [ -n "$VERSION" ]      || die "--version needs a value"; shift 2 ;;
    --dir)           INSTALL_DIR="${2:-}";  [ -n "$INSTALL_DIR" ]  || die "--dir needs a value"; shift 2 ;;
    --sha256)        EXPECT_SHA256="${2:-}";[ -n "$EXPECT_SHA256" ]|| die "--sha256 needs a value"; shift 2 ;;
    --keep-appimage) KEEP_APPIMAGE=1; shift ;;
    --skip-protocol) SKIP_PROTOCOL=1; shift ;;
    --skip-shortcut) SKIP_SHORTCUT=1; shift ;;
    --skip-browser)  SKIP_BROWSER=1; shift ;;
    --force)         FORCE=1; shift ;;
    --plan)          PLAN_ONLY=1; shift ;;
    -y|--yes)        ASSUME_YES=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               die "unknown option: $1 (try --help)" ;;
  esac
done

if [ -n "$VERSION" ]; then
  case "$VERSION" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) die "--version expects something like 3.11.2, got: $VERSION" ;;
  esac
fi
if [ -n "$EXPECT_SHA256" ]; then
  EXPECT_SHA256="$(printf '%s' "$EXPECT_SHA256" | tr 'A-Z' 'a-z')"
  case "$EXPECT_SHA256" in
    *[!0-9a-f]* | "") die "--sha256 expects 64 hex characters" ;;
  esac
  [ "${#EXPECT_SHA256}" -eq 64 ] || die "--sha256 expects 64 hex characters, got ${#EXPECT_SHA256}"
fi

# INSTALL_DIR must be absolute: it is embedded into Windows-side launchers.
case "$INSTALL_DIR" in
  /*) ;;
  ~*) INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}" ;;
  *)  INSTALL_DIR="$PWD/$INSTALL_DIR" ;;
esac
APP_DIR="$INSTALL_DIR/app"
APP_BIN="$APP_DIR/zcode"
STAMP="$APP_DIR/.zcode-wsl-version"     # what we installed, so re-runs can tell

# ---------------------------------------------------------------- preflight ---
step "Checking environment"

[ "$(id -u)" -ne 0 ] || die "do not run this as root.
       ZCode is a per-user desktop app: installing it as root puts it in /root
       and the Windows-side integration would point at the wrong user."

grep -qi microsoft /proc/version 2>/dev/null \
  || die "this does not look like WSL — the installer is WSL-specific.
       On a normal Linux desktop just run the AppImage from https://zcode.z.ai"

[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || die "no display found: WSLg is unavailable, so a GUI app cannot run.
       WSLg needs Windows 11, or Windows 10 22H2+ with an up-to-date WSL.
       Fix:  wsl --update    (in PowerShell), then:  wsl --shutdown"

case "$(uname -m)" in
  x86_64)  ARCH="x64" ;;
  aarch64) ARCH="arm64" ;;
  *) die "unsupported CPU architecture: $(uname -m).
       Z.ai publishes Linux builds for x86_64 and aarch64 only." ;;
esac

for c in curl wslpath; do
  command -v "$c" >/dev/null || die "missing required command: $c"
done

DISTRO="${WSL_DISTRO_NAME:-}"
[ -n "$DISTRO" ] || die "\$WSL_DISTRO_NAME is empty, so Windows cannot be told which distro to launch.
       Older WSL builds do not set it. Upgrade WSL, or set it yourself:
         export WSL_DISTRO_NAME=\"\$(wsl.exe -l -q --running | head -1 | tr -d '\\r')\""

# cmd.exe refuses to start in a UNC cwd, so always call Windows tools from /mnt/c.
win_env() { (cd /mnt/c 2>/dev/null && cmd.exe /c "echo %$1%" 2>/dev/null | tr -d '\r\n'); }

WIN_LOCALAPPDATA="$(win_env LOCALAPPDATA || true)"
if [ -z "$WIN_LOCALAPPDATA" ] || [ "$WIN_LOCALAPPDATA" = "%LOCALAPPDATA%" ]; then
  if [ "$SKIP_PROTOCOL" -eq 1 ] && [ "$SKIP_SHORTCUT" -eq 1 ]; then
    warn "Windows interop unavailable, but nothing Windows-side was requested"
    WIN_LOCALAPPDATA=""
  else
    die "cannot read %LOCALAPPDATA%: Windows interop looks disabled.
       Enable it (/etc/wsl.conf → [interop] enabled=true), or install with
       --skip-protocol --skip-shortcut to stay entirely inside WSL."
  fi
fi
if [ -n "$WIN_LOCALAPPDATA" ]; then
  WIN_HELPER_WIN="$WIN_LOCALAPPDATA\\zcode-wsl"
  WIN_HELPER_DIR="$(wslpath -u "$WIN_HELPER_WIN" 2>/dev/null || true)"
  [ -n "$WIN_HELPER_DIR" ] || die "could not translate $WIN_HELPER_WIN to a WSL path"
fi

ok "WSL distro: $DISTRO"
ok "architecture: $ARCH"

# ------------------------------------------------------- resolve the version ---
# Version discovery must never be the thing that breaks this installer. Layers:
#   1..4  progressively looser patterns against the download page
#   5     the pinned version above
# Every candidate is then verified with a real request to the CDN, so a bogus
# match cannot turn into a failed install.
fetch_page() {
  local p
  for p in $DOWNLOAD_PAGES; do
    curl -fsSL --max-time 25 --retry 2 --retry-delay 2 \
         -A 'zcode-wsl-installer' "$p" 2>/dev/null && return 0
  done
  return 1
}

# Both URL layouts Z.ai has used; newest first.
appimage_urls_for() {
  local v="$1" f="ZCode-${1}-linux-${ARCH}.AppImage"
  printf '%s\n' "$DOWNLOAD_BASE/$v/linux-$ARCH/$f" "$DOWNLOAD_BASE/$v/$f"
}

url_exists() {
  local code
  code="$(curl -fsSL -o /dev/null -w '%{http_code}' --max-time 20 --retry 2 \
          --retry-delay 2 -r 0-0 "$1" 2>/dev/null || true)"
  case "$code" in 200|206) return 0 ;; *) return 1 ;; esac
}

resolve_download_url() {
  # echoes a working URL for $1, or returns 1
  local u
  while IFS= read -r u; do
    url_exists "$u" && { printf '%s\n' "$u"; return 0; }
  done < <(appimage_urls_for "$1")
  return 1
}

DOWNLOAD_URL=""

if [ -n "$VERSION" ]; then
  step "Checking that version $VERSION exists"
  DOWNLOAD_URL="$(resolve_download_url "$VERSION" || true)"
  [ -n "$DOWNLOAD_URL" ] || die "no Linux $ARCH build found for version $VERSION.
       Check the version number against https://zcode.z.ai/en#all-downloads"
  ok "found $VERSION"
else
  step "Finding the latest version"
  PAGE="$(fetch_page || true)"
  CANDIDATES=""
  if [ -n "$PAGE" ]; then
    # 1) exact current layout        2) filename anywhere
    # 3) any versioned release dir   4) any semver on the page
    CANDIDATES="$(
      {
        printf '%s' "$PAGE" | grep -oE "releases/[0-9]+\.[0-9]+\.[0-9]+/linux-$ARCH/" \
          | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'
        printf '%s' "$PAGE" | grep -oE "ZCode-[0-9]+\.[0-9]+\.[0-9]+-linux-$ARCH" \
          | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'
        printf '%s' "$PAGE" | grep -oE 'releases/[0-9]+\.[0-9]+\.[0-9]+/' \
          | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'
        printf '%s' "$PAGE" | grep -oE '\b[0-9]+\.[0-9]+\.[0-9]+\b'
      } 2>/dev/null | sort -Vru | head -12
    )"
  else
    warn "could not reach the download page"
  fi

  # Try discovered candidates newest-first, then the pinned version.
  for v in $CANDIDATES "$PINNED_VERSION"; do
    [ -n "$v" ] || continue
    DOWNLOAD_URL="$(resolve_download_url "$v" || true)"
    if [ -n "$DOWNLOAD_URL" ]; then
      VERSION="$v"
      break
    fi
  done

  [ -n "$DOWNLOAD_URL" ] || die "could not find any downloadable ZCode build.
       Z.ai may have changed their download layout, or the network is blocking
       the CDN. Work around it with an explicit version:
         ./install.sh --version <x.y.z>
       and please open an issue so the installer can be fixed."

  if [ "$VERSION" = "$PINNED_VERSION" ] && [ -z "$CANDIDATES" ]; then
    warn "falling back to the pinned version $VERSION (page unreadable)"
  else
    ok "latest is $VERSION"
  fi
fi

APPIMAGE="ZCode-${VERSION}-linux-${ARCH}.AppImage"

# ------------------------------------------------------------------- plan -----
INSTALLED_VERSION=""
[ -f "$STAMP" ] && INSTALLED_VERSION="$(cat "$STAMP" 2>/dev/null || true)"

if [ "$PLAN_ONLY" -eq 1 ]; then
  cat <<EOF

${c_bold}Plan${c_reset}  (nothing has been changed)

  Download        $DOWNLOAD_URL
  Extract to      $APP_DIR
  Currently       ${INSTALLED_VERSION:-nothing installed here}

  In WSL
    $APP_DIR/
    ~/.local/share/applications/zcode.desktop
    ~/.local/share/icons/zcode.png
$( [ "$SKIP_BROWSER" -eq 1 ] && echo "    (browser step skipped)" \
   || echo "    wslu package, and wslview as the default browser (if not already working)" )

  On Windows (current user, no admin)
$( [ "$SKIP_PROTOCOL" -eq 1 ] && echo "    (zcode:// handler skipped)" \
   || echo "    ${WIN_HELPER_WIN:-<unavailable>}\\  router.ps1 + a backup of any existing handler
    HKCU\\Software\\Classes\\zcode  ->  router.ps1" )
$( [ "$SKIP_SHORTCUT" -eq 1 ] && echo "    (Start Menu shortcut skipped)" \
   || echo "    ${WIN_HELPER_WIN:-<unavailable>}\\launch.vbs
    Start Menu entry \"ZCode (WSL)\"" )

  Never touched   ~/.zcode/ (your settings, sessions and credentials)
                  any existing ZCode for Windows installation

EOF
  exit 0
fi

if [ -n "$INSTALLED_VERSION" ] && [ "$INSTALLED_VERSION" = "$VERSION" ] && [ "$FORCE" -eq 0 ]; then
  ok "ZCode $VERSION is already installed in $APP_DIR"
  info "pass --force to reinstall it anyway"
  info "the Windows-side integration is refreshed below"
  SKIP_DOWNLOAD=1
else
  SKIP_DOWNLOAD=0
fi

# Replacing the tree under a running instance pulls files out from beneath it,
# which leaves the app in a half-broken state. /proc/<pid>/exe is unreliable
# here (it reads "(deleted)" after an earlier swap), so match on argv[0].
running_pids() {
  local p arg0
  for p in /proc/[0-9]*; do
    [ -r "$p/cmdline" ] || continue
    IFS= read -r -d '' arg0 < "$p/cmdline" 2>/dev/null || continue
    [ "$arg0" = "$APP_BIN" ] && printf '%s ' "${p#/proc/}"
  done
  return 0      # a failed match on the last iteration must not fail the function
}

if [ "$SKIP_DOWNLOAD" -eq 0 ]; then
  RUNNING="$(running_pids || true)"
  if [ -n "$RUNNING" ]; then
    die "ZCode is running right now (pids: ${RUNNING% }).
       Installing over it would pull files out from under the running app.
       Quit ZCode, then run this again. To stop it from here:
         pkill -f '$APP_BIN'"
  fi
fi

# ------------------------------------------------------------ 1. the app ------
stage "ZCode $VERSION"

if [ "$SKIP_DOWNLOAD" -eq 1 ]; then
  info "keeping the existing install"
else
  mkdir -p "$INSTALL_DIR" || die "cannot create $INSTALL_DIR"
  [ -w "$INSTALL_DIR" ] || die "$INSTALL_DIR is not writable"

  free_mb="$(df -Pm "$INSTALL_DIR" | awk 'NR==2 {print $4}')"
  if [ -n "$free_mb" ] && [ "$free_mb" -lt "$NEED_FREE_MB" ]; then
    die "only ${free_mb} MB free in $INSTALL_DIR, need about ${NEED_FREE_MB} MB
       (a ~200 MB download that extracts to ~600 MB)"
  fi

  cd "$INSTALL_DIR"

  if [ -s "$APPIMAGE" ]; then
    info "reusing the download already here: $APPIMAGE"
  else
    info "$DOWNLOAD_URL"
    TMP_FILES+=("$INSTALL_DIR/$APPIMAGE.part")
    curl -fL --progress-bar --retry 3 --retry-delay 2 --retry-connrefused \
         -C - -o "$APPIMAGE.part" "$DOWNLOAD_URL" \
      || die "download failed. Retry — curl resumes where it stopped."
    mv -f "$APPIMAGE.part" "$APPIMAGE"
    TMP_FILES=()
  fi

  # Validate before trusting the file as an executable.
  size="$(stat -c%s "$APPIMAGE")"
  [ "$size" -ge "$MIN_APPIMAGE_BYTES" ] \
    || die "$APPIMAGE is only $size bytes, far too small for a real build.
       It is probably an error page. Delete it and retry:
         rm -f '$INSTALL_DIR/$APPIMAGE'"
  head -c 4 "$APPIMAGE" | grep -qa $'\x7fELF' \
    || die "$APPIMAGE is not a Linux executable — the download is not what we expected.
       Delete it and retry:  rm -f '$INSTALL_DIR/$APPIMAGE'"

  if [ -n "$EXPECT_SHA256" ]; then
    info "verifying checksum"
    actual="$(sha256sum "$APPIMAGE" | awk '{print $1}')"
    [ "$actual" = "$EXPECT_SHA256" ] \
      || die "checksum mismatch — refusing to install.
       expected $EXPECT_SHA256
       actual   $actual"
    ok "checksum matches"
  else
    info "sha256: $(sha256sum "$APPIMAGE" | awk '{print $1}')"
    info "${c_dim}(record it, and pass --sha256 on other machines to pin it)${c_reset}"
  fi

  chmod +x "$APPIMAGE"

  # Ubuntu 24.04 ships fuse3 only, and AppImages self-mount via libfuse2.
  # Extracting avoids that dependency entirely, and needs no root.
  info "extracting"
  EXTRACT_TMP="$(mktemp -d "$INSTALL_DIR/.extract.XXXXXX")"
  TMP_DIRS+=("$EXTRACT_TMP")
  ( cd "$EXTRACT_TMP" && "$INSTALL_DIR/$APPIMAGE" --appimage-extract >/dev/null 2>&1 ) \
    || die "extraction failed. The download may be truncated; delete and retry:
         rm -f '$INSTALL_DIR/$APPIMAGE'"

  NEW_TREE="$EXTRACT_TMP/squashfs-root"
  [ -x "$NEW_TREE/zcode" ] \
    || die "the extracted tree has no zcode binary — upstream layout changed.
       Please open an issue at the zcode-wsl repository."

  # Only now replace the previous install, and refuse if the target is not ours.
  if [ -e "$APP_DIR" ]; then
    if [ ! -e "$APP_DIR/zcode" ] && [ ! -f "$STAMP" ]; then
      die "$APP_DIR exists but does not look like a ZCode install.
       Refusing to delete it. Move it aside, or use --dir <other path>."
    fi
    rm -rf "$APP_DIR.old"
    mv "$APP_DIR" "$APP_DIR.old"
  fi
  mv "$NEW_TREE" "$APP_DIR"
  rm -rf "$APP_DIR.old" "$EXTRACT_TMP"
  TMP_DIRS=()

  printf '%s\n' "$VERSION" > "$STAMP"

  if [ "$KEEP_APPIMAGE" -eq 0 ]; then
    rm -f "$APPIMAGE"
    info "removed the .AppImage (--keep-appimage keeps it)"
  fi
  ok "installed to $APP_DIR"
fi

[ -x "$APP_BIN" ] || die "$APP_BIN is missing or not executable"

# --------------------------------------------------------------- 2. browser ---
# The most common failure by far: WSL has no browser, xdg-open fails silently,
# the sign-in page never opens, and the app sits on
# "Waiting for Z.ai authentication..." forever.
stage "Browser handoff to Windows"
if [ "$SKIP_BROWSER" -eq 1 ]; then
  warn "skipped on request — OAuth sign-in will not be able to complete"
elif xdg-open --version >/dev/null 2>&1 && xdg-settings get default-web-browser 2>/dev/null | grep -q .; then
  # Something is already configured; leave the user's choice alone if it works.
  current="$(xdg-settings get default-web-browser 2>/dev/null || true)"
  ok "default browser already set: $current"
  info "${c_dim}not overriding it${c_reset}"
else
  if command -v wslview >/dev/null 2>&1; then
    ok "wslu already installed"
  else
    info "installing wslu — it lets WSL open your Windows browser"
    info "${c_dim}sudo may ask for your password${c_reset}"
    if   command -v apt-get >/dev/null; then sudo apt-get update -qq && sudo apt-get install -y wslu
    elif command -v dnf     >/dev/null; then sudo dnf install -y wslu
    elif command -v zypper  >/dev/null; then sudo zypper --non-interactive install wslu
    elif command -v pacman  >/dev/null; then sudo pacman -S --noconfirm wslu
    else
      warn "no supported package manager found"
      info "install wslu manually, then re-run this script"
    fi
  fi

  if command -v wslview >/dev/null 2>&1; then
    xdg-settings set default-web-browser wslview.desktop 2>/dev/null || true
    xdg-mime default wslview.desktop x-scheme-handler/http x-scheme-handler/https 2>/dev/null || true
    ok "wslview is now the default browser"
  else
    warn "wslview still unavailable — sign-in will not work until it is"
  fi
fi

# --------------------------------------------------------- 3. desktop entry ---
stage "Linux desktop entry"
FLAGS_SP=""
[ -n "$ZCODE_FLAGS" ] && FLAGS_SP=" $ZCODE_FLAGS"

mkdir -p "$HOME/.local/share/applications" "$HOME/.local/share/icons"
[ -f "$APP_DIR/zcode.png" ] && cp -f "$APP_DIR/zcode.png" "$HOME/.local/share/icons/zcode.png"
cat > "$HOME/.local/share/applications/zcode.desktop" <<EOF
[Desktop Entry]
Name=ZCode
Comment=ZCode Desktop App
Exec="$APP_BIN"$FLAGS_SP %U
Terminal=false
Type=Application
Icon=zcode
Categories=Development;
MimeType=x-scheme-handler/zcode;
StartupWMClass=ZCode
EOF
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
ok "zcode.desktop written"

# ------------------------------------------------------------- 4. zcode:// ----
# After you authorise in the browser, Z.ai redirects to zcode://oauth/callback.
# Only WSL knows that scheme, so Windows drops it. A small forwarder on the
# Windows side closes the loop — and, if ZCode for Windows is also installed,
# keeps that copy working too.
stage "zcode:// handler on Windows"
if [ "$SKIP_PROTOCOL" -eq 1 ]; then
  warn "skipped on request"
  info "sign-in still works (the app also polls Z.ai), but in-app zcode:// links will not"
elif [ -z "${WIN_HELPER_DIR:-}" ]; then
  warn "Windows interop unavailable — skipped"
else
  mkdir -p "$WIN_HELPER_DIR"

  # Preserve whatever is registered now, so uninstall can put it back.
  PREV_REG="$WIN_HELPER_DIR/previous-handler.reg"
  if [ ! -f "$PREV_REG" ]; then
    if reg.exe export 'HKCU\Software\Classes\zcode' "$(wslpath -w "$PREV_REG")" /y >/dev/null 2>&1; then
      # reg.exe writes UTF-16, so strip NULs before matching or grep sees nothing.
      if tr -d '\000' < "$PREV_REG" | grep -qa 'zcode-wsl'; then
        rm -f "$PREV_REG"           # our own earlier install; nothing to preserve
      else
        ok "backed up the existing zcode:// handler"
        info "${c_dim}$(wslpath -w "$PREV_REG")${c_reset}"
      fi
    else
      rm -f "$PREV_REG"             # nothing was registered
    fi
  fi

  # Find a ZCode for Windows install, so callbacks can still reach it.
  WIN_ZCODE_EXE=""
  for p in /mnt/*/Users/*/AppData/Local/Programs/ZCode/ZCode.exe \
           /mnt/*/Program\ Files/ZCode/ZCode.exe; do
    [ -f "$p" ] && { WIN_ZCODE_EXE="$(wslpath -w "$p")"; break; }
  done

  Q_DISTRO="$(ps1_squote "$DISTRO")"
  Q_BIN="$(ps1_squote "$APP_BIN")"
  Q_PATTERN="$(ps1_squote "$APP_DIR/zcode")"

  {
    printf '# Routes zcode:// links to whichever copy of ZCode is running.\n'
    printf '# Generated by zcode-wsl (https://github.com/wowayou/zcode-wsl).\n'
    printf '# Safe to read: it launches ZCode with the URL and nothing else.\n'
    printf 'param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)\n'
    printf '$Url = if ($Rest) { $Rest[0] } else { $null }\n\n'
    printf '$wslRunning = $false\n'
    printf 'try {\n'
    printf '  $n = & wsl.exe -d %s -- pgrep -c -f %s 2>$null\n' "$Q_DISTRO" "$Q_PATTERN"
    printf '  if ($LASTEXITCODE -eq 0 -and [int]$n -gt 0) { $wslRunning = $true }\n'
    printf '} catch {}\n\n'
    if [ -n "$WIN_ZCODE_EXE" ]; then
      printf '# ZCode for Windows was present at install time. It keeps handling\n'
      printf '# callbacks whenever the WSL copy is not the one running.\n'
      printf '$winExe = %s\n\n' "$(ps1_squote "$WIN_ZCODE_EXE")"
      printf 'if (-not $wslRunning -and (Test-Path -LiteralPath $winExe)) {\n'
      printf '  & $winExe $Url\n'
      printf '} else {\n'
      printf '  & wsl.exe -d %s -- %s%s $Url\n' "$Q_DISTRO" "$Q_BIN" "$FLAGS_SP"
      printf '}\n'
    else
      printf '& wsl.exe -d %s -- %s%s $Url\n' "$Q_DISTRO" "$Q_BIN" "$FLAGS_SP"
    fi
  } > "$WIN_HELPER_DIR/router.ps1"

  ROUTER_ESC="${WIN_HELPER_WIN//\\/\\\\}\\\\router.ps1"
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
    ok "zcode:// -> $WIN_HELPER_WIN\\router.ps1"
    [ -n "$WIN_ZCODE_EXE" ] && info "ZCode for Windows detected — it still gets callbacks when the WSL copy is closed"
  else
    warn "could not write the registry entry"
    info "sign-in should still work (the app polls Z.ai as well)"
    info "to retry by hand:  reg.exe import '$(wslpath -w "$REG_FILE")'"
  fi
fi

# ------------------------------------------------------------- 5. shortcut ----
# WSLg is meant to mirror .desktop files into the Start Menu, but it regularly
# skips apps. Creating the shortcut directly always works.
stage "Windows Start Menu shortcut"
if [ "$SKIP_SHORTCUT" -eq 1 ]; then
  warn "skipped on request"
  info "launch with:  $APP_BIN"
elif [ -z "${WIN_HELPER_DIR:-}" ]; then
  warn "Windows interop unavailable — skipped"
else
  mkdir -p "$WIN_HELPER_DIR"

  # Launching wsl.exe directly flashes a console window; wscript + VBS does not.
  {
    printf "' Launches ZCode inside WSL without flashing a console window.\r\n"
    printf "' Generated by zcode-wsl (https://github.com/wowayou/zcode-wsl).\r\n"
    printf 'Set sh = CreateObject("WScript.Shell")\r\n'
    printf 'sh.Run "wsl.exe -d %s -- %s%s", 0, False\r\n' \
      "$(vbs_dquote "$DISTRO")" "$(vbs_dquote "$APP_BIN")" "$FLAGS_SP"
  } > "$WIN_HELPER_DIR/launch.vbs"

  ICON_WIN=""
  if [ -f "$APP_DIR/zcode.png" ] && command -v convert >/dev/null 2>&1; then
    convert "$APP_DIR/zcode.png" -define icon:auto-resize=256,64,48,32,16 \
      "$WIN_HELPER_DIR/zcode.ico" 2>/dev/null && ICON_WIN="$WIN_HELPER_WIN\\zcode.ico"
  fi
  if [ -z "$ICON_WIN" ] && [ -n "${WIN_ZCODE_EXE:-}" ]; then
    ICON_WIN="$WIN_ZCODE_EXE,0"
  fi

  # Build the shortcut from a file, keeping Windows quoting out of the picture.
  MK="$WIN_HELPER_DIR/mkshortcut.ps1"
  {
    printf '$w = New-Object -ComObject WScript.Shell\n'
    printf "\$p = Join-Path \$w.SpecialFolders('Programs') 'ZCode (WSL).lnk'\n"
    printf '$s = $w.CreateShortcut($p)\n'
    printf '$s.TargetPath = Join-Path $env:WINDIR "system32\\wscript.exe"\n'
    printf '$s.Arguments = %s\n' "$(ps1_squote "\"$WIN_HELPER_WIN\\launch.vbs\"")"
    [ -n "$ICON_WIN" ] && printf '$s.IconLocation = %s\n' "$(ps1_squote "$ICON_WIN")"
    printf '$s.Description = %s\n' "$(ps1_squote "ZCode running inside WSL ($DISTRO)")"
    printf '$s.Save()\n'
    printf 'Write-Output $p\n'
  } > "$MK"

  SHORTCUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$MK")" 2>/dev/null | tr -d '\r' | tail -1 || true)"
  if [ -n "$SHORTCUT" ]; then
    ok "Start Menu: ZCode (WSL)"
  else
    warn "could not create the shortcut"
    info "launch with:  $APP_BIN"
    info "or run:  $WIN_HELPER_WIN\\launch.vbs"
  fi
fi

# ------------------------------------------------------------------ summary ---
cat <<EOF

${c_green}${c_bold}Done.${c_reset}  ZCode $VERSION is installed.

  ${c_bold}Launch${c_reset}       Start Menu -> "ZCode (WSL)"
  ${c_bold}Or${c_reset}           $APP_BIN
  ${c_bold}Your data${c_reset}    ~/.zcode/     settings, sessions, credentials
  ${c_bold}Upgrade${c_reset}      re-run ./install.sh
  ${c_bold}Remove${c_reset}       ./uninstall.sh

${c_bold}Signing in${c_reset}
  Click sign-in; your Windows browser opens the Z.ai page. Authorise there and
  the app completes on its own — nothing to paste back.

${c_bold}Known WSLg quirk${c_reset}
  ZCode draws its own title bar, and its minimise button does nothing under
  WSLg. Use Win+Down, or click the taskbar icon. Maximise and close are fine.
EOF
