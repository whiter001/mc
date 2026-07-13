// cmd/main.v — entry point for the `kimi` binary.
//
// P0 supports:
//   kimi -p "task"        single-shot mode (no TUI)
//   kimi -p "task" --model ... --api-base ... --api-key ...
//   kimi login            store an API key
//   kimi version          print version
//   kimi help             show usage
//
// TUI (`kimi` with no `-p`) and ACP (`kimi acp`) land in P1 / P4.
module main

import os
import time
import json

const version = '0.1.0'

struct Cli {
mut:
	cmd             string
	prompt          string
	continue_session string
	model          string
	api_base       string
	api_key        string
	log_level      string
	provider       string
	max_turns      int
	max_tokens     int
	system         string
	yolo           bool
	output_format  string // "text" (default) | "stream-json"
	export_session string
	export_output  string
	export_yes     bool
	export_no_log  bool
	show_help      bool
	show_version   bool
}

fn main() {
	cli := parse_args(os.args) or {
		eprintln('error: ${err.msg()}')
		eprintln('run `kimi help` for usage')
		exit(2)
	}

	mut log := new_logger(parse_level(cli.log_level))

	match cli.cmd {
		'version' {
			println('kimi ${version}')
		}
		'help' {
			print_help()
		}
		'login' {
			run_login(cli) or {
				eprintln('login failed: ${err.msg()}')
				exit(1)
			}
		}
		'sessions' {
			run_sessions() or {
				eprintln('error: ${err.msg()}')
				exit(1)
			}
		}
		'export' {
			run_export(cli) or {
				eprintln('error: ${err.msg()}')
				exit(1)
			}
		}
		'run' {
			if cli.prompt.len > 0 {
				// One-shot mode: run the prompt and exit.
				run_prompt(cli, mut log) or {
					eprintln('error: ${err.msg()}')
					exit(1)
				}
			} else {
				// Interactive TUI mode.
				run_tui_cmd(cli, mut log) or {
					eprintln('error: ${err.msg()}')
					exit(1)
				}
			}
		}
		else {
			eprintln('unknown command: ${cli.cmd}')
			print_help()
			exit(2)
		}
	}
}

fn parse_args(args []string) !Cli {
	mut cli := Cli{}
	cli.cmd = 'run'

	mut i := 1
	for i < args.len {
		a := args[i]
		match a {
			'-p', '--prompt' {
				i++
				if i >= args.len { return error('--prompt requires a value') }
				cli.prompt = args[i]
			}
			'--model' {
				i++
				if i >= args.len { return error('--model requires a value') }
				cli.model = args[i]
			}
			'--api-base' {
				i++
				if i >= args.len { return error('--api-base requires a value') }
				cli.api_base = args[i]
			}
			'--api-key' {
				i++
				if i >= args.len { return error('--api-key requires a value') }
				cli.api_key = args[i]
			}
			'--provider' {
				i++
				if i >= args.len { return error('--provider requires a value') }
				cli.provider = args[i]
			}
			'--log-level' {
				i++
				if i >= args.len { return error('--log-level requires a value') }
				cli.log_level = args[i]
			}
			'--max-turns' {
				i++
				if i >= args.len { return error('--max-turns requires a value') }
				cli.max_turns = args[i].int()
			}
			'--max-tokens' {
				i++
				if i >= args.len { return error('--max-tokens requires a value') }
				cli.max_tokens = args[i].int()
			}
			'--system' {
				i++
				if i >= args.len { return error('--system requires a value') }
				cli.system = args[i]
			}
			'-y', '--yolo' {
				cli.yolo = true
			}
			'--yes' {
				// Used by `kimi export -y` to skip the "really export the
				// most recent session?" prompt. Doesn't conflict with -y
				// because -y is only meaningful in interactive mode.
				cli.export_yes = true
			}
			'--output-format' {
				i++
				if i >= args.len { return error('--output-format requires a value') }
				v := args[i]
				if v !in ['text', 'stream-json'] {
					return error('--output-format must be "text" or "stream-json"')
				}
				cli.output_format = v
			}
			'-o', '--output' {
				i++
				if i >= args.len { return error('--output requires a value') }
				cli.export_output = args[i]
			}
			'--no-include-global-log' {
				cli.export_no_log = true
			}
			'-h', '--help' {
				cli.show_help = true
				cli.cmd = 'help'
			}
			'-V', '--version' {
				cli.show_version = true
				cli.cmd = 'version'
			}
			'--continue' {
				i++
				if i >= args.len { return error('--continue requires a session id') }
				cli.continue_session = args[i]
			}
			'--sessions' {
				cli.cmd = 'sessions'
			}
			'export' {
				cli.cmd = 'export'
				// Next arg may be a session id (no flag).
				if i + 1 < args.len && !args[i + 1].starts_with('-') {
					i++
					cli.export_session = args[i]
				}
			}
			'login' {
				cli.cmd = 'login'
			}
			'version' {
				cli.cmd = 'version'
			}
			'help' {
				cli.cmd = 'help'
			}
			'sessions' {
				cli.cmd = 'sessions'
			}
			else {
				return error('unknown argument: ${a}')
			}
		}

		i++
	}

	if cli.log_level.len == 0 {
		v := os.getenv('KIMI_LOG_LEVEL')
		if v.len == 0 {
			cli.log_level = 'info'
		} else {
			cli.log_level = v
		}
	}

	return cli
}

