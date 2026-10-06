#!/bin/sh
#
# calib-tapes.sh - cycle tapes through a library drive for calibration/exercise
#
# Loads each requested slot into a tape drive, keeps the tape mounted for a
# configurable time (with an optional progress bar), then unloads it again.
# Typical uses: letting new media calibrate/acclimatize in a drive,
# exercising (re-tensioning) long-stored tapes, or burn-in testing a changer.
#
# WARNING: Do not run this while backup software (Bareos, Bacula, Amanda, ...)
#          is using the changer. Stop the storage daemon or disable the
#          device first, otherwise both will fight over the robot.
#
# Copyright (c) 2026 Manuel Sonder
# SPDX-License-Identifier: MIT
# Project home: https://github.com/Nemester/calib-tapes
 
set -eu
 
VERSION=1.0.1
PROG=${0##*/}
 
###############################################################################
# Defaults. Each can be set via environment; command-line options win.
###############################################################################
 
CHANGER=${CHANGER:-}
SLOTS=${SLOTS:-}
DRIVE_INDEX=${DRIVE_INDEX:-${DRIVE_NUM:-0}}
DRIVE=${DRIVE:-}
WAIT_SECS=${WAIT_SECS:-200}
RETRY_SECS=${RETRY_SECS:-60}
MAX_RETRIES=${MAX_RETRIES:-0}          # 0 = retry forever
OFFLINE=${OFFLINE:-0}
MTX_CHANGER=${MTX_CHANGER:-}
STRICT=${STRICT:-0}
DRY_RUN=${DRY_RUN:-0}
PROGRESS=${PROGRESS:-auto}             # auto | yes | no
MTX_BIN=${MTX_BIN:-mtx}
MT_BIN=${MT_BIN:-mt}
 
TICK=5          # seconds between progress updates
BAR_WIDTH=40
 
# Backwards compatibility with the original environment variables.
if [ -z "$SLOTS" ] && [ -n "${START_SLOT:-}" ]; then
  SLOTS="$START_SLOT-${END_SLOT:-$START_SLOT}"
fi
if [ -z "$DRIVE" ] && [ -n "${DRIVE_ID:-}" ]; then
  DRIVE="/dev/tape/by-id/$DRIVE_ID"
fi
 
###############################################################################
# Helpers
###############################################################################
 
usage() {
  cat <<EOF
Usage: $PROG -c CHANGER -s SLOTS [options] [SLOTS...]
 
Load each slot into a tape drive, keep it mounted for a while, unload it again.
 
Required:
  -c, --changer DEV        Changer (robot) control device, e.g. /dev/sg3 or
                           /dev/tape/by-id/scsi-XXXXXXXX. NOT the tape drive
                           (/dev/nstN, .../scsi-XXXX-nst).
  -s, --slots LIST         Slots to process: numbers and ranges separated by
                           commas, e.g. "5", "1-10", "1-4,9,20-22".
                           Slots may also be given as positional arguments.
 
Drive selection:
  -n, --drive-index N      Drive number (Data Transfer Element) [default: 0]
  -d, --drive DEV          Tape device of that drive, e.g. /dev/nst0.
                           Required for --offline and --mtx-changer.
 
Timing:
  -w, --wait SECS          Time to keep each tape loaded [default: 200]
  -r, --retry-delay SECS   Delay between retries of a failed load/unload
                           [default: 60]
  -m, --max-retries N      Give up after N failed attempts, 0 = forever
                           [default: 0]
 
Behaviour:
  -o, --offline            Run 'mt -f DRIVE offline' (eject) before unloading.
                           Needed by libraries that cannot pull a tape the
                           drive has not ejected itself.
      --mtx-changer PATH   Use a Bacula/Bareos-style mtx-changer script for
                           load/unload instead of calling mtx directly.
      --strict             Abort on an empty slot instead of skipping it.
      --dry-run            Only print what would be done ('mtx status' still
                           runs to validate slots and drive).
  -q, --no-progress        Never draw a progress bar (default: only on a TTY)
  -h, --help               Show this help and exit
  -V, --version            Show version and exit
 
Environment variables (overridden by options):
  CHANGER SLOTS DRIVE_INDEX DRIVE WAIT_SECS RETRY_SECS MAX_RETRIES OFFLINE
  MTX_CHANGER STRICT DRY_RUN PROGRESS(auto|yes|no) MTX_BIN MT_BIN
 
Examples:
  $PROG -c /dev/sg5 -n 2 -s 62 -w 7200
  $PROG -c /dev/sg5 -n 1 -d /dev/nst1 --offline 1-24
  $PROG -c /dev/sg5 -n 2 -d /dev/nst2 \\
      --mtx-changer /usr/lib/bareos/scripts/mtx-changer 10-20,30
 
Exit status: 0 success, 1 error, 2 usage error, 128+N killed by signal N.
EOF
}
 
log()  { printf '%s %s\n' "$(date '+%F %T')" "$*"; }
warn() { log "WARNING: $*" >&2; }
die()  { log "ERROR: $*" >&2; exit 1; }
 
usage_error() {
  printf '%s: %s\n' "$PROG" "$*" >&2
  printf "Try '%s --help' for more information.\n" "$PROG" >&2
  exit 2
}
 
need_arg()  { [ "$2" -ge 2 ] || usage_error "option '$1' requires an argument"; }
need_cmd()  { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
is_uint()   { case $1 in ''|*[!0-9]*) return 1 ;; esac; }
check_uint() { is_uint "$2" || usage_error "$1 must be a non-negative integer, got '$2'"; }
 
# Strip leading zeros so "08" is not treated as invalid octal in $((...)).
strip_zeros() { set -- "${1#"${1%%[!0]*}"}"; printf '%s' "${1:-0}"; }
 
is_true() {
  case $1 in
    1|[Yy]|[Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]|[Oo][Nn]) return 0 ;;
    *) return 1 ;;
  esac
}
 
