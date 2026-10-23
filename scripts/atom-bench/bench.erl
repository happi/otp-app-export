%% bench.erl -- compile-speed benchmark harness for Erlang/OTP.
%%
%% Run with the toolchain under test:
%%   erl -noshell -pa .../bench/ebin -run bench main MODE ARGS...
%%
%% Modes (CORPUS is a JSON manifest, SELECT is "all", "cat:<category>" or
%% a comma-separated list of names):
%%   warm   CORPUS SELECT ITERS     per file: 1 warm-up + ITERS measured compiles
%%   fresh  CORPUS SELECT           one file per VM: code-load time + one compile
%%   par    CORPUS SELECT K ROUNDS  K workers, each compiles SELECT ROUNDS times
%%   passes CORPUS SELECT ITERS     {time,_} pass timings, median over ITERS
%%   tprof  CORPUS SELECT TYPE      TYPE = call_time | call_memory, per module
%%   split  CORPUS SELECT ITERS     read / scan / epp / parse decomposition
%%   modules CORPUS SELECT          modules loaded by compiling the first file
%%
%% Environment: BENCH_OUT (jsonl file to append to), BENCH_TAG (free text),
%% BENCH_OPTS (extra compile options as an Erlang list term, e.g. "[no_ssa_opt]"),
%% ERL_TOP (resolves relative paths in the manifest when it has no "root").
%%
%% CORPUS manifest: {"root": DIR, "files": [{"name", "category", "path",
%% "include_dirs"}]}. Relative paths are resolved against "root"; a root
%% of "$ERL_TOP" (or none) means the ERL_TOP environment variable.
-module(bench).
-export([main/1]).

main([Mode|Args]) ->
    try
        run(Mode, Args)
    catch
        Class:Reason:Stk ->
            io:format(standard_error, "bench failed: ~p:~p~n~p~n", [Class, Reason, Stk]),
            halt(1)
    end,
    halt(0).

run("warm", [Corpus, Select, Iters]) ->
    Files = select(Corpus, Select),
    warm_up(),
    [warm_file(F, list_to_integer(Iters)) || F <- Files];
run("fresh", [Corpus, Select]) ->
    Files = select(Corpus, Select),
    T0 = erlang:monotonic_time(),
    Mods = compiler_modules(),
    LoadRes = code:ensure_modules_loaded(Mods),
    T1 = erlang:monotonic_time(),
    [begin
         Opts = opts(F),
         T2 = erlang:monotonic_time(),
         R = compile:file(path(F), Opts),
         T3 = erlang:monotonic_time(),
         emit(F, fresh, #{<<"load_us">> => us(T1 - T0),
                          <<"load_modules">> => length(Mods),
                          <<"load_result">> => fmt(LoadRes),
                          <<"compile_us">> => us(T3 - T2),
                          <<"result">> => summarize(R),
                          <<"atom_count">> => erlang:system_info(atom_count),
                          <<"hwm_kb">> => hwm_kb(),
                          <<"vm_mem_total">> => erlang:memory(total)})
     end || F <- Files];
run("par", [Corpus, Select, K, Rounds]) ->
    Files = select(Corpus, Select),
    warm_up(),
    par(Files, list_to_integer(K), list_to_integer(Rounds));
run("passes", [Corpus, Select, Iters]) ->
    Files = select(Corpus, Select),
    warm_up(),
    [passes_file(F, list_to_integer(Iters)) || F <- Files];
run("tprof", [Corpus, Select, Type]) ->
    Files = select(Corpus, Select),
    warm_up(),
    [tprof_file(F, list_to_atom(Type)) || F <- Files];
run("split", [Corpus, Select, Iters]) ->
    Files = select(Corpus, Select),
    warm_up(),
    [split_file(F, list_to_integer(Iters)) || F <- Files];
