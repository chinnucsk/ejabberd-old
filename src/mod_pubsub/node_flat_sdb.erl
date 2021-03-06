%%% ====================================================================
%%% ``The contents of this file are subject to the Erlang Public License,
%%% Version 1.1, (the "License"); you may not use this file except in
%%% compliance with the License. You should have received a copy of the
%%% Erlang Public License along with this software. If not, it can be
%%% retrieved via the world wide web at http://www.erlang.org/.
%%% 
%%% Software distributed under the License is distributed on an "AS IS"
%%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%%% the License for the specific language governing rights and limitations
%%% under the License.
%%% 
%%% The Initial Developer of the Original Code is ProcessOne.
%%% Portions created by ProcessOne are Copyright 2006-2009, ProcessOne
%%% All Rights Reserved.''
%%% This software is copyright 2006-2009, ProcessOne.
%%%
%%% @copyright 2006-2009 ProcessOne
%%% @author Christophe Romain <christophe.romain@process-one.net>
%%%   [http://www.process-one.net/]
%%% @version {@vsn}, {@date} {@time}
%%% @end
%%% ====================================================================

-module(node_flat_sdb).
-author('christophe.romain@process-one.net').

-include("pubsub.hrl").
-include("jlib.hrl").

-behaviour(gen_pubsub_node).

%% API definition
-export([init/3, terminate/2,
	 options/0, features/0,
	 create_node_permission/6,
	 create_node/2,
	 delete_node/1,
	 purge_node/2,
	 subscribe_node/8,
	 unsubscribe_node/4,
	 publish_item/6,
	 delete_item/4,
	 remove_extra_items/3,
	 get_entity_affiliations/2,
	 get_node_affiliations/1,
	 get_affiliation/2,
	 set_affiliation/3,
	 get_entity_subscriptions/2,
	 get_node_subscriptions/1,
	 get_subscriptions/2,
	 set_subscriptions/4,
	 get_pending_nodes/2,
	 get_states/1,
	 get_state/2,
	 set_state/1,
	 get_items/6,
	 get_items/2,
	 get_item/7,
	 get_item/2,
	 set_item/1,
	 get_item_name/3,
	 node_to_path/1,
	 path_to_node/1
	]).


init(Host, ServerHost, Opts) ->
    node_hometree_sdb:init(Host, ServerHost, Opts).

terminate(Host, ServerHost) ->
    node_hometree_sdb:terminate(Host, ServerHost).

options() ->
    [{deliver_payloads, true},
     {notify_config, false},
     {notify_delete, false},
     {notify_retract, true},
     {persist_items, true},
     {max_items, ?MAXITEMS},
     {subscribe, true},
     {access_model, open},
     {roster_groups_allowed, []},
     {publish_model, publishers},
     {notification_type, headline},
     {max_payload_size, ?MAX_PAYLOAD_SIZE},
     {send_last_published_item, on_sub_and_presence},
     {deliver_notifications, true},
     {presence_based_delivery, false}].

features() ->
    node_hometree_sdb:features().

%% use same code as node_hometree_sdb, but do not limite node to
%% the home/localhost/user/... hierarchy
%% any node is allowed
create_node_permission(Host, ServerHost, _Node, _ParentNode, Owner, Access) ->
    LOwner = jlib:jid_tolower(Owner),
    Allowed = case LOwner of
	{"", Host, ""} ->
	    true; % pubsub service always allowed
	_ ->
	    acl:match_rule(ServerHost, Access, LOwner) =:= allow
    end,
    {result, Allowed}.

create_node(NodeId, Owner) ->
    node_hometree_sdb:create_node(NodeId, Owner).

delete_node(Removed) ->
    node_hometree_sdb:delete_node(Removed).

subscribe_node(NodeId, Sender, Subscriber, AccessModel, SendLast, PresenceSubscription, RosterGroup, Options) ->
    node_hometree_sdb:subscribe_node(NodeId, Sender, Subscriber, AccessModel, SendLast, PresenceSubscription, RosterGroup, Options).

unsubscribe_node(NodeId, Sender, Subscriber, SubID) ->
    node_hometree_sdb:unsubscribe_node(NodeId, Sender, Subscriber, SubID).

publish_item(NodeId, Publisher, Model, MaxItems, ItemId, Payload) ->
    node_hometree_sdb:publish_item(NodeId, Publisher, Model, MaxItems, ItemId, Payload).

remove_extra_items(NodeId, MaxItems, ItemIds) ->
    node_hometree_sdb:remove_extra_items(NodeId, MaxItems, ItemIds).

delete_item(NodeId, Publisher, PublishModel, ItemId) ->
    node_hometree_sdb:delete_item(NodeId, Publisher, PublishModel, ItemId).

purge_node(NodeId, Owner) ->
    node_hometree_sdb:purge_node(NodeId, Owner).

get_entity_affiliations(Host, Owner) ->
    node_hometree_sdb:get_entity_affiliations(Host, Owner).

get_node_affiliations(NodeId) ->
    node_hometree_sdb:get_node_affiliations(NodeId).

get_affiliation(NodeId, Owner) ->
    node_hometree_sdb:get_affiliation(NodeId, Owner).

set_affiliation(NodeId, Owner, Affiliation) ->
    node_hometree_sdb:set_affiliation(NodeId, Owner, Affiliation).

get_entity_subscriptions(Host, Owner) ->
    node_hometree_sdb:get_entity_subscriptions(Host, Owner).

get_node_subscriptions(NodeId) ->
    node_hometree_sdb:get_node_subscriptions(NodeId).

get_subscriptions(NodeId, Owner) ->
    node_hometree_sdb:get_subscriptions(NodeId, Owner).

set_subscriptions(NodeId, Owner, Subscription, SubId) ->
    node_hometree_sdb:set_subscriptions(NodeId, Owner, Subscription, SubId).

get_pending_nodes(Host, Owner) ->
    node_hometree_sdb:get_pending_nodes(Host, Owner).

get_states(NodeId) ->
    node_hometree_sdb:get_states(NodeId).

get_state(NodeId, JID) ->
    node_hometree_sdb:get_state(NodeId, JID).

set_state(State) ->
    node_hometree_sdb:set_state(State).

get_items(NodeId, From) ->
    node_hometree_sdb:get_items(NodeId, From).

get_items(NodeId, JID, AccessModel, PresenceSubscription, RosterGroup, SubId) ->
    node_hometree_sdb:get_items(NodeId, JID, AccessModel, PresenceSubscription, RosterGroup, SubId).

get_item(NodeId, ItemId) ->
    node_hometree_sdb:get_item(NodeId, ItemId).

get_item(NodeId, ItemId, JID, AccessModel, PresenceSubscription, RosterGroup, SubId) ->
    node_hometree_sdb:get_item(NodeId, ItemId, JID, AccessModel, PresenceSubscription, RosterGroup, SubId).

set_item(Item) ->
    node_hometree_sdb:set_item(Item).

get_item_name(Host, Node, Id) ->
    node_hometree_sdb:get_item_name(Host, Node, Id).

node_to_path(Node) ->
    [binary_to_list(Node)].

path_to_node(Path) ->
    case Path of
    % default slot
    [Node] -> list_to_binary(Node);
    % handle old possible entries, used when migrating database content to new format
    [Node|_] when is_list(Node) -> list_to_binary(string:join([""|Path], "/"));
    % default case (used by PEP for example)
    _ -> list_to_binary(Path)
    end.
