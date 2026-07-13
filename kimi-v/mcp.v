// mcp.v — Model Context Protocol client manager.
//
// Wraps the standard-library `mcp` module so the agent can connect to
// external MCP servers (stdio or HTTP), enumerate their tools, and invoke
// them as if they were built-in tools. Live connections are kept on the
// Agent (Agent.mcp_clients); this module provides the connect / list / call
// primitives. A mcp.Client MUST be mutated on every request (it owns the
// JSON-RPC id counter), so tool invocation reaches it through the Agent
// rather than through an immutable Tool value.
module main

import mcp
import json

// McpServerConfig describes one MCP server to connect to. Mirrors the
// `[[mcp]]` array-of-tables in config.toml. Exactly one transport must be
// configured: `command` (stdio) XOR `url` (HTTP streamable).
pub struct McpServerConfig {
pub:
	name    string // logical name, also the tool-name namespace prefix
	command string // stdio: executable to spawn (e.g. "npx")
	args    []string // stdio: argv after the command
	url     string // http: streamable HTTP endpoint (e.g. http://localhost:8000/mcp)
	// headers is only meaningful for HTTP transports.
	headers map[string]string
	// When true, a failure to connect this server is fatal (aborts startup).
	// Default false → a dead server is logged and skipped (fail-soft) so one
	// broken MCP integration never takes down the whole agent.
	required bool
}

// McpClient bundles an mcp.Client with the config it came from.
pub struct McpClient {
pub mut:
	cfg    McpServerConfig
	client mcp.Client
}

// mcp_content_item is the wire shape of one entry in a tool-call `content`
// array. Only the fields we surface to the model are decoded; unknown kinds
// (image/resource/audio) are rendered as a short placeholder.
struct McpContentItem {
	type      string @[json: 'type']
	text      string @[json: 'text']
	data      string @[json: 'data']
	mime_type string @[json: 'mimeType']
}

// mcp_tool_call_result is the JSON-RPC result of `tools/call`.
struct McpToolCallResult {
	content  string @[json: 'content'] // raw JSON array of mcp_content_item
	is_error bool   @[json: 'isError']
}

// mcp_tools_list_result is the JSON-RPC result of `tools/list`.
struct McpToolsListResult {
	tools []mcp.Tool @[json: 'tools']
}

fn transport_label(cfg McpServerConfig) string {
	if cfg.url.len > 0 {
		return cfg.url
	}
	return '${cfg.command} ${cfg.args.join(' ')}'
}

// connect_mcp_server establishes a connection to a single MCP server and runs
// the initialization handshake.
fn connect_mcp_server(cfg McpServerConfig) !McpClient {
	if cfg.name.len == 0 {
		return error('mcp server config missing name')
	}
	mut client_config := mcp.ClientConfig{}
	for k, v in cfg.headers {
		client_config.headers[k] = v
	}
	mut client := mcp.Client{}
	if cfg.url.len > 0 {
		client = mcp.connect_http(cfg.url, client_config) or {
			return error('mcp connect (http ${cfg.url}) failed: ${err.msg()}')
		}
	} else if cfg.command.len > 0 {
		client = mcp.connect_stdio(cfg.command, cfg.args, client_config) or {
			return error('mcp connect (stdio ${cfg.command}) failed: ${err.msg()}')
		}
	} else {
		return error('mcp server "${cfg.name}" has neither command nor url')
	}
	client.initialize() or {
		client.close()
		return error('mcp initialize (${cfg.name}) failed: ${err.msg()}')
	}
	return McpClient{ cfg: cfg, client: client }
}

// connect_all_mcp_servers connects every configured server, populating the
// provided clients map (keyed by name). A non-required server that fails is
// logged and skipped; a required one that fails aborts startup with an error.
pub fn connect_all_mcp_servers(mut clients map[string]&McpClient, servers []McpServerConfig) ! {
	for cfg in servers {
		mut mc := connect_mcp_server(cfg) or {
			if cfg.required {
				return error('required mcp server "${cfg.name}" failed: ${err.msg()}')
			}
			eprintln('[mcp] skipping server "${cfg.name}": ${err.msg()}')
			continue
		}
		clients[cfg.name] = &mc
		eprintln('[mcp] connected to "${cfg.name}" (${transport_label(cfg)})')
	}
}

// list_mcp_tools returns the tools advertised by the named server.
fn list_mcp_tools(clients map[string]&McpClient, server_name string) ![]mcp.Tool {
	mut mc := clients[server_name] or {
		return error('mcp server "${server_name}" is not connected')
	}
	resp := mc.client.request_message('tools/list', map[string]string{}) or {
		return error('mcp tools/list (${server_name}) failed: ${err.msg()}')
	}
	if resp.error.code != 0 {
		return error('mcp tools/list (${server_name}) error ${resp.error.code}: ${resp.error.message}')
	}
	parsed := json.decode(McpToolsListResult, resp.result) or {
		return error('mcp tools/list (${server_name}) decode failed: ${err.msg()}')
	}
	return parsed.tools
}

// call_mcp_tool invokes a tool on the named server and returns a normalized
// ToolResult. The remote `content` array is flattened into a single text
// block; non-text items are summarised so the model still sees something.
fn call_mcp_tool(clients map[string]&McpClient, server_name string, tool_name string, args_raw string) !ToolResult {
	mut mc := clients[server_name] or {
		return error('mcp server "${server_name}" is not connected')
	}
	// `tools/call` params: { "name": ..., "arguments": <json object> }.
	arg_obj := if args_raw.trim_space().len > 0 { args_raw } else { '{}' }
	params := '{"name":${json.encode(tool_name)},"arguments":${arg_obj}}'
	resp := mc.client.request_message('tools/call', params) or {
		return error('mcp tools/call (${server_name}/${tool_name}) failed: ${err.msg()}')
	}
	if resp.error.code != 0 {
		return ToolResult{
			content:  'mcp error ${resp.error.code}: ${resp.error.message}'
			is_error: true
		}
	}
	parsed := json.decode(McpToolCallResult, resp.result) or {
		return error('mcp tools/call (${server_name}/${tool_name}) decode failed: ${err.msg()}')
	}
	mut out := ''
	if parsed.content.trim_space().len > 0 {
		items := json.decode([]McpContentItem, parsed.content) or { []McpContentItem{} }
		for i, item in items {
			if i > 0 {
				out += '\n'
			}
			if item.type == 'text' {
				out += item.text
			} else if item.type == 'image' {
				out += '[image: ${item.mime_type}]'
			} else if item.type == 'resource' {
				out += '[resource: ${item.mime_type}]'
			} else {
				out += '[${item.type}]'
			}
		}
	}
	return ToolResult{
		content:  out
		is_error: parsed.is_error
	}
}

// close_all_mcp_servers tears down every live connection (best-effort).
pub fn close_all_mcp_servers(mut clients map[string]&McpClient) {
	for name, mc in clients {
		mc.client.close()
		_ := name
	}
	clients.clear()
}
