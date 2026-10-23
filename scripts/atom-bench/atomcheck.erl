%% atomcheck.erl -- concurrent correctness check for atom creation/lookup.
%%
%%   erl +S 16 +t 4000000 -noshell -pa ebin -run atomcheck main P N ROUNDS
%%
%% P processes each walk the same N names in a different order, calling
%% binary_to_atom/2, list_to_atom/1 and *_to_existing_atom on names they
%% (or a peer) created, while the table grows through several rehashes.
%% Checks: every call returns the atom whose text is the name; an atom
%% created by any process is found by list_to_existing_atom in every
%% process afterwards; atom_count grows by exactly the number of distinct
%% new names. Exit status 0 on success.
-module(atomcheck).
-export([main/1]).

main(["collide", PS, KS]) ->
    %% hashpjw: "aQ" and "bA" both contribute 97*16+81 = 98*16+65, so all
    %% 2^K concatenations of K such blocks share one hash value and one
    %% chain, which exercises the long-chain fallback of the lock-free path.
    P = list_to_integer(PS), K = list_to_integer(KS),
    Names0 = lists:foldl(fun(_, Acc) -> [<<X/binary, B/binary>> || X <- Acc, B <- [<<"aQ">>, <<"bA">>]] end, [<<"c">>], lists:seq(1, K)),
    Names = list_to_tuple(Names0),
    N = tuple_size(Names),
    A0 = erlang:system_info(atom_count),
    Parent = self(),
    Pids = [spawn_link(fun() -> Parent ! {self(), worker(Names, N, W, P)} end) || W <- lists:seq(1, P)],
    Errs = lists:append([receive {Pid, E} -> E end || Pid <- Pids]),
    Added = erlang:system_info(atom_count) - A0,
    Missing = [I || I <- lists:seq(1, N), try binary_to_existing_atom(element(I, Names)) of A -> atom_to_binary(A) =/= element(I, Names) catch error:badarg -> true end],
    case {Errs, Missing, Added} of
        {[], [], N} -> io:format("atomcheck collide ok: ~w procs x ~w colliding names~n", [P, N]), halt(0);
        Other -> io:format("atomcheck collide FAILED: ~P~n", [Other, 20]), halt(1)
    end;
main([PS, NS, RS]) ->
    P = list_to_integer(PS), N = list_to_integer(NS), Rounds = list_to_integer(RS),
    Res = [round(P, N, R) || R <- lists:seq(1, Rounds)],
    case lists:all(fun(X) -> X =:= ok end, Res) of
        true -> io:format("atomcheck ok: ~w rounds x ~w procs x ~w names~n", [Rounds, P, N]), halt(0);
        false -> io:format("atomcheck FAILED: ~p~n", [Res]), halt(1)
    end.

round(P, N, R) ->
    Prefix = <<"chk", (integer_to_binary(R))/binary, "_">>,
    Names = list_to_tuple([<<Prefix/binary, (integer_to_binary(I))/binary, "_", (unicode:characters_to_binary([16#e5 + (I rem 3)]))/binary>>
                           || I <- lists:seq(1, N)]),
    A0 = erlang:system_info(atom_count),
    Parent = self(),
    Pids = [spawn_link(fun() -> Parent ! {self(), worker(Names, N, W, P)} end) || W <- lists:seq(1, P)],
    Errs = lists:append([receive {Pid, E} -> E end || Pid <- Pids]),
    A1 = erlang:system_info(atom_count),
    %% After everyone is done, every name must exist and map back.
    Missing = [I || I <- lists:seq(1, N),
                    try binary_to_existing_atom(element(I, Names), utf8) of
                        A -> atom_to_binary(A, utf8) =/= element(I, Names)
                    catch error:badarg -> true end],
    case {Errs, Missing, A1 - A0} of
        {[], [], N} -> ok;
        Other -> {round, R, Other}
    end.

%% Each worker visits the names in a stride order of its own, so creation
%% and lookup of the same names interleave across processes.
worker(Names, N, W, P) ->
    Stride = pick_stride(N, W),
    lists:foldl(fun(K, Errs) ->
                        I = ((K * Stride + W * 7) rem N) + 1,
                        B = element(I, Names),
                        A = case (K + W) rem 3 of
                                0 -> binary_to_atom(B, utf8);
                                1 -> list_to_atom(unicode:characters_to_list(B, utf8));
                                2 -> binary_to_atom(B)
                            end,
                        Errs1 = case atom_to_binary(A, utf8) of
                                    B -> Errs;
                                    Got -> [{wrong_atom, I, B, Got} | Errs]
                                end,
                        %% A name visited by a peer at least P strides ago must
                        %% already exist; check with the existing-atom BIFs.
                        J = ((max(0, K - P) * Stride + W * 7) rem N) + 1,
                        BJ = element(J, Names),
                        try binary_to_existing_atom(BJ, utf8) of
                            AJ -> case atom_to_binary(AJ, utf8) of BJ -> Errs1; G -> [{wrong_existing, J, G} | Errs1] end
                        catch error:badarg ->
                                case K >= P of
                                    true -> [{missing_existing, J} | Errs1];
                                    false -> Errs1
                                end
                        end
                end, [], lists:seq(0, N - 1)).

pick_stride(N, W) ->
    next_coprime(7919 * W + 1, N).

next_coprime(S, N) ->
    case gcd(S, N) of 1 -> S; _ -> next_coprime(S + 1, N) end.

gcd(A, 0) -> A;
gcd(A, B) -> gcd(B, A rem B).
