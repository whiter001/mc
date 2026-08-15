// llm_capability_test.v — unit tests for the per-model capability registry.
//
// lookup_capability is pure (no I/O), so it is tested directly against the
// documented model matrix. The registry is case-insensitive and falls back
// to a permissive default for unknown models — both properties are checked
// here so a regression in either breaks the build's green bar.
module main

// ---------- OpenAI reasoning family (o1/o3/o4-mini/gpt-5) -----------------
//
// These models think internally and reject image input, but still use tools.

fn test_capability_oai_reasoning_thinking_no_image() {
	for m in ['o1', 'o3', 'o3-mini', 'o4-mini', 'gpt-5', 'gpt-5-mini'] {
		cap := lookup_capability(m)
		assert cap.thinking == true, '${m}: expected thinking=true'
		assert cap.image_in == false, '${m}: expected image_in=false'
		assert cap.tool_use == true, '${m}: expected tool_use=true'
	}
}

// ---------- OpenAI vision family (gpt-4o / gpt-4.1 / gpt-4.5 / gpt-4-turbo) -
//
// These accept images + tools but do not think internally.

fn test_capability_oai_vision_no_thinking() {
	for m in ['gpt-4o', 'gpt-4o-mini', 'gpt-4.1', 'gpt-4.5', 'gpt-4-turbo'] {
		cap := lookup_capability(m)
		assert cap.image_in == true, '${m}: expected image_in=true'
		assert cap.thinking == false, '${m}: expected thinking=false'
		assert cap.tool_use == true, '${m}: expected tool_use=true'
	}
}

// ---------- gpt-3.5-turbo: text only ----------------------------------------

fn test_capability_gpt35_text_only() {
	cap := lookup_capability('gpt-3.5-turbo')
	assert cap.image_in == false, 'gpt-3.5-turbo: expected image_in=false'
	assert cap.thinking == false, 'gpt-3.5-turbo: expected thinking=false'
	assert cap.tool_use == true, 'gpt-3.5-turbo: expected tool_use=true'
}

// ---------- Claude 4 family (opus/sonnet/haiku/fable): vision + thinking ---

fn test_capability_claude4_thinking_vision() {
	for m in ['claude-opus-4', 'claude-sonnet-4', 'claude-haiku-4', 'claude-fable'] {
		cap := lookup_capability(m)
		assert cap.thinking == true, '${m}: expected thinking=true'
		assert cap.image_in == true, '${m}: expected image_in=true'
		assert cap.tool_use == true, '${m}: expected tool_use=true'
	}
}

// ---------- Claude 3 / 3.5 / 3.7: vision, no thinking -----------------------

fn test_capability_claude35_vision_no_thinking() {
	for m in ['claude-3.5-sonnet', 'claude-3.5-haiku', 'claude-3-opus', 'claude-3-7-sonnet'] {
		cap := lookup_capability(m)
		assert cap.image_in == true, '${m}: expected image_in=true'
		assert cap.thinking == false, '${m}: expected thinking=false'
		assert cap.tool_use == true, '${m}: expected tool_use=true'
	}
}

// ---------- Gemini 2.5 Pro: full multimodal (video_in) ----------------------

fn test_capability_gemini25_pro_video() {
	cap := lookup_capability('gemini-2.5-pro')
	assert cap.video_in == true, 'gemini-2.5-pro: expected video_in=true'
}

// ---------- Kimi / Moonshot: vision ----------------------------------------

fn test_capability_kimi_moonshot_vision() {
	for m in ['kimi-k2', 'kimi-k2-thinking', 'moonshot-v1', 'moonshot-v1-8k'] {
		cap := lookup_capability(m)
		assert cap.image_in == true, '${m}: expected image_in=true'
	}
}

// ---------- Case-insensitivity ----------------------------------------------

fn test_capability_case_insensitive() {
	// Catalog matching lower-cases the model name, so any casing of a known
	// family must resolve to the same capability.
	assert lookup_capability('GPT-4O').image_in == true, 'GPT-4O should match gpt-4o'
	assert lookup_capability('Claude-Opus-4').thinking == true, 'Claude-Opus-4 should think'
	assert lookup_capability('O3-MINI').thinking == true, 'O3-MINI should think'
	assert lookup_capability('gpt-4O').image_in == true, 'mixed-case gpt-4O should accept images'
}

// ---------- Unknown model: permissive default -------------------------------

fn test_capability_unknown_lenient_default() {
	// An unlisted model must keep working: tools + images on, thinking off.
	cap := lookup_capability('some-random-model')
	assert cap.tool_use == true, 'unknown model: tool_use should default true'
	assert cap.image_in == true, 'unknown model: image_in should default true'
	assert cap.thinking == false, 'unknown model: thinking should default false'
	assert cap.video_in == false, 'unknown model: video_in should default false'
}

// ---------- Empty model: same lenient default -------------------------------

fn test_capability_empty_model_lenient() {
	// model == '' is also "unknown" → permissive default, so existing
	// behavior (attachments always allowed) is preserved.
	cap := lookup_capability('')
	assert cap.image_in == true, 'empty model: image_in should default true'
	assert cap.tool_use == true, 'empty model: tool_use should default true'
	assert cap.thinking == false, 'empty model: thinking should default false'
}
