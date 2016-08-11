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

%% @doc Plugin implementing a SIP server and client
-module(nkmedia_sip_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([plugin_deps/0, plugin_syntax/0, plugin_defaults/0, plugin_config/2, 
         plugin_start/2, plugin_stop/2]).
-export([error_code/1]).
-export([nkmedia_sip_invite/5]).
-export([nkmedia_sip_invite_ringing/2, nkmedia_sip_invite_rejected/1, 
         nkmedia_sip_invite_answered/2]).
-export([sip_get_user_pass/4, sip_authorize/3]).
-export([sip_register/2, sip_invite/2, sip_reinvite/2, sip_cancel/3, sip_bye/2]).
-export([nkmedia_call_resolve/3, nkmedia_call_invite/5, nkmedia_call_cancel/3,
         nkmedia_call_reg_event/4]).
-export([nkmedia_session_reg_event/4]).

-include_lib("nklib/include/nklib.hrl").


%% ===================================================================
%% Types
%% ===================================================================


-type continue() :: continue | {continue, list()}.

-record(sip_config, {
    registrar :: boolean(),
    domain :: binary(),
    force_domain :: boolean(),
    invite_not_registered :: boolean
}).



%% ===================================================================
%% Plugin callbacks
%% ===================================================================


plugin_deps() ->
    [nkmedia, nksip].


plugin_syntax() ->
    #{
        sip_registrar => boolean,
        sip_domain => binary,
        sip_registrar_force_domain => boolean,
        sip_invite_not_registered => boolean
    }.


plugin_defaults() ->
    #{
        sip_registrar => true,
        sip_domain => <<"nkmedia">>,
        sip_registrar_force_domain => true,
        sip_invite_not_registered => true
    }.


plugin_config(Config, _Service) ->
    #{
        sip_registrar := Registrar,
        sip_domain := Domain,
        sip_registrar_force_domain := Force,
        sip_invite_not_registered := External
    } = Config,
    Config2 = #sip_config{
        registrar = Registrar,
        domain = Domain,
        force_domain = Force,
        invite_not_registered = External
    },
    {ok, Config, Config2}.


plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA SIP (~s) starting", [Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA SIP (~p) stopping", [Name]),
    {ok, Config}.



%% ===================================================================
%% Offering Callbacks
%% ===================================================================

%% @doc Called when a new SIP invite arrives
-spec nkmedia_sip_invite(nkservice:id(), binary(),
                         nkmedia:offer(), nksip:request(), nksip:call()) ->
    {ok, nkmedia_sip:id()} | {rejected, nkservice:error()} | continue().

nkmedia_sip_invite(SrvId, Dest, Offer, _Req, _Call) ->
    case start_session(SrvId, Dest, Offer) of
        {ok, {CallType, Callee, Offer2, SessId, _SessPid}} ->
            Config = #{
                type => CallType,
                callee => Callee, 
                offer => Offer2, 
                session_id => SessId,
                register => {nkmedia_sip, self()},
                meta => #{}
            },
            lager:error("SIP INVITE: ~p ~p ~p", [Dest, CallType, Callee]),
            case nkmedia_call:start(SrvId, Callee, Config) of
                {ok, _CallId, _CallPid} ->
                    {ok, {nkmedia_session, SessId}};
                {error, Error} ->
                    lager:warning("NkMEDIA SIP Invite error: ~p", [Error]),
                    {rejected, call_error}
            end;
        {error, Error} ->
            lager:warning("NkMEDIA SIP Invite error: ~p", [Error]),
            {rejected, session_error}
    end.


%% @doc Called when a SIP INVITE we are launching is ringing
-spec nkmedia_sip_invite_ringing(Id::term(), nkmedia:answer()) ->
    ok.

nkmedia_sip_invite_ringing({nkmedia_call, CallId}, Answer) ->
    nkmedia_call:ringing(CallId, {nkmedia_sip, self()}, Answer);

nkmedia_sip_invite_ringing(_Id, _Answer) ->
    ok.


%% @doc Called when a SIP INVITE we are launching has been rejected
-spec nkmedia_sip_invite_rejected(Id::term()) ->
    ok.

nkmedia_sip_invite_rejected({nkmedia_call, CallId}) ->
    nkmedia_call:rejected(CallId, {nkmedia_sip, self()});

nkmedia_sip_invite_rejected({nkmedia_session, SessId}) ->
    nkmedia_session:stop(SessId, sip_rejected);

nkmedia_sip_invite_rejected(_Id) ->
    ok.


%% @doc Called when a SIP INVITE we are launching has been answered
-spec nkmedia_sip_invite_answered(Id::term(), nkmedia:answer()) ->
    ok | {error, term()}.

