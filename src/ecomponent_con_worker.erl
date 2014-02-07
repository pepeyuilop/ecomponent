-module(ecomponent_con_worker).
-behaviour(gen_server).

-include_lib("exmpp/include/exmpp.hrl").
-include_lib("exmpp/include/exmpp_client.hrl").
-include("ecomponent.hrl").

-record(state, {
    type = server :: server | node,
    xmppCom :: pid(),
    jid :: ecomponent:jid(),
    id :: atom(),
    pass :: string(),
    server :: string(),
    port :: integer(),
    node :: atom()
}).

%% gen_server callbacks
-export([
    start_link/3, 
    stop/1, 
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

start_link(ID, JID, Conf) ->
    gen_server:start_link({local, ID}, ?MODULE, [ID, JID, Conf], []).


-spec stop(ID::atom()) -> ok.

stop(ID) ->
    gen_server:call(ID, stop).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([ID, JIDdefault, Conf]) ->
    Pass = proplists:get_value(pass, Conf),
    Server = proplists:get_value(server, Conf),
    Port = proplists:get_value(port, Conf),
    JID = proplists:get_value(jid, Conf, JIDdefault),
    Active = case proplists:get_value(type, Conf, active) of
        active -> true;
        passive -> false
    end,
    F = case Active of
        true -> active;
        false -> passive
    end,
    case Server of
        undefined ->
            Node = proplists:get_value(node, Conf),
            erlang:monitor_node(Node, true),
            ecomponent_con:F(ID),
            {ok, #state{type = node, node = Node}};
        _ ->
            {_, XmppCom} = make_connection(JID, Pass, Server, Port),
            ecomponent_con:F(ID),
            {ok, #state{
                type = server,
                xmppCom = XmppCom,
                id = ID,
                jid = JID,
                pass = Pass,
                server = Server,
                port = Port
            }}
    end.


-spec handle_info(Msg::any(), State::#state{}) ->
    {noreply, State::#state{}} |
    {noreply, State::#state{}, hibernate | infinity | non_neg_integer()} |
    {stop, Reason::any(), State::#state{}}.

handle_info(#received_packet{from=To,id=ID}=ReceivedPacket, State) ->
    ToBin = exmpp_jid:bare_to_binary(exmpp_jid:make(To)),
    timem:insert({ID, ToBin}, State#state.id),
    ecomponent ! {ReceivedPacket, State#state.id},
    {noreply, State};

handle_info({send, #xmlel{name='iq'}=Packet}, #state{type=node, id=ID, node=Node}=State) ->
    rpc:cast(Node, ecomponent, send, [Packet, 'from_another_node', undefined, false, ID]),
    {noreply, State};

handle_info({send, #xmlel{name='message'}=Packet}, #state{type=node, id=ID, node=Node}=State) ->
    rpc:cast(Node, ecomponent, send_message, [Packet, ID]),
    {noreply, State};

handle_info({send, #xmlel{name='presence'}=Packet}, #state{type=node, id=ID, node=Node}=State) ->
    rpc:cast(Node, ecomponent, send_presence, [Packet, ID]),
    {noreply, State};

handle_info({send, Packet}, #state{xmppCom=XmppCom}=State) ->
    exmpp_component:send_packet(XmppCom, Packet),
    {noreply, State};

handle_info({down, Node}, #state{node=Node}=State) ->
    lager:info("Connection to ~p closed. Trying to reconnect...~n", [Node]),
    ecomponent_con:down(State#state.id),
    case net_kernel:connect_node(Node) of
    true ->
        lager:info("Reconnected ~p.~n", [Node]),
        ecomponent_con:active(State#state.id);
    false ->
        timer:sleep(500)
    end,
    {noreply, State};

handle_info({_, tcp_closed}, #state{jid=JID, server=Server, pass=Pass, port=Port}=State) ->
    lager:info("Connection to ~s closed. Trying to reconnect...~n", [Server]),
    ecomponent_con:down(State#state.id),
    {_, XmppCom} = make_connection(JID, Pass, Server, Port),
    lager:info("Reconnected ~s.~n", [Server]),
    ecomponent_con:active(State#state.id),
    {noreply, State#state{xmppCom=XmppCom}};

handle_info({_,{bad_return_value, _}}, #state{jid=JID, server=Server, pass=Pass, port=Port}=State) ->
    lager:info("Connection to ~s closed. Trying to reconnect...~n", [Server]),
    ecomponent_con:down(State#state.id),
    {_, XmppCom} = make_connection(JID, Pass, Server, Port),
    lager:info("Reconnected ~s.~n", [Server]),
    ecomponent_con:active(State#state.id),
    {noreply, State#state{xmppCom=XmppCom}};

handle_info(Record, State) -> 
    lager:info("Unknown Info Request: ~p~n", [Record]),
    {noreply, State}.

-spec handle_cast(Msg::any(), State::#state{}) ->
    {noreply, State::#state{}} |
    {noreply, State::#state{}, hibernate | infinity | non_neg_integer()} |
    {stop, Reason::any(), State::#state{}}.

handle_cast(_Msg, State) ->
    lager:info("Received: ~p~n", [_Msg]), 
    {noreply, State}.


-spec handle_call(Msg::any(), From::{pid(),_}, State::#state{}) ->
    {reply, Reply::any(), State::#state{}} |
    {reply, Reply::any(), State::#state{}, hibernate | infinity | non_neg_integer()} |
    {noreply, State::#state{}} |
    {noreply, State::#state{}, hibernate | infinity | non_neg_integer()} |
    {stop, Reason::any(), Reply::any(), State::#state{}} |
    {stop, Reason::any(), State::#state{}}.

handle_call(stop, _From, #state{xmppCom=XmppCom}=State) ->
    lager:info("Component Stopped.~n",[]),
    exmpp_component:stop(XmppCom),
    {stop, normal, ok, State};

handle_call(Info, _From, State) ->
    lager:info("Received Call: ~p~n", [Info]),
    {reply, ok, State}.


-spec terminate(Reason::any(), State::#state{}) -> ok.

terminate(_Reason, _State) ->
    lager:info("terminated connection.", []),
    ok.

-spec code_change(OldVsn::string(), State::#state{}, Extra::any()) ->
    {ok, State::#state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

-spec make_connection(JID::string(), Pass::string(), Server::string(), Port::integer()) -> {R::string(), XmppCom::pid()}.

make_connection(JID, Pass, Server, Port) -> 
    make_connection(JID, Pass, Server, Port, 20).
    
-spec make_connection(JID::ecomponent:jid(), Pass::string(), Server::string(), Port::integer(), Tries::integer()) -> {string(), pid()}.    

make_connection(JID, Pass, Server, Port, 0) -> 
    make_connection(JID, Pass, Server, Port);
make_connection(JID, Pass, Server, Port, Tries) ->
    lager:info("Connecting: ~p Tries Left~n",[Tries]),
    XmppCom = exmpp_component:start(),
    try setup_exmpp_component(XmppCom, JID, Pass, Server, Port) of
        R -> 
            lager:info("Connected.~n",[]),
            {R, XmppCom}
    catch
        Class:Exception ->
            lager:warning("Exception ~p: ~p~n",[Class, Exception]),
            exmpp_component:stop(XmppCom),
            timer:sleep((20-Tries) * 200),
            make_connection(JID, Pass, Server, Port, Tries-1)
    end.

-spec setup_exmpp_component(XmppCom::pid(), JID::ecomponent:jid(), Pass::string(), Server::string(), Port::integer()) -> string().

setup_exmpp_component(XmppCom, JID, Pass, Server, Port)->
    exmpp_component:auth(XmppCom, JID, Pass),
    exmpp_component:connect(XmppCom, Server, Port),
    exmpp_component:handshake(XmppCom).

