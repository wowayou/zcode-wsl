#!/usr/bin/env bash
#
# Removes what install.sh added. Your ZCode data in ~/.zcode is left alone
# unless you pass --purge.
#
set -euo pipefail

INSTALL_DIR="$HOME/apps/zcode"
PURGE=0
YES=0

c_reset=$'\033[0m'; c_bold=$'\033[1m'
c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_blue=$'\033[34m'
step() { printf '%s==>%s %s%s\n' "$c_blue$c_bold" "$c_reset" "$c_bold" "$1$c_reset"; }
ok()   { printf '    %s✓%s %s\n' "$c_green" "$c_reset" "$1"; }
warn() { printf '    %s!%s %s\n' "$c_yellow" "$c_reset" "$1"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)   INSTALL_DIR="${2:-}"; shift 2 ;;
    --purge) PURGE=1; shift ;;
    -y|--yes) YES=1; shift ;;
    -h|--help)
      cat <<'USAGE'
Usage: ./uninstall.sh [options]

  --dir <path>   Install location to remove (default: ~/apps/zcode)
  --purge        Also delete ~/.zcode (settings, sessions, saved login)
  -y, --yes      Do not ask for confirmation
  -h, --help     Show this help

Leaves ZCode for Windows and the wslu package untouched.
USAGE
      exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 1 ;;
  esac
done

printf 'This will remove:\n'
printf '  - %s\n' "$INSTALL_DIR"
printf '  - ~/.local/share/applications/zcode.desktop\n'
printf '  - the Start Menu entry "ZCode (WSL)"\n'
printf '  - the zcode:// handler and helpers under %%LOCALAPPDATA%%\\zcode-wsl\n'
if [ "$PURGE" -eq 1 ]; then
  printf '  - %s~/.zcode (settings, sessions, saved login)%s\n' "$c_bold" "$c_reset"
else
  printf '\nKeeping ~/.zcode. Pass --purge to delete it too.\n'
fi

if [ "$YES" -eq 0 ]; then
  printf '\nContinue? [y/N] '
  read -r reply
  case "$reply" in [yY]*) ;; *) printf 'Cancelled.\n'; exit 0 ;; esac
fi

win_env() { (cd /mnt/c && cmd.exe /c "echo %$1%" 2>/dev/null | tr -d '\r\n'); }

step "Removing the app"
rm -rf "$INSTALL_DIR" && ok "$INSTALL_DIR"

step "Removing the desktop entry"
rm -f "$HOME/.local/share/applications/zcode.desktop" "$HOME/.local/share/icons/zcode.png"
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
ok "zcode.desktop"

step "Removing Windows integration"
if WIN_LOCALAPPDATA="$(win_env LOCALAPPDATA)" && [ -n "$WIN_LOCALAPPDATA" ]; then
  helper="$(wslpath -u "$WIN_LOCALAPPDATA\\zcode-wsl" 2>/dev/null || true)"

  # Only touch the registration if it still points at our router: if something
  # else claimed zcode:// in the meantime, that is not ours to remove.
  cur="$(reg.exe query 'HKCU\Software\Classes\zcode\shell\open\command' /ve 2>/dev/null | tr -d '\r' || true)"
  if printf '%s' "$cur" | grep -q 'zcode-wsl'; then
    if reg.exe delete 'HKCU\Software\Classes\zcode' /f >/dev/null 2>&1; then
      ok "zcode:// handler unregistered"
    else
      warn "could not unregister zcode://"
    fi

    # If install.sh found a handler already registered (typically ZCode for
    # Windows), it saved it. Put it back so that copy keeps working.
    prev="${helper:+$helper/previous-handler.reg}"
    # reg.exe writes UTF-16, so strip NULs before matching. Never restore a
    # backup that points back at our own router: that would leave a dead
    # handler aimed at files this script is about to delete.
    if [ -n "$prev" ] && [ -f "$prev" ] \
       && ! tr -d '\000' < "$prev" | grep -q 'zcode-wsl'; then
      if reg.exe import "$(wslpath -w "$prev")" >/dev/null 2>&1; then
        ok "restored the zcode:// handler that was there before"
      else
        warn "could not restore the previous handler; it is kept at:"
        printf '      %s\\zcode-wsl\\previous-handler.reg\n' "$WIN_LOCALAPPDATA"
        KEEP_HELPER=1
      fi
    fi
  elif [ -n "$cur" ]; then
    warn "zcode:// points somewhere else now — left untouched"
  fi

  if [ -n "$helper" ] && [ -d "$helper" ] && [ "${KEEP_HELPER:-0}" -eq 0 ]; then
    rm -rf "$helper" && ok "helper files"
  fi

  if progs="$(powershell.exe -NoProfile -Command '(New-Object -ComObject WScript.Shell).SpecialFolders("Programs")' 2>/dev/null | tr -d '\r')" \
     && [ -n "$progs" ]; then
    lnk="$(wslpath -u "$progs" 2>/dev/null)/ZCode (WSL).lnk"
    [ -f "$lnk" ] && rm -f "$lnk" && ok "Start Menu entry"
  fi
else
  warn "Windows interop unavailable — skipped the Windows-side cleanup"
fi

if [ "$PURGE" -eq 1 ]; then
  step "Removing your ZCode data"
  rm -rf "$HOME/.zcode" && ok "~/.zcode"
fi

printf '\n%sDone.%s\n' "$c_green$c_bold" "$c_reset"
if [ "$PURGE" -eq 0 ]; then
  printf 'Your data is still in ~/.zcode.\n'
fi
printf 'wslu was left installed; remove it with:  sudo apt remove wslu\n'
