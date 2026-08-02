// tools_mcp.v — exposes a remote MCP tool as a first-class `Tool`.
//
// An McpTool is stateless: it only carries the server name, the remote tool
// name, and the schema/description cached at connect time. Invocation is
// delegated to the live mcp.Client held on the Agent (Agent.mcp_clients, see
// mcp.v), which is why this tool's `execute` can stay non-mut while the
// underlying client still gets mutated per request.
module main

// McpTool is a thin adapter from a remote MCP tool to the local Tool
// interface. The model sees it exactly like a built-in tool; its name is
// namespaced as `mcp__<server>__<tool>` to avoid collisions.
pub struct McpTool {
pub:
	server_name  string
	remote_name  string
	display_name string // namespaced name used in the registry / provider
	description  string
	input_schema string
}

// mcp_tool_name builds the registry key for an MCP tool: mcp__server__tool.
fn mcp_tool_name(server string, tool string) string {
	return 'mcp__${server}__${tool}'
}

// name returns the tool identifier used in the registry and provider.
pub fn (t McpTool) name() string {
	return t.display_name
}

// description returns the human-readable description shown to the model.
pub fn (t McpTool) description() string {
	remote := 'MCP tool "${t.remote_name}" from server "${t.server_name}".'
	if t.description.len > 0 {
		return '${remote} ${t.description}'
	}
	return remote
}

// parameters_schema returns the JSON schema describing the tool's arguments.
pub fn (t McpTool) parameters_schema() string {
	if t.input_schema.len > 0 {
		return t.input_schema
	}
	return '{"type":"object","properties":{},"additionalProperties":true}'
}

// execute forwards the call to the live MCP client held by the Agent.
pub fn (t McpTool) execute(args ToolArgs, ctx ToolContext) !ToolResult {
	// MCP tools are not subject to local cwd/permission gating beyond the
	// normal approval path in the agent loop, but they do need the live
	// client, which lives on the Agent (reached via ctx.agent).
	a := ctx.agent or {
		return error('mcp tool "${t.display_name}" requires an agent context')
	}
	ag := a
	if t.server_name !in ag.mcp_clients {
		return error('mcp server "${t.server_name}" is not connected')
	}
	return call_mcp_tool(ag.mcp_clients, t.server_name, t.remote_name, args.raw)
}

// register_mcp_tools connects the configured servers (filling `clients`),
// then registers every remote tool into the registry. Failures are surfaced
// as warnings except for servers explicitly marked `required`.
pub fn register_mcp_tools(mut r ToolRegistry, mut clients map[string]&McpClient, servers []McpServerConfig) {
	if servers.len == 0 {
		return
	}
	connect_all_mcp_servers(mut clients, servers) or {
		eprintln('[mcp] ${err.msg()}')
		return
	}
	for cfg in servers {
		tools := list_mcp_tools(clients, cfg.name) or {
			eprintln('[mcp] could not list tools for "${cfg.name}": ${err.msg()}')
			continue
		}
		for rt in tools {
			t := McpTool{
				server_name:  cfg.name
				remote_name:  rt.name
				display_name: mcp_tool_name(cfg.name, rt.name)
				description:  rt.description
				input_schema: rt.input_schema
			}
			r.register(t)
		}
		eprintln('[mcp] registered ${tools.len} tool(s) from "${cfg.name}"')
	}
}