fn run_prompt(cli Cli, mut log Logger) ! {
	if cli.prompt.len == 0 {
		print_help()
		return error('no prompt provided; use `-p "your task"`')
	}

	cli_cfg := Config{
		provider:      cli.provider
		api_base:      cli.api_base
		api_key:       cli.api_key
		model:         cli.model
		system_prompt: cli.system
		log_level:     cli.log_level
		max_turns:     cli.max_turns
		max_tokens:    cli.max_tokens
	}
	mut cfg := load_config(cli_cfg)!
	cfg.validate()!
	// CLI flag overrides the env (load_config already applied KIMI_YOLO).
	if cli.yolo {
		cfg.yolo = true
	}
	// Output-format switch. Default is "text" (plain stdout, current
	// behavior). stream-json emits one JSON object per line for CI
	// consumption: delta/thinking/tool_call/tool_result/done events.
	if cli.output_format.len == 0 {
		cfg.output_format = 'text'
	} else {
		cfg.output_format = cli.output_format
	}

	log.info('provider=${cfg.provider} model=${cfg.model} base=${cfg.api_base}')
	log.info('cwd=${cfg.cwd}')

	mut provider := OpenAICompatProvider{
		model:    cfg.model
		api_base: cfg.api_base
		api_key:  cfg.api_key
	}

	default_system := 'You are Kimi Code, an AI coding assistant running in the terminal. ' +
		'Use the available tools to read files, edit files, and run shell commands. ' +
		'Be concise. Prefer reading files before editing them.'
	system := if cfg.system_prompt.len > 0 { cfg.system_prompt } else { default_system }

	mut a := new_agent(provider, system)
	a.max_turns = cfg.max_turns
	a.registry = default_registry(mut a, cfg.cwd, cfg.mcp_servers)
	// Tear down MCP connections on any exit path (best-effort).
	defer {
		close_all_mcp_servers(mut a.mcp_clients)
	}
	// Wire up skills + hooks (parity with kimi-code lifecycle).
	a.set_skills(discover_skills(cfg.cwd))
	mut hook_engine := new_hook_engine(cfg.cwd, a.session_id)
	for h in cfg.hooks {
		hook_engine.add(h)
	}
	a.set_hooks(hook_engine)
	// Non-interactive (`-p`) mode: plan-mode approvals must auto-pass so
	// the agent never blocks on a UI that isn't present.
	a.non_interactive = true
	// Apply user-configured risky-tools list (config.toml /
	// KIMI_RISKY_TOOLS). Empty means "use the built-in default".
	if cfg.risky_tools.len > 0 {
		a.risky_tools = cfg.risky_tools
	}
	// approved_tools starts empty for a one-shot run — there's no
	// "remember" UI in -p mode. The TUI mutates this in place.
	a.approved_tools = cfg.approved_tools
	// yolo is propagated from cfg (--yolo flag or KIMI_YOLO=1).
	// One-shot mode never shows the approval modal in yolo anyway
	// (see agent_loop.gate), but we keep the wiring consistent.
	a.yolo = cfg.yolo

	// Wire delta/thinking/tool callbacks to the right sink depending on
	// output format. Text mode prints to stdout directly (current
	// behavior); stream-json mode emits one JSON object per line.
	if cfg.output_format == 'stream-json' {
		// In stream-json mode, assistant text and thinking both go to
		// stdout as JSONL events. Tool calls and tool results also get
		// their own event types. Tool execution progress ("running
		// bash...") and "resuming session" notices go to stderr so
		// the JSONL stream on stdout stays machine-parseable.
		a.on_delta = fn (_ string) {
			// Handled per-token via a separate event in stream-json.
			// (The agent emits deltas chunk-by-chunk; we accumulate
			// the assistant text and emit a single .assistant message
			// event at the end of the turn. For real streaming-JSONL
			// we'd want the provider to forward deltas to a custom
			// channel; that's a follow-up. For now, model the
			// stream-json shape on top of the final text.)
		}
		a.on_thinking = fn (_ string) {
			// Thinking content is dropped in stream-json (matches the
			// upstream behaviour; thinking isn't useful to scripts and
			// would bloat the log).
		}
		a.on_tool = fn (name string, args string) {
			emit_jsonl_event('tool_call', {
				'name': name
				'args': args
			})
		}
	} else {
		a.on_delta = fn [log] (chunk string) {
			print(chunk)
			stdout_flush()
		}
		a.on_thinking = fn [log] (chunk string) {
			print('\x1b[90m${chunk}\x1b[0m') // grey
			stdout_flush()
		}
	}

	mut sess := if cli.continue_session.len > 0 {
		log.info('resuming session: ${cli.continue_session}')
		load(cli.continue_session)!
	} else {
		log.info('new session')
		new_session(cfg.cwd)
	}
	a.session_id = sess.id
	// Re-wire the hook engine with the now-known session id.
	mut he2 := new_hook_engine(cfg.cwd, sess.id)
	for h in cfg.hooks {
		he2.add(h)
	}
	a.set_hooks(he2)
	// ── SessionStart hook (observation-only) ──
	mut ss_input := map[string]string{}
	ss_input['source'] = 'startup'
	he2.run_hook_for_event(.session_start, 'startup', ss_input)
	// ── UserPromptSubmit hook (blockable) ──
	mut ups_input := map[string]string{}
	ups_input['prompt'] = cli.prompt
	upb := he2.run_hook_for_event(.user_prompt_submit, cli.prompt, ups_input)
	if upb != none {
		log.warn('prompt blocked by UserPromptSubmit hook: ${upb}')
		eprintln('[blocked] ${upb}')
		save(sess) or {}
		return
	}
	sess.append_user(cli.prompt)

	log.info('running agent loop...')
	t0 := time.now()
	result := a.run(mut sess) or {
		// ── StopFailure hook (observation-only) ──
		mut sf_input := map[string]string{}
		sf_input['error'] = err.msg()
		he2.run_hook_for_event(.stop_failure, err.msg(), sf_input)
		log.error('agent loop failed: ${err.msg()}')
		save(sess) or { log.warn('session save failed: ${err.msg()}') }
		return error(err.msg())
	}
	// ── Stop hook (blockable; surfaced for parity, fail-open) ──
	he2.run_hook_for_event(.stop, '', map[string]string{})
	elapsed := time.since(t0)

	if result.outcome != .finished {
		eprintln('[warn] loop ended with outcome: ${result.outcome}')
	}
	// In stream-json mode, emit the final assistant message + done
	// event so scripts can parse the conversation transcript. The agent
	// has already appended the assistant turn to `sess`; we pull the
	// last message so the JSONL stream is a complete record.
	if cfg.output_format == 'stream-json' {
		emit_assistant_message(&sess)
		emit_jsonl_event('done', {
			'turns':         result.turns.str()
			'input_tokens':  result.usage.input_tokens.str()
			'output_tokens': result.usage.output_tokens.str()
			'outcome':       outcome_str(result.outcome)
			'elapsed_ms':    elapsed.milliseconds().str()
		})
	} else {
		println('')
	}
	log.info('finished in ${elapsed.milliseconds()}ms, turns=${result.turns}, tokens=${result.usage.input_tokens}+${result.usage.output_tokens}')

	save(sess) or { log.warn('session save failed: ${err.msg()}') }
}

