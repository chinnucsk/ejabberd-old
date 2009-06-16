%%%----------------------------------------------------------------------
%%% File    : ejabberd_http_bind.erl
%%% Author  : Stefan Strigler <steve@zeank.in-berlin.de>
%%% Purpose : HTTP Binding support (JEP-0124)
%%% Created : 21 Sep 2005 by Stefan Strigler <steve@zeank.in-berlin.de>
%%% Id      : $Id: $
%%%----------------------------------------------------------------------

-module(ejabberd_http_bind).
-author('steve@zeank.in-berlin.de').
-vsn('Revision: 1.4').

-behaviour(gen_fsm).

%% External exports
-export([start_link/2,
	 init/1,
	 handle_event/3,
	 handle_sync_event/4,
	 code_change/4,
	 handle_info/3,
	 terminate/3,
	 send/2,
	 setopts/2,
	 controlling_process/2,
	 close/1,
	 process_request/1]).

%%-define(ejabberd_debug, true).

-include("ejabberd.hrl").
-include("jlib.hrl").
-include("ejabberd_http.hrl").

-record(http_bind, {id, pid, to, hold, wait}).

%% http binding request
-record(hbr, {rid,
	      key,
	      in,
	      out}).

-record(state, {id,
		rid = error,
		key,
		output = "",
		input = "",
		waiting_input = false,
		last_receiver,
		last_poll,
		ctime = 0,
		timer,
		req_list = [] % list of requests
	       }).


%-define(DBGFSM, true).

-ifdef(DBGFSM).
-define(FSMOPTS, [{debug, [trace]}]).
-else.
-define(FSMOPTS, []).
-endif.

-define(MAX_REQUESTS, 2).  % number of simultaneous requests
-define(MIN_POLLING, "2"). % don't poll faster than that or we will shoot you
-define(MAX_WAIT, 60).     % max num of secs to keep a request on hold
-define(MAX_INACTIVITY, 30000). % msecs to wait before terminating idle sessions
-define(CT, {"Content-Type", "text/xml; charset=utf-8"}).
-define(BAD_REQUEST, ?CT).


%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
start(ID, Key) ->
    mnesia:create_table(http_bind,
        		[{ram_copies, [node()]},
        		 {attributes, record_info(fields, http_bind)}]),
    supervisor:start_child(ejabberd_http_bind_sup, [ID, Key]).

start_link(ID, Key) ->
    gen_fsm:start_link(?MODULE, [ID, Key], ?FSMOPTS).

send({http_bind, FsmRef}, Packet) ->
    gen_fsm:sync_send_all_state_event(FsmRef, {send, Packet}).

setopts({http_bind, FsmRef}, Opts) ->
    case lists:member({active, once}, Opts) of
	true ->
	    gen_fsm:sync_send_all_state_event(FsmRef, activate);
	_ ->
	    ok
    end.

controlling_process(_Socket, _Pid) ->
    ok.

close({http_bind, FsmRef}) ->
    catch gen_fsm:sync_send_all_state_event(FsmRef, close).