run("lcnt", [Corpus, Select, K, Rounds]) ->
    %% Lock contention during K-way parallel compilation; needs the
    %% lock-counting emulator (cerl -lcnt). Text report on stdout.
    Files = select(Corpus, Select),
    warm_up(),
    _ = par(Files, list_to_integer(K), 1),         % warm, also loads lcnt
    {ok, _} = lcnt:start(),
    _ = lcnt:rt_opt({copy_save, false}),
    ok = lcnt:clear(),
    _ = par(Files, list_to_integer(K), list_to_integer(Rounds)),
    ok = lcnt:collect(),
    io:format("~n== lcnt conflicts (K=~s)~n", [K]),
    lcnt:conflicts([{max_locks, 30}, {print, [name, id, tries, colls, ratio, time, duration]}]),
    io:format("~n== lcnt atom_tab~n"),
    lcnt:inspect(atom_tab, [{max_locks, 10}, {print, [name, id, tries, colls, ratio, time, duration]}]),
    io:format("~n== lcnt locations atom_tab~n"),
    lcnt:inspect(atom_tab, [{locations, true}, {max_locks, 10}]),
    lcnt:stop();
run("modules", [Corpus, Select]) ->
    [F|_] = select(Corpus, Select),
    Before = sets:from_list([M || {M, _} <- code:all_loaded()]),
    {ok, _, _, _} = compile:file(path(F), opts(F)),
    After = [M || {M, _} <- code:all_loaded(), not sets:is_element(M, Before)],
    io:format("~s~n", [lists:join("\n", [atom_to_list(M) || M <- lists:sort(After)])]).

%%% ---------------------------------------------------------------------
%%% corpus

