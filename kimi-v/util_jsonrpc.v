// internal/util/jsonrpc.v
// A minimal JSON-RPC 2.0 envelope used by both MCP (client) and ACP (server).
// Keeping it minimal avoids a dependency on V's bare-bones JSON-RPC ecosystem
// (there isn't one) and lets us evolve the schema alongside the protocol.
module main

import json

pub const jsonrpc_version = '2.0'

pub struct JsonRpcRequest {
pub:
	jsonrpc string = jsonrpc_version  @[json: jsonrpc]
	id      int     @[json: id]
	method  string  @[json: method]
	params  ?string @[json: params]
}

pub struct JsonRpcNotification {
pub:
	jsonrpc string = jsonrpc_version  @[json: jsonrpc]
	method  string  @[json: method]
	params  ?string @[json: params]
}

pub struct JsonRpcResponse {
pub:
	jsonrpc string        @[json: jsonrpc]
	id      int           @[json: id]
	result  ?string       @[json: result]
	err     ?JsonRpcError @[json: error]
}

pub struct JsonRpcError {
pub:
	code    int     @[json: code]
	message string  @[json: message]
	data    ?string @[json: data]
}

pub fn encode_request(id int, method string, params string) !string {
	r := JsonRpcRequest{
		id:     id
		method: method
		params: if params.len > 0 { params } else { none }
	}
	return json.encode(r)
}

pub fn encode_notification(method string, params string) !string {
	n := JsonRpcNotification{
		method: method
		params: if params.len > 0 { params } else { none }
	}
	return json.encode(n)
}

pub fn decode_response(line string) !JsonRpcResponse {
	return json.decode(JsonRpcResponse, line)!
}