repeat() {
  n=$1 out=
  while [ "$n" -gt 0 ]; do out="$out$2"; n=$((n - 1)); done
  printf '%s' "$out"
}
 
fmt_dur() {
  printf '%02d:%02d:%02d' $(($1 / 3600)) $(($1 % 3600 / 60)) $(($1 % 60))
}
 
# Expand "1-3,7" into one slot number per line.
expand_slots() {
  # shellcheck disable=SC2020  # deliberate: map each separator char to newline
  printf '%s\n' "$1" | tr ', \t' '\n\n\n' | while IFS= read -r item; do
    [ -n "$item" ] || continue
    case $item in
      *-*) lo=${item%%-*} hi=${item#*-} ;;
      *)   lo=$item hi=$item ;;
    esac
    if ! is_uint "$lo" || ! is_uint "$hi"; then
      printf '%s: invalid slot specification: %s\n' "$PROG" "$item" >&2
      exit 1
    fi
    lo=$(strip_zeros "$lo") hi=$(strip_zeros "$hi")
    if [ "$lo" -lt 1 ] || [ "$lo" -gt "$hi" ]; then
      printf '%s: invalid slot range: %s\n' "$PROG" "$item" >&2
      exit 1
    fi
    while [ "$lo" -le "$hi" ]; do echo "$lo"; lo=$((lo + 1)); done
  done
}
 
