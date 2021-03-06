%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <andrew@pixid.com>
%%% @copyright 2014-2015, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  13 Aug 2015 by Andrew Bennett <andrew@pixid.com>
%%%-------------------------------------------------------------------
-module(jose_server).
-behaviour(gen_server).

-include_lib("public_key/include/public_key.hrl").

-define(SERVER, ?MODULE).

%% API
-export([start_link/0]).
-export([config_change/0]).
-export([curve25519_module/1]).
-export([curve448_module/1]).
-export([json_module/1]).
-export([sha3_module/1]).

%% gen_server callbacks
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-define(CRYPTO_FALLBACK, application:get_env(jose, crypto_fallback, false)).

-define(TAB, jose_jwa).

-define(POISON_MAP, #{
	<<"a">> => 1,
	<<"b">> => 2,
	<<"c">> => #{
		<<"d">> => 3,
		<<"e">> => 4
	}
}).
-define(POISON_BIN, <<"{\"a\":1,\"b\":2,\"c\":{\"d\":3,\"e\":4}}">>).

%% Types
-record(state, {}).

%%%===================================================================
%%% API functions
%%%===================================================================

start_link() ->
	gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

config_change() ->
	gen_server:call(?SERVER, config_change).

curve25519_module(Curve25519Module) when is_atom(Curve25519Module) ->
	gen_server:call(?SERVER, {curve25519_module, Curve25519Module}).

curve448_module(Curve448Module) when is_atom(Curve448Module) ->
	gen_server:call(?SERVER, {curve448_module, Curve448Module}).

json_module(JSONModule) when is_atom(JSONModule) ->
	gen_server:call(?SERVER, {json_module, JSONModule}).

