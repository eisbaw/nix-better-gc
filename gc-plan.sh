#!/usr/bin/env bash
# gc-plan.sh — plan (never execute) an LRU-ish Nix store cleanup.
#
# Enumerates dead (unreferenced) store paths, sorts them OLDEST-FIRST by an
# "effective last-activity" timestamp, and greedily selects from the oldest
# until a target amount of disk space would be freed. Prints age / size /
# cumulative / store path.
#
# Ordering signal:
#   * registrationTime — a *birth* timestamp, always available from the Nix DB.
#   * atime (access time) — a *last-read* timestamp, but ONLY where the store
#     filesystem maintains it. A read-only store (ro) freezes atime; `noatime`
#     disables it. On such installs atime carries no usage signal at all.
#
#   This script DETECTS whether atime is sensible for the store's mount (see
#   --atime below). When it is, each path's sort key becomes the MOST RECENT of
#   {registrationTime, atime} — so a path read recently is treated as "young"
#   and sorts to the KEEP end: recent reads protect it from selection. When
#   atime is not sensible (ro / noatime / no post-birth signal), the script
#   falls back to registrationTime only (identical to the original behaviour).
#
#   Caveat: the atime read is on the store path itself (a directory for most
#   paths). Under relatime it advances at most once/24h, and a directory's atime
#   reflects when it was *listed*, which can lag reads of files inside it. Treat
#   atime as a soft protective hint, not ground truth.
#
# Note: `nix-store --gc --print-dead` OVER-REPORTS deletability. A path (often a
# .drv) can be listed dead yet still be pinned alive by keep-derivations/
# keep-outputs from a rooted output; `nix-store --delete` then refuses it. So the
# plan's total is an UPPER BOUND on reclaimable space, and --delete skips (and
# tallies) any pinned paths rather than failing.
#
# By default it DELETES NOTHING — it writes the selected paths to a file and
# prints the plan. Deletion is opt-in via --delete and only ever touches the
# reviewed, selected dead paths (via `nix-store --delete`) — never a blanket
# `nix-collect-garbage`.
#
# Usage:
#   ./gc-plan.sh <target>                  e.g. 10G, 500MiB, 41GiB, 2000000000
#   ./gc-plan.sh <target> -o FILE          write selected paths to FILE
#   ./gc-plan.sh <target> --atime MODE     MODE = auto (default) | on | off
#   ./gc-plan.sh <target> --delete MODE    MODE = no (default) | confirm | force
#                                          no      = plan only, delete nothing
#                                          confirm = show plan, then prompt [y/N]
#                                          force   = delete the plan, no prompt
set -euo pipefail

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit "${1:-0}"; }

[ $# -ge 1 ] || usage 1
case "$1" in -h|--help) usage 0;; esac

TARGET_HUMAN="$1"; shift
OUTFILE="gc-plan-paths.txt"
ATIME_MODE="auto"
DELETE_MODE="no"
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUTFILE="$2"; shift 2;;
    --atime) ATIME_MODE="$2"; shift 2;;
    --atime=*) ATIME_MODE="${1#*=}"; shift;;
    --delete) DELETE_MODE="$2"; shift 2;;
    --delete=*) DELETE_MODE="${1#*=}"; shift;;
    *) echo "unknown arg: $1" >&2; usage 1;;
  esac
done
case "$ATIME_MODE" in auto|on|off) ;; *) echo "bad --atime: $ATIME_MODE" >&2; usage 1;; esac
case "$DELETE_MODE" in no|confirm|force) ;; *) echo "bad --delete: $DELETE_MODE (use no|confirm|force)" >&2; usage 1;; esac

# Parse target into bytes. numfmt --from=iec wants single-letter suffixes (K/M/G/T,
# 1024-based), so normalise IEC forms (300MiB->300M, 2GiB->2G, 512B->512) first.
NORM="${TARGET_HUMAN%iB}"; NORM="${NORM%B}"
TARGET_BYTES=$(numfmt --from=iec "$NORM" 2>/dev/null \
  || numfmt --from=auto "$TARGET_HUMAN" 2>/dev/null) \
  || { echo "cannot parse target: $TARGET_HUMAN (try 10G, 500MiB, 41GiB, or plain bytes)" >&2; exit 1; }

NOW=$(date +%s)
DAY=86400
STORE_DIR="${NIX_STORE_DIR:-/nix/store}"

# ---- detect whether atime is a sensible ordering signal for this store ----
# Structural check first (mount options), then an empirical check later once we
# have real birth/atime pairs. Sets ATIME_CAP=on|off and ATIME_REASON.
detect_atime_cap() {
  local opts=""
  opts=$(findmnt -no OPTIONS --target "$STORE_DIR" 2>/dev/null || true)
  if [ -z "$opts" ]; then
    # Fallback: longest matching mountpoint in /proc/mounts.
    opts=$(awk -v p="$STORE_DIR" '
      { mp=$2; if (index(p,mp)==1 && length(mp)>bl) { bl=length(mp); o=$4 } }
      END { print o }' /proc/mounts 2>/dev/null || true)
  fi
  ATIME_MNT_OPTS="${opts:-unknown}"
  case ",$opts," in
    *,noatime,*) ATIME_CAP=off; ATIME_REASON="mount has 'noatime' — atime disabled ($opts)"; return;;
  esac
  case ",$opts," in
    *,ro,*) ATIME_CAP=off; ATIME_REASON="store mounted read-only ('ro') — atime frozen ($opts)"; return;;
  esac
  ATIME_CAP=on; ATIME_REASON="mount is rw (${opts:-unknown}) — atime can advance"
}
detect_atime_cap