# True if $1 looks like a tape drive node (st/nst) rather than a changer.
looks_like_tape_drive() {
  name=${1##*/} target=$1
  if command -v readlink >/dev/null 2>&1; then
    t=$(readlink -f "$1" 2>/dev/null) || t=
    if [ -n "$t" ]; then target=$t; fi
  fi
  case $name in *-nst|*-st) return 0 ;; esac
  case ${target##*/} in nst[0-9]*|st[0-9]*) return 0 ;; esac
  return 1
}
 
###############################################################################
# Changer interaction
###############################################################################
 
# element_state "Storage Element" 62        -> Full | Empty | (nothing)
# element_state "Data Transfer Element" 0   -> Full | Empty | (nothing)
element_state() {
  status=$("$MTX_BIN" -f "$CHANGER" status) || return 1
  printf '%s\n' "$status" | awk -v prefix="$1" -v want="$2" '
    $0 ~ "^[ \t]*" prefix "[ \t]+[0-9]" {
      line = $0
      sub("^[ \t]*" prefix "[ \t]+", "", line)
      num = line
      sub(/[^0-9].*$/, "", num)
      if (num + 0 == want + 0) {
        if (line ~ /:[ \t]*Full/)       print "Full"
        else if (line ~ /:[ \t]*Empty/) print "Empty"
        exit
      }
    }'
}
 
run() {
  log "CMD: $*"
  if is_true "$DRY_RUN"; then
    return 0
  fi
  "$@"
}
 
# retry DESCRIPTION MAX_TRIES COMMAND [ARGS...]
retry() {
  r_desc=$1 r_max=$2
  shift 2
  r_tries=0
  while :; do
    if "$@"; then
      return 0
    fi
    r_tries=$((r_tries + 1))
    if [ "$r_max" -ne 0 ] && [ "$r_tries" -ge "$r_max" ]; then
      warn "$r_desc failed after $r_tries attempt(s), giving up"
      return 1
    fi
    warn "$r_desc failed (attempt $r_tries), retrying in ${RETRY_SECS}s"
    sleep "$RETRY_SECS"
  done
}
 
do_load() {
  if [ -n "$MTX_CHANGER" ]; then
    run "$MTX_CHANGER" "$CHANGER" load "$1" "$DRIVE" "$DRIVE_INDEX"
  else
    run "$MTX_BIN" -f "$CHANGER" load "$1" "$DRIVE_INDEX"
  fi
}
 
do_unload() {
  if is_true "$OFFLINE"; then
    run "$MT_BIN" -f "$DRIVE" offline || warn "'mt offline' failed, trying to unload anyway"
  fi
  if [ -n "$MTX_CHANGER" ]; then
    run "$MTX_CHANGER" "$CHANGER" unload "$1" "$DRIVE" "$DRIVE_INDEX"
  else
    run "$MTX_BIN" -f "$CHANGER" unload "$1" "$DRIVE_INDEX"
  fi
}
 
###############################################################################
# Waiting / progress
###############################################################################
 
draw_bar() {
  pct=$(($1 * 100 / $2))
  filled=$((pct * BAR_WIDTH / 100))
  bar="$(repeat "$filled" '#')$(repeat $((BAR_WIDTH - filled)) '-')"
  printf '\r%s [%s] %3d%%  remaining %s ' \
    "$(date '+%F %T')" "$bar" "$pct" "$(fmt_dur $(($2 - $1)))"
}
 
wait_loaded() {
  total=$1
  if [ "$total" -le 0 ]; then
    return 0
  fi
  if is_true "$DRY_RUN"; then
    log "(dry run) would wait $(fmt_dur "$total")"
    return 0
  fi
  log "Keeping tape loaded for $(fmt_dur "$total")"
  start=$(date +%s)
  end=$((start + total))
  while :; do
    now=$(date +%s)
    if [ "$now" -ge "$end" ]; then
      break
    fi
    if [ "$SHOW_BAR" = 1 ]; then
      draw_bar $((now - start)) "$total"
    fi
    chunk=$TICK
    if [ $((end - now)) -lt "$chunk" ]; then
      chunk=$((end - now))
    fi
    sleep "$chunk"
  done
  if [ "$SHOW_BAR" = 1 ]; then
    draw_bar "$total" "$total"
    printf '\n'
  fi
}
 
###############################################################################
# Signal handling: never leave a tape in the drive when interrupted.
###############################################################################
 
CURRENT_SLOT=
 
on_signal() {
  trap - INT TERM HUP
  if [ "${SHOW_BAR:-0}" = 1 ]; then
    printf '\n'
  fi
  warn "interrupted by SIG$1"
  if [ -n "$CURRENT_SLOT" ]; then
    log "Unloading slot $CURRENT_SLOT before exiting (press Ctrl-C again to abort)"
    if ! retry "unload(slot=$CURRENT_SLOT)" 3 do_unload "$CURRENT_SLOT"; then
      warn "tape from slot $CURRENT_SLOT is still in drive $DRIVE_INDEX"
    fi
  fi
  exit "$2"
}
 
###############################################################################
# Argument parsing
###############################################################################
 
while [ $# -gt 0 ]; do
  case $1 in
    -c|--changer)       need_arg "$1" $#; CHANGER=$2; shift 2 ;;
    --changer=*)        CHANGER=${1#*=}; shift ;;
    -s|--slots)         need_arg "$1" $#; SLOTS="$SLOTS,$2"; shift 2 ;;
    --slots=*)          SLOTS="$SLOTS,${1#*=}"; shift ;;
    -n|--drive-index)   need_arg "$1" $#; DRIVE_INDEX=$2; shift 2 ;;
    --drive-index=*)    DRIVE_INDEX=${1#*=}; shift ;;
    -d|--drive)         need_arg "$1" $#; DRIVE=$2; shift 2 ;;
    --drive=*)          DRIVE=${1#*=}; shift ;;
    -w|--wait)          need_arg "$1" $#; WAIT_SECS=$2; shift 2 ;;
    --wait=*)           WAIT_SECS=${1#*=}; shift ;;
    -r|--retry-delay)   need_arg "$1" $#; RETRY_SECS=$2; shift 2 ;;
    --retry-delay=*)    RETRY_SECS=${1#*=}; shift ;;
    -m|--max-retries)   need_arg "$1" $#; MAX_RETRIES=$2; shift 2 ;;
    --max-retries=*)    MAX_RETRIES=${1#*=}; shift ;;
    --mtx-changer)      need_arg "$1" $#; MTX_CHANGER=$2; shift 2 ;;
    --mtx-changer=*)    MTX_CHANGER=${1#*=}; shift ;;
    -o|--offline)       OFFLINE=1; shift ;;
    --strict)           STRICT=1; shift ;;
    --dry-run)          DRY_RUN=1; shift ;;
    -q|--no-progress)   PROGRESS=no; shift ;;
    -h|--help)          usage; exit 0 ;;
    -V|--version)       printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
    --)                 shift; break ;;
    -?*)                usage_error "unknown option: $1" ;;
    *)                  SLOTS="$SLOTS,$1"; shift ;;
  esac
