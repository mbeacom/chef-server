%% -*- erlang-indent-level: 4;indent-tabs-mode: nil;fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% @author Kevin Smith <kevin@opscode.com>
%% @copyright 2011 Opscode, Inc.
-module(mover_manager).

-behaviour(gen_fsm).

%% API
-export([start_link/1,
         status/0,
         start_batch/2]).

%% States
-export([init_storage/2,
         init_storage/3,
         load_orgs/2,
         load_orgs/3,
         preload_org_nodes/2,
         preload_org_nodes/3,
         ready/3,
         running/3]).

%% gen_fsm callbacks
-export([init/1,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).

-define(SERVER, ?MODULE).
-define(DETS_OPTS(EstSize), [{auto_save, 1000},
                             {keypos, 2},
                             {estimated_no_objects, EstSize}]).
-define(ORG_SPEC(Preloaded, Active, Complete),
        #org{guid = '$1',
             name = '$2',
             preloaded = Preloaded,
             read_only = '_',
             active = Active,
             complete = Complete,
             worker = '_'}).

-record(state, {couch_cn,
                preload_amt,
                workers=0}).

-record(org, {guid,
              name,
              preloaded = false,
              read_only = false,
              active = false,
              complete = false,
              worker = undefined}).

-record(node, {name,
               id,
               authz_id,
               requestor,
               error}).

-include("node_mover.hrl").

start_link(PreloadAmt) ->
    gen_fsm:start_link({local, ?SERVER}, ?MODULE, [PreloadAmt], []).

status() ->
    gen_fsm:sync_send_event(?SERVER, status, infinity).

start_batch(NumOrgs, NumNodes) ->
    gen_fsm:sync_send_event(?SERVER, {start, NumOrgs, NumNodes}).