case "$ATIME_MODE" in
  on)  USE_ATIME=1; ATIME_REASON="forced on (--atime on); mount=$ATIME_MNT_OPTS";;
  off) USE_ATIME=0; ATIME_REASON="forced off (--atime off)";;
  auto) [ "$ATIME_CAP" = on ] && USE_ATIME=1 || USE_ATIME=0;;
esac
echo "atime: $([ "$USE_ATIME" = 1 ] && echo IN USE || echo not used) — $ATIME_REASON" >&2

echo "Enumerating dead store paths (this walks all gc-roots, ~30s)..." >&2
DEAD=$(mktemp); ATIMES=$(mktemp); ROWS_F=$(mktemp); COMBINED=$(mktemp); STATS=$(mktemp)
trap 'rm -f "$DEAD" "$ATIMES" "$ROWS_F" "$COMBINED" "$STATS"' EXIT
nix-store --gc --print-dead 2>/dev/null > "$DEAD"
echo "  $(wc -l < "$DEAD") dead paths found." >&2

# birth (registrationTime) \t narSize \t path   (guard nulls)
# --extra-experimental-features: `nix path-info` is the new CLI; some installs
# (e.g. non-NixOS) don't enable nix-command by default. Harmless where enabled.
nix --extra-experimental-features nix-command path-info --json --stdin < "$DEAD" 2>/dev/null \
  | jq -r 'to_entries[]
      | select(.value.registrationTime != null)
      | [ .value.registrationTime, (.value.narSize // 0), .key ] | @tsv' \
  > "$ROWS_F"

# atime \t path  for each dead path (only if we intend to use it)
if [ "$USE_ATIME" = 1 ]; then
  tr '\n' '\0' < "$DEAD" | xargs -0 -r stat --printf='%X\t%n\n' 2>/dev/null > "$ATIMES" || true
  # Empirical confirmation: does atime ever exceed birth (real post-birth read)?
  naccess=$(awk -F'\t' -v afile="$ATIMES" '
    FILENAME==afile { at[$2]=$1; next }
    { b=$1; p=$3; a=(p in at)?at[p]:0; if (a>b+86400) c++ }
    END { print c+0 }' "$ATIMES" "$ROWS_F")
  if [ "${naccess:-0}" -eq 0 ]; then
    if [ "$ATIME_MODE" = auto ]; then
      USE_ATIME=0
      echo "atime: DOWNGRADED to unused — present but no path shows access after birth (degenerate/frozen)." >&2
    else
      echo "atime: WARNING — no path shows access after birth; ordering will equal registrationTime." >&2
    fi
  else
    echo "atime: $naccess dead paths were read after birth — usable protective signal." >&2
  fi
fi

# Build combined rows and sort OLDEST-FIRST by effective time = max(birth, atime).
# Columns: eff \t birth \t atime \t size \t path   (atime=0 when unknown/unused)
awk -F'\t' -v useat="$USE_ATIME" -v afile="$ATIMES" '
  FILENAME==afile { if (useat) at[$2]=$1; next }  # ATIMES: atime \t path (robust to empty file)
  {
    birth=$1; size=$2; path=$3
    a = (useat && (path in at)) ? at[path] : 0
    eff = birth
    if (a > 0 && a > birth) eff = a               # recent read => younger => protected
    print eff "\t" birth "\t" a "\t" size "\t" path
  }
' "$ATIMES" "$ROWS_F" | sort -n -k1,1 > "$COMBINED"

# Greedy select oldest-first (by effective time) until cumulative narSize >= target.
printf '%-8s %-8s %-8s %9s %9s  %s\n' EFF_AGE BIRTH ATIME SIZE CUM PATH
: > "$OUTFILE"
awk -F'\t' -v now="$NOW" -v day="$DAY" -v target="$TARGET_BYTES" -v out="$OUTFILE" -v useat="$USE_ATIME" -v stats="$STATS" -v delmode="$DELETE_MODE" '
  BEGIN { cum=0; n=0 }
  {
    eff=$1; birth=$2; atime=$3; size=$4; path=$5
    cum+=size; n++
    effage = int((now-eff)/day) "d"
    bage   = int((now-birth)/day) "d"
    aage   = (useat && atime>0) ? int((now-atime)/day) "d" : "-"
    printf "%-8s %-8s %-8s %9s %9s  %s\n", effage, bage, aage, h(size), h(cum), path
    print path >> out
    if (cum>=target) { met=1; exit }
  }
  END {
    printf "\n" > "/dev/stderr"
    if (met)
      printf "PLAN: delete %d oldest dead paths to free %s (target %s). Met.\n", n, h(cum), h(target) > "/dev/stderr"
    else
      printf "PLAN: only %d dead paths totalling %s available — target %s NOT met.\n", n, h(cum), h(target) > "/dev/stderr"
    printf "Ordering key: %s.\n", (useat ? "max(registrationTime, atime) — recent reads protected" : "registrationTime only") > "/dev/stderr"
    printf "%d %d\n", n, cum > stats
    if (delmode == "no")
      printf "Selected paths written to %s (nothing deleted). Delete them with --delete confirm|force, or: xargs -a %s nix-store --delete\n", out, out > "/dev/stderr"
    else
      printf "Preview above = oldest paths up to the %s size target; --delete walks the FULL dead list oldest-first, skips pinned paths, and continues until %s is actually freed.\n", h(target), h(target) > "/dev/stderr"
  }
  function h(b,   u,i) {
    split("B KiB MiB GiB TiB", u, " ")
    i=1; while (b>=1024 && i<5) { b/=1024; i++ }
    return sprintf((i==1)?"%d%s":"%.1f%s", b, u[i])
  }' "$COMBINED"

# ---- optional deletion: walk the full list until the goal is actually freed ----
# The script NEVER touches gc-roots or result pins. It asks Nix to delete each
# dead path oldest-first; Nix refuses any still pinned alive (keep-derivations/
# keep-outputs from a rooted output). Those are SKIPPED and we proceed down the
# list, accumulating ACTUAL freed bytes, until TARGET_BYTES is met or the whole
# dead list has been tried.
if [ "$DELETE_MODE" = no ]; then
  exit 0
fi
if [ ! -s "$COMBINED" ]; then
  echo "No dead paths — nothing to delete." >&2
  exit 0
fi

TARGET_H=$(numfmt --to=iec "$TARGET_BYTES" 2>/dev/null || echo "${TARGET_BYTES}B")

if [ "$DELETE_MODE" = confirm ]; then
  # Probe by actually opening /dev/tty (perm bits alone lie when there is no
  # controlling terminal — open() then fails with ENXIO).
  if { exec 3<>/dev/tty; } 2>/dev/null; then
    printf 'Delete oldest dead paths until ~%s is freed (pinned paths skipped, gc-roots untouched)? [y/N] ' "$TARGET_H" >&3
    read -r ans <&3 || ans=""
    exec 3>&- 3<&-
  else
    echo "--delete=confirm but no usable controlling tty; refusing to delete. Use --delete=force to skip the prompt." >&2
    exit 3
  fi
  case "$ans" in
    y|Y|yes|YES|Yes) ;;
    *) echo "Aborted — nothing deleted." >&2; exit 0;;
  esac
fi

# Delete chunk-by-chunk for speed; if a chunk is refused (contains a path Nix
# still considers alive), salvage it per-path so deletable siblings are still
# freed. Stop as soon as the ACTUAL freed total reaches the target.
FREED=0; DELETED=0; PINNED=0; TRIED=0; CP=(); CS=()
: > "$OUTFILE"
flush_chunk() {
  ((${#CP[@]})) || return 0
  local i
  if printf '%s\n' "${CP[@]}" | xargs -r nix-store --delete >/dev/null 2>&1; then
    for i in "${!CP[@]}"; do FREED=$((FREED+CS[i])); DELETED=$((DELETED+1)); printf '%s\n' "${CP[i]}" >>"$OUTFILE"; done
  else
    for i in "${!CP[@]}"; do
      if nix-store --delete "${CP[i]}" >/dev/null 2>&1; then
        FREED=$((FREED+CS[i])); DELETED=$((DELETED+1)); printf '%s\n' "${CP[i]}" >>"$OUTFILE"
      else
        PINNED=$((PINNED+1))
      fi
    done
  fi
  CP=(); CS=()
}

echo "Deleting oldest-first until ~$TARGET_H freed or dead list exhausted (skipping pinned paths; gc-roots untouched)..." >&2
while IFS=$'\t' read -r _e _b _a sz pth; do
  [ -n "$pth" ] || continue
  TRIED=$((TRIED+1)); CP+=("$pth"); CS+=("$sz")
  if [ "${#CP[@]}" -ge 256 ]; then
    flush_chunk
    if [ "$FREED" -ge "$TARGET_BYTES" ]; then break; fi
  fi
done < "$COMBINED"
flush_chunk

FREED_H=$(numfmt --to=iec "$FREED" 2>/dev/null || echo "${FREED}B")
DEAD_TOTAL=$(wc -l < "$COMBINED")
if [ "$FREED" -ge "$TARGET_BYTES" ]; then
  echo "GOAL MET: freed ~$FREED_H nar (target $TARGET_H) — deleted $DELETED, skipped $PINNED pinned, tried $TRIED of $DEAD_TOTAL. On-disk bytes differ (hardlinks); check df." >&2
else
  echo "LIST EXHAUSTED: freed ~$FREED_H nar of $TARGET_H target — deleted $DELETED, skipped $PINNED pinned, tried $TRIED of $DEAD_TOTAL (remaining dead is all pinned by gc-roots/keep-derivations)." >&2
fi
echo "Actually-deleted paths written to $OUTFILE." >&2
