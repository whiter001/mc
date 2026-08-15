// tools_web_search_test.v — unit tests for the web_search tool's pure logic.
//
// The provider HTTP calls (DDG scrape / Moonshot API) are network-bound, so
// we focus on the response parsing that both paths depend on. The Moonshot
// response decoder is a pure function, easy to drive with canned JSON.

module main

fn test_parse_moonshot_results_parses_entries() {
	raw := '{"search_results":[' +
		'{"title":"V Lang","url":"https://vlang.io","snippet":"Fast, simple language"},' +
		'{"title":"Docs","url":"https://docs.vlang.io","snippet":"Official docs"}]}'
	results := parse_moonshot_results(raw, 8)
	assert results.len == 2
	assert results[0].title == 'V Lang'
	assert results[0].url == 'https://vlang.io'
	assert results[0].snippet == 'Fast, simple language'
	assert results[1].title == 'Docs'
	assert results[1].url == 'https://docs.vlang.io'
	assert results[1].snippet == 'Official docs'
}

fn test_parse_moonshot_results_respects_max_results() {
	raw := '{"search_results":[' +
		'{"title":"a","url":"u1","snippet":"s"},' +
		'{"title":"b","url":"u2","snippet":"s"},' +
		'{"title":"c","url":"u3","snippet":"s"}]}'
	results := parse_moonshot_results(raw, 2)
	assert results.len == 2
	assert results[0].title == 'a'
	assert results[1].title == 'b'
}

fn test_parse_moonshot_results_empty_array() {
	results := parse_moonshot_results('{"search_results":[]}', 8)
	assert results.len == 0
}

fn test_parse_moonshot_results_missing_array() {
	// No search_results key at all → treated as empty, not an error.
	results := parse_moonshot_results('{"other":"data"}', 8)
	assert results.len == 0
}

fn test_parse_moonshot_results_invalid_json() {
	results := parse_moonshot_results('this is not json', 8)
	assert results.len == 0
}

fn test_parse_moonshot_results_missing_fields_default_empty() {
	// Entries may omit title/url/snippet; they map to empty strings
	// (parity with the upstream provider, which uses `?? ''`).
	raw := '{"search_results":[{"url":"https://x.example"},{"title":"no url"}]}'
	results := parse_moonshot_results(raw, 8)
	assert results.len == 2
	assert results[0].title == ''
	assert results[0].url == 'https://x.example'
	assert results[0].snippet == ''
	assert results[1].title == 'no url'
	assert results[1].url == ''
	assert results[1].snippet == ''
}

fn test_web_search_default_provider_is_duckduckgo() {
	// The config default drives dispatch; the tool built with the default
	// config must land on the DDG path.
	tool := WebSearchTool{ cfg: WebSearchConfig{} }
	assert tool.cfg.provider == 'duckduckgo'
	assert tool.description().contains('configured search provider')
}
