// internal/util/jsonrpc.v
// A minimal JSON-RPC 2.0 envelope used by both MCP (client) and ACP (server).
// Keeping it minimal avoids a dependency on V's bare-bones JSON-RPC ecosystem
// (there isn't one) and lets us evolve the schema alongside the protocol.
module main

import json

pub const jsonrpc_version = '2.0'

// JsonRpcRequest is a JSON-RPC 2.0 request envelope with an optional params string.
pub struct JsonRpcRequest {
pub:
	jsonrpc string = jsonrpc_version  @[json: jsonrpc]
	id      int     @[json: id]
	method  string  @[json: method]
	params  ?string @[json: params]
}

// JsonRpcNotification is a JSON-RPC 2.0 notification (no id).
pub struct JsonRpcNotification {
pub:
	jsonrpc string = jsonrpc_version  @[json: jsonrpc]
	method  string  @[json: method]
	params  ?string @[json: params]
}

// JsonRpcResponse is a JSON-RPC 2.0 response envelope.
pub struct JsonRpcResponse {
pub:
	jsonrpc string        @[json: jsonrpc]
	id      int           @[json: id]
	result  ?string       @[json: result]
	err     ?JsonRpcError @[json: error]
}

// JsonRpcError is the error object inside a JSON-RPC response.
pub struct JsonRpcError {
pub:
	code    int     @[json: code]
	message string  @[json: message]
	data    ?string @[json: data]
}

// encode_request builds a JSON-RPC request string from id, method and params.
pub fn encode_request(id int, method string, params string) !string {
	r := JsonRpcRequest{
		id:     id
		method: method
		params: if params.len > 0 { params } else { none }
	}
	return json.encode(r)
}

// encode_notification builds a JSON-RPC notification string.
pub fn encode_notification(method string, params string) !string {
	n := JsonRpcNotification{
		method: method
		params: if params.len > 0 { params } else { none }
	}
	return json.encode(n)
}

// decode_response parses a JSON-RPC response line.
pub fn decode_response(line string) !JsonRpcResponse {
	return json.decode(JsonRpcResponse, line)!
}
