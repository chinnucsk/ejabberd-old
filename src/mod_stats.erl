%%%----------------------------------------------------------------------
%%% File    : mod_stats.erl
%%% Author  : Alexey Shchepin <alexey@sevcom.net>
%%% Purpose : 
%%% Created : 11 Jan 2003 by Alexey Shchepin <alexey@sevcom.net>
%%% Id      : $Id$
%%%----------------------------------------------------------------------

-module(mod_stats).
-author('alexey@sevcom.net').
-vsn('$Revision$ ').

-export([start/0,
	 process_local_iq/3]).

-include("namespaces.hrl").

start() ->
    ejabberd_local:register_iq_handler(?NS_STATS, ?MODULE, process_local_iq).


process_local_iq(From, To, {iq, ID, Type, XMLNS, SubEl}) ->
    Lang = xml:get_tag_attr_s("xml:lang", SubEl),
    case Type of
	set ->
	    {iq, ID, error, XMLNS, [SubEl, {xmlelement, "error",
					    [{"code", "405"}],
					    [{xmlcdata, "Not Allowed"}]}]};
	get ->
	    {xmlelement, _, Attrs, Els} = SubEl,
	    Node = string:tokens(xml:get_tag_attr_s("node", SubEl), "/"),
	    Names = get_names(Els, []),
	    
	    case get_local_stats(Node, Names) of
		{result, Res} ->
		    {iq, ID, result, XMLNS,
		     [{xmlelement, "query", [{"xmlns", XMLNS}], Res}]};
		{error, Code, Desc} ->
		    {iq, ID, error, XMLNS,
		     [SubEl, {xmlelement, "error",
			      [{"code", Code}],
			      [{xmlcdata, Desc}]}]}
	    end
    end.


get_names([], Res) ->
    Res;
get_names([{xmlelement, "stat", Attrs, _} | Els], Res) ->
    Name = xml:get_attr_s("name", Attrs),
    case Name of
	"" ->
	    get_names(Els, Res);
	_ ->
	    get_names(Els, [Name | Res])
    end;
get_names([_ | Els], Res) ->
    get_names(Els, Res).


-define(STAT(Name), {xmlelement, "stat", [{"name", Name}], []}).

get_local_stats([], []) ->
    {result,
     [?STAT("users/online"),
      ?STAT("users/total")
     ]};

get_local_stats([], Names) ->
    {result, lists:map(fun(Name) -> get_local_stat([], Name) end, Names)};

get_local_stats(["running nodes", _], []) ->
    {result,
     [?STAT("time/uptime"),
      ?STAT("time/cputime"),
      ?STAT("users/online")
     ]};

get_local_stats(["running nodes", ENode], Names) ->
    case search_running_node(ENode) of
	false ->
	    {error, "404", "Not Found"};
	Node ->
	    {result,
	     lists:map(fun(Name) -> get_node_stat(Node, Name) end, Names)}
    end;

get_local_stats(_, _) ->
    {error, "501", "Not Implemented"}.



-define(STATVAL(Val, Unit),
	{xmlelement, "stat",
	 [{"name", Name},
	  {"units", Unit},
	  {"value", Val}
	 ], []}).

-define(STATERR(Code, Desc),
	{xmlelement, "stat",
	 [{"name", Name}],
	 [{xmlelement, "error",
	   [{"code", Code}],
	   [{xmlcdata, Desc}]}]}).


%get_local_stat([], Name) when Name == "time/uptime" ->
%    ?STATVAL(io_lib:format("~.3f", [element(1, statistics(wall_clock))/1000]),
%	     "seconds");
%get_local_stat([], Name) when Name == "time/cputime" ->
%    ?STATVAL(io_lib:format("~.3f", [element(1, statistics(runtime))/1000]),
%	     "seconds");
get_local_stat([], Name) when Name == "users/online" ->
    case catch ejabberd_sm:dirty_get_sessions_list() of
	{'EXIT', Reason} ->
	    ?STATERR("500", "Internal Server Error");
	Users ->
	    ?STATVAL(integer_to_list(length(Users)), "users")
    end;
get_local_stat([], Name) when Name == "users/total" ->
    case catch ejabberd_auth:dirty_get_registered_users() of
	{'EXIT', Reason} ->
	    ?STATERR("500", "Internal Server Error");
	Users ->
	    ?STATVAL(integer_to_list(length(Users)), "users")
    end;
get_local_stat(_, Name) ->
    ?STATERR("404", "Not Found").



get_node_stat(Node, Name) when Name == "time/uptime" ->
    case catch rpc:call(Node, erlang, statistics, [wall_clock]) of
	{badrpc, Reason} ->
	    ?STATERR("500", "Internal Server Error");
	CPUTime ->
	    ?STATVAL(
	       io_lib:format("~.3f", [element(1, CPUTime)/1000]), "seconds")
    end;

get_node_stat(Node, Name) when Name == "time/cputime" ->
    case catch rpc:call(Node, erlang, statistics, [runtime]) of
	{badrpc, Reason} ->
	    ?STATERR("500", "Internal Server Error");
	RunTime ->
	    ?STATVAL(
	       io_lib:format("~.3f", [element(1, RunTime)/1000]), "seconds")
    end;

get_node_stat(Node, Name) when Name == "users/online" ->
    case catch rpc:call(Node, ejabberd_sm, dirty_get_my_sessions_list, []) of
	{badrpc, Reason} ->
	    ?STATERR("500", "Internal Server Error");
	Users ->
	    ?STATVAL(integer_to_list(length(Users)), "users")
    end;
get_node_stat(_, Name) ->
    ?STATERR("404", "Not Found").


search_running_node(SNode) ->
    search_running_node(SNode, mnesia:system_info(running_db_nodes)).

search_running_node(_, []) ->
    false;
search_running_node(SNode, [Node | Nodes]) ->
    case atom_to_list(Node) of
	SNode ->
	    Node;
	_ ->
	    search_running_node(SNode, Nodes)
    end.
