#!/bin/bash
# hypercaffeinated: your Mac gets no sleep. Not with the lid closed, not on battery.
#
#   Install:   sudo bash install.sh [--min-batt 20] [--max-hours 12]
#   Uninstall: sudo bash install.sh --uninstall
#
# How it works:
#   ~/NoSleep/state   you, a Shortcut or your coding agent write "on" or "off" here (no admin needed)
#   ~/NoSleep/status  the daemon writes the current state here
#   ~/NoSleep/nosleep small helper: nosleep on|off|toggle|status
#   A root LaunchDaemon reads the flag (on change + every 60 s) and runs pmset.
#   It only compares the flag to "on"/"off" and never runs anything from it.
# Safety: automatic OFF when on battery at <= MIN_BATT %, after MAX_HOURS, or when
# macOS reports a serious or critical thermal state.
# Written for the macOS system bash (3.2): no bash 4+ features, please.
set -euo pipefail

LABEL=local.hypercaffeinated
PLIST=/Library/LaunchDaemons/$LABEL.plist
BIN=/usr/local/sbin/hypercaffeinatedd
DB=/var/db/hypercaffeinated

usage() {
  cat <<'USAGE'
Usage: sudo bash install.sh [--min-batt N] [--max-hours N]
       sudo bash install.sh --uninstall

  --min-batt N   auto OFF on battery at or below N % (0-100, default 20)
  --max-hours N  auto OFF after N hours on (1-168, default 12)
USAGE
}