init([PreloadAmt]) ->
    {ok, init_storage, #state{preload_amt=PreloadAmt}, 0}.

init_storage(_Event, _From, State) ->
    {reply, {busy, init_storage}, load_orgs, State}.

init_storage(timeout, State) ->
    error_logger:info_msg("initializing migration storage~n"),
    {ok, _} = dets:open_file(all_orgs, ?DETS_OPTS(?ORG_ESTIMATE)),
    {ok, _} = dets:open_file(all_nodes, ?DETS_OPTS(?NODE_ESTIMATE)),
    {ok, _} = dets:open_file(error_nodes, ?DETS_OPTS(10000)),
    {next_state, load_orgs, State, 0}.

load_orgs(_Event, _From, State) ->
    {reply, {busy, load_orgs}, load_orgs, State}.

load_orgs(timeout, State) ->
    error_logger:info_msg("loading unassigned orgs~n"),
    Cn = chef_otto:connect(),
    [insert_org(NameGuid) || NameGuid <- chef_otto:fetch_assigned_orgs(Cn)],
    error_logger:info_msg("loaded orgs: ~p~n", [summarize_orgs()]),
    {next_state, preload_org_nodes, State#state{couch_cn=Cn}, 0}.

preload_org_nodes(status, _From, State) ->
    {reply, {busy, preload_org_nodes}, preload_org_nodes, State}.

preload_org_nodes(timeout, #state{preload_amt=Amt}=State) ->
    error_logger:info_msg("preloading nodes for ~B orgs~n", [Amt]),
    case preload_orgs(Amt, State) of
        {ok, State1} ->
            error_logger:info_msg("preloading complete~n"),
            {next_state, ready, State1};
        Error ->
            {stop, Error, State}
    end.

%% find_migration_candidates
%% mark_candidates_as_read_only
%% 
ready(status, _From, State) ->
    {reply, {ok, 0}, ready, State};
ready({start, BatchSize, NodeBatchSize}, _From, #state{workers = 0}=State) ->
    case find_migration_candidates(BatchSize) of
        {ok, none} ->
            error_logger:info_msg("no migration candidates~n"),
            {reply, no_candidates, ready, State};
        {ok, Orgs} ->
            %% Tell darklaunch to put these orgs into read-only
            %% mode for nodes.
            ok = darklaunch_disable_node_writes([ Name || {_, Name} <- Orgs ]),
            [ mark_org(read_only, OrgId) || {OrgId, _} <- Orgs ],
            case start_workers(Orgs, NodeBatchSize) of
                0 ->
                    {reply, {error, none_started}, ready, State};
                Count ->
                    {reply, {ok, Count}, running, State#state{workers=Count}}
            end
    end.

running(status, _From, #state{workers=Workers}=State) ->
    {reply, {ok, Workers}, running, State};
running({start, _BatchSize, _NodeBatchSize}, _From, State) ->
    {reply, {error, running_batch}, running, State}.

handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(status, _From, StateName, State) when StateName =:= init_storage;
                                                        StateName =:= load_orgs;
                                                        StateName =:= preload_org_nodes ->
    {reply, {busy, StateName}, StateName, State};
handle_sync_event(status, _From, running, #state{workers=Workers}=State) ->
    {reply, {ok, Workers}, running, State};
handle_sync_event(_Event, _From, StateName, State) ->
    {next_state, StateName, State}.


handle_info({'DOWN', _MRef, process, Pid, normal}, StateName,
            #state{workers = Workers}=State) when Workers > 0 ->
    %% TODO: Preload another org to keep pipe full?
    case find_org_by_worker(Pid) of
        #org{}=Org ->
            mark_org(complete, Org#org.guid),
            WorkerCount = Workers - 1,
            NextState = case WorkerCount > 0 of
                            true -> StateName;
                            false -> ready
                        end,
            %% the org is now marked as complete and we regenerate the list of unmigrated
            %% orgs and send updates to our nginx lbs.  Marking the orgs as not_read_only is
            %% only for accounting so that we can find orgs that are migrated, but not
            %% turned on in nginx later.
            case route_orgs_to_erchef_sql() of
                ok -> mark_org(not_read_only, Org#org.guid);
                _Ignore -> ok
            end,
            {next_state, NextState, State#state{workers = WorkerCount}};
        _NotFound ->
            %% ignore the msg
            {next_state, StateName, State}
    end;
%% FIXME: when worker terminates w/ nodes_failed, is this what we get?
handle_info({'DOWN', _MRef, process, Pid, nodes_failed}, StateName,
            #state{workers = Workers}=State) when Workers > 0 ->
    case find_org_by_worker(Pid) of
        #org{}=Org ->
            mark_org(nodes_failed, Org#org.guid),
            WorkerCount = Workers - 1,
            NextState = case WorkerCount > 0 of
                            true -> StateName;
                            false -> ready
                        end,
            %% this org has failed nodes.  To minimize downtime for this org, we will fail
            %% the migration and turn on writes back in couch-land.
            darklaunch_enable_node_writes(Org#org.name),
            {next_state, NextState, State#state{workers = WorkerCount}};
        _NotFound ->
            %% ignore the msg
            {next_state, StateName, State}
    end;
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

terminate(_Reason, _StateName, _State) ->
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%% Internal functions

insert_org({Name, Guid}) ->
    case dets:lookup(all_orgs, Guid) of
        [] ->
            Org = #org{guid=Guid, name=Name},
            dets:insert(all_orgs, Org);
        [#org{}] ->
            ok
        %% Hey Kevin, why change state of orgs already loaded?
        %% [Org] ->
        %%     dets:insert(all_orgs, Org#org{preloaded=false, complete=false, active=false})
    end.

preload_orgs(BatchSize, State) ->
    case find_preload_candidates(BatchSize) of
        {ok, none} ->
            {ok, State};
        {ok, Orgs} ->
            load_org_nodes(Orgs, State);
        Error ->
            Error
    end.

load_org_nodes([], State) ->
    {ok, State};
load_org_nodes([{OrgId, _Name}|T], #state{couch_cn=Cn}=State) ->
    NodeList = chef_otto:fetch_nodes_with_ids(Cn, OrgId),
    [store_node(Cn, OrgId, NodeId, NodeName) || {NodeName, NodeId} <- NodeList],
    mark_org(preload, OrgId),
    load_org_nodes(T, State).

find_preload_candidates(BatchSize) ->
    {Preloaded, Active, Complete} = {false, false, false},
    case dets:match(all_orgs, ?ORG_SPEC(Preloaded, Active, Complete), BatchSize) of
        {error, Why} ->
            {error, Why};
        '$end_of_table' ->
            {ok, none};
        {[], _Cont} ->
            {ok, none};
        {Data, _Cont} ->
            Orgs = [{Guid, Name} || [Guid, Name] <- Data],
            {ok, Orgs}
    end.

find_migration_candidates(BatchSize) ->
    {Preloaded, Active, Complete} = {true, false, false},
    case dets:match(all_orgs, ?ORG_SPEC(Preloaded, Active, Complete), BatchSize) of
        {error, Why} ->
            {error, Why};
        '$end_of_table' ->
            {ok, none};
        {[], _Cont} ->
            {ok, none};
        {Data, _Cont} ->
            Orgs = [{Guid, Name} || [Guid, Name] <- Data],
            {ok, Orgs}
    end.

store_node(Cn, OrgId, NodeId, NodeName) ->
    case chef_otto:fetch_by_name(Cn, OrgId, NodeName, authz_node) of
        {ok, MixlibNode} ->
            MixlibId = ej:get({<<"_id">>}, MixlibNode),
            AuthzId = chef_otto:fetch_auth_join_id(Cn, MixlibId, user_to_auth),
            RequestorId = ej:get({<<"requester_id">>}, MixlibNode),
            Node = #node{name=NodeName, id=NodeId,
                         authz_id=AuthzId, requestor=RequestorId},
            dets:insert(all_nodes, Node);
        Error ->
            dets:insert(error_nodes, #node{name=NodeName, id=NodeId, error=Error})
    end.

mark_org(preload, OrgId) ->
    case dets:lookup(all_orgs, OrgId) of
        [] ->
            ok;
        [Org] ->
            Org1 = Org#org{preloaded=true},
            dets:insert(all_orgs, Org1)
    end;
mark_org(read_only, OrgId) ->
    case dets:lookup(all_orgs, OrgId) of
        [] ->
            ok;
        [Org] ->
            Org1 = Org#org{read_only=true},
            dets:insert(all_orgs, Org1)
    end;
mark_org(not_read_only, OrgId) ->
    case dets:lookup(all_orgs, OrgId) of
        [] ->
            ok;
        [Org] ->
            Org1 = Org#org{read_only=false},
            dets:insert(all_orgs, Org1)
    end;
mark_org(complete, OrgId) ->
    case dets:lookup(all_orgs, OrgId) of
        [] ->
            ok;
        [Org] ->
            Org1 = Org#org{complete=true, active=false, worker=undefined},
            dets:insert(all_orgs, Org1)
    end;
mark_org(nodes_failed, OrgId) ->
    case dets:lookup(all_orgs, OrgId) of
        [] ->
            ok;
        [Org] ->
            Org1 = Org#org{complete=nodes_failed, worker=undefined},
            dets:insert(all_orgs, Org1)
    end.

mark_org(active, OrgId, WorkerPid) ->
    case dets:lookup(all_orgs, OrgId) of
        [] ->
            ok;
        [Org] ->
            Org1 = Org#org{active=true, worker=WorkerPid},
            dets:insert(all_orgs, Org1)
    end.

find_org_by_worker(Pid) ->
    Spec = (wildcard_org_spec())#org{worker = Pid},
    case dets:match_object(all_orgs, Spec) of
        [] ->
            error_logger:error_msg("No org found for pid ~p~n", [Pid]),
            not_found;
        [#org{}=Org] ->
            Org;
        {error, Why} ->
            error_logger:error_report({error, {find_org_by_worker, Pid, Why}}),
            {error, Why}
    end.
                
start_workers(Orgs, BatchSize) ->
    lists:foldl(fun({Guid, Name}, Count) ->
                        Config = make_worker_config(Guid, Name, BatchSize),
                        case node_mover_sup:new_mover(Config) of
                            {ok, Pid} -> 
                                node_mover_worker:migrate(Pid),
                                monitor(process, Pid),
                                mark_org(active, Guid, Pid),
                                Count + 1;
                            _NoPid ->
                                error_logger:error_msg("unable to launch worker for ~p ~p~n", [Name, _NoPid]),
                                Count
                        end
                end, 0, Orgs).

make_worker_config(Guid, Name, BatchSize) ->
    [{org_name, Name}, {org_id, Guid}, {batch_size, BatchSize},
     {chef_otto, chef_otto:connect()}].

list_unmigrated_orgs() ->
    Spec = (wildcard_org_spec())#org{complete = true, worker = undefined},
    dets:match_object(all_orgs, Spec).

route_orgs_to_erchef_sql() ->
    %% so we actually need to send a list of all non-migrated orgs each time.
    %% That's any org not complete
    {ok, NginxControlUrls} = application:get_env(mover, nginx_control_urls),
    Body = format_response(list_unmigrated_orgs()),
    %% dialyzer doesn't see the use of PostFun and warns that fake_post_to_nginx and
    %% post_to_nginx are unused.
    %%
    %% PostFun = case is_dry_run() of
    %%               true -> fake_post_to_nginx;
    %%               false -> post_to_nginx
    %%           end,
    Results = [ case is_dry_run() of
                    true -> fake_post_to_nginx(Url, Body);
                    false -> post_to_nginx(Url, Body)
                end
                || Url <- NginxControlUrls ],
    BadResults = [ X || X <- Results, X =/= ok ], 
    case BadResults of
        [] -> ok;
        _ -> {error, BadResults}
    end.

fake_post_to_nginx(Url, Body) ->
    %% error_logger:info_msg("fake POST of data to nginx at ~s~n~p~n", [Url, Body]),
    ok.

post_to_nginx(Url, Body) ->
    Headers = [{"content-type", "application/json"}],
    IbrowseOpts = [{ssl_options, []}, {response_format, binary}],
    case ibrowse:send_req(Url, Headers, post, Body, IbrowseOpts) of
        {ok, [$2, $0|_], _H, _Body} -> ok;
        Error -> {error, Error}
    end.

format_response(Orgs) ->
    OrgNames = [ Org#org.name || Org <- Orgs ],
    ejson:encode({[{<<"couch-orgs">>, OrgNames}]}).


darklaunch_enable_node_writes(OrgNames) ->
    case is_dry_run() of
        true ->
            error_logger:info_msg("FAKE enable node writes for ~p org via darklaunch~n",
                                  [length(OrgNames)]),
            ok;
        false ->
            error(implement_me)
    end.

darklaunch_disable_node_writes(OrgNames) ->
    case is_dry_run() of
        true ->
            error_logger:info_msg("disabling node writes for ~p via darklaunch~n", [OrgNames]),
            ok;
        false ->
            error(implement_me)
    end.

is_dry_run() ->
    {ok, DryRun} = application:get_env(mover, dry_run),
    DryRun.

wildcard_org_spec() ->
    #org{guid = '_',
         name = '_',
         preloaded = '_',
         read_only = '_',
         active = '_',
         complete = '_',
         worker = '_'}.

summarize_orgs() ->
    Counts = dets:foldl(fun(Org, {NTotal, NPreloaded, NReadOnly, NActive, NComplete}) ->
                                {NTotal + 1,
                                 NPreloaded + preloaded_count(Org),
                                 NReadOnly + as_number(Org#org.read_only),
                                 NActive + as_number(Org#org.active),
                                 NComplete + as_number(Org#org.complete)}
                        end, {0, 0, 0, 0, 0}, all_orgs),
    lists:zip([total, preloaded, read_only, active, complete], tuple_to_list(Counts)).

preloaded_count(#org{preloaded=true, complete = false}) ->
    1;
preloaded_count(#org{}) ->
    0.



as_number(true) ->
    1;
as_number(_) ->
    0.