fn run_login(cli Cli) ! {
	println('Kimi Code CLI — login')
	println('')
	println('Available providers:')
	println('  1) Moonshot OpenAI-compatible  (https://api.moonshot.cn/v1)')
	println('  2) Custom OpenAI-compatible   (BYO base URL)')
	println('')
	print('Choose [1/2]: ')
	stdout_flush()

	choice := read_line().trim_space()
	match choice {
		'1' {
			println('Enter your Moonshot API key:')
			key := read_secret()
			if key.len == 0 {
				return error('empty key')
			}
			persist_credentials('https://api.moonshot.cn/v1', 'moonshot-v1-8k', key)
			println('Saved. Try: kimi -p "hello"')
		}
		'2' {
			print('API base URL: ')
			stdout_flush()
			base := read_line().trim_space()
			print('Model name: ')
			stdout_flush()
			model := read_line().trim_space()
			println('Enter your API key:')
			key := read_secret()
			if base.len == 0 || model.len == 0 || key.len == 0 {
				return error('base, model, and key are all required')
			}
			persist_credentials(base, model, key)
			println('Saved. Try: kimi -p "hello"')
		}
		else {
			return error('invalid choice: ${choice}')
		}
	}
}

fn persist_credentials(api_base string, model string, api_key string) {
	dir := config_dir()
	ensure_dir(dir) or { return }
	path := os.join_path(dir, 'config.toml')

	contents := '# Kimi Code user config\n' + 'provider = "openai-compat"\n' +
		'api_base = "${api_base}"\n' + 'model = "${model}"\n' + 'api_key = "${api_key}"\n'

	os.write_file(path, contents) or {
		eprintln('failed to write config: ${err.msg()}')
		return
	}
	println('wrote ${path}')
}