process_request(#request{path = [],
			 data = Data}) ->
    case catch parse_request(Data) of
	{ok, ID1, RID, Key, NewKey, Attrs, Packet} ->
	    XmppDomain = xml:get_attr_s("to",Attrs),
	    if 
		(ID1 == "") and (XmppDomain == "") ->
		    {200, [?CT], "<body type='terminate' "
		     "condition='improper-addressing' "
		     "xmlns='http://jabber.org/protocol/httpbind'/>"};
		true ->
	    ID = if
		     (ID1 == "") ->
			 %% create new session
			 NewID = sha:sha(term_to_binary({now(), make_ref()})),
			 {ok, Pid} = start(NewID, Key),
			 Wait = case
				    string:to_integer(xml:get_attr_s("wait",Attrs))
				    of
				    {error, _} ->
					?MAX_WAIT;
				    {CWait, _} ->
					if 
					    (CWait > ?MAX_WAIT) ->
						?MAX_WAIT;
					    true ->
						CWait
					end
				end,
			 Hold = case
				    string:to_integer(
				      xml:get_attr_s("hold",Attrs))
				    of
				    {error, _} ->
					(?MAX_REQUESTS - 1);
				    {CHold, _} ->
					if 
					    (CHold > (?MAX_REQUESTS - 1)) ->
						(?MAX_REQUESTS - 1);
					    true ->
						CHold
					end
				end,
			 mnesia:transaction(
			   fun() ->
				   mnesia:write(#http_bind{id = NewID,
							   pid = Pid,
                                                           to = XmppDomain,
							   wait = Wait,
							   hold = Hold})
			   end),
			 StreamStart = if
                                           (XmppDomain /= "") ->
                                               true;
                                           true ->
                                               false
				    end,
                         InPacket = Packet,
			 NewID;
		     true ->
			 %% old session
			 Type = xml:get_attr_s("type",Attrs),
                         StreamStart =  
                             case xml:get_attr_s("xmpp:restart",Attrs) of
                                 "true" ->
                                     true;
                                 _ ->
                                     false
                             end,
			 Wait = ?MAX_WAIT,
			 Hold = (?MAX_REQUESTS - 1),
			 if 
			     (Type == "terminate") ->
				 %% terminate session
				 InPacket = Packet ++ "</stream:stream>";
			     true ->
				 InPacket = Packet
			 end,
			 ID1
		 end,
