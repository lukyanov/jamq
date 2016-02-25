%%% vim: ts=4 sts=4 sw=4 expandtab:

-module(jamq_supervisor).

-behaviour(supervisor).

-export([
    init/1,
    start_link/0,
    reconfigure/0,
    get_broker_role_hosts/1,
    children_specs/1,
    restart_subscribers/0,
    force_restart_subscribers/0,
    read_brokers_from_config/0
]).

-include_lib("amqp_client/include/amqp_client.hrl").

start_link() ->
    BrokerSpecs = read_brokers_from_config(),
    start_link(BrokerSpecs).

start_link(BrokerSpecs) ->
    lager:info("[start_link] Starting JAMQ supervisor"),
    supervisor:start_link({local, ?MODULE}, ?MODULE, BrokerSpecs).

init(BrokerSpecs) ->

    ChanservSup = {chanserv_sup, {jamq_chanserv_sup, start_link, [BrokerSpecs]}, permanent, infinity, supervisor, [jamq_chanserv_sup]},

    PublishersSup = {publisher_sup, {jamq_publisher_sup, start_link, [BrokerSpecs]}, permanent, infinity, supervisor, [jamq_publisher_sup]},

    SubscribersSup = {subscribers_sup, {jamq_subscriber_top_sup, start_link, []}, permanent, infinity, supervisor, [jamq_subscriber_top_sup]},

    {ok, {{one_for_all, 3, 10}, [ChanservSup, PublishersSup, SubscribersSup]}}.

children_specs({_, start_link, []}) ->
    {ok, {_, Specs}} = init(read_brokers_from_config()),
    Specs;
children_specs({_, start_link, [BrokerSpecs]}) ->
    {ok, {_, Specs}} = init(BrokerSpecs),
    Specs.

reconfigure() ->
    jamq_chanserv_sup:reconfigure(),
    restart_subscribers(),
    jamq_publisher_sup:reconfigure().

get_broker_role_hosts(Role) ->
    BrokerSpecs = read_brokers_from_config(),
    case proplists:get_value(Role, BrokerSpecs) of
        undefined ->
            lager:error("Invalid broker group name: ~p", [Role]),
            erlang:error({no_such_broker_group, Role});
        Brokers ->
            [H || {_, H} <- Brokers]
    end.

read_brokers_from_config() ->
    {ok, Brokers} = application:get_env(jamq, amq_servers),
    [{Role, [{URI, broker_host_from_uri(URI)} || URI <- BrokerURIs]} ||
        {Role, BrokerURIs} <- Brokers].

broker_host_from_uri(BrokerURI) ->
    {ok, BrokerParams} = amqp_uri:parse(BrokerURI),
    BrokerParams#amqp_params_network.host.

restart_subscribers() ->
    L = supervisor:which_children(jamq_subscriber_top_sup),
    io:format("* Restarting subscribers... "),
    K = lists:foldl(
        fun
            ({_, undefined, _, _}, N) -> N;
            ({_, Ref, _, _}, N) ->
                try
                    ok = jamq_subscriber_sup:reconfigure(Ref),
                    N + 1
                catch
                    _:E ->
                        lager:error("Restart subscriber failed: ~p~nReason: ~p~nStacktrace: ~p", [Ref, E, erlang:get_stacktrace()]),
                        N
                end
        end, 0, L),
    io:format("~p/~p~n", [K, erlang:length(L)]).

force_restart_subscribers() ->
    L = supervisor:which_children(jamq_subscriber_top_sup),
    io:format("* Restarting subscribers... "),
    K = lists:foldl(
        fun
            ({_, undefined, _, _}, N) -> N;
            ({Ref, _, _, _}, N) ->
                try
                    ok = supervisor:terminate_child(jamq_subscriber_top_sup, Ref),
                    {ok, _} = supervisor:restart_child(jamq_subscriber_top_sup, Ref),
                    N + 1
                catch
                    _:E ->
                        lager:error("Restart subscriber failed: ~p~nReason: ~p~nStacktrace: ~p", [Ref, E, erlang:get_stacktrace()]),
                        N
                end
        end, 0, L),
    io:format("~p/~p~n", [K, erlang:length(L)]).