fn stdout_flush() {
}

fn read_line() string {
	return os.get_raw_line()
}

fn read_secret() string {
	return read_line().trim_space()
}

fn run_sessions() ! {
	summaries := list_all()!
	if summaries.len == 0 {
		println('No saved sessions found.')
		return
	}
	println('Sessions (newest first):')
	println('')
	for i, s in summaries {
		date_str := s.updated_at.format()
		date := if date_str.len > 16 { date_str[..16] } else { date_str }
		println('  [${i}] ${s.id}')
		println('      cwd: ${s.cwd}')
		println('      updated: ${date}   msgs: ${s.msg_count}')
		println('')
	}
	println('To continue a session:')
	println('  kimi --continue <id> -p "your next task"')
}

// run_export packages a session into a ZIP file for sharing, archiving,
// or submitting bug reports.
//
// Usage:
//   kimi export                  # most recent session in cwd, with prompt
//   kimi export -y               # most recent, skip prompt
//   kimi export <id>             # specific session
//   kimi export <id> -o bug.zip  # custom output path
//   kimi export --no-include-global-log
//
// We shell out to the system `zip` command — V has no stdlib zip module
// and a third-party dep would be overkill for a self-use tool. macOS and
// Linux both ship `zip`; Windows users can run inside WSL or a Unix
// shell.
fn run_export(cli Cli) ! {
	// Resolve the session id. Explicit id > most recent in cwd.
	mut session_id := cli.export_session
	if session_id.len == 0 {
		summaries := list_all()!
		if summaries.len == 0 {
			return error('no saved sessions to export')
		}
		// Pick the most recent session whose cwd matches os.getwd(),
		// or fall back to the absolute most recent if none match.
		cwd := os.getwd()
		mut pick := summaries[0]
		for s in summaries {
			if s.cwd == cwd {
				pick = s
				break
			}
		}
		session_id = pick.id
		if !cli.export_yes {
			println('Will export session ${pick.id} (cwd: ${pick.cwd}, ${pick.msg_count} messages, updated ${pick.updated_at.format()}).')
			print('Continue? [y/N] ')
			stdout_flush()
			answer := read_line().trim_space().to_lower()
			if answer != 'y' && answer != 'yes' {
				println('aborted.')
				return
			}
		}
	}

	// Verify the session exists.
	load(session_id)!

	// Output path. Default: kimi-session-<id>-<YYYYMMDD>.zip in cwd.
	mut out_path := cli.export_output
	if out_path.len == 0 {
		date_str := time.now().format()
		mut date_compact := date_str.replace(' ', '').replace('-', '').replace(':', '')
		if date_compact.len > 8 {
			date_compact = date_compact[..8]
		}
		out_path = os.join_path(os.getwd(), 'kimi-session-${session_id}-${date_compact}.zip')
	}

	// Build the source list. We always include the session TOML;
	// optionally include the global log.
	cli_cfg := Config{
		provider:  cli.provider
		api_base:  cli.api_base
		api_key:   cli.api_key
		model:     cli.model
		system_prompt: cli.system
		log_level: cli.log_level
		max_turns: cli.max_turns
	}
	_ = cli_cfg // not used here; only present for consistency with run_prompt
	dirs := config_paths_struct()
	session_path := os.join_path(dirs.sessions, '${session_id}.toml')
	log_path := os.join_path(dirs.logs, 'kimi-code.log')

	if !os.exists(session_path) {
		return error('session file missing: ${session_path}')
	}

	// Stage files in a temp directory so the zip is self-contained and
	// the relative paths inside it are clean. Layout:
	//   <tmp>/sessions/<id>.toml
	//   <tmp>/logs/kimi-code.log      (if present + not disabled)
	stage := os.join_path(os.temp_dir(), 'kimi-export-${session_id}')
	os.rmdir_all(stage) or {} // clean up from a previous run
	os.mkdir_all(os.join_path(stage, 'sessions'))!
	os.cp(session_path, os.join_path(stage, 'sessions', '${session_id}.toml'))!

	include_log := !cli.export_no_log && os.exists(log_path)
	if include_log {
		os.mkdir_all(os.join_path(stage, 'logs'))!
		os.cp(log_path, os.join_path(stage, 'logs', 'kimi-code.log')) or {
			eprintln('warning: could not copy global log: ${err.msg()}')
		}
	}

	// Build the zip. `-r` is recursive (we have a directory); `-X` strips
	// extra file attributes so the zip is reproducible across systems.
	zip_cmd := 'cd "${stage}" && zip -rX "${out_path}" .'
	res := os.execute(zip_cmd)
	if res.exit_code != 0 {
		return error('zip failed (exit ${res.exit_code}): ${res.output}')
	}
	// Clean up the stage directory.
	os.rmdir_all(stage) or {}

	mut summary := 'exported session ${session_id} to ${out_path}'
	if include_log {
		summary += ' (with global log)'
	} else {
		summary += ' (no global log)'
	}
	println(summary)
}

