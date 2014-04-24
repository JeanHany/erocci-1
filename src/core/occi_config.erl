%%% @author Jean Parpaillon <jean.parpaillon@free.fr>
%%% @copyright (C) 2014, Jean Parpaillon
%%% @doc Config has 2 sources:
%%%  - application env
%%%  - load/1 arg
%%% Application env override load/1 env
%%%
%%% Config properties:
%%%  - backends: a list of backends, loaded with occi_store:register/1
%%%  - name: base URI of the server. Normally, listeners are responsible for discovering name 
%%%          (e.g.: http://localhost:8080)
%%%  - listeners: a list of listeners, loaded with occi_listener:register/1.
%%%  - backend_timeout: timeout after which a backend is considered dead. Default to 5000 (ms)
%%%  - categories_map: a function for mapping category id (occi_cid()) to an URI. Default to 
%%%                    occi_category_mgr:hash/1
%%%  - categories_prefix: prefix for collections, for the occi_category_mgr:hash/1 function. 
%%%                       Default: /collections
%%%
%%% All other properties are stored in the config manager and accessible with get/1 and get/2.
%%% @end
%%% Created : 20 Jan 2014 by Jean Parpaillon <jean.parpaillon@free.fr>

-module(occi_config).
-compile([{parse_transform, lager_transform}]).

-include("occi.hrl").

-export([start/0,
	 load/1,
	 get/1,
	 get/2,
	 set/2,
	 to_url/1,
	 gen_id/1]).

-define(TABLE, ?MODULE).

start() ->
    lager:info("Starting OCCI config manager"),
    ?TABLE = ets:new(?TABLE, [set, public, {keypos, 1}, named_table]),
    ok.

%%% @doc Config is a proplist, which can be overriden by application env
-spec load(list()) -> ok.
load(Config) ->
    Env = application:get_all_env(occi),
    setup(Env ++ Config).

get(Name) ->
    get(Name, undefined).

get(Name, Default) ->
    case ets:match_object(?TABLE, {Name, '_'}) of
	[] ->
	    Default;
	[{_, Value}] ->
	    Value
    end.

set(Name, Value) ->
    ets:insert(?TABLE, {Name, Value}).

to_url(#uri{}=Uri) ->
    case get(name, undefined) of
	undefined ->
	    throw({error, undefined_name});
	#uri{scheme=Scheme, host=Host, port=Port, userinfo=UserInfo} ->
	    Uri#uri{scheme=Scheme, host=Host, port=Port, userinfo=UserInfo}
    end.

-spec gen_id(string() | binary()) -> uri().
gen_id(Prefix) when is_binary(Prefix) ->
    gen_id(binary_to_list(Prefix));
gen_id(Prefix) when is_list(Prefix) ->
    #uri{host=Host}=Server = get(name, undefined),
    Id = uuid:to_string(uuid:uuid3(uuid:uuid4(), Host)),
    Server#uri{path=Prefix++Id}.

%%%
%%% Private
%%%
setup(Props) ->
    lager:debug("setup(~p)~n", [Props]),
    P2 = case proplists:get_value(categories_map, Props) of
	     undefined ->
		 ets:insert(?TABLE, {categories_map, {occi_category_mgr, hash}}),
		 Props;
	     {Mod, Fun} ->
		 case erlang:function_exported(Mod, Fun, 1) of
		     true -> 
			 ets:insert(?TABLE, {categories_map, {Mod, Fun}}),
			 proplists:delete(categories_map, Props);
		     false -> 
			 throw({error, {invalid_conf, categories_map}})
		 end
	 end,
    P21 = case proplists:get_value(categories_prefix, P2) of
	      undefined -> P2;
	      [$/ | Prefix ] ->
		  ets:insert(?TABLE, {categories_prefix, [$/ | Prefix]}),
		  proplists:delete(categories_prefix, P2);
	      _ ->
		  throw({error, {invalid_conf, categories_prefix}})
	  end,
    P3 = case proplists:get_value(backends, P21) of
	undefined -> P21;
	Backends -> 
		 load_backends(Backends),
		 proplists:delete(backends, P21)
    end,
    P4 = case proplists:get_value(name, P3) of
	     undefined -> P3;
	     Name ->
		 ets:insert(?TABLE, {name, occi_uri:parse(Name)}),
		 proplists:delete(name, P3)
	 end,
    P5 = case proplists:get_value(listeners, P4) of
	     undefined -> P4;
	     Listeners -> 
		 load_listeners(Listeners),
		 proplists:delete(listeners, P4)
	 end,
    case proplists:get_value(backend_timeout, P5, 5000) of
	5000 -> 
	    ets:insert(?TABLE, {backend_timeout, 5000});
	V when is_integer(V) ->
	    ets:insert(?TABLE, {backend_timeout, V});
	V when is_list(V) ->
	    ets:insert(?TABLE, {backend_timeout, list_to_integer(V)})
    end,
    P6 = proplists:delete(backend_timeout, P5),
    P7 = case proplists:get_value(handlers, P6) of
	     undefined -> P6;
	     Handlers -> 
		 load_handlers(Handlers),
		 proplists:delete(handlers, P6)
	 end,
    store(P7).

store(Props) ->
    lists:foreach(fun (Key) ->
			  ets:insert(?TABLE, {Key, proplists:get_value(Key, Props)})
		  end, proplists:get_keys(Props)).

load_backends([]) ->
    ok;
load_backends([B|Backends]) ->
    case occi_store:register(B) of
	{ok, _Pid} ->
	    load_backends(Backends);
	{error, Err} ->
	    throw({error, Err})
    end.

load_listeners([]) ->
    ok;
load_listeners([L|Listeners]) ->
    case occi_listener:register(L) of
	{ok, _Pid} ->
	    load_listeners(Listeners);
	{error, Err} ->
	    {error, Err}
    end.

load_handlers([]) ->
    ok;
load_handlers([H|Handlers]) ->
    case occi_hook:register(H) of
	ok ->
	    load_handlers(Handlers);
	{error, Err} ->
	    {error, Err}
    end.
