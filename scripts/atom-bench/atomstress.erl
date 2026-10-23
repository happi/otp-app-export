%% atomstress.erl -- isolate the atom table's lookup/insert interaction.
%%
%%   erl +S N +t 4000000 -noshell -pa ebin -run atomstress main stall R W MS
%%       R reader processes call binary_to_atom/2 on EXISTING atoms; W writer
%%       processes create NEW atoms as fast as they can; run for MS ms.
%%       Reports reader throughput, reader latency histogram (log2 ns), and
%%       writer throughput.
%%   erl ... -run atomstress main inserts N
%%       one process creates N new atoms; reports per-insert latency
%%       percentiles and the slowest inserts with the table size at the time
%%       (hash-table growth rehashes the whole table under the write lock).
%%
%% Atom names are built at run time, so nothing is constant-folded.
-module(atomstress).
-export([main/1]).

main(["stall", RS, WS, MsS]) -> stall(list_to_integer(RS), list_to_integer(WS), list_to_integer(MsS)), halt();
main(["inserts", NS]) -> inserts(list_to_integer(NS)), halt().

%%% readers vs writers

stall(R, W, Ms) ->
    Pool = list_to_tuple([binary_to_atom(name(<<"existing_">>, I), utf8) || I <- lists:seq(1, 4096)]),
    PoolB = list_to_tuple([atom_to_binary(A) || A <- tuple_to_list(Pool)]),
    Parent = self(),
    Stop = atomics:new(1, []),
    Readers = [spawn_opt(fun() -> receive go -> ok end, Parent ! {reader, reader(PoolB, Stop, I, 0, #{}, 0)} end,
                         [link, {priority, normal}]) || I <- lists:seq(1, R)],
    Writers = [spawn_opt(fun() -> receive go -> ok end, Parent ! {writer, writer(Stop, J, 0)} end, [link])
               || J <- lists:seq(1, W)],
    A0 = erlang:system_info(atom_count),
    T0 = erlang:monotonic_time(),
    [P ! go || P <- Readers ++ Writers],
    timer:sleep(Ms),
    atomics:put(Stop, 1, 1),
    RRes = [receive {reader, X} -> X end || _ <- Readers],
    WRes = [receive {writer, X} -> X end || _ <- Writers],
    T1 = erlang:monotonic_time(),
    ElapsedUs = erlang:convert_time_unit(T1 - T0, native, microsecond),
    Ops = lists:sum([N || {N, _, _} <- RRes]),
    Hist = lists:foldl(fun({_, H, _}, Acc) -> maps:merge_with(fun(_, X, Y) -> X + Y end, H, Acc) end, #{}, RRes),
    MaxNs = lists:max([0 | [M || {_, _, M} <- RRes]]),
    Ins = lists:sum(WRes),
    Rec = #{<<"mode">> => <<"stall">>, <<"readers">> => R, <<"writers">> => W, <<"ms">> => Ms,
            <<"elapsed_us">> => ElapsedUs,
            <<"reader_ops">> => Ops, <<"reader_mops">> => Ops / ElapsedUs,
            <<"reader_ns_per_op">> => case Ops of 0 -> 0; _ -> R * ElapsedUs * 1000 / Ops end,
            <<"reader_max_ns">> => MaxNs,
            <<"reader_hist_log2ns">> => [#{<<"le_ns">> => 1 bsl B, <<"n">> => N} || {B, N} <- lists:sort(maps:to_list(Hist))],
            <<"reader_p99_ns">> => pct(Hist, 0.99), <<"reader_p999_ns">> => pct(Hist, 0.999),
            <<"inserts">> => Ins, <<"inserts_per_s">> => Ins * 1.0e6 / ElapsedUs,
            <<"atoms_added">> => erlang:system_info(atom_count) - A0,
            <<"schedulers">> => erlang:system_info(schedulers_online),
            <<"tag">> => list_to_binary(os:getenv("BENCH_TAG", "")),
            <<"otp">> => list_to_binary(string:trim(erlang:system_info(system_version)))},
    emit(Rec).

%% Timestamp every 64th call (timing every call would dominate); the
%% histogram therefore holds the latency of single lookups sampled 1/64.
reader(PoolB, Stop, Seed, N, Hist, Max) ->
    case N band 4095 of
        0 -> case atomics:get(Stop, 1) of
                 1 -> {N, Hist, Max};
                 _ -> reader1(PoolB, Stop, Seed, N, Hist, Max)
             end;
        _ -> reader1(PoolB, Stop, Seed, N, Hist, Max)
    end.

reader1(PoolB, Stop, Seed, N, Hist, Max) ->
    B = element(((N * 7919 + Seed * 104729) band 4095) + 1, PoolB),
    case N band 63 of
        0 ->
            T0 = erlang:monotonic_time(nanosecond),
            _ = binary_to_atom(B, utf8),
            D = erlang:monotonic_time(nanosecond) - T0,
            Bucket = bucket(D),
            reader(PoolB, Stop, Seed, N + 1, Hist#{Bucket => maps:get(Bucket, Hist, 0) + 1}, max(Max, D));
        _ ->
            _ = binary_to_atom(B, utf8),
            reader(PoolB, Stop, Seed, N + 1, Hist, Max)
    end.

writer(Stop, J, N) ->
    case N band 255 of
        0 -> case atomics:get(Stop, 1) of
                 1 -> N;
                 _ -> _ = binary_to_atom(name(<<"w", (integer_to_binary(J))/binary, "_">>, N), utf8), writer(Stop, J, N + 1)
             end;
        _ -> _ = binary_to_atom(name(<<"w", (integer_to_binary(J))/binary, "_">>, N), utf8), writer(Stop, J, N + 1)
    end.

%%% single-process insert latency

inserts(N) ->
    Names = [name(<<"ins_">>, I) || I <- lists:seq(1, N)],
    A0 = erlang:system_info(atom_count),
    {Lat, _} = lists:foldl(fun(B, {Acc, I}) ->
                                   T0 = erlang:monotonic_time(nanosecond),
                                   _ = binary_to_atom(B, utf8),
                                   D = erlang:monotonic_time(nanosecond) - T0,
                                   {[{D, A0 + I} | Acc], I + 1}
                           end, {[], 1}, Names),
    Sorted = lists:sort([D || {D, _} <- Lat]),
    Len = length(Sorted),
    P = fun(Q) -> lists:nth(max(1, round(Q * Len)), Sorted) end,
    Slowest = lists:sublist(lists:reverse(lists:keysort(1, Lat)), 15),
    emit(#{<<"mode">> => <<"inserts">>, <<"n">> => N, <<"start_atom_count">> => A0,
           <<"mean_ns">> => lists:sum(Sorted) / Len, <<"p50_ns">> => P(0.5), <<"p99_ns">> => P(0.99),
           <<"p9999_ns">> => P(0.9999), <<"max_ns">> => lists:last(Sorted),
           <<"slowest">> => [#{<<"ns">> => D, <<"atom_count">> => C} || {D, C} <- Slowest],
           <<"otp">> => list_to_binary(string:trim(erlang:system_info(system_version)))}).

%%% helpers

name(Prefix, I) -> <<Prefix/binary, (integer_to_binary(I))/binary, "_abcdef">>.

bucket(D) when D =< 1 -> 0;
bucket(D) -> bucket(D, 0).
bucket(D, B) when (1 bsl B) >= D -> B;
bucket(D, B) -> bucket(D, B + 1).

pct(Hist, Q) ->
    L = lists:sort(maps:to_list(Hist)),
    Total = lists:sum([N || {_, N} <- L]),
    pct(L, Q * Total, 0).
pct([{B, N} | Rest], Target, Acc) ->
    case Acc + N >= Target of true -> 1 bsl B; false -> pct(Rest, Target, Acc + N) end;
pct([], _, _) -> 0.

emit(Rec) ->
    Line = iolist_to_binary([json:encode(Rec), "\n"]),
    io:put_chars(Line),
    case os:getenv("BENCH_OUT") of false -> ok; Out -> ok = file:write_file(Out, Line, [append]) end.