// config_paths_struct returns the standard on-disk locations so run_export
// (and any future command that needs the layout) can find session files
// and logs without re-deriving paths.
struct ConfigPaths {
pub:
	config  string
	sessions string
	logs    string
}

fn config_paths_struct() ConfigPaths {
	base := config_dir()
	return ConfigPaths{
		config:   base
		sessions: os.join_path(base, 'sessions')
		logs:     os.join_path(base, 'logs')
	}
}

// ---------- stream-json output (item #2) ----------------------------------
//
// In stream-json mode, one JSON object is written per line to stdout.
// The shape is roughly:
//   {"type":"tool_call","name":"...","args":"..."}
//   {"type":"assistant","content":"...","tool_call_count":N}
//   {"type":"done","turns":N,"input_tokens":N,"output_tokens":N,...}
//
// Tool execution progress (e.g. "running bash...") and "resuming session"
// notices go to stderr so the stdout stream stays machine-parseable.
// Thinking content is dropped (not useful to scripts; would bloat the
// log); matches upstream kimi-code's stream-json shape.
//
// V 0.5's stdlib `json` module is low-level (no `Any` type), so we
// build the event as a `map[string]string` and run it through
// `json.encode`. Numbers are stringified before encoding; consumers
// parse them with `parseInt`/`parseFloat` on their side.

