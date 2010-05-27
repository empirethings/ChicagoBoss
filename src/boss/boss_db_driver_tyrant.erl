-module(boss_db_driver_tyrant).
-behaviour(boss_db_driver).
-export([start/0, stop/0, find/1, find/3, find/4, find/5, find/6]).
-export([count/1, count/2, counter/1, incr/1, incr/2, delete/1, save_record/1]).

-define(TRILLION, (1000 * 1000 * 1000 * 1000)).

start() ->
    medici:start().

stop() ->
    medici:stop().

find(Id) when is_list(Id) ->
    find(list_to_binary(Id));
find(<<"">>) ->
    undefined;
find(Id) when is_binary(Id) ->
    Type = infer_type_from_id(Id),
    case medici:get(Id) of
        Record when is_list(Record) ->
            case model_is_loaded(Type) of
                true ->
                    activate_record(Record, Type);
                false ->
                    {error, {module_not_loaded, Type}}
            end;
        {error, invalid_operation} ->
            undefined;
        {error, Reason} ->
            {error, Reason}
    end;

find(_Id) -> {error, invalid_id}.

find(Type, Conditions, Max) when is_atom(Type) and is_list(Conditions) and is_integer(Max) ->
    find(Type, Conditions, Max, 0).

find(Type, Conditions, Max, Skip) ->
    find(Type, Conditions, Max, Skip, primary).

find(Type, Conditions, Max, Skip, Sort) ->
    find(Type, Conditions, Max, Skip, Sort, str_ascending).

find(Type, Conditions, Max, Skip, Sort, SortOrder) ->
    case model_is_loaded(Type) of
        true ->
            Query = build_query(Type, Conditions, Max, Skip, Sort, SortOrder),
            lists:map(fun({_Id, Record}) -> activate_record(Record, Type) end,
                medici:mget(medici:search(Query)));
        false ->
            []
    end.

count(Type) ->
    count(Type, []).

count(Type, Conditions) ->
    medici:searchcount(build_conditions(Type, Conditions)).

counter(Id) when is_list(Id) ->
    counter(list_to_binary(Id));
counter(Id) when is_binary(Id) ->
    case medici:get(Id) of
        Record when is_list(Record) ->
            list_to_integer(binary_to_list(
                    proplists:get_value(<<"_num">>, Record, <<"0">>)));
        {error, _Reason} -> 0
    end.

incr(Id) ->
    medici:addint(Id, 1).

incr(Id, Count) ->
    medici:addint(Id, Count).

delete(Id) when is_list(Id) ->
    delete(list_to_binary(Id));
delete(Id) when is_binary(Id) ->
    medici:out(Id).

save_record(Record) when is_tuple(Record) ->
    Type = element(1, Record),
    Id = case Record:id() of
        id ->
            atom_to_list(Type) ++ "-" ++ binary_to_list(medici:genuid());
        Defined when is_list(Defined) ->
            Defined
    end,
    RecordWithId = Record:id(Id),
    Result = medici:put(list_to_binary(Id), pack_record(RecordWithId, Type)),
    case Result of
        ok -> {ok, RecordWithId};
        {error, Error} -> {error, [Error]}
    end.

pack_record(RecordWithId, Type) ->
    % metadata string stores the data types, <Data Type><attribute name>
    % L = list, T = time, B = binary, A = atom, I = integer, F = float
    {Columns, MetadataString} = lists:mapfoldl(fun
            (Attr, Acc) -> 
                {PackedValue, Acc1} = case RecordWithId:Attr() of
                    Val when is_list(Val) ->
                        {list_to_binary(Val), lists:concat([Attr, "L", Acc])};
                    {MegaSec, Sec, MicroSec} when is_integer(MegaSec) andalso is_integer(Sec) andalso is_integer(MicroSec) ->
                        {pack_now({MegaSec, Sec, MicroSec}), lists:concat([Attr, "T", Acc])};
                    {{_, _, _} = Date, {_, _, _} = Time} ->
                        {pack_datetime({Date, Time}), lists:concat([Attr, "T", Acc])};
                    Val when is_binary(Val) ->
                        {Val, lists:concat([Attr, "B", Acc])};
                    Val when is_integer(Val) ->
                        {list_to_binary(integer_to_list(Val)), lists:concat([Attr, "I", Acc])};
                    Val when is_float(Val) ->
                        {list_to_binary(integer_to_list(trunc(Val * ?TRILLION))), lists:concat([Attr, "F", Acc])}
                end,
                {{attribute_to_colname(Attr, Type), PackedValue}, Acc1}
        end, [], RecordWithId:attribute_names()),
    [{attribute_to_colname('_type', Type), list_to_binary(atom_to_list(Type))},
        {attribute_to_colname('_metadata', Type), list_to_binary(MetadataString)}|Columns].

