// mcp_test.v — unit tests for MCP config parsing and tool-name namespacing.
module main

import json
import os
import toml

fn test_mcp_tool_name_namespacing() {
	// The registry key must be mcp__<server>__<tool> so remote tools never
	// collide with built-in tools or each other.
	assert mcp_tool_name('fs', 'read') == 'mcp__fs__read'
	assert mcp_tool_name('github', 'create_issue') == 'mcp__github__create_issue'
}

fn test_mcp_config_parsing_stdio() {
	raw := '
[[mcp]]
name = "fs"
command = "npx"
args = ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
required = true
'
	mut cfg := default_config()
	apply_toml(mut cfg, raw)
	assert cfg.mcp_servers.len == 1
	s := cfg.mcp_servers[0]
	assert s.name == 'fs'
	assert s.command == 'npx'
	assert s.args.len == 3
	assert s.args[0] == '-y'
	assert s.required == true
	assert s.url.len == 0
}

fn test_mcp_config_parsing_http_with_headers() {
	raw := '
[[mcp]]
name = "remote"
url = "http://localhost:8000/mcp"
headers = { Authorization = "Bearer tok" }
'
	mut cfg := default_config()
	apply_toml(mut cfg, raw)
	assert cfg.mcp_servers.len == 1
	s := cfg.mcp_servers[0]
	assert s.name == 'remote'
	assert s.url == 'http://localhost:8000/mcp'
	assert s.headers['Authorization'] == 'Bearer tok'
	assert s.command.len == 0
	assert s.required == false
}

fn test_mcp_config_skips_missing_transport() {
	// An entry with neither command nor url is skipped with a warning.
	raw := '
[[mcp]]
name = "broken"
required = true

[[mcp]]
name = "ok"
command = "echo"
'
	mut cfg := default_config()
	apply_toml(mut cfg, raw)
	// Only the valid "ok" entry survives; "broken" is dropped.
	assert cfg.mcp_servers.len == 1
	assert cfg.mcp_servers[0].name == 'ok'
}

fn test_mcp_config_skips_missing_name() {
	raw := '
[[mcp]]
command = "echo"
'
	mut cfg := default_config()
	apply_toml(mut cfg, raw)
	assert cfg.mcp_servers.len == 0
}

// test_mcp_content_parsing checks that a tool-call result with mixed content
// kinds is flattened correctly by the decode structs used in call_mcp_tool.
fn test_mcp_content_parsing() {
	raw := '{"content":[{"type":"text","text":"hello"},{"type":"image","mimeType":"image/png","data":"AAA="}],"isError":false}'
	parsed := json.decode(McpToolCallResult, raw) or {
		assert false
		return
	}
	assert parsed.is_error == false
	items := json.decode([]McpContentItem, parsed.content) or {
		assert false
		return
	}
	assert items.len == 2
	assert items[0].type == 'text'
	assert items[0].text == 'hello'
	assert items[1].type == 'image'
	assert items[1].mime_type == 'image/png'
}

fn test_mcp_toml_doc_value_api() {
	// Smoke test that the toml module decodes an [[mcp]] array as expected
	// using the same path apply_toml takes.
	raw := '[[mcp]]\nname="x"\nurl="http://h/mcp"\n'
	doc := toml.parse_text(raw) or {
		assert false
		return
	}
	arr := doc.value('mcp').array()
	assert arr.len == 1
	assert arr[0].value('name').string() == 'x'
}

fn test_mcp_default_registry_with_empty_servers() {
	// No MCP servers configured → registry built cleanly, no crash.
	mut a := new_agent(OpenAICompatProvider{}, 'sys')
	a.registry = default_registry(mut a, os.getwd(), [])
	assert 'read_file' in a.registry.names()
}
