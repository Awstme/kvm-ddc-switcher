#!/bin/zsh
set -u

DIR="${0:A:h}"
CONFIG="$DIR/config.env"
[[ -f "$CONFIG" ]] && source "$CONFIG"

KVM_HUB_NAME="${KVM_HUB_NAME:-USB 2.0 Hub [Safe]}"
MONITOR_NAME="${MONITOR_NAME:-Mi Monitor}"
POLL_INTERVAL="${POLL_INTERVAL:-0.5}"
STABLE_SAMPLES="${STABLE_SAMPLES:-2}"
DRY_RUN="${DRY_RUN:-0}"
# KVM_DRY_RUN=1 ./kvm-watch.sh 可临时只记录不切换
DRY_RUN="${KVM_DRY_RUN:-$DRY_RUN}"
M1DDC="${M1DDC:-$DIR/m1ddc-src/m1ddc}"
WINDOWS_INPUT="${WINDOWS_INPUT:-16}"
DISPLAY_SELECTOR="${DISPLAY_SELECTOR:-}"
LOG="${LOG:-$DIR/logs/kvm-auto-switch.log}"

mkdir -p "$(dirname "$LOG")"

log() {
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') $*"
  print -r -- "$line" >> "$LOG"
  print -r -- "$line"
}

resolve_selector() {
  local uuid
  uuid="$("$M1DDC" display list 2>/dev/null | /usr/bin/awk -F'[()]' -v name="$MONITOR_NAME" 'index($0, name) { print $2; exit }')"
  if [[ -n "$uuid" ]]; then
    DISPLAY_SELECTOR="$uuid"
  fi
}

kvm_present() {
  ioreg -p IOUSB -w0 -d 3 -n "$KVM_HUB_NAME" 2>/dev/null | /usr/bin/grep -qF "$KVM_HUB_NAME"
}

switch_to_windows() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN: would switch display to Windows input $WINDOWS_INPUT"
    return
  fi

  resolve_selector
  if [[ -z "$DISPLAY_SELECTOR" ]]; then
    log "SKIP: Mi Monitor not found; no DDC switch attempted"
    return
  fi

  local out rc
  out="$("$M1DDC" display "$DISPLAY_SELECTOR" set input "$WINDOWS_INPUT" 2>&1)"
  rc=$?
  log "DDC set input $WINDOWS_INPUT rc=$rc ${out//$'\n'/ }"
}

last_state=""
pending_state=""
pending_count=0

while true; do
  if kvm_present; then
    current_state="present"
  else
    current_state="absent"
  fi

  if [[ "$current_state" != "$last_state" ]]; then
    if [[ "$current_state" == "$pending_state" ]]; then
      pending_count=$((pending_count + 1))
    else
      pending_state="$current_state"
      pending_count=1
    fi

    if (( pending_count >= STABLE_SAMPLES )); then
      if [[ -z "$last_state" ]]; then
        log "KVM initial state: $current_state (no action)"
      elif [[ "$current_state" == "absent" ]]; then
        log "KVM left Mac (present -> absent); switching monitor to Windows input $WINDOWS_INPUT"
        switch_to_windows
      else
        log "KVM returned to Mac (absent -> present); no DDC action (manual switch back)"
      fi
      last_state="$current_state"
      pending_state=""
      pending_count=0
    fi
  else
    pending_state=""
    pending_count=0
  fi

  sleep "$POLL_INTERVAL"
done