%%		    ?DEBUG("~n InPacket: ~s ~n", [InPacket]),
	    case http_put(ID, RID, Key, NewKey, Hold, InPacket, StreamStart) of
		{error, not_exists} ->
		    ?DEBUG("no session associated with sid: ~p", [ID]),
		    {404, [?BAD_REQUEST], ""};
		{error, bad_key} ->
		    ?DEBUG("bad key: ~s", [Key]),
		    case mnesia:dirty_read({http_bind, ID}) of
			[] ->
			    {404, [?BAD_REQUEST], ""};
			[#http_bind{pid = FsmRef}] ->
			    gen_fsm:sync_send_all_state_event(FsmRef,stop),
			    {404, [?BAD_REQUEST], ""}		    
		    end;
		{error, polling_too_frequently} ->
		    ?DEBUG("polling too frequently: ~p", [ID]),
		    case mnesia:dirty_read({http_bind, ID}) of
			[] -> %% unlikely! (?)
			    {404, [?BAD_REQUEST], ""};
			[#http_bind{pid = FsmRef}] ->
			    gen_fsm:sync_send_all_state_event(FsmRef,stop),
			    {403, [?BAD_REQUEST], ""}		    
		    end;
		{repeat, OutPacket} ->
		    ?DEBUG("http_put said 'repeat!' ...~nOutPacket: ~p", 
			   [OutPacket]),
		    send_outpacket(ID, OutPacket);
		ok ->
		    receive_loop(ID,ID1,RID,Wait,Hold,Attrs)
	    end
	    end;
	_ ->
	    {400, [?BAD_REQUEST], ""}
    end;
process_request(_Request) ->
    {400, [], {xmlelement, "h1", [],
	       [{xmlcdata, "400 Bad Request"}]}}.

receive_loop(ID,ID1,RID,Wait,Hold,Attrs) ->
    receive
	after 100 -> ok
	end,
    prepare_response(ID,ID1,RID,Wait,Hold,Attrs).

prepare_response(ID,ID1,RID,Wait,Hold,Attrs) ->
    case http_get(ID,RID) of
	{error, not_exists} ->
            ?DEBUG("no session associated with sid: ~s", ID),
	    {404, [?BAD_REQUEST], ""};
	{ok, keep_on_hold} ->
	    receive_loop(ID,ID1,RID,Wait,Hold,Attrs);
	{ok, cancel} ->
	    %% actually it would be better if we could completely
	    %% cancel this request, but then we would have to hack
	    %% ejabberd_http and I'm too lazy now
	    {404, [?BAD_REQUEST], ""}; 
	{ok, OutPacket} ->
            ?DEBUG("OutPacket: ~s", [OutPacket]),
	    if
		ID == ID1 ->
		    send_outpacket(ID, OutPacket);
		true ->
		    To = xml:get_attr_s("to",Attrs),
		    OutEls = case xml_stream:parse_element(
                                    OutPacket++"</stream:stream>") of
                                 El when element(1, El) == xmlelement ->
                                     {xmlelement, _, OutAttrs, Els} = El,
                                     AuthID = xml:get_attr_s("id", OutAttrs),
                                     StreamError = false,
                                     case Els of
                                         [] ->
                                             [];
                                         [{xmlelement, "stream:features", StreamAttribs, StreamEls} | StreamTail] ->
                                             [{xmlelement, "stream:features", [{"xmlns:stream","http://etherx.jabber.org/streams"}] ++ StreamAttribs, StreamEls}] ++ StreamTail;
                                         Xml ->
                                             Xml
                                     end;
                                 {error, _} ->
                                     AuthID = "",
                                     StreamError = true,
                                     []
                             end,
		    if
			To == "" ->
			    {200, [?CT], "<body type='terminate' "
			     "condition='improper-addressing' "
			     "xmlns='http://jabber.org/protocol/httpbind'/>"};
			StreamError == true ->
			    {200, [?CT], "<body type='terminate' "
			     "condition='host-unknown' "
			     "xmlns='http://jabber.org/protocol/httpbind'/>"};
			true ->
			    {200, [?CT],
			     xml:element_to_string(
			       {xmlelement,"body",
				[{"xmlns",
				  "http://jabber.org/protocol/httpbind"},
				 {"sid",ID},
				 {"wait", integer_to_list(Wait)},
				 {"requests", integer_to_list(Hold+1)},
				 {"inactivity", 
				  integer_to_list(trunc(?MAX_INACTIVITY/1000))},
				 {"polling", ?MIN_POLLING},
				 {"authid", AuthID}
				],OutEls})}
		    end
	    end
    end.
    
send_outpacket(ID, OutPacket) ->
    case OutPacket of
	"" ->
	    {200, [?CT], "<body xmlns='http://jabber.org/protocol/httpbind'/>"};
	"</stream:stream>" ->
	    case mnesia:dirty_read({http_bind, ID}) of
		[#http_bind{pid = FsmRef}] ->
		    gen_fsm:sync_send_all_state_event(FsmRef,stop)
	    end,
	    {200, [?CT], "<body xmlns='http://jabber.org/protocol/httpbind'/>"};
	_ ->
	    case xml_stream:parse_element("<body>" 
					  ++ OutPacket
					  ++ "</body>") 
		of
		El when element(1, El) == xmlelement ->
		    {xmlelement, _, _, OEls} = El,
		    TypedEls = [xml:replace_tag_attr("xmlns",
						     "jabber:client",OEl) ||
				   OEl <- OEls],
		    ?DEBUG(" --- outgoing data --- ~n~s~n --- END --- ~n",
			   [xml:element_to_string(
			      {xmlelement,"body",
			       [{"xmlns",
				 "http://jabber.org/protocol/httpbind"}],
			       TypedEls})]
			  ),
		    {200, [?CT],
		     xml:element_to_string(
		       {xmlelement,"body",
			[{"xmlns",
			  "http://jabber.org/protocol/httpbind"}],
			TypedEls})};
		{error, _E} ->
		    OutEls = case xml_stream:parse_element(
                                    OutPacket++"</stream:stream>") of
                                 SEl when element(1, SEl) == xmlelement ->
                                     {xmlelement, _, _OutAttrs, SEls} = SEl,
                                     StreamError = false,
                                     case SEls of
                                         [] ->
                                             [];
                                         [{xmlelement, "stream:features", StreamAttribs, StreamEls} | StreamTail] ->
                                             TypedTail = [xml:replace_tag_attr("xmlns",
                                                                              "jabber:client",OEl) ||
                                                            OEl <- StreamTail],
                                             [{xmlelement, "stream:features", [{"xmlns:stream","http://etherx.jabber.org/streams"}] ++ StreamAttribs, StreamEls}] ++ TypedTail;
                                         Xml ->
                                             Xml
                                     end;
                                 {error, _} ->
                                     StreamError = true,
                                     []
                             end,
                    if 
                        StreamError ->
                            StreamErrCond = case xml_stream:parse_element(
                                                   "<stream:stream>"++OutPacket) of
                                                El when element(1, El) == xmlelement ->
                                                    {xmlelement, _Tag, _Attr, Els} = El,
                                                    [{xmlelement, SE, _, Cond} | _] = Els,
                                                    if 
                                                        SE == "stream:error" ->
                                                            Cond;
                                                        true ->
                                                            null
                                                    end;
                                                {error, _E} ->
                                                    null
                                            end,
                            case mnesia:dirty_read({http_bind, ID}) of
                                [#http_bind{pid = FsmRef}] ->
                                    gen_fsm:sync_send_all_state_event(FsmRef,stop);
                                _ ->
                                    err %% hu?
                            end,
                            case StreamErrCond of
                                null ->
                                    {200, [?CT],
                                     "<body type='terminate' "
                                     "condition='internal-server-error' "
                                     "xmlns='http://jabber.org/protocol/httpbind'/>"};
                                _ ->
                                    {200, [?CT],
                                     "<body type='terminate' "
                                     "condition='remote-stream-error' "
                                     "xmlns='http://jabber.org/protocol/httpbind'>" ++
                                     elements_to_string(StreamErrCond) ++
                                     "</body>"}
                            end;
                        true ->
                            {200, [?CT],
                             xml:element_to_string(
                               {xmlelement,"body",
                                [{"xmlns",
                                  "http://jabber.org/protocol/httpbind"}],
                                OutEls})}
                    end
	    end
    end.

%%%----------------------------------------------------------------------
%%% Callback functions from gen_fsm
%%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, StateName, StateData}          |
%%          {ok, StateName, StateData, Timeout} |
%%          ignore                              |
%%          {stop, StopReason}                   
%%----------------------------------------------------------------------
init([ID, Key]) ->
    ?INFO_MSG("started: ~p", [{ID, Key}]),
    Opts = [], % TODO
    {ok, C2SPid} = ejabberd_c2s:start({?MODULE, {http_bind, self()}}, Opts),
    ejabberd_c2s:become_controller(C2SPid),
    Timer = erlang:start_timer(?MAX_INACTIVITY, self(), []),
    {ok, loop, #state{id = ID,
		      key = Key,
		      timer = Timer}}.

%%----------------------------------------------------------------------
%% Func: StateName/2
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}                         
%%----------------------------------------------------------------------


%%----------------------------------------------------------------------
%% Func: StateName/3
%% Returns: {next_state, NextStateName, NextStateData}            |
%%          {next_state, NextStateName, NextStateData, Timeout}   |
%%          {reply, Reply, NextStateName, NextStateData}          |
%%          {reply, Reply, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}                          |
%%          {stop, Reason, Reply, NewStateData}                    
%%----------------------------------------------------------------------
%state_name(Event, From, StateData) ->
%    Reply = ok,
%    {reply, Reply, state_name, StateData}.

%%----------------------------------------------------------------------
%% Func: handle_event/3
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}                         
%%----------------------------------------------------------------------
handle_event(_Event, StateName, StateData) ->
    {next_state, StateName, StateData}.

