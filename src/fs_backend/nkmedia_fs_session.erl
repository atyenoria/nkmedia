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

%% @doc Session Management
-module(nkmedia_fs_session).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/2, offer/3, answer/3, update/3, stop/2]).
-export([handle_call/3, handle_cast/2, fs_event/3, send_bridge/2]).

-export_type([session/0, type/0, opts/0, update/0]).

-define(LLOG(Type, Txt, Args, Session),
    lager:Type("NkMEDIA FS Session ~s "++Txt, 
               [maps:get(session_id, Session) | Args])).

-define(LLOG2(Type, Txt, Args, SessId),
    lager:Type("NkMEDIA FS Session ~s "++Txt, 
               [SessId | Args])).


-include("../../include/nkmedia.hrl").



%% ========================= ==========================================
%% Types
%% ===================================================================

-type session_id() :: nkmedia_session:id().
-type continue() :: continue | {continue, list()}.


-type session() :: 
    nkmedia_session:session() |
    #{
        nkmedia_fs_id => nmedia_fs_engine:id()
    }.
    

-type type() ::
    nkmedia_session:type() |
    park    |
    echo    |
    mcu     |
    bridge.


-type opts() ::  
    nkmedia_session:session() |
    #{
    }.


-type update() ::
    nkmedia_session:update().


-type fs_event() ::
    parked | {hangup, term()} | {bridge, session_id()} | {mcu, map()} | stop.



%% ===================================================================
%% External
%% ===================================================================


%% @private Called from nkmedia_fs_engine and nkmedia_fs_verto
-spec fs_event(session_id(), nkmedia_fs:id(), fs_event()) ->
    ok.

fs_event(SessId, FsId, Event) ->
    case session_cast(SessId, {fs_event, FsId, Event}) of
        ok -> 
            ok;
        {error, _} when Event==stop ->
            ok;
        {error, _} -> 
            ?LLOG(warning, "FS event ~p for unknown session", [Event], SessId) 
    end.


%% @private
send_bridge(Remote, Local) ->
    session_cast(Remote, {bridge, Local}).





%% ===================================================================
%% Callbacks
%% ===================================================================


%% @private
-spec start(nkmedia_session:type(), session()) ->
    {ok, session()} |
    {error, nkservice:error(), session()} | continue().

start(Type, Session) ->
    case is_supported(Type) of
        true ->
            Update = #{
                backend => nkmedia_fs, 
                no_offer_trickle_ice => true,
                no_answer_trickle_ice => true
            },
            Session2 = ?SESSION(Update, Session),
            case get_engine(Session2) of
                {ok, Session3} ->
                    do_start(Session3);
                {error, Error} ->
                    {error, Error, Session2}
            end;
        false ->
            continue
    end.


