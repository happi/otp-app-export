#!/bin/bash
# compile_bench.sh -- full-compile measurements with bench.erl for one build.
#
#   ERL="<erl command>" TAG=<name> ./compile_bench.sh [corpus.json]
#
# Runs, in order: split (read/scan/epp/parse decomposition), warm (single
# compiles with GC accounting), passes ({time,_} pass timings), par (K
# concurrent compiles, K = 1 2 4 8) and fresh (one VM per compile). Paths
# in the corpus are relative to $ERL_TOP unless it names another root.
# CPUS and SCHED as in compare.sh (default: CPUs 0-7, +S 8); FRESH lists the
# modules measured in fresh VMs (default: dict lists gen_statem erl_lint erl_parse).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
: "${ERL:?set ERL to the erl command to measure}"
: "${ERL_TOP:?set ERL_TOP to the OTP source tree the corpus refers to}"
TAG=${TAG:-compile}
CORPUS=${1:-$HERE/corpus.json}
CPUS=${CPUS:-0-7}
SCHED=${SCHED:-8}
OUT=${OUT:-$HERE/results}
mkdir -p "$OUT" "$HERE/ebin"
[ "$HERE/ebin/bench.beam" -nt "$HERE/bench.erl" ] || $ERL -noshell -eval "{ok,_} = compile:file(\"$HERE/bench.erl\", [{outdir,\"$HERE/ebin\"}]), halt()." || exit 1
export BENCH_OUT=$OUT/$TAG.jsonl BENCH_TAG=$TAG ERL_TOP
b() { echo "== $(date -Is) $*" >> "$OUT/$TAG.log"
      taskset -c "$CPUS" $ERL +S "$SCHED:$SCHED" -noshell -pa "$HERE/ebin" -run bench main "$@" >> "$OUT/$TAG.log" 2>&1 \
        || echo "!! failed: $*" | tee -a "$OUT/$TAG.log"; }
b split "$CORPUS" all 5
b warm "$CORPUS" all 7
b passes "$CORPUS" all 3
for k in 1 2 4 8; do b par "$CORPUS" cat:ordinary $k 3; done
for k in 1 2 4 8; do b par "$CORPUS" cat:generated $k 1; done
for f in ${FRESH:-dict lists gen_statem erl_lint erl_parse}; do for i in 1 2 3; do b fresh "$CORPUS" $f; done; done
python3 "$HERE/summarize.py" "$OUT/$TAG.jsonl"