fn emit_jsonl_event(kind string, fields map[string]string) {
	mut obj := {
		'type': kind
	}
	for k, v in fields {
		obj[k] = v
	}
	line := json.encode(obj)
	println(line)
	stdout_flush()
}

fn outcome_str(o LoopOutcome) string {
	match o {
		.finished { return 'finished' }
		.max_turns { return 'max_turns' }
		.errored { return 'errored' }
	}
}

fn emit_assistant_message(sess &Session) {
	// Walk the session backwards to find the last assistant message.
	mut last := ''
	mut tool_call_count := 0
	for i := sess.messages.len - 1; i >= 0; i-- {
		m := sess.messages[i]
		if m.role == .assistant {
			last = m.content
			tool_call_count = m.tool_calls.len
			break
		}
	}
	mut fields := map[string]string{}
	fields['content'] = last
	if tool_call_count > 0 {
		fields['tool_call_count'] = tool_call_count.str()
	}
	emit_jsonl_event('assistant', fields)
}

fn print_help() {
	println('kimi ${version} — terminal AI coding agent')
	println('')
	println('USAGE:')
	println('    kimi -p "task"                    run a single task and exit')
	println('    kimi --continue <id> -p "task"     resume a session and run task')
	println('    kimi --sessions                    list saved sessions')
	println('    kimi login                          store credentials')
	println('    kimi version                        print version')
	println('    kimi help                           this message')
	println('')
	println('OPTIONS:')
	println('    -p, --prompt TEXT               the task to run')
	println('        --continue <id>            resume a saved session')
	println('        --sessions                 list all saved sessions')
	println('        --model NAME               model identifier')
	println('        --api-base URL             OpenAI-compatible endpoint')
	println('        --api-key KEY              API key (prefer KIMI_API_KEY env)')
	println('        --provider NAME            provider (default: openai-compat)')
	println('        --system TEXT               override system prompt')
	println('        --max-turns INT             agent loop cap (default 32)')
	println('        --max-tokens INT            completion token cap (default 4096)')
	println('        --log-level LEVEL           debug|info|warn|error (default info)')
	println('    -y, --yolo                      skip approval for non-sensitive tool calls')
	println('        --output-format FMT         text (default) or stream-json (-p only)')
	println('    -h, --help')
	println('    -V, --version')
	println('')
	println('ENVIRONMENT:')
	println('    KIMI_API_KEY                   API key')
	println('    KIMI_API_BASE                  API base URL')
	println('    KIMI_MODEL                     model name')
	println('    KIMI_PROVIDER                  provider')
	println('    KIMI_SYSTEM_PROMPT             system prompt override')
	println('    KIMI_LOG_LEVEL                 log verbosity')
	println('    KIMI_CONFIG_DIR                config dir override')
	println('    KIMI_RISKY_TOOLS               comma-separated list of tools requiring approval')
	println('    KIMI_YOLO                      1|true to skip approvals by default')
	println('')
	println('FILES:')
	println('    <config-dir>/config.toml       user config')
	println('    <config-dir>/sessions/         saved sessions')
}

// run_tui_cmd is the interactive TUI entry. Builds the same agent as
// run_prompt but defers to run_tui() for the loop.
fn run_tui_cmd(cli Cli, mut log Logger) ! {
	cli_cfg := Config{
		provider:      cli.provider
		api_base:      cli.api_base
		api_key:       cli.api_key
		model:         cli.model
		system_prompt: cli.system
		log_level:     cli.log_level
		max_turns:     cli.max_turns
		max_tokens:    cli.max_tokens
	}
	mut cfg := load_config(cli_cfg)!
	cfg.validate()!
	if cli.yolo {
		cfg.yolo = true
	}
	_ = cli.output_format

	mut provider := OpenAICompatProvider{
		model:    cfg.model
		api_base: cfg.api_base
		api_key:  cfg.api_key
	}

	mut cfg_mut := cfg
	result := run_tui(mut cfg_mut, provider)
	match result {
		.clean_exit {
			// Nothing to do — terminal already restored.
		}
		.fallback_to_stdout {
			eprintln('error: stdin is not a TTY; cannot enter interactive mode')
			eprintln('hint:  use `-p "task"` for one-shot mode')
			exit(1)
		}
	}
}