sha3_module(SHA3Module) when is_atom(SHA3Module) ->
	gen_server:call(?SERVER, {sha3_module, SHA3Module}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
init([]) ->
	?TAB = ets:new(?TAB, [
		named_table,
		public,
		ordered_set,
		{read_concurrency, true}
	]),
	ok = support_check(),
	{ok, #state{}}.

%% @private
handle_call(config_change, _From, State) ->
	{reply, support_check(), State};
handle_call({curve25519_module, M}, _From, State) ->
	Curve25519Module = check_curve25519_module(M),
	true = ets:insert(?TAB, {curve25519_module, Curve25519Module}),
	{reply, ok, State};
handle_call({curve448_module, M}, _From, State) ->
	Curve448Module = check_curve448_module(M),
	true = ets:insert(?TAB, {curve448_module, Curve448Module}),
	{reply, ok, State};
handle_call({json_module, M}, _From, State) ->
	JSONModule = check_json_module(M),
	true = ets:insert(?TAB, {json_module, JSONModule}),
	{reply, ok, State};
handle_call({sha3_module, M}, _From, State) ->
	SHA3Module = check_sha3_module(M),
	true = ets:insert(?TAB, {sha3_module, SHA3Module}),
	{reply, ok, State};
handle_call(_Request, _From, State) ->
	{reply, ignore, State}.

%% @private
handle_cast(_Request, State) ->
	{noreply, State}.

%% @private
handle_info(_Info, State) ->
	{noreply, State}.

%% @private
terminate(_Reason, _State) ->
	ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
support_check() ->
	Fallback = ?CRYPTO_FALLBACK,
	Entries = lists:flatten(lists:foldl(fun(Check, Acc) ->
		Check(Fallback, Acc)
	end, [], [
		fun check_ec_key_mode/2,
		fun check_curve25519/2,
		fun check_curve448/2,
		fun check_json/2,
		fun check_sha3/2,
		fun check_crypto/2,
		fun check_public_key/2
	])),
	true = ets:delete_all_objects(?TAB),
	true = ets:insert(?TAB, Entries),
	ok.

%%%-------------------------------------------------------------------
%%% Internal check functions
%%%-------------------------------------------------------------------

%% @private
check_ec_key_mode(_Fallback, Entries) ->
	ECPEMEntry = {
		'ECPrivateKey',
		<<
			48,119,2,1,1,4,32,104,152,88,12,19,82,251,156,171,31,222,207,
			0,76,115,88,210,229,36,106,137,192,81,153,154,254,226,38,247,
			70,226,157,160,10,6,8,42,134,72,206,61,3,1,7,161,68,3,66,0,4,
			46,75,29,46,150,77,222,40,220,159,244,193,125,18,190,254,216,
			38,191,11,52,115,159,213,230,77,27,131,94,17,46,21,186,71,62,
			36,225,0,90,21,186,235,132,152,229,13,189,196,121,64,84,64,
			229,173,12,24,23,127,175,67,247,29,139,91
		>>,
		not_encrypted
	},
	case public_key:pem_entry_decode(ECPEMEntry) of
		#'ECPrivateKey'{ privateKey = PrivateKey, publicKey = PublicKey } when is_list(PrivateKey) andalso is_tuple(PublicKey) ->
			[{ec_key_mode, list} | Entries];
		#'ECPrivateKey'{ privateKey = PrivateKey, publicKey = PublicKey } when is_binary(PrivateKey) andalso is_binary(PublicKey) ->
			[{ec_key_mode, binary} | Entries]
	end.

%% @private
check_curve25519(false, Entries) ->
	check_curve25519(jose_curve25519_unsupported, Entries);
check_curve25519(true, Entries) ->
	check_curve25519(jose_jwa_curve25519, Entries);
check_curve25519(Fallback, Entries) ->
	true = ets:delete_object(?TAB, {curve25519_module, jose_jwa_curve25519}),
	true = ets:delete_object(?TAB, {curve25519_module, jose_curve25519_unsupported}),
	Curve25519Module = case ets:lookup(?TAB, curve25519_module) of
		[{curve25519_module, M}] when is_atom(M) ->
			M;
		[] ->
			case application:get_env(jose, curve25519_module, undefined) of
				undefined ->
					check_curve25519_modules(Fallback, [libdecaf, libsodium]);
				M when is_atom(M) ->
					check_curve25519_module(M)
			end
	end,
	[{curve25519_module, Curve25519Module} | Entries].

%% @private
check_curve25519_module(libdecaf) ->
	jose_curve25519_libdecaf;
check_curve25519_module(libsodium) ->
	jose_curve25519_libsodium;
check_curve25519_module(Module) when is_atom(Module) ->
	Module.

%% @private
check_curve25519_modules(Fallback, [Module | Modules]) ->
	case code:ensure_loaded(Module) of
		{module, Module} ->
			_ = application:ensure_all_started(Module),
			check_curve25519_module(Module);
		_ ->
			check_curve25519_modules(Fallback, Modules)
	end;
check_curve25519_modules(Fallback, []) ->
	Fallback.

%% @private
check_curve448(false, Entries) ->
	check_curve448(jose_curve448_unsupported, Entries);
check_curve448(true, Entries) ->
	check_curve448(jose_jwa_curve448, Entries);
check_curve448(Fallback, Entries) ->
	true = ets:delete_object(?TAB, {curve448_module, jose_jwa_curve448}),
	true = ets:delete_object(?TAB, {curve448_module, jose_curve448_unsupported}),
	Curve448Module = case ets:lookup(?TAB, curve448_module) of
		[{curve448_module, M}] when is_atom(M) ->
			M;
		[] ->
			case application:get_env(jose, curve448_module, undefined) of
				undefined ->
					check_curve448_modules(Fallback, [libdecaf]);
				M when is_atom(M) ->
					check_curve448_module(M)
			end
	end,
	[{curve448_module, Curve448Module} | Entries].

%% @private
check_curve448_module(libdecaf) ->
	jose_curve448_libdecaf;
check_curve448_module(Module) when is_atom(Module) ->
	Module.

%% @private
check_curve448_modules(Fallback, [Module | Modules]) ->
	case code:ensure_loaded(Module) of
		{module, Module} ->
			_ = application:ensure_all_started(Module),
			check_curve448_module(Module);
		_ ->
			check_curve448_modules(Fallback, Modules)
	end;
check_curve448_modules(Fallback, []) ->
	Fallback.

%% @private
check_json(_Fallback, Entries) ->
	JSONModule = case ets:lookup(?TAB, json_module) of
		[{json_module, M}] when is_atom(M) ->
			M;
		[] ->
			case application:get_env(jose, json_module, undefined) of
				undefined ->
					case code:ensure_loaded(elixir) of
						{module, elixir} ->
							check_json_modules(['Elixir.Poison', jiffy, jsone, jsx]);
						_ ->
							check_json_modules([jiffy, jsone, jsx])
					end;
				M when is_atom(M) ->
					check_json_module(M)
			end
	end,
	[{json_module, JSONModule} | Entries].

%% @private
check_json_module(jiffy) ->
	jose_json_jiffy;
check_json_module(jsx) ->
	jose_json_jsx;
check_json_module(jsone) ->
	jose_json_jsone;
check_json_module('Elixir.Poison') ->
	Map = ?POISON_MAP,
	Bin = ?POISON_BIN,
	case jose_json_poison:encode(Map) of
		Bin ->
			jose_json_poison;
		_ ->
			check_json_module('Elixir.JOSE.Poison')
	end;
check_json_module('Elixir.JOSE.Poison') ->
	Map = ?POISON_MAP,
	Bin = ?POISON_BIN,
	case code:ensure_loaded('Elixir.JOSE.Poison') of
		{module, 'Elixir.JOSE.Poison'} ->
			try jose_json_poison_lexical_encoder:encode(Map) of
				Bin ->
					jose_json_poison_lexical_encoder;
				_ ->
					check_json_module(jose_json_poison_compat_encoder)
			catch
				_:_ ->
					check_json_module(jose_json_poison_compat_encoder)
			end;
		_ ->
			check_json_module(jose_json_poison_compat_encoder)
	end;
check_json_module(jose_json_poison_compat_encoder) ->
	Map = ?POISON_MAP,
	Bin = ?POISON_BIN,
	try jose_json_poison_compat_encoder:encode(Map) of
		Bin ->
			jose_json_poison_compat_encoder;
		_ ->
			jose_json_poison
	catch
		_:_ ->
			jose_json_poison
	end;
check_json_module(Module) when is_atom(Module) ->
	Module.

%% @private
check_json_modules([Module | Modules]) ->
	case code:ensure_loaded(Module) of
		{module, Module} ->
			_ = application:ensure_all_started(Module),
			check_json_module(Module);
		_ ->
			check_json_modules(Modules)
	end;
check_json_modules([]) ->
	jose_json_unsupported.

%% @private
check_sha3(false, Entries) ->
	check_sha3(jose_sha3_unsupported, Entries);
check_sha3(true, Entries) ->
	check_sha3(jose_jwa_sha3, Entries);
check_sha3(Fallback, Entries) ->
	true = ets:delete_object(?TAB, {sha3_module, jose_jwa_sha3}),
	true = ets:delete_object(?TAB, {sha3_module, jose_sha3_unsupported}),
	SHA3Module = case ets:lookup(?TAB, sha3_module) of
		[{sha3_module, M}] when is_atom(M) ->
			M;
		[] ->
			case application:get_env(jose, sha3_module, undefined) of
				undefined ->
					check_sha3_modules(Fallback, [keccakf1600, libdecaf]);
				M when is_atom(M) ->
					check_sha3_module(M)
			end
	end,
	[{sha3_module, SHA3Module} | Entries].

%% @private
check_sha3_module(keccakf1600) ->
	check_sha3_module(jose_sha3_keccakf1600);
check_sha3_module(libdecaf) ->
	check_sha3_module(jose_sha3_libdecaf);
check_sha3_module(jose_sha3_keccakf1600) ->
	_ = code:ensure_loaded(keccakf1600),
	case erlang:function_exported(keccakf1600, hash, 3) of
		false ->
			% version < 2
			check_sha3_module(jose_sha3_keccakf1600_driver);
		true ->
			% version >= 2
			check_sha3_module(jose_sha3_keccakf1600_nif)
	end;
check_sha3_module(Module) when is_atom(Module) ->
	Module.

%% @private
check_sha3_modules(Fallback, [Module | Modules]) ->
	case code:ensure_loaded(Module) of
		{module, Module} ->
			_ = application:ensure_all_started(Module),
			check_sha3_module(Module);
		_ ->
			check_sha3_modules(Fallback, Modules)
	end;
check_sha3_modules(Fallback, []) ->
	Fallback.

%% @private
check_crypto(false, Entries) ->
	check_crypto(jose_jwa_unsupported, Entries);
check_crypto(true, Entries) ->
	check_crypto(jose_jwa_aes, Entries);
check_crypto(Fallback, Entries) ->
	Ciphers = [
		aes_cbc,
		aes_ecb,
		aes_gcm
	],
	KeySizes = [
		128,
		192,
		256
	],
	CipherEntries = [begin
		case has_cipher(Cipher, KeySize) of
			false ->
				{{cipher, {Cipher, KeySize}}, {Fallback, {Cipher, KeySize}}};
			{true, CryptoCipher} ->
				{{cipher, {Cipher, KeySize}}, {crypto, CryptoCipher}}
		end
	end || Cipher <- Ciphers, KeySize <- KeySizes],
	[CipherEntries | Entries].

%% @private
check_public_key(Fallback, Entries) ->
	RSACrypt = check_rsa_crypt(Fallback),
	RSASign = check_rsa_sign(Fallback),
	[RSACrypt, RSASign | Entries].

%% @private
check_rsa_crypt(false) ->
	check_rsa_crypt(jose_jwa_unsupported);
check_rsa_crypt(true) ->
	check_rsa_crypt(jose_jwa_pkcs1);
check_rsa_crypt(Fallback) ->
	Algorithms = [
		%% Algorithm,    LegacyOptions,                       FutureOptions
		{rsa1_5,       [{rsa_pad, rsa_pkcs1_padding}],      [{rsa_padding, rsa_pkcs1_padding}]},
		{rsa_oaep,     [{rsa_pad, rsa_pkcs1_oaep_padding}], [{rsa_padding, rsa_pkcs1_oaep_padding}]},
		{rsa_oaep_256, notsup,                              [{rsa_padding, rsa_pkcs1_oaep_padding}, {rsa_oaep_md, sha256}]}
	],
	_ = code:ensure_loaded(public_key),
	_ = application:ensure_all_started(public_key),
	Legacy = case erlang:function_exported(public_key, sign, 4) of
		false ->
			legacy;
		true ->
			future
	end,
	CryptEntries = [begin
		case has_rsa_crypt(Algorithm, Legacy, LegacyOptions, FutureOptions) of
			false ->
				{{rsa_crypt, Algorithm}, {Fallback, FutureOptions}};
			{true, Module, Options} ->
				{{rsa_crypt, Algorithm}, {Module, Options}}
		end
	end || {Algorithm, LegacyOptions, FutureOptions} <- Algorithms],
	CryptEntries.

%% @private
check_rsa_sign(false) ->
	check_rsa_sign(jose_jwa_unsupported);
check_rsa_sign(true) ->
	check_rsa_sign(jose_jwa_pkcs1);
check_rsa_sign(Fallback) ->
	Paddings = [
		rsa_pkcs1_padding,
		rsa_pkcs1_pss_padding
	],
	_ = code:ensure_loaded(public_key),
	_ = application:ensure_all_started(public_key),
	Legacy = case erlang:function_exported(public_key, sign, 4) of
		false ->
			legacy;
		true ->
			future
	end,
	SignEntries = [begin
		case has_rsa_sign(Padding, Legacy, sha) of
			false ->
				{{rsa_sign, Padding}, {Fallback, [{rsa_padding, Padding}]}};
			{true, Module} ->
				{{rsa_sign, Padding}, {Module, undefined}};
			{true, Module, Options} ->
				{{rsa_sign, Padding}, {Module, Options}}
		end
	end || Padding <- Paddings],
	SignEntries.

%% @private
has_cipher(aes_cbc, KeySize) ->
	Key = << 0:KeySize >>,
	IV = << 0:128 >>,
	PlainText = jose_jwa_pkcs7:pad(<<>>),
	case has_block_cipher(aes_cbc, {Key, IV, PlainText}) of
		false ->
			Cipher = list_to_atom("aes_cbc" ++ integer_to_list(KeySize)),
			has_block_cipher(Cipher, {Key, IV, PlainText});
		Other ->
			Other
	end;
has_cipher(aes_ecb, KeySize) ->
	Key = << 0:KeySize >>,
	PlainText = jose_jwa_pkcs7:pad(<<>>),
	has_block_cipher(aes_ecb, {Key, PlainText});
has_cipher(aes_gcm, KeySize) ->
	Key = << 0:KeySize >>,
	IV = << 0:96 >>,
	AAD = <<>>,
	PlainText = jose_jwa_pkcs7:pad(<<>>),
	has_block_cipher(aes_gcm, {Key, IV, AAD, PlainText}).

%% @private
has_block_cipher(Cipher, {Key, PlainText}) ->
	case catch crypto:block_encrypt(Cipher, Key, PlainText) of
		CipherText when is_binary(CipherText) ->
			case catch crypto:block_decrypt(Cipher, Key, CipherText) of
				PlainText ->
					{true, Cipher};
				_ ->
					false
			end;
		_ ->
			false
	end;
has_block_cipher(Cipher, {Key, IV, PlainText}) ->
	case catch crypto:block_encrypt(Cipher, Key, IV, PlainText) of
		CipherText when is_binary(CipherText) ->
			case catch crypto:block_decrypt(Cipher, Key, IV, CipherText) of
				PlainText ->
					{true, Cipher};
				_ ->
					false
			end;
		_ ->
			false
	end;
has_block_cipher(Cipher, {Key, IV, AAD, PlainText}) ->
	case catch crypto:block_encrypt(Cipher, Key, IV, {AAD, PlainText}) of
		{CipherText, CipherTag} when is_binary(CipherText) andalso is_binary(CipherTag) ->
			case catch crypto:block_decrypt(Cipher, Key, IV, {AAD, CipherText, CipherTag}) of
				PlainText ->
					{true, Cipher};
				_ ->
					false
			end;
		_ ->
			false
	end.

%% @private
has_rsa_crypt(_Algorithm, future, _LegacyOptions, FutureOptions) ->
	PlainText = << 0:8 >>,
	PublicKey = rsa_public_key(),
	case catch public_key:encrypt_public(PlainText, PublicKey, FutureOptions) of
		CipherText when is_binary(CipherText) ->
			PrivateKey = rsa_private_key(),
			case catch public_key:decrypt_private(CipherText, PrivateKey, FutureOptions) of
				PlainText ->
					{true, public_key, FutureOptions};
				_ ->
					false
			end;
		_ ->
			false
	end;
has_rsa_crypt(_Algorithm, legacy, notsup, _FutureOptions) ->
	false;
has_rsa_crypt(_Algorithm, legacy, LegacyOptions, _FutureOptions) ->
	PlainText = << 0:8 >>,
	PublicKey = rsa_public_key(),
	case catch public_key:encrypt_public(PlainText, PublicKey, LegacyOptions) of
		CipherText when is_binary(CipherText) ->
			PrivateKey = rsa_private_key(),
			case catch public_key:decrypt_private(CipherText, PrivateKey, LegacyOptions) of
				PlainText ->
					{true, public_key, LegacyOptions};
				_ ->
					false
			end;
		_ ->
			false
	end.

%% @private
has_rsa_sign(Padding, future, DigestType) ->
	Message = << 0:8 >>,
	PrivateKey = rsa_private_key(),
	Options = [{rsa_padding, Padding}],
	case catch public_key:sign(Message, DigestType, PrivateKey, Options) of
		Signature when is_binary(Signature) ->
			PublicKey = rsa_public_key(),
			case catch public_key:verify(Message, DigestType, Signature, PublicKey, Options) of
				true ->
					{true, public_key, Options};
				_ ->
					false
			end;
		_ ->
			false
	end;
has_rsa_sign(rsa_pkcs1_padding, legacy, DigestType) ->
	Message = << 0:8 >>,
	PrivateKey = rsa_private_key(),
	case catch public_key:sign(Message, DigestType, PrivateKey) of
		Signature when is_binary(Signature) ->
			PublicKey = rsa_public_key(),
			case catch public_key:verify(Message, DigestType, Signature, PublicKey) of
				true ->
					{true, public_key};
				_ ->
					false
			end;
		_ ->
			false
	end;
has_rsa_sign(_Padding, legacy, _DigestType) ->
	false.

%% @private
read_pem_key(PEM) ->
	public_key:pem_entry_decode(hd(public_key:pem_decode(PEM))).

%% @private
rsa_public_key() ->
	read_pem_key(<<
		"-----BEGIN PUBLIC KEY-----\n"
		"MHwwDQYJKoZIhvcNAQEBBQADawAwaAJhAL/f1xISwDSm4m6sYHm6WD4WK2egfyfZ\n"
		"hd0w4iVeZvHjUurZVRVQojs7hZC7DKBfjShl6M7BT9j7gkaYOXlJHLhK6/J+Zr0C\n"
		"g6PMkkbejQltgr4fUzbG8zUBo7BMs4Xm0wIDAQAB\n"
		"-----END PUBLIC KEY-----\n"
	>>).

%% @private
rsa_private_key() ->
	read_pem_key(<<
		"-----BEGIN RSA PRIVATE KEY-----\n"
		"MIIBzAIBAAJhAL/f1xISwDSm4m6sYHm6WD4WK2egfyfZhd0w4iVeZvHjUurZVRVQ\n"
		"ojs7hZC7DKBfjShl6M7BT9j7gkaYOXlJHLhK6/J+Zr0Cg6PMkkbejQltgr4fUzbG\n"
		"8zUBo7BMs4Xm0wIDAQABAmEAiisNO7WG9SNLoPi+TEn061iZjvjTOAX60Io3/0LY\n"
		"jMzu07EHBN9Yw6CcENmxQPcsdIRlSKLlt+UeUdBES6Zoccek5fJl+gnqExeX2Av1\n"
		"v0Y8vIP2yejV7Pw+SrNxpY5ZAjEA+WMEZEgFrK8cPJmZLR9Kj3jvN5P+AmIKzg00\n"
		"VMW93rS+sdHmYQUStqBuu2XRw5SlAjEAxPZlLCZ83GrqdStcmChCFpflzCRyU/wC\n"
		"qVVP8QYfct49Cca3TyC8lCywwXI5s5wXAjA1JQK0lByRdiegSmM4GGj9NhpUT7db\n"
		"rqT60BmMzy7tHLtejYp4tmoMfRfb25DeCvkCMQCO+usQ9NOZUsfmzNaH4lmvew8n\n"
		"daHFE+F+uV6x8ibsRSZ8LVQuze33hsW9eEUo/HsCMQDKkImE3DSqHgwfKPjtecFH\n"
		"oftdsGQ4u+MUGkST94Hh8479oNYaNveCRDOTJ4GJjUE=\n"
		"-----END RSA PRIVATE KEY-----\n"
	>>).
