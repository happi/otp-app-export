%% lintbench.erl -- concurrent front-end work over many DISTINCT modules,
%% the pattern of a linter or language server sweeping a large code base.
%%
%%   erl +S N -noshell -pa ebin -run lintbench main FILELIST K PASSES WORK PRE [LIMIT]
%%
%% PRE is "none" or a file written by harvest.erl: its atom names are
%% created serially, in one process, before the first timed pass (the
%% control for "everything cold except the atom table").
%%
%% WORK is one of
%%   lint  epp:parse_file/2 + erl_lint:module/3 (what erlc and ELP do first)
%%   epp   epp:parse_file/2 only
%%   scan  file:read_file + unicode:characters_to_list + erl_scan:string/3
%% K workers pull file indices from a shared atomics counter. Pass 1 sees
%% the source atoms for the first time; later passes find them in the table.
%% Each pass prints one JSON line. With the lock-counting emulator
%% (cerl -lcnt) the atom_tab lock statistics are added per pass.
-module(lintbench).
-export([main/1]).

main([FileList, KS, PassesS, Work, Pre | Rest]) ->
    try run(FileList, list_to_integer(KS), list_to_integer(PassesS), list_to_atom(Work), Pre, Rest)
    catch C:R:S -> io:format(standard_error, "lintbench failed: ~p:~p~n~p~n", [C, R, S]), halt(1)
    end,
    halt(0).

run(FileList, K, Passes, Work, Pre, Rest) ->
    {ok, Bin} = file:read_file(FileList),
    All = [binary_to_list(L) || L <- binary:split(Bin, <<"\n">>, [global, trim_all])],
    Files0 = case Rest of [Lim | _] -> lists:sublist(All, list_to_integer(Lim)); [] -> All end,
    Files = list_to_tuple([{F, includes(F)} || F <- Files0]),
    %% Page cache and module loading are not what we measure.
    Bytes = lists:sum([begin {ok, B} = file:read_file(F), byte_size(B) end || {F, _} <- tuple_to_list(Files)]),
    warm_up(Work),
    PreInfo = precreate(Pre),
    Lcnt = lcnt_available(),
    [pass(P, Files, K, Work, Bytes, Lcnt, PreInfo) || P <- lists:seq(1, Passes)],
    ok.

includes(F) ->
    Dir = filename:dirname(F),
    App = filename:dirname(Dir),
    [Dir, filename:join(App, "include"), filename:join(App, "src"), App].

warm_up(Work) ->
    Src = "-module(lintbench_warm).\n-export([f/1]).\n-record(r, {a, b}).\nf(#r{a = A} = R) -> {A, R#r.b, [X || X <- [1,2]]}.\n",
    Dir = os:getenv("BENCH_SCRATCH", os:getenv("TMPDIR", "/tmp")),
    ok = filelib:ensure_path(Dir),
    F = filename:join(Dir, "lintbench_warm_" ++ os:getpid() ++ ".erl"),
    ok = file:write_file(F, Src),
    do_work(Work, F, []),
    _ = file:delete(F),
    ok.

do_work(lint, F, Incs) ->
    case epp:parse_file(F, [{includes, Incs}, {location, {1, 1}}]) of
        {ok, Forms} ->
            case erl_lint:module(Forms, F, []) of
                {ok, _} -> ok;
                {error, _, _} -> lint_error
            end;
        {error, _} -> epp_error
    end;
do_work(epp, F, Incs) ->
    case epp:parse_file(F, [{includes, Incs}, {location, {1, 1}}]) of
        {ok, _} -> ok;
        {error, _} -> epp_error
    end;
do_work(scan, F, _Incs) ->
    {ok, B} = file:read_file(F),
    case unicode:characters_to_list(B) of
        Cs when is_list(Cs) ->
            case erl_scan:string(Cs, {1, 1}, []) of
                {ok, _, _} -> ok;
                {error, _, _} -> scan_error
            end;
        _ -> not_utf8
    end.

precreate("none") -> #{<<"pre">> => <<"none">>};
precreate(NamesFile) ->
    {ok, B} = file:read_file(NamesFile),
    Names = binary_to_term(B),
    A0 = erlang:system_info(atom_count),
    T0 = erlang:monotonic_time(),
    lists:foreach(fun(N) -> _ = binary_to_atom(N, utf8) end, Names),
    T1 = erlang:monotonic_time(),
    #{<<"pre">> => <<"atoms">>, <<"pre_names">> => length(Names),
      <<"pre_atoms_added">> => erlang:system_info(atom_count) - A0,
      <<"pre_us">> => erlang:convert_time_unit(T1 - T0, native, microsecond)}.