do_start(#{offer:=_}=Session) ->
    %% Wait for offer callback
    {ok, Session};

do_start(Session) ->
    case get_fs_offer(Session) of
        {ok, Offer} ->
            {ok, ?SESSION(#{offer=>Offer}, Session)};
        {error, Error, Session} ->
            {error, Error, Session}
    end.
                    


%% @private
-spec offer(type(), nkmedia:offer(), session()) ->
    {ok, session()} | {error, nkservice:error(), session()}.

offer(_Type, #{backend:=nkmedia_fs}, Session) ->
    {ok, Session};

offer(Type, Offer, Session) ->
    case get_fs_answer(Offer, Session) of
        {ok, Answer}  ->
            do_start_type(Type, ?SESSION(#{answer=>Answer}, Session));
        {error, Error} ->
            {error, Error, Session}
    end.


%% @private
-spec answer(type(), nkmedia:answer(), session()) ->
    {ok, session()} | {error, nkservice:error(), session()}.

answer(_Type, #{backend:=nkmedia_fs}, Session) ->
    {ok, Session};

answer(Type, Answer, #{session_id:=SessId, offer:=Offer}=Session) ->
    SdpType = maps:get(sdp_type, Offer, webrtc),
    Mod = fs_mod(SdpType),
    case Mod:answer_out(SessId, Answer) of
        ok ->
            wait_park(Session),
            do_start_type(Type, Session);
        {error, Error} ->
            {error, Error, Session}
    end.


%% @private
-spec update(update(), Opts::map(), session()) ->
    {ok, Reply::term(), session()} | {error, term(), session()} | continue().

update(session_type, #{session_type:=Type}=Opts, Session) ->
    case check_record(Opts, Session) of
        {ok, Session2} ->
            case do_type(Type, Opts, Session2) of
                {ok, TypeExt, Session3} -> 
                    update_type(Type, TypeExt),
                    {ok, TypeExt, Session3};
                {error, Error, Session3} ->
                    {error, Error, Session3}
            end;
        {error, Error} ->
            {error, Error, Session}
    end;

update(media, Opts, Session) ->
    case check_record(Opts, Session) of
        {ok, Session2} ->
            %% TODO: update medias
            {ok, #{}, Session2};
        {error, Error} ->
            {error, Error, Session}
    end;

update(mcu_layout, #{mcu_layout:=Layout}, 
       #{type:=mcu, type_ext:=#{room_id:=Room}=Ext, nkmedia_fs_id:=FsId}=Session) ->
    case nkmedia_fs_cmd:conf_layout(FsId, Room, Layout) of
        ok  ->
            update_type(mcu, Ext#{mcu_layout=>Layout}),
            {ok, #{}, Session};
        {error, Error} ->
            {error, Error, Session}
    end;

update(_Update, _Opts, _Session) ->
    continue.


%% @private
-spec stop(nkservice:error(), session()) ->
    {ok, session()}.

stop(_Reason, #{session_id:=SessId, nkmedia_fs_id:=FsId}=Session) ->
    Session2 = reset_type(Session),
    nkmedia_fs_cmd:hangup(FsId, SessId),
    {ok, Session2};

stop(_Reason, Session) ->
    {ok, Session}.


%% @private Called from nkmedia_fs_callbacks
handle_cast({bridge_stop, PeerId}, #{nkmedia_fs_bridged_to:=PeerId}=Session) ->
    ?LLOG(info, "received bridge stop from ~s", [PeerId], Session),
    case nkmedia_session:bridge_stop(PeerId, Session) of
        {ok, Session2} ->
            Session3 = reset_type(Session2),
            % In case we were linked
            nkmedia_session:unlink_session(self(), PeerId),
            nkmedia_session:update_type(park, #{}),
            {noreply, Session3};
        {stop, Session2} ->
            nkmedia_session:stop(self(), bridge_stop),
            {noreply, Session2}
    end;

handle_cast({bridge_stop, PeerId}, Session) ->
    ?LLOG(notice, "ignoring bridge stop from ~s", [PeerId], Session),
    {noreply, Session};

handle_cast({fs_event, FsId, Event}, #{nkmedia_fs_id:=FsId, type:=Type}=Session) ->
    do_fs_event(Event, Type, Session),
    {noreply, Session};

handle_cast({fs_event, _FsId, _Event}, Session) ->
    ?LLOG(warning, "received FS Event for unknown FsId!", [], Session),
    {noreply, Session}.


%% @private Called from nkmedia_fs_callbacks
handle_call({bridge, PeerId}, _From, Session) ->
    case fs_bridge(PeerId, Session) of
        ok ->
            update_type(bridge, #{peer_id=>PeerId}),
            Session2 = ?SESSION(#{nkmedia_fs_bridged_to=>PeerId}, Session),
            ?LLOG(info, "received remote ~s bridge request", [PeerId], Session),
            {reply, ok, Session2};
        {error, Error} ->
            ?LLOG(notice, "error when received remote ~s bridge: ~p", 
                  [PeerId, Error], Session),
            {reply, {error, Error}, Session}
    end.


%% ===================================================================
%% Internal
%% ===================================================================

%% @private
is_supported(park) -> true;
is_supported(echo) -> true;
is_supported(mcu) -> true;
is_supported(bridge) -> true;
is_supported(_) -> false.



%% @private
-spec do_start_type(type(), session()) ->
    {ok, session()} | {error, nkservice:error(), session()}.

do_start_type(Type, Session) ->
    case check_record(Session, Session) of
        {ok, Session2} ->
            case do_type(Type, Session2, Session2) of
                {ok, TypeExt, Session3} ->
                    update_type(Type, TypeExt),
                    {ok, Session3};
                {error, Error, Session3} ->
                    {error, Error, Session3}
            end;
        {error, Error} ->
            {error, Error, Session}
    end.


%% @private
-spec do_type(type(), map(), session()) ->
    {ok, nkmedia_session:type_ext(), session()} |
    {error, nkservice:error(), session()}.

do_type(park, _Opts, #{type:=park}=Session) ->
    {ok, #{}, Session};
    
do_type(park, _Opts, Session) ->
    Session2 = reset_type(Session),
    case fs_transfer("park", Session) of
        ok ->
            {ok, #{}, Session2};
        {error, Error} ->
            {error, Error, Session2}
    end;

do_type(echo, _Opts, Session) ->
    Session2 = reset_type(Session),
    case fs_transfer("echo", Session2) of
        ok ->
            {ok, #{}, Session2};
        {error, Error} ->
            {error, Error, Session2}
    end;

do_type(mcu, Opts, Session) ->
    Session2 = reset_type(Session),
    Room = case maps:find(room_id, Opts) of
        {ok, Room0} -> nklib_util:to_binary(Room0);
        error -> nklib_util:uuid_4122()
    end,
    RoomType = maps:get(room_type, Opts, <<"video-mcu-stereo">>),
    Cmd = [<<"conference:">>, Room, <<"@">>, RoomType],
    case fs_transfer(Cmd, Session) of
        ok ->
            TypeExt = #{room_id=>Room, room_type=>RoomType},
            {ok, TypeExt, Session2};
        {error, Error} ->
            {error, Error, Session2}
    end;

do_type(bridge, #{peer_id:=PeerId}, #{session_id:=SessId}=Session) ->
    Session2 = reset_type(Session),
    case session_call(PeerId, {bridge, SessId}) of
        ok ->
            ?LLOG(info, "bridged accepted at ~s", [PeerId], Session),
            Session3 = ?SESSION(#{nkmedia_fs_bridged_to=>PeerId}, Session2),
            {ok, #{peer_id=>PeerId}, Session3};
        {error, Error} ->
            ?LLOG(notice, "bridged not accepted at ~s", [PeerId], Session),
            {error, Error, Session2}
    end;

do_type(_Type, _Opts, Session) ->
    {error, invalid_operation, Session}.


%% @private
get_fs_answer(Offer, #{nkmedia_fs_id:=FsId, session_id:=SessId}=Session) ->
    case nkmedia_fs_verto:start_in(SessId, FsId, Offer) of
        {ok, SDP} ->
            wait_park(Session),
            Answer = #{
                sdp => SDP,
                trickle_ice => false,
                sdp_type => webrtc,
                backend => nkmedia_fs
            },
            {ok, Answer};
        {error, Error} ->
            ?LLOG(warning, "error calling start_in: ~p", [Error], Session),
            {error, fs_get_answer_error}
    end.



%% @private
get_fs_offer(#{nkmedia_fs_id:=FsId, session_id:=SessId}=Session) ->
    Type = maps:get(sdp_type, Session, webrtc),
    Mod = fs_mod(Type),
    case Mod:start_out(SessId, FsId, #{}) of
        {ok, SDP} ->
            Offer = #{
                sdp => SDP,
                trickle_ice => false,
                sdp_type => Type,
                backend => nkmedia_fs
            },
            {ok, Offer};
        {error, Error} ->
            ?LLOG(warning, "error calling start_out: ~p", [Error], Session),
            {error, fs_get_offer_error}
    end.


%% @private
-spec get_engine(session()) ->
    {ok, session()} | {error, term()}.

get_engine(#{nkmedia_fs_id:=_}=Session) ->
    {ok, Session};

get_engine(#{srv_id:=SrvId}=Session) ->
    case SrvId:nkmedia_fs_get_mediaserver(SrvId) of
        {ok, Id} ->
            {ok, ?SESSION(#{nkmedia_fs_id=>Id}, Session)};
        {error, Error} ->
            {error, Error}
    end.


%% @private Adds or removed medias in the EP -> Proxy path
-spec check_record(map(), session()) ->
    {ok, session()} | {error, term()}.

check_record(Opts, Session) ->
    case Opts of
        #{record:=true} ->
            % TODO start record
            {ok, Session};
        #{record:=false} ->
            {ok, Session};
        _ ->
            {ok, Session}
    end.


%% @private
-spec reset_type(session()) ->
    {ok, session()} | {error, term()}.

reset_type(#{session_id:=SessId}=Session) ->
    % TODO: Check player
    case Session of
        #{nkmedia_fs_bridged_to:=PeerId} ->
            ?LLOG(info, "sending bridge stop to ~s", [PeerId], Session),
            session_cast(PeerId, {bridge_stop, SessId}),
            % In case we were linked
            nkmedia_session:unlink_session(self(), PeerId),
            Session2 = ?SESSION_RM(nkmedia_fs_bridged_to, Session);
        _ ->
            Session2 = Session
    end,
    Session2.


%% @private
fs_transfer(Dest, #{session_id:=SessId, nkmedia_fs_id:=FsId}=Session) ->
    ?LLOG(info, "sending transfer to ~s", [Dest], Session),
    case nkmedia_fs_cmd:transfer_inline(FsId, SessId, Dest) of
        ok ->
            ok;
        {error, Error} ->
            ?LLOG(warning, "transfer error: ~p", [Error], Session),
            {error, fs_transfer_error}
    end.


%% @private
fs_bridge(SessIdB, #{session_id:=SessIdA, nkmedia_fs_id:=FsId}=Session) ->
    case nkmedia_fs_cmd:set_var(FsId, SessIdA, "park_after_bridge", "true") of
        ok ->
            case nkmedia_fs_cmd:set_var(FsId, SessIdB, "park_after_bridge", "true") of
                ok ->
                    ?LLOG(info, "sending bridge to ~s", [SessIdB], Session),
                    nkmedia_fs_cmd:bridge(FsId, SessIdA, SessIdB);
                {error, Error} ->
                    ?LLOG(warning, "FS bridge error: ~p", [Error], Session),
                    error
            end;
        {error, Error} ->
            ?LLOG(warning, "FS bridge error: ~p", [Error], Session),
            {error, fs_bridge_error}
    end.



%% @private
do_fs_event(parked, park, _Session) ->
    ok;

do_fs_event(parked, _Type, Session) ->
    ?LLOG(notice, "received parked in ~p!", [_Type], Session),
    % case Session of
    %     #{park_after_bridge:=true} ->
    %         nkmedia_session:unlink_session(self()),
    %         nkmedia_session:ext_ops(self(), #{type=>park});
    %     _ ->
    %         nkmedia_session:stop(self(), peer_hangup)
    % end;
    nkmedia_session:stop(self(), peer_hangup);

do_fs_event({bridge, PeerId}, bridge, Session) ->
    case Session of
        #{type_ext:=#{peer_id:=PeerId}} ->
            ok;
        #{type_ext:=Ext} ->
            ?LLOG(warning, "received bridge for different peer ~s: ~p!", 
                  [PeerId, Ext], Session)
    end,
    update_type(bridge, #{peer_id=>PeerId});

do_fs_event({bridge, PeerId}, Type, Session) ->
    ?LLOG(warning, "received bridge in ~p state", [Type], Session),
    update_type(bridge, #{peer_id=>PeerId});

do_fs_event({mcu, McuInfo}, mcu, Session) ->
    ?LLOG(info, "FS MCU Info: ~p", [McuInfo], Session),
    {ok, Session};

do_fs_event(mcu, Type, Session) ->
    ?LLOG(warning, "received mcu in ~p state", [Type], Session),
    update_type(mcu, #{});

do_fs_event({hangup, Reason}, _Type, Session) ->
    ?LLOG(warning, "received hangup from FS: ~p", [Reason], Session),
    nkmedia_session:stop(self(), Reason);

do_fs_event(stop, _Type, Session) ->
    ?LLOG(info, "received stop from FS", [], Session),
    nkmedia_session:stop(self(), fs_channel_stop);
   
do_fs_event(Event, Type, Session) ->
    ?LLOG(warning, "received FS event ~p in type '~p'!", [Event, Type], Session).


%% @private
fs_mod(webrtc) ->nkmedia_fs_verto;
fs_mod(rtp) -> nkmedia_fs_sip.



%% @private
wait_park(Session) ->
    receive
        {'$gen_cast', {nkmedia_fs, {fs_event, _, parked}}} -> ok
    after 
        2000 -> 
            ?LLOG(warning, "parked not received", [], Session)
    end.


%% @private
update_type(Type, TypeExt) ->
    nkmedia_session:set_type(self(), Type, TypeExt).


%% @private
session_call(SessId, Msg) ->
    nkmedia_session:do_call(SessId, {nkmedia_fs, Msg}).


%% @private
session_cast(SessId, Msg) ->
    nkmedia_session:do_cast(SessId, {nkmedia_fs, Msg}).




% Layouts
% 1up_top_left+5
% 1up_top_left+7
% 1up_top_left+9
% 1x1
% 1x1+2x1
% 1x2
% 2up_bottom+8
% 2up_middle+8
% 2up_top+8
% 2x1
% 2x1-presenter-zoom
% 2x1-zoom
% 2x2
% 3up+4
% 3up+9
% 3x1-zoom
% 3x2-zoom
% 3x3
% 4x2-zoom
% 4x4, 
% 5-grid-zoom
% 5x5
% 6x6
% 7-grid-zoom
% 8x8
% overlaps
% presenter-dual-horizontal
% presenter-dual-vertical
% presenter-overlap-large-bot-right
% presenter-overlap-large-top-right
% presenter-overlap-small-bot-right
% presenter-overlap-small-top-right