%%----------------------------------------------------------------------
%% Func: handle_sync_event/4
%% Returns: {next_state, NextStateName, NextStateData}            |
%%          {next_state, NextStateName, NextStateData, Timeout}   |
%%          {reply, Reply, NextStateName, NextStateData}          |
%%          {reply, Reply, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}                          |
%%          {stop, Reason, Reply, NewStateData}                    
%%----------------------------------------------------------------------
handle_sync_event({send, Packet}, _From, StateName, StateData) ->
    Output = [StateData#state.output | Packet],
    Reply = ok,
    {reply, Reply, StateName, StateData#state{output = Output}};

handle_sync_event(activate, From, StateName, StateData) ->
    case StateData#state.input of
	"" ->
	    {reply, ok, StateName, StateData#state{
				     waiting_input = From}};
	Input ->
	    From ! {tcp, {http_bind, self()}, list_to_binary(Input)},
	    {reply, ok, StateName, StateData#state{
				     input = "",
				     waiting_input = false,
				     last_receiver = From}}
    end;

handle_sync_event(stop, _From, _StateName, StateData) ->
    Reply = ok,
    {stop, normal, Reply, StateData};

handle_sync_event({http_put, RID, Key, NewKey, Hold, Packet, StartTo},
		  _From, StateName, StateData) ->
    %% check if RID valid
    RidAllow = case RID of
		   error -> 
		       false;
		   _ ->
		       case StateData#state.rid of
			   error -> 
			       %% first request - nothing saved so far
			       true;
			   OldRID ->
			       ?DEBUG("state.rid/cur rid: ~p/~p", 
				      [OldRID, RID]),
			       if 
				   (OldRID < RID) and 
				   (RID =< (OldRID + Hold + 1)) ->
				       true;
				   (RID =< OldRID) and 
				   (RID > OldRID - Hold - 1) ->
				       repeat;
				   true ->
				       false
			       end
		       end
	       end,
    %% check if key valid
    KeyAllow = case RidAllow of
		   repeat -> 
		       true;
		   false ->
		       false;
		   true ->
		       case StateData#state.key of
			   "" ->
			       true;
			   OldKey ->
			       NextKey = httpd_util:to_lower(
					   hex(binary_to_list(
						 crypto:sha(Key)))),
			       ?DEBUG("Key/OldKey/NextKey: ~s/~s/~s", 
				      [Key, OldKey, NextKey]),
			       if
				   OldKey == NextKey ->
				       true;
				   true ->
				       ?DEBUG("wrong key: ~s",[Key]),
				       false
			       end
		       end
	       end,
    {_,TSec,TMSec} = now(),
    TNow = TSec*1000*1000 + TMSec,
    LastPoll = if 
		   Packet == "" ->
		       TNow;
		   true ->
		       0
	       end,
    {MinPoll, _} = string:to_integer(?MIN_POLLING),
    if
	(Packet == "") and 
	(TNow - StateData#state.last_poll < MinPoll*1000*1000) ->
	    Reply = {error, polling_too_frequently},
	    {reply, Reply, StateName, StateData};
	KeyAllow ->
	    case RidAllow of
		false ->
		    Reply = {error, not_exists},
		    {reply, Reply, StateName, StateData};
		repeat ->
		    ?DEBUG("REPEATING ~p", [RID]),
		    [Out | _XS] = [El#hbr.out || 
				      El <- StateData#state.req_list, 
				      El#hbr.rid == RID],
		    case Out of 
			[[] | OutPacket] ->
			    Reply = {repeat, OutPacket};
			_ ->
			    Reply = {repeat, Out}
		    end,
		    {reply, Reply, StateName, 
		     StateData#state{input = "cancel", last_poll = LastPoll}};
		true ->
		    SaveKey = if 
				  NewKey == "" ->
				      Key;
				  true ->
				      NewKey
			      end,
		    ?DEBUG(" -- SaveKey: ~s~n", [SaveKey]),

		    %% save request
		    ReqList = [#hbr{rid=RID,
				    key=StateData#state.key,
				    in=StateData#state.input,
				    out=StateData#state.output
				   } | 
			       [El || El <- StateData#state.req_list, 
				      El#hbr.rid < RID, 
				      El#hbr.rid > (RID - 1 - Hold)]
			      ],
%%		    ?DEBUG("reqlist: ~p", [ReqList]),
		    case StateData#state.waiting_input of
			false ->
			    cancel_timer(StateData#state.timer),
			    Timer = erlang:start_timer(
				      ?MAX_INACTIVITY, self(), []),
			    Input = Packet ++ [StateData#state.input],
			    Reply = ok,
			    {reply, Reply, StateName, 
			     StateData#state{input = Input,
					     rid = RID,
					     key = SaveKey,
					     ctime = TNow,
					     timer = Timer,
					     last_poll = LastPoll,
					     req_list = ReqList
					    }};
			{Receiver, _Tag} ->
                            SendPacket = 
                                if 
                                    StartTo /= "" ->
                                        ["<stream:stream to='",
                                         StartTo, 
                                         "' xmlns='jabber:client' "
                                         "version='1.0' "
                                         "xmlns:stream='http://etherx.jabber.org/streams'>"] ++ Packet;
                                    true ->
                                        Packet
                                end,
                            ?DEBUG("really sending now: ~s", [SendPacket]),
			    Receiver ! {tcp, {http_bind, self()},
					list_to_binary(SendPacket)},
			    cancel_timer(StateData#state.timer),
			    Timer = erlang:start_timer(
				      ?MAX_INACTIVITY, self(), []),
			    Reply = ok,
			    {reply, Reply, StateName,
			     StateData#state{waiting_input = false,
					     last_receiver = Receiver,
					     input = "",
					     rid = RID,
					     key = SaveKey,
					     ctime = TNow,
					     timer = Timer,
					     last_poll = LastPoll,
					     req_list = ReqList
					    }}
		    end
	    end;
	true ->
	    Reply = {error, bad_key},
	    {reply, Reply, StateName, StateData}
    end;

handle_sync_event({http_get, RID, Wait, Hold}, _From, StateName, StateData) ->
    {_,TSec,TMSec} = now(),
    TNow = TSec*1000*1000 + TMSec,
    cancel_timer(StateData#state.timer),
    Timer = erlang:start_timer(?MAX_INACTIVITY, self(), []),
    if 
	(Hold > 0) and 
	(StateData#state.output == "") and 
	((TNow - StateData#state.ctime) < (Wait*1000*1000)) and 
	(StateData#state.rid == RID) and 
	(StateData#state.input /= "cancel") ->
	    Output = StateData#state.output,
	    ReqList = StateData#state.req_list,
	    Reply = {ok, keep_on_hold};
	(StateData#state.input == "cancel") ->
	    Output = StateData#state.output,
	    ReqList = StateData#state.req_list,
	    Reply = {ok, cancel};
	true ->
	    case StateData#state.output of
		[[]| OutPacket] ->
		    Reply = {ok, OutPacket};
		_ ->
		    Reply = {ok, StateData#state.output}
	    end,
	    %% save request
	    ReqList = [#hbr{rid=RID,
			    key=StateData#state.key,
			    in=StateData#state.input,
			    out=StateData#state.output
			   } | 
		       [El || El <- StateData#state.req_list, 
			      El#hbr.rid /= RID ] 
		      ],
	    Output = ""
    end,
    {reply, Reply, StateName, StateData#state{
				input = "",
				output = Output, 
				timer = Timer,
				req_list = ReqList}};

handle_sync_event(_Event, _From, StateName, StateData) ->
    Reply = ok,
    {reply, Reply, StateName, StateData}.

code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.

%%----------------------------------------------------------------------
%% Func: handle_info/3
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}                         
%%----------------------------------------------------------------------
handle_info({timeout, Timer, _}, _StateName,
	    #state{timer = Timer} = StateData) ->
    ?DEBUG("ding dong", []),
    {stop, normal, StateData};

handle_info(_, StateName, StateData) ->
    {next_state, StateName, StateData}.

%%----------------------------------------------------------------------
%% Func: terminate/3
%% Purpose: Shutdown the fsm
%% Returns: any
%%----------------------------------------------------------------------
terminate(_Reason, _StateName, StateData) ->
    ?DEBUG("terminate: deleting session ~s", [StateData#state.id]),
    mnesia:transaction(
      fun() ->
	      mnesia:delete({http_bind, StateData#state.id})
      end),
    case StateData#state.waiting_input of
	false ->
	    case StateData#state.last_receiver of
		undefined -> ok;
		Receiver -> Receiver ! {tcp_closed, {http_bind, self()}}
	    end;
	{Receiver, _Tag} -> Receiver ! {tcp_closed, {http_bind, self()}}
    end,
    ok.

%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------


http_put(ID, RID, Key, NewKey, Hold, Packet, Restart) ->
    ?DEBUG("http-put",[]),
    case mnesia:dirty_read({http_bind, ID}) of
	[] ->
            ?DEBUG("not found",[]),
	    {error, not_exists};
	[#http_bind{pid = FsmRef,to=To}] ->
            case Restart of
                true ->
                    ?DEBUG("restart requested for ~s", [To]),
                    gen_fsm:sync_send_all_state_event(
                      FsmRef, {http_put, RID, Key, NewKey, Hold, Packet, To});
                _ ->
                    gen_fsm:sync_send_all_state_event(
                      FsmRef, {http_put, RID, Key, NewKey, Hold, Packet, ""})
            end
    end.

http_get(ID,RID) ->
    case mnesia:dirty_read({http_bind, ID}) of
	[] ->
	    {error, not_exists};
	[#http_bind{pid = FsmRef, wait = Wait, hold = Hold}] ->
	    gen_fsm:sync_send_all_state_event(FsmRef, 
					      {http_get, RID, Wait, Hold})
    end.


parse_request(Data) ->
    ?DEBUG("--- incoming data --- ~n~s~n --- END --- ",
	   [Data]),
    case xml_stream:parse_element(Data) of
	El when element(1, El) == xmlelement ->
	    {xmlelement, Name, Attrs, Els} = El,
	    ID = xml:get_attr_s("sid",Attrs),
	    {RID,_X} = string:to_integer(xml:get_attr_s("rid",Attrs)),
	    Key = xml:get_attr_s("key",Attrs),
	    NewKey = xml:get_attr_s("newkey",Attrs),
	    Xmlns = xml:get_attr_s("xmlns",Attrs),
            lists:map(fun(E) ->
                              EXmlns = xml:get_tag_attr_s("xmlns",E),
                              if 
                                  EXmlns == "jabber:client" ->
                                      xml:remove_tag_attr("xmlns",E);
                                  true ->
                                      ok
                              end
                      end, Els),
	    Packet = [xml:element_to_string(E) || E <- Els],
            ?DEBUG("ns fixed packet(s): ~s", [Packet]),
	    if 
		Name /= "body" -> 
		    {error, bad_request};
		Xmlns /= "http://jabber.org/protocol/httpbind" ->
		    {error, bad_request};
		true ->
		    {ok, ID, RID, Key, NewKey, Attrs, Packet}
	    end;
	{error, _Reason} ->
	    {error, bad_request}
    end.

cancel_timer(Timer) ->
    erlang:cancel_timer(Timer),
    receive
	{timeout, Timer, _} ->
	    ok
    after 0 ->
	    ok
    end.

hex(Bin) when binary(Bin) -> hex(binary_to_list(Bin));
hex([]) -> "";
hex([H|T]) -> 
	[A,B] = if 
		H == 0 -> "00";
		H < 16 -> [$0,element(H,{$1,$2,$3,$4,$5,$6,$7,$8,$9,$a,$b,$c,$d,$e,$f})];
		true   -> erlang:integer_to_list(H,16)
	end,
	[A,B|hex(T)].

elements_to_string([]) ->
    [];
elements_to_string([El | Els]) ->
    xml:element_to_string(El) ++ elements_to_string(Els).