nkmedia_sip_invite_answered({nkmedia_call, CallId}, Answer) ->
    nkmedia_call:answered(CallId, {nkmedia_sip, self()}, Answer);

nkmedia_sip_invite_answered({nkmedia_session, SessId}, Answer) ->
    case nkmedia_session:answer(SessId, Answer) of
        {ok, _} -> ok;
        {error, Error} -> {error, Error}
    end;

nkmedia_sip_invite_answered(_Id, _Answer) ->
    {error, not_implemented}.

    


%% ===================================================================
%% Implemented Callbacks - Error
%% ===================================================================

%% @private Error Codes -> 2110 range
error_code(sip_bye)         -> {2110, <<"SIP Bye">>};
error_code(sip_cancel)      -> {2111, <<"SIP Cancel">>};
error_code(sip_no_sdp)      -> {2112, <<"SIP Missing SDP">>};
error_code(sip_send_error)  -> {2113, <<"SIP Send Error">>};
error_code(_) -> continue.




%% ===================================================================
%% Implemented Callbacks - nksip
%% ===================================================================


%% @private
sip_get_user_pass(_User, _Realm, _Req, _Call) ->
    true.


%% @private
sip_authorize(_AuthList, _Req, _Call) ->
    ok.


%% @private
sip_register(Req, Call) ->
    SrvId = nksip_call:srv_id(Call),
    Config = nkservice_srv:get_item(SrvId, config_nkmedia_sip),
    #sip_config{
        registrar = Registrar,
        domain = Domain,
        force_domain = Force
    } = Config,
    case Registrar of
        true ->
            case Force of
                true ->
                    Req2 = nksip_registrar_util:force_domain(Req, Domain),
                    {continue, [Req2, Call]};
                false ->
                    case nksip_request:meta(Req, to_domain) of
                        {ok, Domain} ->
                            {continue, [Req, Call]};
                        _ ->
                            {reply, forbidden}
                    end
            end;
        false ->
            {reply, forbidden}
    end.


%% @private
sip_invite(Req, Call) ->
    SrvId = nksip_call:srv_id(Call),
    Config = nkservice_srv:get_item(SrvId, config_nkmedia_sip),
    #sip_config{domain = DefDomain} = Config,
    {ok, AOR} = nksip_request:meta(aor, Req),
    {_Scheme, User, Domain} = AOR,
    Dest = case Domain of
        DefDomain -> User;
        _ -> <<User/binary, $@, Domain/binary>>
    end,
    {ok, Body} = nksip_request:meta(body, Req),
    Offer = case nksip_sdp:is_sdp(Body) of
        true -> #{sdp=>nksip_sdp:unparse(Body), sdp_type=>rtp};
        false -> #{}
    end,
    case SrvId:nkmedia_sip_invite(SrvId, Dest, Offer, Req, Call) of
        {ok, Id} ->
            nkmedia_sip:register_incoming(Req, Id),
            noreply;
        {reply, Reply} ->
            {reply, Reply};
        {rejected, Reason} ->
            lager:notice("SIP invite rejected: ~p", [Reason]),
            {reply, decline}
    end.
        

%% @private
sip_reinvite(_Req, _Call) ->
    {reply, decline}.


%% @private
sip_cancel(InviteReq, _Request, _Call) ->
    {ok, Handle} = nksip_request:get_handle(InviteReq),
    case nklib_proc:values({nkmedia_sip_handle_to_id, Handle}) of
        [{{nkmedia_session, SessId}, _}|_] ->
            nkmedia_session:stop(SessId, sip_cancel),
            ok;
        [] ->
            ok
    end.


%% @private Called when a BYE is received from SIP
sip_bye(Req, _Call) ->
	{ok, Dialog} = nksip_dialog:get_handle(Req),
    case nklib_proc:values({nkmedia_sip_dialog_to_id, Dialog}) of
        [{{nkmedia_call, CallId}, _}|_] ->
            nkmedia_call:hangup(CallId, sip_bye);
        [{{nkmedia_session, SessId}, _}|_] ->
            nkmedia_session:stop(SessId, sip_bye);
        [] ->
            lager:notice("Received SIP BYE for unknown session")
    end,
	continue.



%% ===================================================================
%% Implemented Callbacks - Call
%% ===================================================================


