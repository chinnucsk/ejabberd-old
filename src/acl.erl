%%%----------------------------------------------------------------------
%%% File    : acl.erl
%%% Author  : Alexey Shchepin <alexey@sevcom.net>
%%% Purpose : 
%%% Created : 18 Jan 2003 by Alexey Shchepin <alexey@sevcom.net>
%%% Id      : $Id$
%%%----------------------------------------------------------------------

-module(acl).
-author('alexey@sevcom.net').
-vsn('$Revision$ ').

-export([start/0, add/2, match_rule/2, match_acl/2]).

-include("ejabberd.hrl").

start() ->
    ets:new(acls, [bag, named_table, public]),
    ok.


add(ACLName, ACLData) ->
    ets:insert(acls, {ACLName, ACLData}).

match_rule(Rule, JID) ->
    case ejabberd_config:get_global_option({access, Rule}) of
	undefined ->
	    deny;
	ACLs ->
	    match_acls(ACLs, JID)
    end.

match_acls([], _) ->
    deny;
match_acls([{Access, ACL} | ACLs], JID) ->
    case match_acl(ACL, JID) of
	true ->
	    Access;
	_ ->
	    match_acls(ACLs, JID)
    end.

match_acl(ACL, JID) ->
    {User, Server, Resource} = jlib:jid_tolower(JID),
    lists:any(fun({_, Spec}) ->
		      case Spec of
			  all ->
			      true;
			  {user, U} ->
			      (U == User) and (?MYNAME == Server);
			  {user, U, S} ->
			      (U == User) and (S == Server);
			  {server, S} ->
			      S == Server
		      end
	      end, ets:lookup(acls, ACL)).