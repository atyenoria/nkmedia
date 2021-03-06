%% -------------------------------------------------------------------
%%
%% Copyright (c) 2016 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc Call management
%%
%% Typical call process:
%% - A session is started
%% - A call is started, linking it with the session (using session_id)
%% - The call registers itself with the session
%% - When the call has an answer, it is captured in nkmedia_call_reg_event
%%   (nkmedia_callbacks) and sent to the session. Same with hangups
%% - If the session stops, it is captured in nkmedia_session_reg_event
%% - When the call stops, the called process must detect it in nkmedia_call_reg_event

-module(nkmedia_call).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start/3, ringing/2, ringing/3, answered/3, rejected/2, hangup/2, hangup_all/0]).
-export([register/2, unregister/2]).
-export([find/1, get_all/0, get_call/1]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export_type([id/0, event/0]).


-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Call ~s "++Txt, [State#state.id | Args])).

-include("nkmedia.hrl").
-include_lib("nkservice/include/nkservice.hrl").



%% ===================================================================
%% Types
%% ===================================================================


-type id() :: binary().

-type callee() :: term().

-type config() ::
    #{
        call_id => id(),                    % Optional
        type => atom(),                     % Optional, used in resolvers
        offer => nkmedia:offer(),           % If included, will be sent to the callee
        session_id => nkmedia_session:id(), % If included, will link with session
        meta => term(),                     % Will be included in the invites
        register => nklib:link(),
        user_id => nkservice:user_id(),             % Informative only
        user_session => nkservice:user_session()    % Informative only
    }.


-type call() ::
    config() |
    #{
        srv_id => nkservice:id(),
        callee => callee(),
        callee_link => nklib:link()

    }.


-type event() :: 
    {ringing, nklib:link(), nkmedia:answer()} | 
    {answer, nklib:link(), nkmedia:answer()} | 
    {hangup, nkservice:error()}.


-type dest() :: term().

-type dest_ext() ::
    #{
        dest => dest(),
        wait => integer(),                      %% secs
        ring => integer(),
        sdp_type => webrtc | rtp
    }.



%% ===================================================================
%% Public
%% ===================================================================

%% @doc Starts a new call
-spec start(nkservice:id(), callee(), config()) ->
    {ok, id(), pid()}.

start(Srv, Callee, Config) ->
    case nkservice_srv:get_srv_id(Srv) of
        {ok, SrvId} ->
            Config2 = Config#{callee=>Callee, srv_id=>SrvId},
            {CallId, Config3} = nkmedia_util:add_id(call_id, Config2),
            {ok, Pid} = gen_server:start(?MODULE, [Config3], []),
            {ok, CallId, Pid};
        not_found ->
            {error, service_not_found}
    end.


%% @doc Called by the invited process
-spec ringing(id(), nklib:link()) ->
    ok | {error, term()}.