MODE=install; MIN_BATT=20; MAX_HOURS=12
while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) MODE=uninstall ;;
    --min-batt|--max-hours)
      [ $# -ge 2 ] || { echo "$1 needs a number"; usage; exit 1; }
      if [ "$1" = --min-batt ]; then MIN_BATT="$2"; else MAX_HOURS="$2"; fi
      shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           echo "Unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done
is_int() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
is_int "$MIN_BATT"  && [ "$MIN_BATT" -le 100 ]                       || { echo "--min-batt must be 0-100"; exit 1; }
is_int "$MAX_HOURS" && [ "$MAX_HOURS" -ge 1 ] && [ "$MAX_HOURS" -le 168 ] || { echo "--max-hours must be 1-168"; exit 1; }

[ "$(uname -s)" = Darwin ] || { echo "macOS only."; exit 1; }
[ "$(id -u)" = 0 ] || { echo "Run with: sudo bash $0"; exit 1; }
U="${SUDO_USER:-}"
[ -n "$U" ] && [ "$U" != root ] || { echo "Run via sudo from your normal account."; exit 1; }
H=$(dscl . -read "/Users/$U" NFSHomeDirectory | awk '{print $2}')

restore_backup() {  # put back the low-power setting we changed when switching on
  [ -f "$DB/backup" ] || return 0
  read -r k b a < "$DB/backup" || true
  if [ "${k:-none}" != none ]; then
    [ -n "${b:-}" ] && pmset -b "$k" "$b"
    [ -n "${a:-}" ] && pmset -c "$k" "$a"
  fi
  return 0
}

if [ "$MODE" = uninstall ]; then
  launchctl bootout system "$PLIST" 2>/dev/null || true
  pmset -a disablesleep 0
  restore_backup
  rm -f "$PLIST" "$BIN"; rm -rf "$DB"
  sudo -u "$U" sh -c "echo off > '$H/NoSleep/state'" 2>/dev/null || true
  echo "hypercaffeinated removed. Your Mac may sleep again. ~/NoSleep left in place."
  exit 0
fi

# The daemon runs as root, so its folder must not be writable by normal users.
mkdir -p /usr/local/sbin
for d in /usr/local /usr/local/sbin; do
  o=$(stat -f %Su "$d"); m=$(stat -f %Lp "$d")
  if [ "$o" != root ] || (( (8#$m & 022) != 0 )); then
    echo "Abort: $d is owned by $o (mode $m); it must be root-owned and not writable by group or others."
    exit 1
  fi
done

cat > "$BIN" <<'DAEMON'
#!/bin/bash
# hypercaffeinatedd: applies ~/NoSleep/state as root. Started by launchd.
# Files in ~/NoSleep are only ever read and written as the user, never as root.
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin

U="${1:?user}"
as_user() { /usr/bin/sudo -n -u "$U" -- "$@"; }
MIN_BATT="${2:-20}"; MAX_HOURS="${3:-12}"
case "$MIN_BATT"  in ''|*[!0-9]*) MIN_BATT=20 ;; esac
case "$MAX_HOURS" in ''|*[!0-9]*) MAX_HOURS=12 ;; esac

H=$(dscl . -read "/Users/$U" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
DIR="$H/NoSleep"; STATE="$DIR/state"; STATUS="$DIR/status"
DB=/var/db/hypercaffeinated
mkdir -p "$DB"; chmod 700 "$DB"

# Only act on a real folder owned by the user (not a symlink).
[ -d "$DIR" ] && [ ! -L "$DIR" ] && [ "$(stat -f %Su "$DIR")" = "$U" ] || exit 0

safe_write() {  # as the user: write a new file and mv it into place (root never touches it)
  printf '%s\n' "$2" | as_user /bin/sh -c \
    't=$(mktemp "$1/.tmp.XXXXXX") || exit 0; cat > "$t" && chmod 644 "$t" && mv -f "$t" "$2" || { rm -f "$t"; exit 1; }' \
    sh "$DIR" "$1" || true
}

want=off
if [ -f "$STATE" ] && [ ! -L "$STATE" ]; then
  v=$(as_user /usr/bin/head -c 16 "$STATE" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
  [ "$v" = on ] && want=on
fi

# Older Macs/macOS use "lowpowermode", newer ones "powermode".
CUSTOM=$(pmset -g custom)
KEY=none
if echo "$CUSTOM" | grep -qw lowpowermode; then KEY=lowpowermode
elif echo "$CUSTOM" | grep -qw powermode; then KEY=powermode; fi
val() { echo "$CUSTOM" | awk -v s="$1" -v k="$KEY" '/^[^ \t]/{f=($0 ~ "^"s)} f && $1==k {print $2; exit}'; }

# ProcessInfo.thermalState: 0 nominal, 1 fair, 2 serious, 3 critical.
# Read through the built-in JavaScript bridge, so nothing needs compiling.
case "$(osascript -l JavaScript -e 'ObjC.import("Foundation"); $.NSProcessInfo.processInfo.thermalState' 2>/dev/null)" in
  0) thermal=nominal ;;
  1) thermal=fair ;;
  2) thermal=serious ;;
  3) thermal=critical ;;
  *) thermal=unknown ;;
esac

# Safety guards
reason=""; hot=no
if [ "$want" = on ]; then
  B=$(pmset -g batt)
  pct=$(echo "$B" | grep -Eo '[0-9]+%' | head -1 | tr -d %)
  if echo "$B" | grep -q "'Battery Power'" && [ -n "$pct" ] && [ "$pct" -le "$MIN_BATT" ]; then
    reason="battery at ${pct}%"
  fi
  if [ -f "$DB/since" ]; then
    s=$(cat "$DB/since")
    [ $(( $(date +%s) - s )) -ge $(( MAX_HOURS * 3600 )) ] && reason="${MAX_HOURS}h limit reached"
  fi
  case "$thermal" in   # checked last: heat wins over the other reasons
    serious|critical) reason="thermal state $thermal"; hot=yes ;;
  esac
  if [ -n "$reason" ]; then
    want=off; safe_write "$STATE" off; echo "$reason" > "$DB/lastreason"
  fi
fi

cur=$(pmset -g | awk '/SleepDisabled/{print $2}'); cur=${cur:-0}

if [ "$want" = on ]; then
  rm -f "$DB/lastreason"
  if [ ! -f "$DB/backup" ]; then        # transition OFF -> ON
    echo "$KEY $(val Battery) $(val AC)" > "$DB/backup"
    date +%s > "$DB/since"
    [ "$KEY" != none ] && pmset -a "$KEY" 1   # run cooler while it can't sleep
  fi
  [ "$cur" = 1 ] || pmset -a disablesleep 1