infer_type_from_id(Id) when is_binary(Id) ->
    infer_type_from_id(binary_to_list(Id));
infer_type_from_id(Id) when is_list(Id) ->
    list_to_atom(hd(string:tokens(Id, "-"))).

extract_metadata(Record, Type) ->
    MetadataString = proplists:get_value(attribute_to_colname('_metadata', Type), Record),
    case MetadataString of
        undefined -> [];
        Val when is_binary(Val) -> 
            parse_metadata_string(binary_to_list(Val))
    end.

parse_metadata_string(Val) ->
    parse_metadata_string(Val, [], []).
parse_metadata_string([], [], MetadataAcc) ->
    MetadataAcc;
parse_metadata_string([H|T], NameAcc, MetadataAcc) when H >= $A, H =< $Z ->
    parse_metadata_string(T, [], [{list_to_atom(lists:reverse(NameAcc)), H}|MetadataAcc]);
parse_metadata_string([H|T], NameAcc, MetadataAcc) when H >= $a, H =< $z; H =:= $_ ->
    parse_metadata_string(T, [H|NameAcc], MetadataAcc).

activate_record(Record, Type) ->
    DummyRecord = apply(Type, new, lists:seq(1, proplists:get_value(new, Type:module_info(exports)))),
    Metadata = extract_metadata(Record, Type),
    apply(Type, new, lists:map(fun
                (Key) ->
                    Val = proplists:get_value(attribute_to_colname(Key, Type), Record, <<"">>),
                    case proplists:get_value(Key, Metadata) of
                        $B -> Val;
                        $I -> list_to_integer(binary_to_list(Val));
                        $F -> list_to_integer(binary_to_list(Val)) / ?TRILLION;
                        $T -> unpack_datetime(Val);
                        _ ->
                            case lists:suffix("_time", atom_to_list(Key)) of
                                true -> unpack_datetime(Val);
                                false -> binary_to_list(Val)
                            end
                    end
            end, DummyRecord:attribute_names())).

model_is_loaded(Type) ->
    case code:is_loaded(Type) of
        {file, _Loaded} ->
            Exports = Type:module_info(exports),
            case proplists:get_value(attribute_names, Exports) of
                1 -> true;
                _ -> false
            end;
        false -> false
    end.

attribute_to_colname(Attribute, _Type) ->
    list_to_binary(atom_to_list(Attribute)).

build_query(Type, Conditions, Max, Skip, Sort, SortOrder) ->
    Query = build_conditions(Type, Conditions),
    medici:query_order(medici:query_limit(Query, Max, Skip), atom_to_list(Sort), SortOrder).

build_conditions(Type, Conditions) ->
    lists:foldl(fun({K, V}, Acc) ->
                medici:query_add_condition(Acc, attribute_to_colname(K, Type), str_eq, [list_to_binary(V)])
        end, [], [{'_type', atom_to_list(Type)} | Conditions]).

pack_datetime({Date, Time}) ->
    list_to_binary(integer_to_list(calendar:datetime_to_gregorian_seconds({Date, Time}))).

pack_now(Now) -> pack_datetime(calendar:now_to_datetime(Now)).

unpack_datetime(<<"">>) -> calendar:gregorian_seconds_to_datetime(0);
unpack_datetime(Bin) -> calendar:universal_time_to_local_time(
        calendar:gregorian_seconds_to_datetime(list_to_integer(binary_to_list(Bin)))).