%% @private
nkmedia_call_resolve(Callee, Acc, #{srv_id:=SrvId}=Call) ->
    case maps:get(type, Call, sip) of
        sip ->
            Config = nkservice_srv:get_item(SrvId, config_nkmedia_sip),
            #sip_config{invite_not_registered=DoExt} = Config,
            Uris1 = case DoExt of
                true ->
                    case nklib_parse:uris(Callee) of
                        error -> 
                            [];
                        Parsed -> 
                            [U || #uri{scheme=S}=U <- Parsed, S==sip orelse S==sips]
                    end;
                false ->
                    []
            end,
            {User, Domain} = case binary:split(Callee, <<"@">>) of
                [User0, Domain0] -> {User0, Domain0};
                [User0] -> {User0, Config#sip_config.domain}
            end,
            Uris2 = nksip_registrar:find(SrvId, sip, User, Domain) ++
                    nksip_registrar:find(SrvId, sips, User, Domain),
            DestExts = [#{dest=>{nkmedia_sip, U}} || U <- Uris1++Uris2],
            {continue, [Callee, Acc++DestExts, Call]};
        _ ->
            continue
    end.


%% @private
nkmedia_call_invite(CallId, {nkmedia_sip, Uri}, Offer, _Meta, #{srv_id:=SrvId}=Call) ->
    case nkmedia_sip:send_invite(SrvId, Uri, Offer, {nkmedia_call, CallId}, []) of
        {ok, Pid} -> 
            {ok, {nkmedia_sip, Pid}, Call};
        {error, Error} ->
            lager:error("error sending sip: ~p", [Error]),
            {remove, Call}
    end;

nkmedia_call_invite(_CallId, _Dest, _Offer, _Meta, _Call) ->
    continue.


%% @private
nkmedia_call_cancel(CallId, {nkmedia_sip, _Pid}, _Call) ->
    nkmedia_sip:send_bye({nkmedia_call, CallId}),
    continue;

nkmedia_call_cancel(_CallId, _Link, _Call) ->
    continue.


nkmedia_call_reg_event(CallId, {nkmedia_sip, _Pid}, {hangup, _Reason}, _Call) ->
    nkmedia_sip:send_bye({nkmedia_call, CallId}),
    continue;

nkmedia_call_reg_event(_CallId, _Link, _Event, _Call) ->
    continue.


%% ===================================================================
%% Implemented Callbacks - Session
%% ===================================================================


%% @private
nkmedia_session_reg_event(SessId, {nkmedia_sip, in, _SipPid}, Event, Session) ->
    Id = {nkmedia_session, SessId},
    spawn(
        fun() ->
            case Event of
                {answer, #{sdp:=SDP}} ->
                    [{Handle, _}|_] = nklib_proc:values({nkmedia_sip_id_to_handle, Id}),
                    Body = nksip_sdp:parse(SDP),
                    case nksip_request:reply({answer, Body}, Handle) of
                        ok ->
                            ok;
                        {error, Error} ->
                            lager:error("Error in SIP reply: ~p", [Error]),
                            nkmedia_session:stop(self(), process_down)
                    end;
                {stop, _Reason} ->
                    case Session of
                        #{answer:=#{sdp:=_}} ->
                            nkmedia_sip:send_bye({nkmedia_session,  SessId});
                        _ ->
                            [{Handle, _}|_] = 
                                nklib_proc:values({nkmedia_sip_id_to_handle, Id}),
                            nksip_request:reply(decline, Handle)
                    end;
                _ ->
                    ok
            end
        end),
    {ok, Session};

nkmedia_session_reg_event(SessId, {nkmedia_sip, out, _SipPid}, 
                          {stop, _Reason}, Session) ->
    spawn(fun() -> nkmedia_sip:send_bye({nkmedia_session, SessId}) end),
    {ok, Session};

nkmedia_session_reg_event(_SessId, _Link, _Event, _Session) ->
    continue.


%% ===================================================================
%% Internal
%% ===================================================================


%% @private
%% We start a session, and register with it with {nkmedia_sip, in, pid()} 
%% so that we detect answer and stop
start_session(SrvId, Dest, Offer) ->
    Config1 = #{offer=>Offer, register=>{nkmedia_sip, in, self()}},
    case Dest of
        <<"sip-", Callee/binary>> ->
            case nkmedia_session:start(SrvId, p2p, Config1) of
                {ok, SessId, SessPid, #{}} ->
                    {ok, {sip, Callee, Offer, SessId, SessPid}};
                {error, Error} ->
                    {error, Error}
            end;
        <<"verto-", Callee/binary>> ->
            Config2 = Config1#{backend => nkmedia_janus},
            case nkmedia_session:start(SrvId, proxy, Config2) of
                {ok, SessId, SessPid, #{offer:=Offer2}} ->
                    {ok, {verto, Callee, Offer2, SessId, SessPid}};
                {error, Error} ->
                    {error, Error}
            end;
        Callee ->
            Config2 = Config1#{backend => nkmedia_janus},
            case nkmedia_session:start(SrvId, proxy, Config2) of
                {ok, SessId, SessPid, #{offer:=Offer2}} ->
                    {ok, {user, Callee, Offer2, SessId, SessPid}};
                {error, Error} ->
                    {error, Error}
            end
    end.
