# Atom table and front-end benchmarks

Benchmarks for the patch on branch `exp/atom-lockfree` ("erts: Look up
existing atoms without the atom table lock"), and the compile-time harness
used to decide where compile time goes. They are review material, not
intended for merging into OTP. Erlang/OTP 27 or later is needed (they use
the `json` module).

## What is measured

A linter or language server that scans many distinct modules
concurrently in one VM creates new atoms at a high rate: the scanner turns
every atom and variable token into an atom. Each new atom takes the atom
table's write lock, and while the writer waits for every scheduler's
reader slot to drain, atom lookups on all schedulers stall.
`lintbench.erl` reproduces that: K workers pull distinct files from a
shared counter and run either

- `lint`: `epp:parse_file/2` plus `erl_lint:module/3`, or
- `scan`: `file:read_file/1`, `unicode:characters_to_list/1` and
  `erl_scan:string/3`.

Each VM runs two passes over the files. Pass 1 creates the source atoms;
pass 2 finds them in the table. The control condition (`PRE=names`) first
creates every name serially, in one process, from a file written by
`harvest.erl`, so pass 1 then differs from the cold run only in the atom
table. Cold minus control is the cost of creating atoms under concurrency.

## Quick start

Build the tree twice: first without the patch, keeping that emulator under
its own type name, then with it. The patch only touches the emulator, so
the second build is a `make emulator`.

```bash
cd $ERL_TOP                                     # a clone of this fork
git checkout --detach exp/atom-lockfree~1       # upstream master, unpatched
./configure && make -j8
B=$ERL_TOP/bin/$($ERL_TOP/make/autoconf/config.guess)
cp -p $B/beam.smp $B/beam.base.smp
cp -p $B/erl_child_setup $B/erl_child_setup.base
git checkout exp/atom-lockfree-bench            # the patch plus these scripts
make emulator

cd scripts/atom-bench
./make_filelist.sh $ERL_TOP/lib $ERL_TOP/erts > files.txt      # or your own code base
BASE="$ERL_TOP/bin/erl -emu_type base" TEST="$ERL_TOP/bin/erl" ./compare.sh
```

`compare.sh` interleaves the builds, repeats each configuration three
times and prints a table per build; raw results are JSON lines in
`results/`. Add `REF=/path/to/stock/bin/erl` to include a release build,
and `LCNT="$ERL_TOP/bin/cerl -lcnt"` (after `make emulator TYPE=lcnt`) to
record `atom_tab` lock statistics. `WORKERS`, `WORK`, `REPS`, `CPUS` and
`SCHED` are described at the top of the script. Pin `CPUS` to cores the
host is not otherwise using; the default is every CPU the shell may use.

One configuration by hand:

```bash
erlc -o ebin *.erl
taskset -c 0-15 $ERL_TOP/bin/erl +S 16:16 -noshell -pa ebin \
    -run lintbench main files.txt 16 2 scan none        # FILES K PASSES WORK PRE
```

## Files

| File | Purpose |
| --- | --- |
| `lintbench.erl` | concurrent lint or scan over a file list; one JSON line per pass (wall, CPU, scheduler states, GC, atoms added, `atom_tab` lock counts on an lcnt emulator) |
| `harvest.erl` | collects the atom and variable names that scanning the files and their `.hrl` files creates |
| `compare.sh` | interleaved before/after sweep of `lintbench.erl` |
| `lintsum.py` | per-build tables: cold vs control, speedup per worker count, lock statistics |
| `atomstress.erl` | `stall R W MS`: R lookup processes against W atom-creating processes; `inserts N`: per-insert latency, which shows the whole-table rehash pauses |
| `atomcheck.erl` | concurrent correctness check: every created atom is found by every process, by `list_to_atom/1`, `binary_to_atom/1,2` and `binary_to_existing_atom/2`, while the table grows; `collide P K` builds 2^K names with one hash value |
| `bench.erl`, `compile_bench.sh`, `summarize.py`, `corpus.json` | full-compile harness: read/scan/epp/parse split, warm compiles with GC and allocation estimates, `{time,_}` pass timings, `tprof` attribution, K concurrent compiles, fresh-VM compiles |
| `make_filelist.sh` | lists the `.erl` files under `src/` directories |

`corpus.json` lists 27 OTP modules (ordinary, large hand-written and
generated) with paths relative to `$ERL_TOP`:

```bash
ERL="$ERL_TOP/bin/erl" TAG=mybuild ./compile_bench.sh
```

## Notes on measuring

- Timing on shared hosts drifts by several percent. Compare builds only
  within one interleaved run, and read medians.
- Atoms are never freed. A warm VM sees no new atoms on a repeat pass, so
  the cold condition needs a fresh VM per run (`lintbench` starts one per
  configuration).
- The compiler constant-folds `list_to_atom/1` and `binary_to_atom/1,2` on
  literal arguments; `atomstress` and `atomcheck` build their names at run
  time for that reason.
- `tprof` traces only processes spawned from the compiler process. The
  scanner runs in the file io server (epp reads through
  `io:scan_erl_form/4`), so use `bench split` for front-end costs.
