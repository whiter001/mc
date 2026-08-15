// llm_capability.v — per-model capability registry.
//
// Parity with kimi-code's providers/capability.ts and
// capability-registry.ts. Each catalogued model family maps to a fixed
// ModelCapability; anything not in the catalog falls back to a permissive
// default.
//
// DELIBERATE DIVERGENCE FROM kimi-code:
//   kimi-code's UNKNOWN_CAPABILITY is all-false (image_in=false,
//   tool_use=false, ...), so an unlisted model can never be sent images.
//   kimi-v instead returns a permissive default (tool_use=true,
//   image_in=true, thinking=false, video_in=false, audio_in=false) that
//   preserves the existing behavior where every model accepts image
//   attachments. Only models explicitly catalogued below are tightened
//   (e.g. the OpenAI reasoning family drops image_in). This keeps
//   regressions from creeping in when a user configures a model we have
//   not seen before — a wrong guess must never silently disable a
//   modality the model actually supports.
module main

// ModelCapability declares which modalities a model accepts. Consumed by
// request builders (e.g. whether to send `temperature`) and by the TUI's
// attachment gate (whether pasted images are allowed).
pub struct ModelCapability {
pub:
	image_in          bool
	video_in          bool
	audio_in          bool
	thinking          bool
	tool_use          bool
	// 0 means "unknown" — callers that don't budget on context length can
	// ignore the field (same convention as kimi-code).
	max_context_tokens int
}

// default_capability is the permissive fallback for models not in the
// catalog. See the module comment for why this differs from kimi-code.
fn default_capability() ModelCapability {
	return ModelCapability{
		image_in:           true
		video_in:           false
		audio_in:           false
		thinking:           false
		tool_use:           true
		max_context_tokens: 0
	}
}

// is_oai_reasoning matches the OpenAI reasoning family: o1/o3/o4-mini/...
// (an "o" followed by a digit) plus the gpt-5 line. These models think
// internally and reject `temperature`; they also take no image input.
fn is_oai_reasoning(name string) bool {
	if name.len >= 2 && name[0] == `o` && name[1] >= `0` && name[1] <= `9` {
		return true
	}
	return name.starts_with('gpt-5')
}

// lookup_capability returns the declared capability for a model, matched
// case-insensitively against the catalog in order. Unknown models get the
// permissive default_capability().
pub fn lookup_capability(model string) ModelCapability {
	name := model.to_lower()
	// OpenAI reasoning family (o1/o3/o4-mini/gpt-5 ...): thinking, no images.
	if is_oai_reasoning(name) {
		return ModelCapability{
			image_in: false
			thinking: true
			tool_use: true
		}
	}
	// OpenAI vision family (gpt-4o / gpt-4.1 / gpt-4.5 / gpt-4-turbo):
	// images + tools, no thinking.
	if name.starts_with('gpt-4o') || name.starts_with('gpt-4.1')
		|| name.starts_with('gpt-4.5') || name.starts_with('gpt-4-turbo') {
		return ModelCapability{
			image_in: true
			thinking: false
			tool_use: true
		}
	}
	// gpt-3.5-turbo: text only.
	if name.starts_with('gpt-3.5-turbo') {
		return ModelCapability{
			image_in: false
			thinking: false
			tool_use: true
		}
	}
	// Claude 4 family (opus/sonnet/haiku/fable): vision + thinking + tools.
	if name.starts_with('claude-opus-4') || name.starts_with('claude-sonnet-4')
		|| name.starts_with('claude-haiku-4') || name.starts_with('claude-fable') {
		return ModelCapability{
			image_in: true
			thinking: true
			tool_use: true
		}
	}
	// Claude 3/3.5/3.7: vision + tools, no thinking.
	if name.starts_with('claude-3-') || name.starts_with('claude-3.5-')
		|| name.starts_with('claude-3.7-') {
		return ModelCapability{
			image_in: true
			thinking: false
			tool_use: true
		}
	}
	// Gemini 1.5/2.0/2.5 catalogued models: full multimodal + thinking.
	if name.starts_with('gemini-1.5-pro') || name.starts_with('gemini-1.5-flash')
		|| name.starts_with('gemini-2.0-flash') || name.starts_with('gemini-2.0-pro')
		|| name.starts_with('gemini-2.5-pro') || name.starts_with('gemini-2.5-flash') {
		return ModelCapability{
			image_in:           true
			video_in:           true
			audio_in:           true
			thinking:           true
			tool_use:           true
			max_context_tokens: 0
		}
	}
	// Kimi / Moonshot: vision + tools.
	if name.starts_with('kimi-') || name.starts_with('moonshot-') {
		return ModelCapability{
			image_in: true
			thinking: false
			tool_use: true
		}
	}
	return default_capability()
}