done
for arg in "$@"; do
  SLOTS="$SLOTS,$arg"
done
 
###############################################################################
# Validation
###############################################################################
 
[ -n "$CHANGER" ] || usage_error "no changer device given (use -c/--changer)"
 
check_uint "drive index" "$DRIVE_INDEX"
check_uint "wait time" "$WAIT_SECS"
check_uint "retry delay" "$RETRY_SECS"
check_uint "max retries" "$MAX_RETRIES"
DRIVE_INDEX=$(strip_zeros "$DRIVE_INDEX")
WAIT_SECS=$(strip_zeros "$WAIT_SECS")
RETRY_SECS=$(strip_zeros "$RETRY_SECS")
MAX_RETRIES=$(strip_zeros "$MAX_RETRIES")
 
SLOT_LIST=$(expand_slots "$SLOTS") || usage_error "invalid slot list: ${SLOTS#,}"
[ -n "$SLOT_LIST" ] || usage_error "no slots given (use -s/--slots or positional arguments)"
SLOT_COUNT=$(printf '%s\n' "$SLOT_LIST" | wc -l | tr -d ' ')
 
if [ -z "$DRIVE" ]; then
  if is_true "$OFFLINE"; then
    usage_error "--offline requires the drive device (-d/--drive)"
  fi
  if [ -n "$MTX_CHANGER" ]; then
    usage_error "--mtx-changer requires the drive device (-d/--drive)"
  fi