ringing(CallId, Link) ->
    ringing(CallId, Link, #{}).


%% @doc Called by the invited process, when you want to include an answer
-spec ringing(id(), nklib:link(), nkmedia:answer()) ->
    ok | {error, term()}.

ringing(CallId, Link, Answer) ->
    do_call(CallId, {ringing, Link, Answer}).


%% @doc Called by the invited process
-spec answered(id(), nklib:link(), nkmedia:answer()) ->
    ok | {error, term()}.

answered(CallId, Link, Answer) ->
    do_call(CallId, {answered, Link, Answer}).


%% @doc Called by the invited process
-spec rejected(id(), nklib:link()) ->
    ok | {error, term()}.

rejected(CallId, Link) ->
    do_cast(CallId, {rejected, Link}).


%% @doc
-spec hangup(id(), nkservice:error()) ->
    ok | {error, term()}.

hangup(CallId, Reason) ->
    do_cast(CallId, {hangup, Reason}).


%% @private
hangup_all() ->
    lists:foreach(fun({CallId, _Pid}) -> hangup(CallId, 16) end, get_all()).


%% @doc Registers a process with the call
-spec register(id(), nklib:link()) ->
    {ok, pid()} | {error, nkservice:error()}.

register(CallId, Link) ->
    do_call(CallId, {register, Link}).


%% @doc Registers a process with the call
-spec unregister(id(), nklib:link()) ->
    ok | {error, nkservice:error()}.

unregister(CallId, Link) ->
    do_call(CallId, {unregister, Link}).


%% @private
-spec get_all() ->
    [{id(), pid()}].

get_all() ->
    nklib_proc:values(?MODULE).


%% @doc
-spec get_call(id()) ->
    {ok, call()} | {error, term()}.

get_call(CallId) ->
    do_call(CallId, get_call).


% ===================================================================
%% gen_server behaviour
%% ===================================================================

-record(invite, {
    pos :: integer(),
    dest :: dest(),
    ring :: integer(),
    sdp_type :: webrtc | rtp,
    launched :: boolean(),
    timer :: reference(),
    link :: nklib:link()
}).

-record(state, {
    id :: id(),
    srv_id :: nkservice:id(),
    links :: nklib_links:links(),
    invites = [] :: [#invite{}],
    pos = 0 :: integer(),
    stop_sent = false :: boolean(),
    call :: call()
}).


%% @private
-spec init(term()) ->
    {ok, tuple()}.

init([#{srv_id:=SrvId, call_id:=CallId, callee:=Callee}=Call]) ->
    nklib_proc:put(?MODULE, CallId),
    nklib_proc:put({?MODULE, CallId}),
    State1 = #state{
        id = CallId, 
        srv_id = SrvId, 
        links = nklib_links:new(),
        call = Call
    },
    State2 = case Call of
        #{session_id:=SessId} -> 
            {ok, SessPid} = 
                nkmedia_session:register(SessId, {nkmedia_call, CallId, self()}),
            links_add(session, SessId, SessPid, State1);
        _ ->
            State1
    end,
    State3 = case Call of
        #{register:=Link} -> 
            links_add(Link, State2);
        _ ->
            State2
    end,
    gen_server:cast(self(), do_start),
    lager:info("NkMEDIA Call ~s starting to ~p (~p)", [CallId, Callee, self()]),
    handle(nkmedia_call_init, [CallId], State3).


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call({ringing, Link, Answer}, _From, State) ->
    case find_invite_by_link(Link, State) of
        {ok, _} ->
            % Launch event
            {reply, ok, event({ringing, Link, Answer}, State)};
        not_found ->
            {reply, {error, invite_not_found}, State} 
    end;

handle_call({answered, Link, Answer}, From, #state{call=Call}=State) ->
    case find_invite_by_link(Link, State) of
        {ok, #invite{pos=Pos}} ->
            % ?LLOG(info, "received ANSWER", [], State),
            gen_server:reply(From, ok),            
            State2 = cancel_all(Pos, State),
            Call2 = maps:remove(offer, Call#{callee_link=>Link}),
            State3 = State2#state{call=Call2},
            Pid = nklib_links:get_pid(Link),
            State4 = links_add(callee, Link, Pid, State3),
            {noreply, event({answer, Link, Answer}, State4)};
        not_found ->
            {reply, {error, invite_not_found}, State}
    end;

handle_call(get_call, _From, #state{call=Call}=State) -> 
    {reply, {ok, Call}, State};

handle_call({register, Link}, _From, State) ->
    ?LLOG(info, "proc registered (~p)", [Link], State),
    State2 = links_add(Link, State),
    {reply, {ok, self()}, State2};

handle_call({unregister, Link}, _From, State) ->
    ?LLOG(info, "proc unregistered (~p)", [Link], State),
    State2 = links_remove(Link, State),
    {reply, ok, State2};

handle_call(get_state, _From, State) ->
    {reply, State, State};

handle_call(Msg, From, State) -> 
    handle(nkmedia_call_handle_call, [Msg, From], State).


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast(do_start, #state{call=#{callee:=Callee}}=State) ->
    {ok, ExtDests, State2} = handle(nkmedia_call_resolve, [Callee, []], State),
    State3 = launch_invites(ExtDests, State2),
    ?LLOG(info, "Resolved ~p", [State3#state.invites], State),
    {noreply, State3};

handle_cast({rejected, Link}, State) ->
    case find_invite_by_link(Link, State) of
        {ok, #invite{pos=Pos}} ->
            remove_invite(Pos, State);
        not_found ->
            {noreply, State}
    end;

handle_cast({hangup, Reason}, State) ->
    ?LLOG(info, "external hangup: ~p", [Reason], State),
    do_hangup(Reason, State);

handle_cast(Msg, State) -> 
    handle(nkmedia_call_handle_cast, [Msg], State).


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info({launch_out, Pos}, State) ->
    case find_invite_by_pos(Pos, State) of
        {ok, #invite{launched=false, ring=Ring}=Out} ->
            Timer = erlang:send_after(1000*Ring, self(), {ring_timeout, Pos}),
            launch_out(Out#invite{timer=Timer}, State);
        {ok, Out} ->
            launch_out(Out, State);
        not_found ->
            % The call should have been removed because of timeout
            {noreply, State}
    end;

handle_info({ring_timeout, Pos}, #state{id=CallId}=State) ->
    case find_invite_by_pos(Pos, State) of
        {ok, #invite{dest=Dest, link=Link, launched=Launched}} ->
            ?LLOG(info, "call ring timeout for ~p (~p)", [Dest, Pos], State),
            {ok, State2} = case Launched of
                true -> 
                    handle(nkmedia_call_cancel, [CallId, Link], State);
                false ->
                    {ok, State}
            end,
            remove_invite(Pos, State2);
        not_found ->
            {noreply, State}
    end;

handle_info({'DOWN', Ref, process, _Pid, Reason}=Msg, State) ->
    case links_down(Ref, State) of
        {ok, Link, State2} ->
            case Reason of
                normal ->
                    ?LLOG(info, "linked ~p down (normal)", [Link], State);
                _ ->
                    ?LLOG(notice, "linked ~p down (~p)", [Link, Reason], State)
            end,
            case Link of
                callee ->
                    do_hangup(callee_stop, State2);
                session ->
                    do_hangup(session_stop, State2);
                _ ->
                    do_hangup(registered_stop, State2)
            end;
        not_found ->
            handle(nkmedia_call_handle_info, [Msg], State)
    end;

handle_info(Msg, #state{}=State) -> 
    handle(nkmedia_call_handle_info, [Msg], State).


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(Reason, State) ->
    State2 = cancel_all(State),
    {stop, normal, State3} = do_hangup(process_down, State2),
    catch handle(nkmedia_call_terminate, [Reason], State3),
    ?LLOG(info, "stopped: ~p", [Reason], State2).


% ===================================================================
%% Internal
%% ===================================================================

%% @private Generate data and launch messages
-spec launch_invites(callee() | [dest_ext()], State) ->
    State.

launch_invites([], #state{invites=Invs}=State) ->
    ?LLOG(info, "resolved invites: ~p", [Invs], State),
    case length(Invs) of
        0 -> 
            hangup(self(), no_destination);
        _ -> 
            ok
    end,        
    State;

launch_invites([#{dest:=Dest}=DestEx|Rest], #state{invites=Invs, pos=Pos}=State) ->
    Wait = case maps:find(wait, DestEx) of
        {ok, Wait0} -> Wait0;
        error -> 0
    end,
    Ring = case maps:find(ring, DestEx) of
        {ok, Ring0} -> min(Ring0, ?MAX_RING_TIMEOUT);
        error -> ?DEF_RING_TIMEOUT
    end,
    Inv = #invite{
        pos = Pos,
        dest = Dest, 
        ring = Ring, 
        launched = false,
        sdp_type = maps:get(sdp_type, DestEx, webrtc)
    },
    case Wait of
        0 -> self() ! {launch_out, Pos};
        _ -> erlang:send_after(1000*Wait, self(), {launch_out, Pos})
    end,
    launch_invites(Rest, State#state{invites=[Inv|Invs], pos=Pos+1});

launch_invites(Callee, State) ->
    launch_invites([#{dest=>Callee}], State).


%% @private
launch_out(Inv, #state{id=CallId, invites=Invs, call=Call}=State) ->
    #invite{pos=Pos, dest=Dest} = Inv,
    Offer = maps:get(offer, Call, #{}),
    Meta = maps:get(meta, Call, #{}),
    case handle(nkmedia_call_invite, [CallId, Dest, Offer, Meta], State) of
        {ok, Link, State2} ->
            ?LLOG(info, "launching out ~p (~p)", [Dest, Pos], State),
            Inv2 = Inv#invite{launched=true, link=Link},
            Invs2 = lists:keystore(Pos, #invite.pos, Invs, Inv2),
            {noreply, State2#state{invites=Invs2}};
        {retry, Secs, State2} ->
            ?LLOG(notice, "retrying out ~p (~p, ~p secs)", [Dest, Pos, Secs], State),
            erlang:send_after(1000*Secs, self(), {launch_out, Pos}),
            {noreply, State2};
        {remove, State2} ->
            ?LLOG(notice, "removing out ~p (~p)", [Dest, Pos], State),
            remove_invite(Pos, State2)
    end.


%% @private
find_invite_by_pos(Pos, #state{invites=Invs}) ->
   case lists:keyfind(Pos, #invite.pos, Invs) of
        #invite{} = Inv -> {ok, Inv};
        false -> not_found
    end.


%% @private
find_invite_by_link(Link, #state{invites=Invs}) ->
   case lists:keyfind(Link, #invite.link, Invs) of
        #invite{} = Inv -> {ok, Inv};
        false -> not_found
    end.


%% @private
remove_invite(Pos, #state{invites=Invs}=State) ->
    case lists:keytake(Pos, #invite.pos, Invs) of
        {value, #invite{}, []} ->
            ?LLOG(info, "all invites removed", [], State),
            do_hangup(no_answer, State#state{invites=[]});
        {value, #invite{pos=Pos}, Invs2} ->
            ?LLOG(info, "removed invite (~p)", [Pos], State),
            {noreply, State#state{invites=Invs2}};
        false ->
            {noreply, State}
    end.


%% @private
cancel_all(State) ->
    cancel_all(-1, State).


%% @private
cancel_all(Except, #state{id=CallId, invites=Invs}=State) ->
    State2 = lists:foldl(
        fun(#invite{link=Link, pos=Pos, timer=Timer}, Acc) ->
            nklib_util:cancel_timer(Timer),
            case Pos of
                Except ->
                    Acc;
                _ ->
                    ?LLOG(info, "sending CANCEL to ~p", [Link], State),
                    {ok, Acc2} = handle(nkmedia_call_cancel, [CallId, Link], Acc),
                    Acc2
            end
        end,
        State,
        Invs),
    State2#state{invites=[]}.


%% @private
do_hangup(Reason, #state{stop_sent=Sent}=State) ->
    State2 = case Sent of
        false -> event({hangup, Reason}, State);
        true -> State
    end,
    timer:sleep(100),   % Allow events
    {stop, normal, State2#state{stop_sent=true}}.


%% @private
event(Event, #state{id=Id}=State) ->
    case Event of
        {answer, Link, _Ans} ->
            ?LLOG(info, "sending 'event': ~p", [{answer, <<"sdp">>, Link}], State);
        _ ->
            ?LLOG(info, "sending 'event': ~p", [Event], State)
    end,
    Links = links_fold(
        fun
            (session, SessId, Acc) -> [{nkmedia_session, SessId}|Acc];
            (callee, Link, Acc) -> [Link|Acc];
            (Link, _Data, Acc) -> [Link|Acc]
        end,
        [],
        State),
    State2 = lists:foldl(
        fun(Link, AccState) ->
            {ok, AccState2} = 
                handle(nkmedia_call_reg_event, [Id, Link, Event], AccState),
            AccState2
        end,
        State,
        Links),
    {ok, State3} = handle(nkmedia_call_event, [Id, Event], State2),
    State3.


%% @private
handle(Fun, Args, State) ->
    nklib_gen_server:handle_any(Fun, Args, State, #state.srv_id, #state.call).


%% @private
do_call(CallId, Msg) ->
    do_call(CallId, Msg, 5000).


%% @private
do_call(CallId, Msg, Timeout) ->
    case find(CallId) of
        {ok, Pid} -> nkservice_util:call(Pid, Msg, Timeout);
        not_found -> {error, call_not_found}
    end.


%% @private
do_cast(CallId, Msg) ->
    case find(CallId) of
        {ok, Pid} -> gen_server:cast(Pid, Msg);
        not_found -> {error, call_not_found}
    end.

%% @private
find(Pid) when is_pid(Pid) ->
    {ok, Pid};

find(CallId) ->
    case nklib_proc:values({?MODULE, CallId}) of
        [{undefined, Pid}] -> {ok, Pid};
        [] -> not_found
    end.



%% @private
links_add(Link, #state{links=Links}=State) ->
    State#state{links=nklib_links:add(Link, Links)}.


%% @private
links_add(Link, Data, Pid, #state{links=Links}=State) ->
    State#state{links=nklib_links:add(Link, Data, Pid, Links)}.


%% @private
links_remove(Link, #state{links=Links}=State) ->
    State#state{links=nklib_links:remove(Link, Links)}.


%% @private
links_down(Ref, #state{links=Links}=State) ->
    case nklib_links:down(Ref, Links) of
        {ok, Link, _Data, Links2} -> 
            {ok, Link, State#state{links=Links2}};
        not_found -> 
            not_found
    end.


%% @private
links_fold(Fun, Acc, #state{links=Links}) ->
    nklib_links:fold_values(Fun, Acc, Links).