else
  [ "$cur" = 0 ] || pmset -a disablesleep 0
  if [ -f "$DB/backup" ]; then          # transition ON -> OFF: restore old values
    read -r k b a < "$DB/backup" || true
    if [ "${k:-none}" != none ]; then
      [ -n "${b:-}" ] && pmset -b "$k" "$b"
      [ -n "${a:-}" ] && pmset -c "$k" "$a"
    fi
    rm -f "$DB/backup" "$DB/since"
  fi
fi

now=$(pmset -g | awk '/SleepDisabled/{print $2}')
if [ "$now" = 1 ]; then
  msg="☕ No-Sleep ON since $(date -r "$(cat "$DB/since" 2>/dev/null || date +%s)" '+%d.%m. %H:%M')"
else
  msg="😴 No-Sleep OFF, normal sleep"
  [ -f "$DB/lastreason" ] && msg="$msg (auto-off: $(cat "$DB/lastreason"))"
fi
safe_write "$STATUS" "$msg · thermal: $thermal · checked $(date '+%H:%M:%S')"

# Too hot with the lid closed: don't wait for the idle timer, sleep now.
if [ "$hot" = yes ] && [ "$now" != 1 ] &&
   ioreg -r -k AppleClamshellState -d 4 | grep -q '"AppleClamshellState" = Yes'; then
  pmset sleepnow
fi
DAEMON
chown root:wheel "$BIN"; chmod 755 "$BIN"

# User folder + helper (owned by the user, no admin rights needed to toggle)
sudo -u "$U" mkdir -p "$H/NoSleep"
[ -f "$H/NoSleep/state" ] || sudo -u "$U" sh -c "echo off > '$H/NoSleep/state'"
sudo -u "$U" tee "$H/NoSleep/nosleep" > /dev/null <<'HELPER'
#!/bin/bash
# nosleep on|off|toggle|status  (part of hypercaffeinated)
D="$HOME/NoSleep"
cmd="${1:-status}"
case "$cmd" in
  on|off) echo "$cmd" > "$D/state" ;;
  toggle) if grep -qx on "$D/state" 2>/dev/null; then echo off > "$D/state"; else echo on > "$D/state"; fi ;;
  status) ;;
  *) echo "usage: nosleep on|off|toggle|status"; exit 1 ;;
esac
if [ "$cmd" != status ]; then
  before=$(stat -f %m "$D/status" 2>/dev/null || echo 0)
  for _ in $(seq 1 15); do
    sleep 1
    [ "$(stat -f %m "$D/status" 2>/dev/null || echo 0)" != "$before" ] && break
  done
fi
cat "$D/status" 2>/dev/null || echo "No status yet (is the daemon installed?)"
HELPER
sudo -u "$U" chmod 755 "$H/NoSleep/nosleep"

cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$BIN</string><string>$U</string><string>$MIN_BATT</string><string>$MAX_HOURS</string>
  </array>
  <key>WatchPaths</key><array><string>$H/NoSleep/state</string></array>
  <key>StartInterval</key><integer>60</integer>
  <key>RunAtLoad</key><true/>
</dict></plist>
PL
chown root:wheel "$PLIST"; chmod 644 "$PLIST"

launchctl bootout system "$PLIST" 2>/dev/null || true
launchctl bootstrap system "$PLIST"
sleep 2
echo "☕☕☕ hypercaffeinated installed (auto-off at ${MIN_BATT}% battery, after ${MAX_HOURS}h or when running hot)."
echo "Low-power key on this Mac: $(pmset -g custom | grep -ow 'lowpowermode\|powermode' | head -1 || echo none)"
sudo -u "$U" cat "$H/NoSleep/status" 2>/dev/null || true
echo "Toggle with: ~/NoSleep/nosleep on | off | toggle | status"
