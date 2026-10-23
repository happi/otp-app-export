%% harvest.erl -- collect every atom and variable name that scanning the
%% given files (and all .hrl files under the given roots) would create.
%%   erl -noshell -pa ebin -run harvest main FILELIST OUTFILE ROOT...
-module(harvest).
-export([main/1]).
main([FileList, Out | Roots]) ->
    {ok, Bin} = file:read_file(FileList),
    Erls = [binary_to_list(L) || L <- binary:split(Bin, <<"\n">>, [global, trim_all])],
    Hrls = lists:append([filelib:wildcard(filename:join(R, "**/*.hrl")) || R <- Roots]),
    Names = lists:foldl(fun(F, Acc) -> names(F, Acc) end, #{}, Erls ++ Hrls),
    L = lists:sort(maps:keys(Names)),
    ok = file:write_file(Out, term_to_binary([atom_to_binary(A) || A <- L])),
    io:format("~w files, ~w hrl, ~w unique names~n", [length(Erls), length(Hrls), length(L)]),
    halt().
names(F, Acc) ->
    case file:read_file(F) of
        {ok, B} ->
            case unicode:characters_to_list(B) of
                Cs when is_list(Cs) ->
                    case erl_scan:string(Cs, 1, []) of
                        {ok, Toks, _} -> lists:foldl(fun({atom, _, A}, M) -> M#{A => 1};
                                                        ({var, _, V}, M) -> M#{V => 1};
                                                        (_, M) -> M end, Acc, Toks);
                        _ -> Acc
                    end;
                _ -> Acc
            end;
        _ -> Acc
    end.
