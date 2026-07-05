#!/bin/bash
# mem-doctor — local macOS memory diagnostic for developers.
# Usage:
#   mem-doctor            # report: pressure state, swap, top consumers, verdict
#   mem-doctor -i         # interactive: after the report, offer to gracefully
#                         # restart a USER-OWNED process you select (SIGTERM, confirmed)
#   mem-doctor -n N       # show top N consumers (default 8)
#
# Non-destructive by default. No auto-kill, no purge-on-loop. SOC2 CC7.2 aligned:
# read-only unless the operator explicitly confirms a single, user-owned SIGTERM.
INTERACTIVE=0; TOPN=8
usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; }
while getopts ":in:h" o; do case $o in
  i) INTERACTIVE=1 ;;
  n) TOPN=$OPTARG ;;
  h) usage; exit 0 ;;
  *) echo "mem-doctor: invalid option or missing argument" >&2; usage >&2; exit 64 ;;
esac; done

is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

# Sanitize -n (fall back to 8 on non-integer or <1), and only colorize a real
# terminal so redirected output / logs stay clean (SOC2 CC7.2: legible records).
if ! is_int "$TOPN" || (( TOPN < 1 )); then TOPN=8; fi
if [[ -t 1 ]]; then
  c_red=$'\033[31m'; c_yel=$'\033[33m'; c_grn=$'\033[32m'; c_dim=$'\033[2m'; c_rst=$'\033[0m'
else
  c_red=; c_yel=; c_grn=; c_dim=; c_rst=
fi

# --- Pressure level (authoritative signal; degrade gracefully if unavailable) ---
PLEVEL=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)
FREE=$(/usr/bin/memory_pressure 2>/dev/null | awk -F': ' '/free percentage/{gsub(/[^0-9]/,"",$2);print $2}')
case "$PLEVEL" in
  1) STATE="NORMAL";   COL=$c_grn ;;
  2) STATE="WARNING";  COL=$c_yel ;;
  4) STATE="CRITICAL"; COL=$c_red ;;
  *) # fall back to free-% heuristic if the sysctl isn't readable on this build
     if is_int "${FREE:-}"; then
       if   (( FREE < 10 )); then STATE="CRITICAL"; COL=$c_red
       elif (( FREE < 20 )); then STATE="WARNING";  COL=$c_yel
       else                       STATE="NORMAL";   COL=$c_grn
       fi
     else STATE="UNKNOWN"; COL=$c_dim; fi ;;
esac

# --- Swap + swapin churn (1s sample) ---
SWAP=$(sysctl -n vm.swapusage 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="used"){print $(i+2);exit}}')
s1=$(/usr/bin/vm_stat 2>/dev/null | awk '/Swapins/{gsub(/[.]/,"",$NF);print $NF}'); sleep 1
s2=$(/usr/bin/vm_stat 2>/dev/null | awk '/Swapins/{gsub(/[.]/,"",$NF);print $NF}')
if is_int "${s1:-}" && is_int "${s2:-}"; then d=$(( s2 - s1 )); (( d<0 )) && d=0; SWAPIN="$d/s"; else SWAPIN="n/a"; fi

# --- Report ---
printf "\n  Memory pressure : %s%s%s\n" "$COL" "$STATE" "$c_rst"
printf "  Free memory     : %s%%\n" "${FREE:-?}"
printf "  Swap used       : %s\n" "${SWAP:-unknown}"
printf "  Swap-in rate    : %s  %s(sustained high = real thrashing)%s\n\n" "$SWAPIN" "$c_dim" "$c_rst"

printf "  Top %s memory consumers (RSS, approximate):\n" "$TOPN"
ps -Amo pid=,rss=,comm= 2>/dev/null | head -n "$TOPN" | awk -v d="$c_dim" -v r="$c_rst" '{
  pid=$1; rss=$2; $1=""; $2=""; sub(/^ */,""); cmd=$0;
  printf "    %-7s %7.0f MB  %s\n", pid, rss/1024, cmd
}'
printf "  %sRSS overcounts shared pages; for footprint-exact numbers use Activity Monitor or: top -l1 -o mem%s\n\n" "$c_dim" "$c_rst"

# --- Interpretation (the part that actually helps devs) ---
case "$STATE" in
  NORMAL)  printf "  %sVerdict:%s Healthy. macOS deliberately fills RAM with cache — high 'used' is normal and\n           not a problem. No action needed. 'Freeing' cache would only slow you down.\n\n" "$c_grn" "$c_rst" ;;
  WARNING) printf "  %sVerdict:%s Under pressure but coping. If a process above is one you're not using\n           (stale VM, leaked node/python, forgotten model in LM Studio), quit it normally.\n\n" "$c_yel" "$c_rst" ;;
  CRITICAL)printf "  %sVerdict:%s Real pressure + likely swapping. Save your work. Identify the offender above\n           and restart it. Reboot clears it fully if a leak keeps climbing.\n" "$c_red" "$c_rst"
           printf "           %sLast resort: 'sudo purge' frees cache for brief relief, but it won't reclaim a\n           leaking process and evicts warm cache (slower after). Fix the offender or reboot.%s\n\n" "$c_dim" "$c_rst" ;;
  *)       printf "  %sVerdict:%s Could not read pressure state on this build; treat the numbers above as advisory.\n\n" "$c_dim" "$c_rst" ;;
esac

[[ "$INTERACTIVE" -eq 0 ]] && exit 0

# --- Opt-in remediation: single, user-owned, graceful, confirmed. No root, no KILL, no loop. ---
read -r -p "  Enter a PID to gracefully terminate (or press Enter to skip): " pid
[[ -z "$pid" ]] && { echo "  No action taken."; exit 0; }
is_int "$pid" || { echo "  Not a PID. Aborting."; exit 0; }
owner=$(ps -o uid= -p "$pid" 2>/dev/null | tr -d ' ')
if [[ "$owner" != "$(id -u)" ]]; then
  echo "  ${c_red}Refusing:${c_rst} PID $pid is not owned by you (uid ${owner:-?}). Quit system/other-user processes manually."
  exit 0
fi
name=$(ps -o comm= -p "$pid" 2>/dev/null)
read -r -p "  Send SIGTERM to '$name' ($pid)? Unsaved work may be lost. [y/N]: " ok
if [[ "$ok" =~ ^[Yy]$ ]]; then
  if kill -TERM "$pid" 2>/dev/null; then echo "  SIGTERM sent to $pid ($name)."
  else echo "  Could not signal $pid (already exited or permission denied)."; fi
else
  echo "  Cancelled."
fi
