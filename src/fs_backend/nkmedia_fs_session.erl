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

-export([start/3, answer/4, update/4, stop/2, client_trickle_ready/2]).
-export([handle_cast/2, fs_event/3, send_bridge/2]).

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
-type from() :: {pid(), term()}.
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
    bridge  |
    call.

-type ext_ops() :: nkmedia_session:ext_ops().


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
    case send_cast(SessId, {fs_event, FsId, Event}) of
        ok -> 
            ok;
        {error, _} when Event==stop ->
            ok;
        {error, _} -> 
            ?LLOG(warning, "FS event ~p for unknown session", [Event], SessId) 
    end.


%% @private
send_bridge(Remote, Local) ->
    send_cast(Remote, {bridge, Local}).





%% ===================================================================
%% Callbacks
%% ===================================================================



%% @private
-spec start(type(), from(), session()) ->
    {ok, Reply::term(), ext_ops(), session()} |
    {ok, ext_ops(), session()} |
    {error, nkservice:error(), session()} | continue().

start(Type, From, #{offer:=#{sdp:=_}=Offer}=Session) ->
    Trickle = maps:get(trickle_ice, Offer, false),
    case is_supported(Type) of
        true when Trickle == true ->
            Info = #{from=>From},
            Session2 = ?SESSION(#{nkmedia_fs_trikcle=>Info}, Session),
            {wait_client_ice, Session2};
        true ->  
            Session2 = ?SESSION(#{backend=>nkmedia_kms}, Session),
            case get_fs_answer(Session2) of
                {ok, Answer, Session3}  ->
                    case do_type(Type, Session3, Session3) of
                        {ok, Reply, ExtOps, Session4} ->
                            Reply2 = Reply#{answer=>Answer},
                            ExtOps2 = ExtOps#{answer=>Answer},
                            {ok, Reply2, ExtOps2, Session4};
                        {error, Error, Session4} ->
                            {error, Error, Session4}
                    end;
                {error, Error, Session3} ->
                    {error, Error, Session3}
            end;
        false ->
            continue
    end;

start(Type, _From, Session) ->
    case 
        is_supported(Type) orelse
        (Type==call andalso maps:is_key(master_peer, Session))
    of
        true ->  
            case get_fs_offer(Session) of
                {ok, Offer, Session2} ->
                    Reply = ExtOps = #{offer=>Offer},
                    {ok, Reply, ExtOps, Session2};
                {error, Error, Session2} ->
                    {error, Error, Session2}
            end;
        false ->
            continue
    end.


%% @private
-spec answer(type(), nkmedia:answer(), from(), session()) ->
    {ok, Reply::term(), ext_ops(), session()} |
    {ok, ext_ops(), session()} |
    {error, term(), session()} | continue().

answer(Type, Answer, _From, #{session_id:=SessId, offer:=Offer}=Session) ->
    SdpType = maps:get(sdp_type, Offer, webrtc),
    Mod = fs_mod(SdpType),
    case Mod:answer_out(SessId, Answer) of
        ok ->
            wait_park(Session),
            case Type of
                call ->
                    #{master_peer:=Peer} = Session,
                    {ok, #{}, #{answer=>Answer, type_ext=>#{peer_id=>Peer}}, Session};
                _ ->
                    case do_type(Type, Session, Session) of
                        {ok, Reply, ExtOps, Session2} ->
                            {ok, Reply, ExtOps#{answer=>Answer}, Session2};
                        {error, Error, Session2} ->
                            {error, Error, Session2}
                    end
            end;
        {error, Error} ->
            ?LLOG(warning, "error in answer_out: ~p", [Error], Session),
            {error, fs_error, Session}
    end;

answer(_Type, _Answer, _From, _Session) ->
    continue.


%% @private
-spec client_trickle_ready([nkmedia:candidate()], session()) ->
    {ok, ext_ops(), session()} | {error, nkservice:error()}.

client_trickle_ready(Candidates, #{type:=Type, nkmedia_fs_trickle:=Info}=Session) ->
    #{from:=From} = Info,
    #{offer:=#{sdp:=SDP}=Offer} = Session,
    SDP2 = nksip_sdp_util:add_candidates(SDP, Candidates),
    Offer2 = Offer#{sdp:=nksip_sdp:unparse(SDP2), trickle_ice=>false},
    Session2 = ?SESSION(#{offer=>Offer2}, Session),
    Session3 = ?SESSION_RM(nkmedia_fs_trickle, Session2),
    start(Type, From, Session3).


%% @private
-spec update(update(), Opts::map(), from(), session()) ->
    {ok, Reply::term(), ext_ops(), session()} |
    {ok, ext_ops(), session()} |
    {error, term(), session()} | continue().

update(session_type, #{session_type:=Type}=Opts, _From, Session) ->
    do_type(Type, Opts, Session);

update(mcu_layout, #{mcu_layout:=Layout}, _From, 
       #{type:=mcu, type_ext:=#{room_id:=Room}=Ext, nkmedia_fs_id:=FsId}=Session) ->
    case nkmedia_fs_cmd:conf_layout(FsId, Room, Layout) of
        ok  ->
            ExtOps = #{type_ext=>Ext#{mcu_layout=>Layout}},
            {ok, #{}, ExtOps, Session};
        {error, Error} ->
            {error, Error, Session}
    end;

update(_Update, _Opts, _From, _Session) ->
    continue.


%% @private
-spec stop(nkservice:error(), session()) ->
    {ok, session()}.

stop(_Reason, #{session_id:=SessId, nkmedia_fs_id:=FsId}=Session) ->
    Session2 = reset_type(Session),
    nkmedia_fs_cmd:hangup(FsId, SessId),
    {ok, Session2}.


%% @private Called from nkmedia_fs_callbacks
-spec handle_cast(term(), session()) ->
    {noreply, session()}.

handle_cast({fs_event, FsId, Event}, #{nkmedia_fs_id:=FsId, type:=Type}=Session) ->
    do_fs_event(Event, Type, Session),
    {noreply, Session};

handle_cast({fs_event, _FsId, _Event}, Session) ->
    ?LLOG(warning, "received FS Event for unknown FsId!", [], Session),
    {noreply, Session};

handle_cast({bridge, PeerId}, Session) ->
    ?LLOG(notice, "received remote ~s bridge request", [PeerId], Session),
    case fs_bridge(PeerId, Session) of
        ok ->
            Ops = #{type=>bridge, type_ext=>#{peer_id=>PeerId}},
            nkmedia_session:ext_ops(self(), Ops);
        {error, Error} ->
            ?LLOG(warning, "bridge error: ~p", [Error], Session),
            nkmedia_session:stop(self(), fs_bridge_error)
    end,
    {noreply, Session}.


%% ===================================================================
%% Internal
%% ===================================================================


%% @private
do_type(park, _Opts, Session) ->
    Session2 = reset_type(Session),

    nkmedia_session:unlink_session(self()),
    case fs_transfer("park", Session) of
        ok ->
            {ok, #{}, #{type=>park}, Session};
        {error, Error} ->
            {error, Error, Session}
    end;

do_type(echo, _Opts, Session) ->
    nkmedia_session:unlink_session(self()),
    case fs_transfer("echo", Session) of
        ok ->
            {ok, #{}, #{type=>echo}, Session};
        {error, Error} ->
            {error, Error, Session}
    end;

do_type(mcu, Opts, Session) ->
    nkmedia_session:unlink_session(self()),
    Room = case maps:find(room_id, Opts) of
        {ok, Room0} -> nklib_util:to_binary(Room0);
        error -> nklib_util:uuid_4122()
    end,
    RoomType = maps:get(room_type, Opts, <<"video-mcu-stereo">>),
    Cmd = [<<"conference:">>, Room, <<"@">>, RoomType],
    case fs_transfer(Cmd, Session) of
        ok ->
            ExtOps = #{type=>mcu, type_ext=>#{room_id=>Room, room_type=>RoomType}},
            {ok, #{room_id=>Room}, ExtOps, Session};
        {error, Error} ->
            {error, Error, Session}
    end;

do_type(bridge, #{peer_id:=PeerId}, #{session_id:=SessId}=Session) ->
    nkmedia_session:unlink_session(self()),
    send_bridge(PeerId, SessId),
    ExtOps = #{type=>bridge, type_ext=>#{peer_id=>PeerId}},
    {ok, #{}, ExtOps, Session};

do_type(_Op, _Session, _Session) ->
    continue.


 %% @private
is_supported(park) -> true;
is_supported(echo) -> true;
is_supported(mcu) -> true;
is_supported(bridge) -> true;
is_supported(_) -> false.


%% @private
get_fs_answer(#{nkmedia_fs_id:=FsId, session_id:=SessId, offer:=Offer}=Session) ->
    case nkmedia_fs_verto:start_in(SessId, FsId, Offer) of
        {ok, SDP} ->
            wait_park(Session),
            {ok, #{sdp=>SDP}, Session};
        {error, Error} ->
            ?LLOG(warning, "error calling start_in: ~p", [Error], Session),
            {error, fs_get_answer_error, Session}
    end;

get_fs_answer(Session) ->
    case get_mediaserver(Session) of
        {ok, Session2} ->
            get_fs_answer(Session2);
        {error, Error} ->
            {error, Error, Session}
    end.


%% @private
get_fs_offer(#{nkmedia_fs_id:=FsId, session_id:=SessId}=Session) ->
    Type = maps:get(sdp_type, Session, webrtc),
    Mod = fs_mod(Type),
    case Mod:start_out(SessId, FsId, #{}) of
        {ok, SDP} ->
            {ok, #{sdp=>SDP}, Session};
        {error, Error} ->
            ?LLOG(warning, "error calling start_out: ~p", [Error], Session),
            {error, fs_get_offer_error, Session}
    end;

get_fs_offer(Session) ->
    case get_mediaserver(Session) of
        {ok, Session2} ->
            get_fs_offer(Session2);
        {error, Error} ->
            {error, Error, Session}
    end.


%% @private
-spec get_mediaserver(session()) ->
    {ok, session()} | {error, term()}.

get_mediaserver(#{nkmedia_fs_id:=_}=Session) ->
    {ok, Session};

get_mediaserver(#{srv_id:=SrvId}=Session) ->
    case SrvId:nkmedia_fs_get_mediaserver(SrvId) of
        {ok, Id} ->
            {ok, ?SESSION(#{nkmedia_fs_id=>Id}, Session)};
        {error, Error} ->
            {error, Error}
    end.


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
    case Session of
        #{park_after_bridge:=true} ->
            nkmedia_session:unlink_session(self()),
            nkmedia_session:ext_ops(self(), #{type=>park});
        _ ->
            nkmedia_session:stop(self(), peer_hangup)
    end;

do_fs_event({bridge, PeerId}, Type, Session) when Type==bridge; Type==call ->
    case Session of
        #{type_ext:=#{peer_id:=PeerId}} ->
            ok;
        #{type_ext:=Ext} ->
            ?LLOG(warning, "received bridge for different peer ~s: ~p!", 
                  [PeerId, Ext], Session)
    end,
    nkmedia_session:ext_ops(self(), #{type=>bridge, type_ext=>#{peer_id=>PeerId}});

do_fs_event({bridge, PeerId}, Type, Session) ->
    ?LLOG(warning, "received bridge in ~p state", [Type], Session),
    nkmedia_session:ext_ops(self(), #{type=>bridge, type_ext=>#{peer_id=>PeerId}});

do_fs_event({mcu, McuInfo}, mcu, Session) ->
    ?LLOG(info, "FS MCU Info: ~p", [McuInfo], Session),
    {ok, Session};

do_fs_event(mcu, Type, Session) ->
    ?LLOG(warning, "received mcu in ~p state", [Type], Session),
    nkmedia_session:ext_ops(self(), #{type=>mcu, type_ext=>#{}});

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
        {'$gen_cast', {nkmedia_fs_session, {fs_event, _, parked}}} -> ok
    after 
        2000 -> 
            ?LLOG(warning, "parked not received", [], Session)
    end.

%% @private
send_cast(SessId, Msg) ->
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