select(Corpus, Select) ->
    {ok, Bin} = file:read_file(Corpus),
    #{<<"files">> := Files0} = Manifest = json:decode(Bin),
    Root = manifest_root(Manifest),
    Files = [resolve(Root, F) || F <- Files0],
    Sel = case Select of
              "all" -> fun(_) -> true end;
              "cat:" ++ Cat ->
                  CatB = list_to_binary(Cat),
                  fun(#{<<"category">> := C}) -> C =:= CatB end;
              _ ->
                  Names = [list_to_binary(N) || N <- string:lexemes(Select, ",")],
                  fun(#{<<"name">> := N}) -> lists:member(N, Names) end
          end,
    case [F || F <- Files, Sel(F)] of
        [] -> error({no_files_selected, Select});
        L -> L
    end.

path(#{<<"path">> := P}) -> binary_to_list(P).

manifest_root(#{<<"root">> := <<"$ERL_TOP">>}) -> erl_top();
manifest_root(#{<<"root">> := R}) -> binary_to_list(R);
manifest_root(_) -> erl_top().

erl_top() ->
    case os:getenv("ERL_TOP") of
        false -> code:root_dir();
        Top -> Top
    end.

resolve(Root, #{<<"path">> := P, <<"include_dirs">> := Incs} = F) ->
    Abs = fun(X) -> list_to_binary(filename:absname(binary_to_list(X), Root)) end,
    F#{<<"path">> := Abs(P), <<"include_dirs">> := [Abs(I) || I <- Incs]}.
name(#{<<"name">> := N}) -> N.

opts(#{<<"include_dirs">> := Incs}) ->
    [binary, return | [{i, binary_to_list(D)} || D <- Incs]] ++ extra_opts().

extra_opts() ->
    case os:getenv("BENCH_OPTS") of
        false -> [];
        "" -> [];
        S ->
            {ok, Toks, _} = erl_scan:string(S ++ "."),
            {ok, Term} = erl_parse:parse_term(Toks),
            Term
    end.

%% Compile a trivial module so that the compiler's own code is loaded
%% before anything is measured.
warm_up() ->
    Forms = [{attribute, 1, module, bench_warm_up},
             {attribute, 1, export, [{f, 1}]},
             {function, 1, f, 1, [{clause, 1, [{var, 1, 'X'}], [], [{op, 1, '+', {var, 1, 'X'}, {integer, 1, 1}}]}]}],
    {ok, _, _, _} = compile:forms(Forms, [binary, return]),
    %% Load every module a real compile is known to pull in (see the
    %% "modules" mode), so that lazy code loading and its atoms stay out
    %% of the measurements.
    _ = code:ensure_modules_loaded(compiler_modules()),
    ok.

%%% ---------------------------------------------------------------------
%%% warm: single compiles with per-process GC accounting

warm_file(F, Iters) ->
    Opts = [no_spawn_compiler_process | opts(F)],
    Path = path(F),
    %% The warm-up compile of this file is recorded as iteration 0: it is the
    %% only one that shows the file's own atom-table growth.
    _ = emit(F, warm, (measure(fun() -> compile:file(Path, Opts) end))#{<<"iter">> => 0}),
    [emit(F, warm, (measure(fun() -> compile:file(Path, Opts) end))#{<<"iter">> => I})
     || I <- lists:seq(1, Iters)].

%% Run Fun in a fresh process, tracing its garbage collections, and report
%% wall time, OS CPU time, scheduler-active time, reductions, GC counts,
%% an allocation estimate and atom-table growth.
measure(Fun) ->
    flush(),
    Atoms0 = erlang:system_info(atom_count),
    _ = file:write_file("/proc/self/clear_refs", <<"5">>),
    {GcN0, GcW0, _} = erlang:statistics(garbage_collection),
    Swt0 = swt(),
    Cpu0 = os_cpu_ns(),
    {Pid, Ref} = spawn_monitor(fun() ->
                                       receive go -> ok end,
                                       T0 = erlang:monotonic_time(),
                                       R = Fun(),
                                       T1 = erlang:monotonic_time(),
                                       {reductions, Reds} = process_info(self(), reductions),
                                       {memory, Mem} = process_info(self(), memory),
                                       exit({done, T1 - T0, Reds, Mem, summarize(R)})
                               end),
    %% Trace GC in the worker and in every process spawned from now on:
    %% the epp server and the file io server do real work for a compile.
    1 = erlang:trace(Pid, true, [garbage_collection]),
    _ = erlang:trace(new_processes, true, [garbage_collection]),
    msacc_on(),
    W0 = erlang:monotonic_time(),
    Pid ! go,
    Res = receive {'DOWN', Ref, process, Pid, R0} -> R0 end,
    W1 = erlang:monotonic_time(),
    Ms = msacc_off(),
    Cpu1 = os_cpu_ns(),
    Swt1 = swt(),
    _ = erlang:trace(new_processes, false, [garbage_collection]),
    {GcN1, GcW1, _} = erlang:statistics(garbage_collection),
    Atoms1 = erlang:system_info(atom_count),
    Gc = gc_stats(drain([])),
    {InnerNative, Reds, Mem, Summary} =
        case Res of
            {done, T, Rd, M, S} -> {T, Rd, M, S};
            Other -> {0, 0, 0, fmt({crashed, Other})}
        end,
    WallUs = us(W1 - W0),
    maps:merge(Gc, Ms#{<<"wall_us">> => WallUs,
        <<"inner_us">> => us(InnerNative),
        <<"cpu_us">> => (Cpu1 - Cpu0) div 1000,
        <<"sched_active_us">> => sched_active_us(Swt0, Swt1, WallUs),
        <<"reductions">> => Reds,
        <<"proc_mem_end">> => Mem,
        <<"vm_gc_count">> => GcN1 - GcN0,
        <<"vm_gc_words_reclaimed">> => GcW1 - GcW0,
        <<"atoms_added">> => Atoms1 - Atoms0,
        <<"hwm_kb">> => hwm_kb(),
        <<"vm_mem_total">> => erlang:memory(total),
        <<"result">> => Summary}).

%% Allocation estimate: for each process, the young heap grows from the
%% live size left by one GC to the size seen at the start of the next GC;
%% summing those growths (plus heap fragments) approximates words allocated.
%% Allocation after a process's last GC is not seen (lower bound).
gc_stats(Msgs) ->
    gc_stats(Msgs, 0, 0, 0, 0, #{}).

gc_stats([{trace, P, Tag, Info}|Ms], Minor, Major, Alloc, Peak, Live)
  when Tag =:= gc_minor_start; Tag =:= gc_major_start ->
    HS = kv(heap_size, Info), MB = kv(mbuf_size, Info),
    Foot = kv(heap_block_size, Info) + kv(old_heap_block_size, Info) + MB,
    {Minor1, Major1} = case Tag of
                           gc_minor_start -> {Minor + 1, Major};
                           gc_major_start -> {Minor, Major + 1}
                       end,
    PrevLive = maps:get(P, Live, 0),
    gc_stats(Ms, Minor1, Major1, Alloc + max(0, HS + MB - PrevLive), max(Peak, Foot), Live);
gc_stats([{trace, P, Tag, Info}|Ms], Minor, Major, Alloc, Peak, Live)
  when Tag =:= gc_minor_end; Tag =:= gc_major_end ->
    gc_stats(Ms, Minor, Major, Alloc, Peak, Live#{P => kv(heap_size, Info)});
gc_stats([_|Ms], Minor, Major, Alloc, Peak, Live) ->
    gc_stats(Ms, Minor, Major, Alloc, Peak, Live);
gc_stats([], Minor, Major, Alloc, Peak, Live) ->
    #{<<"gc_minor">> => Minor, <<"gc_major">> => Major, <<"gc_processes">> => map_size(Live),
      <<"alloc_words_est">> => Alloc, <<"peak_heap_words">> => Peak}.

%% Microstate accounting (basic states): time schedulers spent in GC and
%% in the emulator while the measurement ran, summed over all threads.
msacc_on() ->
    erlang:system_flag(microstate_accounting, reset),
    erlang:system_flag(microstate_accounting, true).

msacc_off() ->
    erlang:system_flag(microstate_accounting, false),
    Stats = erlang:statistics(microstate_accounting),
    Sum = fun(Key) ->
                  lists:sum([erlang:convert_time_unit(maps:get(Key, C, 0), perf_counter, microsecond)
                             || #{counters := C} <- Stats])
          end,
    #{<<"msacc_gc_us">> => Sum(gc), <<"msacc_emulator_us">> => Sum(emulator),
      <<"msacc_aux_us">> => Sum(aux), <<"msacc_other_us">> => Sum(other),
      <<"msacc_port_us">> => Sum(port), <<"msacc_check_io_us">> => Sum(check_io)}.

kv(K, L) -> proplists:get_value(K, L, 0).

%%% ---------------------------------------------------------------------
%%% par: K workers compiling concurrently (VM-wide accounting only)

par(Files, K, Rounds) ->
    Parent = self(),
    Work = [{path(F), opts(F)} || F <- Files],
    N = K * Rounds * length(Files),
    Workers = [spawn_monitor(fun() ->
                                     receive go -> ok end,
                                     Errs = lists:sum([worker_round(Work) || _ <- lists:seq(1, Rounds)]),
                                     Parent ! {done, self(), Errs}
                             end) || _ <- lists:seq(1, K)],
    _ = file:write_file("/proc/self/clear_refs", <<"5">>),
    Atoms0 = erlang:system_info(atom_count),
    {GcN0, GcW0, _} = erlang:statistics(garbage_collection),
    Swt0 = swt(),
    Cpu0 = os_cpu_ns(),
    msacc_on(),
    W0 = erlang:monotonic_time(),
    [P ! go || {P, _} <- Workers],
    Errs = lists:sum([receive {done, P, E} -> E end || {P, _} <- Workers]),
    W1 = erlang:monotonic_time(),
    Ms = msacc_off(),
    Cpu1 = os_cpu_ns(),
    Swt1 = swt(),
    {GcN1, GcW1, _} = erlang:statistics(garbage_collection),
    Atoms1 = erlang:system_info(atom_count),
    WallUs = us(W1 - W0),
    emit(#{<<"name">> => list_to_binary(lists:join(",", [binary_to_list(name(F)) || F <- Files])),
           <<"category">> => <<"set">>},
         par,
         Ms#{<<"k">> => K, <<"rounds">> => Rounds, <<"compiles">> => N, <<"errors">> => Errs,
           <<"wall_us">> => WallUs,
           <<"compiles_per_s">> => N * 1000000 / max(1, WallUs),
           <<"cpu_us">> => (Cpu1 - Cpu0) div 1000,
           <<"sched_active_us">> => sched_active_us(Swt0, Swt1, WallUs),
           <<"vm_gc_count">> => GcN1 - GcN0,
           <<"vm_gc_words_reclaimed">> => GcW1 - GcW0,
           <<"atoms_added">> => Atoms1 - Atoms0,
           <<"hwm_kb">> => hwm_kb(),
           <<"vm_mem_total">> => erlang:memory(total)}).

worker_round(Work) ->
    lists:sum([case compile:file(P, O) of
                   {ok, _, _} -> 0;
                   {ok, _, _, _} -> 0;
                   _ -> 1
               end || {P, O} <- Work]).

%%% ---------------------------------------------------------------------
%%% passes: per-pass timings via the {time, Handler} option

passes_file(F, Iters) ->
    Parent = self(),
    Opts = [{time, fun(_File, Times) -> Parent ! {pass_times, Times} end} | opts(F)],
    Path = path(F),
    Runs = [begin
                _ = compile:file(Path, Opts),
                receive {pass_times, T} -> T end
            end || _ <- lists:seq(1, Iters + 1)],
    [_Warm | Measured] = Runs,
    PassNames = [N || {N, _, _, _} <- hd(Measured)],
    Passes = [begin
                  Ts = [us(T) || Run <- Measured, {N, T, _, _} <- Run, N =:= Name],
                  Mems = [M || Run <- Measured, {N, _, M, _} <- Run, N =:= Name],
                  #{<<"pass">> => to_bin(Name),
                    <<"median_us">> => median(Ts), <<"min_us">> => lists:min(Ts),
                    <<"out_flat_bytes">> => lists:max(Mems)}
              end || Name <- PassNames],
    Total = lists:sum([maps:get(<<"median_us">>, P) || P <- Passes]),
    Sub = sub_passes(Measured),
    emit(F, passes, #{<<"iters">> => Iters, <<"total_median_us">> => Total,
                      <<"passes">> => Passes, <<"sub_passes">> => Sub}).

%% Sub-pass times (beam_ssa_opt and friends): sum per name within a run,
%% median across runs.
sub_passes(Measured) ->
    PerRun = [lists:foldl(fun({Pass, _, _, SubTimes}, Acc) ->
                                  lists:foldl(fun({S, T}, A) ->
                                                      Key = {Pass, S},
                                                      maps:update_with(Key, fun(V) -> V + T end, T, A)
                                              end, Acc, SubTimes)
                          end, #{}, Run) || Run <- Measured],
    Keys = lists:usort(lists:append([maps:keys(M) || M <- PerRun])),
    Rows = [#{<<"pass">> => to_bin(P), <<"sub">> => to_bin(S),
              <<"median_us">> => median([us(maps:get({P, S}, M, 0)) || M <- PerRun])}
            || {P, S} <- Keys],
    lists:reverse(lists:sort(fun(A, B) -> maps:get(<<"median_us">>, A) =< maps:get(<<"median_us">>, B) end, Rows)).

%%% ---------------------------------------------------------------------
%%% tprof: call_time / call_memory attribution per module and function

tprof_file(F, Type) ->
    Opts = [no_spawn_compiler_process | opts(F)],
    Path = path(F),
    _ = compile:file(Path, Opts),
    {_Result, Profile} = tprof:profile(fun() -> compile:file(Path, Opts) end,
                                       #{type => Type, report => return, set_on_spawn => true}),
    #{all := {Type, Total, Lines}} = tprof:inspect(Profile, total, measurement),
    ByMod = lists:foldl(fun({M, _FA, _Calls, Meas, _PerCall, _Pct}, Acc) ->
                                maps:update_with(M, fun(V) -> V + Meas end, Meas, Acc)
                        end, #{}, Lines),
    Mods = lists:reverse(lists:keysort(2, maps:to_list(ByMod))),
    Top = lists:sublist(lists:reverse(lists:keysort(4, Lines)), 60),
    emit(F, tprof, #{<<"type">> => atom_to_binary(Type), <<"total">> => Total,
                     <<"by_module">> => [#{<<"module">> => atom_to_binary(M), <<"measurement">> => V,
                                           <<"pct">> => round(1000 * V / max(1, Total)) / 10}
                                         || {M, V} <- Mods, V > 0],
                     <<"top_functions">> => [#{<<"mfa">> => list_to_binary(io_lib:format("~w:~w/~w", [M, Fn, A])),
                                               <<"calls">> => C, <<"measurement">> => Meas,
                                               <<"pct">> => round(1000 * Meas / max(1, Total)) / 10}
                                             || {M, {Fn, A}, C, Meas, _, _} <- Top]}).

%%% ---------------------------------------------------------------------
%%% split: where parse_module's time goes (read, scan, preprocess, parse)

split_file(F, Iters) ->
    Path = path(F),
    Incs = [binary_to_list(D) || D <- maps:get(<<"include_dirs">>, F)],
    EppOpts = [{includes, [".", filename:dirname(Path) | Incs]}, {location, {1, 1}},
               {reserved_word_fun, fun erl_scan:f_reserved_word/1}],
    {ok, Bin} = file:read_file(Path),
    Chars = unicode:characters_to_list(Bin, utf8),
    {ok, TokForms, _} = epp:scan_file(Path, EppOpts),
    Stages =
        [{read_file, fun() -> {ok, _} = file:read_file(Path) end},
         {to_list, fun() -> unicode:characters_to_list(Bin, utf8) end},
         {scan_string, fun() -> {ok, _, _} = erl_scan:string(Chars, {1, 1}, []) end},
         {scan_string_text, fun() -> {ok, _, _} = erl_scan:string(Chars, {1, 1}, [text]) end},
         {scan_tokens_chunked, fun() -> scan_chunked(Chars) end},
         {epp_scan_file, fun() -> {ok, _, _} = epp:scan_file(Path, EppOpts) end},
         {epp_parse_file, fun() -> {ok, _} = epp:parse_file(Path, EppOpts) end},
         {parse_forms, fun() -> [erl_parse:parse_form(T) || T <- TokForms, is_list(T)] end}],
    Rows = [begin
                _ = measure(Fun),
                Ms = [measure(Fun) || _ <- lists:seq(1, Iters)],
                #{<<"stage">> => atom_to_binary(Name),
                  <<"median_us">> => median([maps:get(<<"wall_us">>, M) || M <- Ms]),
                  <<"min_us">> => lists:min([maps:get(<<"wall_us">>, M) || M <- Ms]),
                  <<"alloc_words_est">> => median([maps:get(<<"alloc_words_est">>, M) || M <- Ms]),
                  <<"gc_minor">> => median([maps:get(<<"gc_minor">>, M) || M <- Ms]),
                  <<"gc_major">> => median([maps:get(<<"gc_major">>, M) || M <- Ms]),
                  <<"peak_heap_words">> => median([maps:get(<<"peak_heap_words">>, M) || M <- Ms]),
                  <<"reductions">> => median([maps:get(<<"reductions">>, M) || M <- Ms])}
            end || {Name, Fun} <- Stages],
    {ok, Toks, _} = erl_scan:string(Chars, {1, 1}, []),
    Atoms = lists:usort([A || {atom, _, A} <- Toks]),
    Vars = lists:usort([V || {var, _, V} <- Toks]),
    emit(F, split, #{<<"iters">> => Iters, <<"bytes">> => byte_size(Bin), <<"chars">> => length(Chars),
                     <<"tokens">> => length(Toks), <<"forms">> => length(TokForms),
                     <<"unique_atoms">> => length(Atoms), <<"unique_vars">> => length(Vars),
                     <<"atom_tokens">> => length([1 || {atom, _, _} <- Toks]),
                     <<"var_tokens">> => length([1 || {var, _, _} <- Toks]),
                     <<"stages">> => Rows}).

%% Mimic the io-server driven path: erl_scan:tokens/3 fed in 1024-char chunks.
scan_chunked(Chars) ->
    scan_chunked(Chars, [], {1, 1}, 0).

scan_chunked(Chars, Cont, Loc, N) ->
    {Chunk, Rest} = split_at(1024, Chars),
    Input = case Chunk of [] -> eof; _ -> Chunk end,
    case erl_scan:tokens(Cont, Input, Loc, []) of
        {done, {ok, _Toks, EndLoc}, Left} when Left =/= eof ->
            scan_chunked(Left ++ Rest, [], EndLoc, N + 1);
        {done, {ok, _Toks, _EndLoc}, eof} -> N + 1;
        {done, {eof, _}, _} -> N;
        {done, {error, _, _}, _} -> N;
        {more, Cont1} when Input =:= eof -> error({scan_more_at_eof, Cont1, N});
        {more, Cont1} -> scan_chunked(Rest, Cont1, Loc, N)
    end.

split_at(N, L) ->
    try lists:split(N, L) catch error:badarg -> {L, []} end.

%%% ---------------------------------------------------------------------
%%% utilities

%% Modules a compile loads: from compiler_modules.txt next to ebin/ (write it
%% with the "modules" mode for the release under test), else the compiler
%% application's own module list.
compiler_modules() ->
    Dir = filename:dirname(code:which(?MODULE)),
    File = filename:join([Dir, "..", "compiler_modules.txt"]),
    case file:read_file(File) of
        {ok, Bin} -> [binary_to_atom(M) || M <- binary:split(Bin, <<"\n">>, [global, trim_all])];
        _ ->
            _ = application:load(compiler),
            case application:get_key(compiler, modules) of
                {ok, Mods} -> Mods;
                undefined -> []
            end
    end.

emit(F, Mode, Fields) ->
    Rec = Fields#{<<"mode">> => atom_to_binary(Mode),
                  <<"name">> => name(F),
                  <<"category">> => maps:get(<<"category">>, F, <<"">>),
                  <<"tag">> => list_to_binary(env("BENCH_TAG", "")),
                  <<"otp">> => list_to_binary(string:trim(erlang:system_info(system_version))),
                  <<"compiler_dir">> => list_to_binary(code:lib_dir(compiler)),
                  <<"erl_scan">> => list_to_binary(code:which(erl_scan)),
                  <<"schedulers">> => erlang:system_info(schedulers_online),
                  <<"extra_opts">> => list_to_binary(io_lib:format("~w", [extra_opts()]))},
    Line = iolist_to_binary([json:encode(Rec), "\n"]),
    io:put_chars(Line),
    case os:getenv("BENCH_OUT") of
        false -> ok;
        "" -> ok;
        Out -> ok = file:write_file(Out, Line, [append])
    end,
    Rec.

env(K, D) -> case os:getenv(K) of false -> D; V -> V end.

to_bin(A) when is_atom(A) -> atom_to_binary(A);
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(T) -> fmt(T).

summarize({ok, _, _}) -> <<"ok">>;
summarize({ok, _, _, _}) -> <<"ok">>;
summarize({ok, _}) -> <<"ok">>;
summarize(ok) -> <<"ok">>;
summarize(L) when is_list(L) -> <<"ok">>;
summarize(Other) -> fmt(Other).

fmt(T) -> list_to_binary(lists:sublist(lists:flatten(io_lib:format("~p", [T])), 400)).

us(Native) -> erlang:convert_time_unit(Native, native, microsecond).

median([]) -> 0;
median(L) ->
    S = lists:sort(L), N = length(S),
    case N rem 2 of
        1 -> lists:nth(N div 2 + 1, S);
        0 -> (lists:nth(N div 2, S) + lists:nth(N div 2 + 1, S)) / 2
    end.

flush() -> receive _ -> flush() after 0 -> ok end.
drain(Acc) -> receive M -> drain([M|Acc]) after 0 -> lists:reverse(Acc) end.

%% OS CPU time of the whole VM (all threads), in ns, from /proc/self/task/*/schedstat.
os_cpu_ns() ->
    {ok, Tasks} = file:list_dir("/proc/self/task"),
    lists:sum([case file:read_file("/proc/self/task/" ++ T ++ "/schedstat") of
                   {ok, B} -> binary_to_integer(hd(binary:split(B, <<" ">>)));
                   _ -> 0
               end || T <- Tasks]).

swt() ->
    erlang:system_flag(scheduler_wall_time, true),
    lists:sort(erlang:statistics(scheduler_wall_time)).

%% Scheduler-active time summed over schedulers, in us (Active/Total fractions
%% scaled to wall time, since the raw units are unspecified).
sched_active_us(S0, S1, WallUs) ->
    {A, T} = lists:foldl(fun({{Id, A0, T0}, {Id, A1, T1}}, {Aa, Ta}) -> {Aa + (A1 - A0), Ta + (T1 - T0)} end,
                         {0, 0}, lists:zip(S0, S1)),
    case T of 0 -> 0; _ -> round(WallUs * length(S0) * A / T) end.

hwm_kb() ->
    {ok, S} = file:read_file("/proc/self/status"),
    case [L || L <- binary:split(S, <<"\n">>, [global]), binary:part(L, 0, min(6, byte_size(L))) =:= <<"VmHWM:">>] of
        [L] -> binary_to_integer(hd(string:lexemes(binary:part(L, 6, byte_size(L) - 6), " \tkB")));
        _ -> 0
    end.