pass(P, Files, K, Work, Bytes, Lcnt, PreInfo) ->
    N = tuple_size(Files),
    Ctr = atomics:new(1, []),
    Parent = self(),
    erlang:garbage_collect(),
    Workers = [spawn_opt(fun() ->
                                 receive go -> ok end,
                                 Res = worker(Ctr, Files, N, Work, #{}),
                                 Parent ! {done, self(), Res}
                         end, [link]) || _ <- lists:seq(1, K)],
    _ = Lcnt andalso (erts_debug:lcnt_clear() =:= ok),
    A0 = erlang:system_info(atom_count),
    Cpu0 = os_cpu_ns(),
    msacc_on(),
    {_, Gc0, _} = erlang:statistics(garbage_collection),
    T0 = erlang:monotonic_time(),
    [W ! go || W <- Workers],
    Results = [receive {done, W, R} -> R end || W <- Workers],
    T1 = erlang:monotonic_time(),
    {_, Gc1, _} = erlang:statistics(garbage_collection),
    Ms = msacc_off(),
    Cpu1 = os_cpu_ns(),
    A1 = erlang:system_info(atom_count),
    LcntRes = case Lcnt of true -> lcnt_atom_tab(); false -> #{} end,
    Outcomes = lists:foldl(fun(M, Acc) -> maps:fold(fun(Kk, V, A) -> maps:update_with(Kk, fun(X) -> X + V end, V, A) end, Acc, M) end,
                           #{}, Results),
    WallUs = erlang:convert_time_unit(T1 - T0, native, microsecond),
    Rec = maps:merge(maps:merge(Ms, PreInfo), LcntRes#{
            <<"pass">> => P, <<"k">> => K, <<"work">> => atom_to_binary(Work),
            <<"files">> => N, <<"bytes">> => Bytes,
            <<"wall_us">> => WallUs,
            <<"files_per_s">> => N * 1.0e6 / WallUs,
            <<"mb_per_s">> => Bytes / WallUs,
            <<"cpu_us">> => (Cpu1 - Cpu0) div 1000,
            <<"atoms_added">> => A1 - A0, <<"atom_count">> => A1,
            <<"gc_words_reclaimed">> => Gc1 - Gc0,
            <<"outcomes">> => maps:from_list([{atom_to_binary(Kk), V} || Kk := V <- Outcomes]),
            <<"schedulers">> => erlang:system_info(schedulers_online),
            <<"lcnt">> => Lcnt,
            <<"tag">> => list_to_binary(os:getenv("BENCH_TAG", "")),
            <<"otp">> => list_to_binary(string:trim(erlang:system_info(system_version)))}),
    Line = iolist_to_binary([json:encode(Rec), "\n"]),
    io:put_chars(Line),
    case os:getenv("BENCH_OUT") of
        false -> ok;
        Out -> ok = file:write_file(Out, Line, [append])
    end.

worker(Ctr, Files, N, Work, Acc) ->
    I = atomics:add_get(Ctr, 1, 1),
    if
        I > N -> Acc;
        true ->
            {F, Incs} = element(I, Files),
            R = try do_work(Work, F, Incs) catch _:_ -> crashed end,
            worker(Ctr, Files, N, Work, maps:update_with(R, fun(X) -> X + 1 end, 1, Acc))
    end.

%%% lock counting

lcnt_available() ->
    try erlang:system_info(lock_counting) catch _:_ -> false end.

%% Pull atom_tab statistics out of the raw lcnt data: tries, collisions and
%% accumulated wait time, split by acquisition site (atom.c line).
lcnt_atom_tab() ->
    Locks = proplists:get_value(locks, erts_debug:lcnt_collect()),
    case [L || L <- Locks, element(1, L) =:= atom_tab] of
        [{atom_tab, _Id, _Type, Stats}] -> lcnt_stats(Stats);
        Other -> #{<<"lcnt_error">> => list_to_binary(io_lib:format("~p", [Other]))}
    end.

%% Per acquisition site: {{File, Line}, {Tries, Colls, {S, Ns, N}}, Histogram}.
%% atom.c:290 is the read-locked lookup, atom.c:330 the write-locked insert.
lcnt_stats(Stats) ->
    Rows = [#{<<"site">> => list_to_binary(io_lib:format("~s:~w", [F, L])),
              <<"tries">> => Tr, <<"colls">> => Co, <<"wait_us">> => (S * 1000000) + (Ns div 1000),
              <<"hist_log2_us">> => tuple_to_list(H)}
            || {{F, L}, {Tr, Co, {S, Ns, _N}}, H} <- Stats, Tr > 0],
    #{<<"atom_tab_tries">> => lists:sum([maps:get(<<"tries">>, R) || R <- Rows]),
      <<"atom_tab_colls">> => lists:sum([maps:get(<<"colls">>, R) || R <- Rows]),
      <<"atom_tab_wait_us">> => lists:sum([maps:get(<<"wait_us">>, R) || R <- Rows]),
      <<"atom_tab_sites">> => Rows}.

%%% accounting

msacc_on() ->
    erlang:system_flag(microstate_accounting, reset),
    erlang:system_flag(microstate_accounting, true).

msacc_off() ->
    erlang:system_flag(microstate_accounting, false),
    Stats = erlang:statistics(microstate_accounting),
    Sum = fun(Key, Types) ->
                  lists:sum([erlang:convert_time_unit(maps:get(Key, C, 0), perf_counter, microsecond)
                             || #{type := T, counters := C} <- Stats, lists:member(T, Types)])
          end,
    Sch = [scheduler],
    #{<<"sched_emulator_us">> => Sum(emulator, Sch), <<"sched_gc_us">> => Sum(gc, Sch),
      <<"sched_other_us">> => Sum(other, Sch), <<"sched_aux_us">> => Sum(aux, Sch),
      <<"sched_sleep_us">> => Sum(sleep, Sch), <<"sched_busy_wait_us">> => Sum(busy_wait, Sch),
      <<"sched_check_io_us">> => Sum(check_io, Sch), <<"sched_port_us">> => Sum(port, Sch)}.

os_cpu_ns() ->
    {ok, Tasks} = file:list_dir("/proc/self/task"),
    lists:sum([case file:read_file("/proc/self/task/" ++ T ++ "/schedstat") of
                   {ok, B} -> binary_to_integer(hd(binary:split(B, <<" ">>)));
                   _ -> 0
               end || T <- Tasks]).
