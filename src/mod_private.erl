%%%----------------------------------------------------------------------
%%% File    : mod_private.erl
%%% Author  : Alexey Shchepin <alexey@sevcom.net>
%%% Purpose : 
%%% Created : 16 Jan 2003 by Alexey Shchepin <alexey@sevcom.net>
%%% Id      : $Id$
%%%----------------------------------------------------------------------

-module(mod_private).
-author('alexey@sevcom.net').
-vsn('$Revision$ ').

-export([start/0,
	 process_local_iq/3]).

-include("ejabberd.hrl").
-include("namespaces.hrl").

-record(private_storage, {userns, xml}).

start() ->
    mnesia:create_table(private_storage,
			[{disc_only_copies, [node()]},
			 {attributes, record_info(fields, private_storage)}]),
    ejabberd_local:register_iq_handler(?NS_PRIVATE, ?MODULE, process_local_iq).


process_local_iq(From, To, {iq, ID, Type, XMLNS, SubEl}) ->
    {User, Server, _} = From,
    LUser = jlib:tolower(User),
    LServer = jlib:tolower(Server),
    case ?MYNAME of
	Server ->
	    {xmlelement, Name, Attrs, Els} = SubEl,
	    case Type of
		set ->
		    F = fun() ->
				lists:foreach(
				  fun(El) ->
					  set_data(LUser, El)
				  end, Els)
			end,
		    mnesia:transaction(F),
		    {iq, ID, result, XMLNS, [{xmlelement, Name, Attrs, []}]};
		get ->
		    case catch get_data(LUser, Els) of
			{'EXIT', Reason} ->
			    {iq, ID, error, XMLNS,
			     [SubEl, {xmlelement, "error",
				      [{"code", "500"}],
				      [{xmlcdata, "Internal Server Error"}]}]};
			Res ->
			    {iq, ID, error, XMLNS,
			     [{xmlelement, Name, Attrs, Res}]}
		    end
	    end;
	_ ->
	    {iq, ID, error, XMLNS, [SubEl, {xmlelement, "error",
					    [{"code", "405"}],
					    [{xmlcdata, "Not Allowed"}]}]}
    end.

set_data(LUser, El) ->
    case El of
	{xmlelement, Name, Attrs, Els} ->
	    XMLNS = xml:get_attr_s("xmlns", Attrs),
	    case XMLNS of
		"" ->
		    ignore;
		_ ->
		    mnesia:write(#private_storage{userns = {LUser, XMLNS},
						  xml = El})
	    end;
	_ ->
	    ignore
    end.

get_data(LUser, Els) ->
    get_data(LUser, Els, []).

get_data(LUser, [], Res) ->
    lists:reverse(Res);
get_data(LUser, [El | Els], Res) ->
    case El of
	{xmlelement, Name, Attrs, _} ->
	    XMLNS = xml:get_attr_s("xmlns", Attrs),
	    case mnesia:dirty_read(private_storage, {LUser, XMLNS}) of
		[R] ->
		    get_data(LUser, Els, [R#private_storage.xml | Res]);
		[] ->
		    get_data(LUser, Els, [El | Res])
	    end;
	_ ->
	    get_data(LUser, Els, Res)
    end.