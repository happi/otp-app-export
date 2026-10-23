#!/bin/bash
# compare.sh -- interleaved before/after sweep of lintbench.erl.
#
#   BASE="<erl command>" TEST="<erl command>" [REF="<erl command>"] ./compare.sh
#
# BASE and TEST (and optionally REF, e.g. a stock release) are complete erl
# commands, for example
#   BASE="$ERL_TOP/bin/erl -emu_type base"   TEST="$ERL_TOP/bin/erl"
# Every repetition runs each work type, worker count and atom condition on
# every build, alternating the build order between repetitions so that host
# drift hits all of them. Results: one JSON line per pass in $OUT/<arm>.jsonl,
# summarised by lintsum.py at the end.
#
# Settings (environment):
#   FILES    file list (default ./files.txt; see make_filelist.sh)
#   NAMES    names file from harvest.erl (default ./names.bin; built if missing)
#   WORK     work types (default "lint scan")
#   WORKERS  worker counts (default "1 4 8 16")
#   PRE      atom conditions: "none" (new atoms) and/or "names" (the harvested
#            names created serially first) (default "none names")
#   REPS     repetitions (default 3)
#   CPUS     taskset CPU list (default: all CPUs this shell may use)
#   SCHED    +S value (default: number of CPUs in CPUS)
#   OUT      result directory (default ./results)
#   LCNT     optional erl command for a lock-counting emulator; if set, one
#            extra repetition runs on it and records atom_tab statistics
#   NAME_ROOTS  directories searched for .hrl files when harvesting names
#            (default: the application directories of the listed files)
#
# The benchmark modules are compiled with REF if it is set, else with BASE;
# use the oldest release as REF so the .beam files load on every build.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
: "${BASE:?set BASE to the baseline erl command}"
: "${TEST:?set TEST to the erl command under test}"
REF=${REF:-}
FILES=${FILES:-$HERE/files.txt}
NAMES=${NAMES:-$HERE/names.bin}
WORK=${WORK:-lint scan}
WORKERS=${WORKERS:-1 4 8 16}
PRE=${PRE:-none names}
REPS=${REPS:-3}
CPUS=${CPUS:-$(taskset -pc $$ | sed 's/.*: //')}
ncpus() { local n=0 part a b; for part in ${1//,/ }; do
            if [[ $part == *-* ]]; then a=${part%-*}; b=${part#*-}; n=$((n + b - a + 1)); else n=$((n + 1)); fi
          done; echo $n; }
SCHED=${SCHED:-$(ncpus "$CPUS")}
OUT=${OUT:-$HERE/results}
LCNT=${LCNT:-}
mkdir -p "$OUT" "$HERE/ebin"
LOG=$OUT/compare.log
[ -f "$FILES" ] || { echo "no file list $FILES (see make_filelist.sh)" >&2; exit 1; }
COMPILER=${REF:-$BASE}
for m in lintbench harvest; do
  [ "$HERE/ebin/$m.beam" -nt "$HERE/$m.erl" ] || $COMPILER -noshell -eval "{ok,_} = compile:file(\"$HERE/$m.erl\", [{outdir,\"$HERE/ebin\"}]), halt()." || exit 1
done
if [ ! -f "$NAMES" ]; then
  NAME_ROOTS=${NAME_ROOTS:-$(sed 's|/src/.*||' "$FILES" | sort -u)}
  echo "harvesting names into $NAMES" | tee -a "$LOG"
  $COMPILER -noshell -pa "$HERE/ebin" -run harvest main "$FILES" "$NAMES" $NAME_ROOTS 2>&1 | tee -a "$LOG"
fi
run() { # arm cmd work k pre
  local arm=$1 cmd=$2 work=$3 k=$4 pre=$5 prearg=none
  [ "$pre" = names ] && prearg=$NAMES
  echo "== $(date -Is) load=$(cut -d' ' -f1 /proc/loadavg) $arm $work k=$k pre=$pre" >> "$LOG"
  BENCH_TAG=$arm BENCH_OUT=$OUT/$arm.jsonl taskset -c "$CPUS" $cmd +S "$SCHED:$SCHED" -noshell -pa "$HERE/ebin" \
      -run lintbench main "$FILES" "$k" 2 "$work" "$prearg" >> "$LOG" 2>&1 || echo "!! failed $arm $work $k $pre" | tee -a "$LOG"
}
ARMS="base test"; [ -n "$REF" ] && ARMS="ref base test"
for rep in $(seq 1 "$REPS"); do
  order=$ARMS; [ $((rep % 2)) = 0 ] && order=$(echo $ARMS | tr ' ' '\n' | tac | tr '\n' ' ')
  for work in $WORK; do for k in $WORKERS; do for arm in $order; do for pre in $PRE; do
    case $arm in base) cmd=$BASE;; test) cmd=$TEST;; ref) cmd=$REF;; esac
    run "$arm" "$cmd" "$work" "$k" "$pre"
  done; done; done; done
done
if [ -n "$LCNT" ]; then
  for work in $WORK; do for k in $WORKERS; do for pre in $PRE; do run lcnt "$LCNT" "$work" "$k" "$pre"; done; done; done
fi
for arm in $ARMS; do python3 "$HERE/lintsum.py" "$OUT/$arm.jsonl" --label "$arm"; done
[ -n "$LCNT" ] && python3 "$HERE/lintsum.py" "$OUT/lcnt.jsonl" --label lcnt --lcnt "$OUT/lcnt.jsonl"
exit 0
