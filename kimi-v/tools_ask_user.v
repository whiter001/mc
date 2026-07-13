// tools_ask_user.v — AskUserQuestion (parity with upstream `AskUserQuestion`).
//
// Lets the model pose a multiple-choice (or free-form) question to the
// user mid-turn. In TUI mode the Agent forwards the request to the TUI
// via ask_ch, the TUI renders a modal, and the answer comes back on
// ask_result_ch. In non-interactive (-p) mode there's no consumer, so we
// time out gracefully instead of deadlocking.

module main

import json
import time

pub struct AskUserQuestionTool {}

pub fn (t AskUserQuestionTool) name() string {
	return 'AskUserQuestion'
}

pub fn (t AskUserQuestionTool) description() string {
	return 'Ask the user a question to gather preferences or clarify ambiguity. ' +
		'Provide a clear `question`, an optional `header` (short category tag), ' +
		'and 2-4 `options` each with a `label` and `description`. Set `multi: true` ' +
		'to allow multiple selections. Use this instead of guessing when a choice ' +
		'would materially change the work.'
}

pub fn (t AskUserQuestionTool) parameters_schema() string {
	return '{"type":"object","properties":{"question":{"type":"string","description":"The question to ask"},' +
		'"header":{"type":"string","description":"Optional short category tag (max 12 chars)"},' +
		'"options":{"type":"array","description":"2-4 options","items":{"type":"object","properties":{"label":{"type":"string","description":"Short label (1-5 words)"},"description":{"type":"string","description":"Explanation of this option"}},"required":["label","description"]}},' +
		'"multi":{"type":"boolean","description":"Allow multiple selections (default false)"}},' +
		'"required":["question","options"],"additionalProperties":false}'
}

struct AskArgs {
	question string
	header   string
	options  []AskOption
	multi    bool
}

pub fn (t AskUserQuestionTool) execute(args ToolArgs, ctx ToolContext) !ToolResult {
	parsed := json.decode(AskArgs, args.raw) or {
		return ToolResult{
			content:  'invalid arguments: ${err.msg()} (expected {"question":..., "options":[...]})'
			is_error: true
		}
	}
	if parsed.question.len == 0 || parsed.options.len == 0 {
		return ToolResult{
			content:  'missing required argument: question and options'
			is_error: true
		}
	}

	a := ctx.agent or {
		return ToolResult{
			content:  'ask tool: no agent context available'
			is_error: true
		}
	}

	// Forward the request to whatever owns the TUI (or times out).
	req_id := a.next_approval_id + 1_000_000 // distinct id space from approvals
	req := AskRequest{
		id:       req_id
		question: parsed.question
		header:   parsed.header
		options:  parsed.options
		multi:    parsed.multi
	}
	// Non-blocking send; if nobody is listening (e.g. -p mode), the send
	// is dropped and we fall through to the timeout path.
	select {
		a.ask_ch <- req {}
		else {}
	}

	// Wait for the answer with a generous timeout. Poll ask_result_ch so
	// we never block forever in non-interactive contexts. The timeout
	// check sits *outside* the select so V's control-flow analysis sees a
	// reachable return each iteration.
	mut deadline := time.now().add_seconds(120)
	for {
		if time.since(deadline) > 0 {
			return ToolResult{
				content: '[no interactive answer within timeout; running non-interactively?]'
			}
		}
		select {
			res := <-a.ask_result_ch {
				if res.id == req_id {
					if !res.ok {
						return ToolResult{ content: '[user declined to answer]' }
					}
					if res.choices.len > 0 {
						return ToolResult{ content: res.choices.join(', ') }
					}
					return ToolResult{ content: '[user gave no selection]' }
				}
				// Mismatched id — keep waiting.
			}
			1 * time.millisecond {}
		}
	}
	return ToolResult{
		content: '[ask tool: no answer]'
		is_error: true
	}
}