fi
 
case $PROGRESS in
  auto) if [ -t 1 ]; then SHOW_BAR=1; else SHOW_BAR=0; fi ;;
  *)    if is_true "$PROGRESS"; then SHOW_BAR=1; else SHOW_BAR=0; fi ;;
esac
 
need_cmd "$MTX_BIN"
need_cmd awk
[ -e "$CHANGER" ] || die "changer device not found: $CHANGER"
if looks_like_tape_drive "$CHANGER"; then
  usage_error "'$CHANGER' looks like a tape drive, not a changer.
Pass the drive with -d/--drive and the changer (robot) with -c/--changer.
Find the changer with 'lsscsi -g' (type 'mediumx') or 'ls -l /dev/tape/by-id/'."
fi
if [ -n "$DRIVE" ]; then
  [ -e "$DRIVE" ] || die "drive device not found: $DRIVE"
fi
if is_true "$OFFLINE"; then
  need_cmd "$MT_BIN"
fi
if [ -n "$MTX_CHANGER" ]; then
  [ -x "$MTX_CHANGER" ] || die "mtx-changer script not executable: $MTX_CHANGER"
fi
 
###############################################################################
# Main
###############################################################################
 
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM
trap 'on_signal HUP 129' HUP
 
# Pre-flight: make sure we are really talking to a medium changer.
if inquiry=$("$MTX_BIN" -f "$CHANGER" inquiry 2>&1); then
  ptype=$(printf '%s\n' "$inquiry" | sed -n 's/^Product Type:[[:space:]]*//p')
  case $ptype in
    ''|*[Cc]hanger*|*[Ll]ibrary*) ;;
    *) die "'$CHANGER' reports product type '$ptype', expected a medium changer" ;;
  esac
else
  die "cannot talk to changer '$CHANGER': $inquiry"
fi
 
log "$PROG $VERSION"
log "Changer: $CHANGER"
log "Drive:   index $DRIVE_INDEX${DRIVE:+ ($DRIVE)}"
log "Slots:   ${SLOTS#,} ($SLOT_COUNT total), $(fmt_dur "$WAIT_SECS") each"
if is_true "$DRY_RUN"; then
  log "DRY RUN: no tapes will be moved"
fi
 
cycled=0
skipped=0
idx=0
 
for slot in $SLOT_LIST; do
  idx=$((idx + 1))
  log "[$idx/$SLOT_COUNT] Slot $slot"
 
  state=$(element_state "Storage Element" "$slot") || die "cannot read changer status"
  case $state in
    Full) ;;
    Empty)
      if is_true "$STRICT"; then
        die "slot $slot is empty"
      fi
      warn "slot $slot is empty, skipping"
      skipped=$((skipped + 1))
      continue
      ;;
    *) die "slot $slot not found in changer status" ;;
  esac
 
  dstate=$(element_state "Data Transfer Element" "$DRIVE_INDEX") || die "cannot read changer status"
  [ -n "$dstate" ] || die "drive $DRIVE_INDEX not found in changer status"
  [ "$dstate" = Empty ] || die "drive $DRIVE_INDEX is not empty, unload it first"
 
  log "Loading slot $slot into drive $DRIVE_INDEX"
  retry "load(slot=$slot, drive=$DRIVE_INDEX)" "$MAX_RETRIES" do_load "$slot" \
    || die "could not load slot $slot"
  CURRENT_SLOT=$slot
 
  wait_loaded "$WAIT_SECS"
 
  log "Unloading slot $slot from drive $DRIVE_INDEX"
  retry "unload(slot=$slot, drive=$DRIVE_INDEX)" "$MAX_RETRIES" do_unload "$slot" \
    || die "could not unload slot $slot, tape is still in drive $DRIVE_INDEX"
  CURRENT_SLOT=
 
  cycled=$((cycled + 1))
done
 
log "Done: $cycled tape(s) cycled, $skipped empty slot(s) skipped."
