// The desktop harness: config + session + tools + the agent loop, running on
// a worker thread and reporting structured events to the UI. Nothing in this
// package knows about Dear ImGui, so a future CLI can use the same guts.
package harness

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

Event_Kind :: enum {
	Note,
	User,
	Assistant_Start,
	Assistant_Delta,
	Assistant_End,
	Reasoning_Start,
	Reasoning_Delta,
	Reasoning_End,
	Tool_Start,
	Tool_Output,
	Tool_End,
	Context,
	Error,
	// Turn_End marks the end of an agent turn: a prompt was accepted and the
	// model/tool loop ran. Work that finishes without starting a turn (a slash
	// command, an archive load, or a prompt rejected before it begins) emits
	// Action_End instead, so consumers can tell the two apart.
	Turn_End,
	Action_End,
	Session_Changed,
}

Event :: struct {
	kind:     Event_Kind,
	text:     string,
	name:     string,
	meta:     string,
	call_id:  string,
	stream:   Tool_Stream,
	code:     int,
	tokens:   int,
	limit:    int,
	measured: bool,
}

event_destroy :: proc(ev: ^Event) {
	delete(ev.text)
	delete(ev.name)
	delete(ev.meta)
	delete(ev.call_id)
	ev^ = {}
}

// Work_Item is one queued operation for the harness worker. Archive loads keep
// their target separate from prompt text so a GUI action can pass an absolute
// path (including spaces) without going through slash-command word splitting.
Work_Item :: struct {
	prompt:  string,
	archive: string,
}

Harness :: struct {
	// config, tools, and startup_notes are replaced by the worker at turn
	// boundaries. UI readers take runtime_mutex; the worker itself is the only
	// writer and can use them directly between swaps.
	runtime_mutex: sync.Mutex,
	config:        Config,
	session:       Session,
	tools:         []Tool,
	startup_notes: string,

	events:       [dynamic]Event,
	events_mutex: sync.Mutex,

	work_mutex:   sync.Mutex,
	work_cond:    sync.Cond,
	work:         [dynamic]Work_Item,
	running:      bool,
	shutdown:     bool,
	cancel:       i32,

	worker:       ^thread.Thread,

	// Live-block state, touched only by the worker thread.
	reasoning_open: bool,
	assistant_open: bool,

	// state_mutex guards the session's in-memory items when the UI asks for a
	// snapshot after a Session_Changed event.
	state_mutex: sync.Mutex,
	// Cached context size, so the UI never walks the session while the worker
	// is appending to it.
	context_mutex: sync.Mutex,
	ctx_tokens:    int,
	ctx_limit:     int,
	ctx_measured:  bool,
	ctx_items:     int,

	// Last (or currently running) turn metrics for the details view. This is
	// deliberately separate from the event queue: events are drained by the UI,
	// while a details page can ask for a fresh snapshot at any time.
	turn_mutex: sync.Mutex,
	turn:       Turn_Info,
}

// --- events ----------------------------------------------------------------

h_emit :: proc(h: ^Harness, ev: Event) {
	e := ev
	e.text = strings.clone(ev.text)
	e.name = strings.clone(ev.name)
	e.meta = strings.clone(ev.meta)
	e.call_id = strings.clone(ev.call_id)
	sync.mutex_lock(&h.events_mutex)
	append(&h.events, e)
	sync.mutex_unlock(&h.events_mutex)
}

harness_poll_event :: proc(h: ^Harness, ev: ^Event) -> bool {
	sync.mutex_lock(&h.events_mutex)
	defer sync.mutex_unlock(&h.events_mutex)
	if len(h.events) == 0 do return false
	ev^ = h.events[0]
	ordered_remove(&h.events, 0)
	return true
}

h_emit_note :: proc(h: ^Harness, text: string) {
	h_emit(h, Event{kind = .Note, text = text})
}

h_emit_error :: proc(h: ^Harness, text: string) {
	h_emit(h, Event{kind = .Error, text = text})
}

h_emit_reasoning_delta :: proc(h: ^Harness, delta: string) {
	if !h.reasoning_open {
		h.reasoning_open = true
		h_emit(h, Event{kind = .Reasoning_Start})
	}
	h_emit(h, Event{kind = .Reasoning_Delta, text = delta})
}

h_emit_reasoning_end :: proc(h: ^Harness) {
	if h.reasoning_open {
		h.reasoning_open = false
		h_emit(h, Event{kind = .Reasoning_End})
	}
}

h_emit_assistant_delta :: proc(h: ^Harness, delta: string) {
	if !h.assistant_open {
		h.assistant_open = true
		h_emit(h, Event{kind = .Assistant_Start, name = "MiAgent"})
	}
	h_emit(h, Event{kind = .Assistant_Delta, text = delta})
}

h_emit_assistant_end :: proc(h: ^Harness) {
	if h.assistant_open {
		h.assistant_open = false
		h_emit(h, Event{kind = .Assistant_End, meta = clock_string()})
	}
}

h_emit_tool_output :: proc(h: ^Harness, call_id: string, stream: Tool_Stream, text: string) {
	h_emit(h, Event{kind = .Tool_Output, call_id = call_id, stream = stream, text = text})
}

h_emit_context :: proc(h: ^Harness) {
	refresh_context(h)
	info := harness_context(h)
	h_emit(h, Event{
		kind = .Context,
		tokens = info.tokens,
		limit = info.limit,
		measured = info.measured,
	})
}

clock_string :: proc() -> string {
	hour, minute, _ := time.clock_from_time(time.now())
	ampm := hour >= 12 ? "PM" : "AM"
	h12 := hour % 12
	if h12 == 0 do h12 = 12
	return fmt.aprintf("%d:%02d %s", h12, minute, ampm)
}

// --- lifecycle -------------------------------------------------------------

harness_init :: proc(h: ^Harness) -> string {
	return harness_init_project(h, ".")
}

// harness_init_project initializes a harness rooted at project_dir. The
// project directory is the working directory for tools and the base for the
// default .miagent/session.jsonl path, so several GUI projects can each own a
// harness without changing the process's working directory.
harness_init_project :: proc(h: ^Harness, project_dir: string) -> string {
	return harness_init_project_session(h, project_dir, "")
}

// harness_init_project_session is harness_init_project with an explicit
// session file. The GUI uses it to give each conversation tab its own file;
// MIAGENT_SESSION still selects the default file when session_path is empty.
// Per-turn reloads preserve this path. The caller keeps ownership of
// session_path.
harness_init_project_session :: proc(h: ^Harness, project_dir, session_path: string) -> string {
	h.config = config_load_for(project_dir)
	if len(session_path) > 0 {
		delete(h.config.session_path)
		h.config.session_path = strings.clone(session_path)
	}
	h.session = session_init(h.config.session_path)
	h.work = make([dynamic]Work_Item, 0, 4)
	h.events = make([dynamic]Event, 0, 64)

	notes := h.config.setup_error
	if err := session_load(&h.session); err != "" {
		notes = join_notes(notes, err)
	}

	if len(h.config.model) == 0 {
		notes = join_notes(notes, "OPENAI_MODEL is not set; the agent cannot run until it is configured")
	}
	if len(h.config.api_key) == 0 {
		notes = join_notes(notes, "OPENAI_API_KEY is not set")
	}

	tools, warnings := discover_tools(&h.config)
	h.tools = tools
	if len(warnings) > 0 do notes = join_notes(notes, warnings)
	h.startup_notes = strings.clone(notes)
	refresh_context(h)

	h.worker = thread.create_and_start_with_poly_data(h, worker_loop)
	if h.worker == nil {
		return join_notes(notes, "could not start harness worker thread")
	}
	return ""
}

// h_reload_runtime refreshes the long-lived harness at a turn boundary. It
// reloads dotenv/config and therefore the effective SYSTEM.md + AGENTS.md
// instructions, and optionally rediscovers tools. The active session file is
// preserved on purpose: editing MIAGENT_SESSION must not switch conversations
// under a live tab. This is also what lets the future multi-session UI own
// session selection while every tab still shares the project's fresh config.
h_reload_runtime :: proc(h: ^Harness, reload_tools: bool) {
	sync.mutex_lock(&h.runtime_mutex)
	project_dir := strings.clone(h.config.project_dir)
	active_session_path := strings.clone(h.session.path)
	sync.mutex_unlock(&h.runtime_mutex)
	defer delete(project_dir)
	defer delete(active_session_path)

	new_config := config_load_for(project_dir)
	if len(active_session_path) > 0 {
		delete(new_config.session_path)
		new_config.session_path = strings.clone(active_session_path)
	}

	new_tools: []Tool
	notes := ""
	notes_changed := false
	if reload_tools {
		tools, warnings := discover_tools(&new_config)
		new_tools = tools
		notes = strings.clone(new_config.setup_error)
		if len(new_config.model) == 0 {
			updated := join_notes(notes, "OPENAI_MODEL is not set; the agent cannot run until it is configured")
			delete(notes)
			notes = updated
		}
		if len(new_config.api_key) == 0 {
			updated := join_notes(notes, "OPENAI_API_KEY is not set")
			delete(notes)
			notes = updated
		}
		if len(warnings) > 0 {
			updated := join_notes(notes, warnings)
			delete(notes)
			notes = updated
			delete(warnings)
		}
	}

	sync.mutex_lock(&h.runtime_mutex)
	config_destroy(&h.config)
	h.config = new_config
	if reload_tools {
		tools_destroy(&h.tools)
		h.tools = new_tools
		notes_changed = notes != h.startup_notes
		delete(h.startup_notes)
		h.startup_notes = notes
	}
	sync.mutex_unlock(&h.runtime_mutex)

	refresh_context(h)
	if reload_tools && notes_changed && len(notes) > 0 {
		h_emit_note(h, notes)
	}
}

refresh_context :: proc(h: ^Harness) {
	sync.mutex_lock(&h.state_mutex)
	used, measured := session_context(&h.session)
	item_count := len(h.session.items)
	sync.mutex_unlock(&h.state_mutex)
	sync.mutex_lock(&h.context_mutex)
	h.ctx_tokens = used
	h.ctx_limit = h.config.context_limit
	h.ctx_measured = measured
	h.ctx_items = item_count
	sync.mutex_unlock(&h.context_mutex)
}

harness_destroy :: proc(h: ^Harness) {
	sync.mutex_lock(&h.work_mutex)
	h.shutdown = true
	sync.atomic_store(&h.cancel, 1)
	sync.cond_signal(&h.work_cond)
	sync.mutex_unlock(&h.work_mutex)
	if h.worker != nil do thread.join(h.worker)

	for &w in h.work {
		delete(w.prompt)
		delete(w.archive)
	}
	delete(h.work)
	for &ev in h.events do event_destroy(&ev)
	delete(h.events)
	harness_reset_live(h)
	tools_destroy(&h.tools)
	session_destroy(&h.session)
	config_destroy(&h.config)
	delete(h.startup_notes)
	turn_info_destroy(&h.turn)
}

harness_reset_live :: proc(h: ^Harness) {
	h.reasoning_open = false
	h.assistant_open = false
}

harness_submit :: proc(h: ^Harness, prompt: string) -> bool {
	trimmed := strings.trim_space(prompt)
	if len(trimmed) == 0 do return false
	sync.mutex_lock(&h.work_mutex)
	if h.shutdown {
		sync.mutex_unlock(&h.work_mutex)
		return false
	}
	append(&h.work, Work_Item{prompt = strings.clone(trimmed)})
	sync.cond_signal(&h.work_cond)
	sync.mutex_unlock(&h.work_mutex)
	return true
}

// harness_load_archive queues the same operation as `/load TARGET`, but takes
// the archive path directly. The current session is archived before the target
// is adopted, exactly like the slash command. The caller does not need to keep
// archive_path alive after this returns.
harness_load_archive :: proc(h: ^Harness, archive_path: string) -> bool {
	target := strings.trim_space(archive_path)
	if len(target) == 0 do return false
	sync.mutex_lock(&h.work_mutex)
	if h.shutdown {
		sync.mutex_unlock(&h.work_mutex)
		return false
	}
	append(&h.work, Work_Item{archive = strings.clone(target)})
	sync.cond_signal(&h.work_cond)
	sync.mutex_unlock(&h.work_mutex)
	return true
}

harness_cancel :: proc(h: ^Harness) {
	sync.atomic_store(&h.cancel, 1)
}

harness_is_running :: proc(h: ^Harness) -> bool {
	sync.mutex_lock(&h.work_mutex)
	defer sync.mutex_unlock(&h.work_mutex)
	return h.running
}

harness_has_queued :: proc(h: ^Harness) -> bool {
	sync.mutex_lock(&h.work_mutex)
	defer sync.mutex_unlock(&h.work_mutex)
	return len(h.work) > 0
}

h_cancelled :: proc(h: ^Harness) -> bool {
	return sync.atomic_load(&h.cancel) != 0
}

worker_loop :: proc(h: ^Harness) {
	for {
		sync.mutex_lock(&h.work_mutex)
		for len(h.work) == 0 && !h.shutdown {
			sync.cond_wait(&h.work_cond, &h.work_mutex)
		}
		if h.shutdown {
			sync.mutex_unlock(&h.work_mutex)
			break
		}
		item := h.work[0]
		ordered_remove(&h.work, 0)
		h.running = true
		sync.atomic_store(&h.cancel, 0)
		sync.mutex_unlock(&h.work_mutex)

		if len(item.archive) > 0 {
			h_run_archive_load(h, item.archive)
		} else {
			h_run_prompt(h, item.prompt)
		}
		delete(item.prompt)
		delete(item.archive)

		sync.mutex_lock(&h.work_mutex)
		h.running = false
		sync.mutex_unlock(&h.work_mutex)
	}
}

// --- introspection ---------------------------------------------------------

// String getters return owned copies because the worker can replace the
// configuration and tool list at a turn boundary.
harness_model :: proc(h: ^Harness) -> string {
	sync.mutex_lock(&h.runtime_mutex)
	defer sync.mutex_unlock(&h.runtime_mutex)
	return strings.clone(h.config.model)
}

harness_base_url :: proc(h: ^Harness) -> string {
	sync.mutex_lock(&h.runtime_mutex)
	defer sync.mutex_unlock(&h.runtime_mutex)
	return strings.clone(h.config.base_url)
}

harness_session_path :: proc(h: ^Harness) -> string {
	sync.mutex_lock(&h.runtime_mutex)
	defer sync.mutex_unlock(&h.runtime_mutex)
	return strings.clone(h.config.session_path)
}

harness_project_dir :: proc(h: ^Harness) -> string {
	sync.mutex_lock(&h.runtime_mutex)
	defer sync.mutex_unlock(&h.runtime_mutex)
	return strings.clone(h.config.project_dir)
}

harness_startup_notes :: proc(h: ^Harness) -> string {
	sync.mutex_lock(&h.runtime_mutex)
	defer sync.mutex_unlock(&h.runtime_mutex)
	return strings.clone(h.startup_notes)
}

harness_tool_count :: proc(h: ^Harness) -> int {
	sync.mutex_lock(&h.runtime_mutex)
	defer sync.mutex_unlock(&h.runtime_mutex)
	return len(h.tools)
}

harness_config_dir :: proc(h: ^Harness) -> string {
	sync.mutex_lock(&h.runtime_mutex)
	defer sync.mutex_unlock(&h.runtime_mutex)
	return strings.clone(h.config.config_dir)
}

harness_tool_call_size :: proc(h: ^Harness) -> int {
	sync.mutex_lock(&h.runtime_mutex)
	defer sync.mutex_unlock(&h.runtime_mutex)
	return h.config.tool_call_size
}

harness_reasoning_effort :: proc(h: ^Harness) -> string {
	sync.mutex_lock(&h.runtime_mutex)
	defer sync.mutex_unlock(&h.runtime_mutex)
	return strings.clone(h.config.reasoning_effort)
}

harness_context_limit :: proc(h: ^Harness) -> int {
	sync.mutex_lock(&h.runtime_mutex)
	defer sync.mutex_unlock(&h.runtime_mutex)
	return h.config.context_limit
}

harness_context_headroom :: proc(h: ^Harness) -> int {
	sync.mutex_lock(&h.runtime_mutex)
	defer sync.mutex_unlock(&h.runtime_mutex)
	return h.config.context_headroom
}

harness_session_compacted :: proc(h: ^Harness) -> bool {
	sync.mutex_lock(&h.state_mutex)
	defer sync.mutex_unlock(&h.state_mutex)
	return h.session.compacted
}

// harness_mcp_configured tells the desktop whether the MCP bridge is relevant
// for this project. harness_has_mcp_tools is the stronger signal that
// discovery actually produced MCP-backed tools.
harness_mcp_configured :: proc(h: ^Harness) -> bool {
	sync.mutex_lock(&h.runtime_mutex)
	defer sync.mutex_unlock(&h.runtime_mutex)
	return mcp_bridge_configured(&h.config)
}

harness_has_mcp_tools :: proc(h: ^Harness) -> bool {
	sync.mutex_lock(&h.runtime_mutex)
	defer sync.mutex_unlock(&h.runtime_mutex)
	for t in h.tools do if strings.has_prefix(t.name, "mcp__") do return true
	return false
}

Context_Info :: struct {
	tokens:   int,
	limit:    int,
	measured: bool,
	items:    int,
}

harness_context :: proc(h: ^Harness) -> Context_Info {
	sync.mutex_lock(&h.context_mutex)
	defer sync.mutex_unlock(&h.context_mutex)
	return Context_Info{
		tokens = h.ctx_tokens,
		limit = h.ctx_limit,
		measured = h.ctx_measured,
		items = h.ctx_items,
	}
}

clone_reasoning :: proc(src: Reasoning) -> Reasoning {
	r := Reasoning{}
	r.id = strings.clone(src.id)
	r.encrypted_content = strings.clone(src.encrypted_content)
	r.summary = make([]ReasoningPart, len(src.summary))
	for p, i in src.summary do r.summary[i] = ReasoningPart{kind = strings.clone(p.kind), text = strings.clone(p.text)}
	r.content = make([]ReasoningPart, len(src.content))
	for p, i in src.content do r.content[i] = ReasoningPart{kind = strings.clone(p.kind), text = strings.clone(p.text)}
	return r
}

clone_item :: proc(src: StoredItem) -> StoredItem {
	it := StoredItem{
		// item_destroy deliberately does not free role: most callers use string
		// literals. Sharing the source role is therefore safe and avoids an
		// allocation that would otherwise leak on every clone.
		role = src.role,
		content = strings.clone(src.content),
		call_id = strings.clone(src.call_id),
		name = strings.clone(src.name),
		arguments = strings.clone(src.arguments),
		output = strings.clone(src.output),
		source = strings.clone(src.source),
		nugget_id = strings.clone(src.nugget_id),
	}
	if r, ok := src.reasoning.?; ok do it.reasoning = clone_reasoning(r)
	if len(src.attachments) > 0 {
		it.attachments = make([]Attachment, len(src.attachments))
		for att, i in src.attachments {
			it.attachments[i] = Attachment{
				name = strings.clone(att.name),
				mime = strings.clone(att.mime),
				kind = strings.clone(att.kind),
				text = strings.clone(att.text),
				url = strings.clone(att.url),
				size = att.size,
			}
		}
	}
	return it
}

harness_free_items :: proc(items: []StoredItem) {
	for &it in items do item_destroy(&it)
	delete(items)
}

// harness_history returns a deep copy of the loaded conversation so the UI can
// build its initial transcript without sharing ownership with the worker.
harness_history :: proc(h: ^Harness) -> []StoredItem {
	sync.mutex_lock(&h.state_mutex)
	defer sync.mutex_unlock(&h.state_mutex)
	out := make([]StoredItem, len(h.session.items))
	for it, i in h.session.items do out[i] = clone_item(it)
	return out
}

// --- agent loop ------------------------------------------------------------

// h_run_archive_load adopts an archive without parsing a slash command. It
// mirrors the command path's event sequence so the GUI reloads the transcript
// and then appends the command's notes.
h_run_archive_load :: proc(h: ^Harness, target: string) {
	if len(h.config.project_dir) > 0 do h_reload_runtime(h, false)
	harness_reset_live(h)
	if err := cmd_load_target(h, target); err != "" do h_emit_error(h, err)
	h_emit(h, Event{kind = .Action_End})
}

h_run_prompt :: proc(h: ^Harness, prompt: string) {
	command := strings.has_prefix(prompt, "/")
	if len(h.config.project_dir) > 0 do h_reload_runtime(h, !command)
	harness_reset_live(h)
	if command {
		h_run_command(h, prompt)
		h_emit(h, Event{kind = .Action_End})
		return
	}

	if len(h.config.model) == 0 {
		h_emit_error(h, "model not configured: set OPENAI_MODEL")
		h_emit(h, Event{kind = .Action_End})
		return
	}
	if len(h.config.instructions) == 0 {
		h_emit_error(h, "system prompt missing: install prompts/SYSTEM.md in the MiAgent configuration directory")
		h_emit(h, Event{kind = .Action_End})
		return
	}
	if len(h.config.api_key) == 0 {
		// Some local endpoints accept no key; the request will decide. Only
		// warn when the URL looks like a hosted provider.
		if strings.contains(h.config.base_url, "api.openai.com") || strings.contains(h.config.base_url, "deepseek.com") {
			h_emit_error(h, "OPENAI_API_KEY is not set")
			h_emit(h, Event{kind = .Action_End})
			return
		}
	}

	// Context headroom: refuse before a request that can barely fit.
	if h.config.context_headroom > 0 && h.config.context_limit > 0 {
		sync.mutex_lock(&h.state_mutex)
		used, measured := session_context(&h.session)
		sync.mutex_unlock(&h.state_mutex)
		remaining := h.config.context_limit - used
		if remaining * 100 < h.config.context_limit * h.config.context_headroom {
			h_emit_note(h, fmt.aprintf(
				"context: %d / %d tokens%s, only %.1f%% left (below the %d%% headroom to start a turn); compact the session before sending again",
				used, h.config.context_limit, measured ? "" : " (estimated)",
				100 * f32(max(remaining, 0)) / f32(h.config.context_limit), h.config.context_headroom))
			h_emit(h, Event{kind = .Action_End})
			return
		}
	}

	sync.mutex_lock(&h.state_mutex)
	session_append_item(&h.session, StoredItem{role = "user", content = strings.clone(prompt)})
	sync.mutex_unlock(&h.state_mutex)
	turn_info_begin(h, prompt)
	defer turn_info_auto_finish(h)
	h_emit(h, Event{kind = .User, text = prompt})

	// Nuggets are hard, unchanging context, so one copy per unique content is
	// enough. Seed the set from the whole session and keep it current as this
	// turn appends new nuggets. This also makes a repeated skill activation a
	// no-op at the context level.
	sync.mutex_lock(&h.state_mutex)
	nugget_digests := session_nugget_digests(h.session.items[:])
	sync.mutex_unlock(&h.state_mutex)
	defer delete(nugget_digests)

	for {
		input := build_input(h.session.items[:])
		tools := build_tools(h.tools)
		items, usage, got_usage, final, err := run_model_turn(h, input, tools)
		for v in tools do json.destroy_value(v)
		delete(tools)
		for v in input do json.destroy_value(v)
		delete(input)

		sync.mutex_lock(&h.state_mutex)
		if len(items) > 0 {
			for it in items do append(&h.session.items, it)
		}
		if got_usage {
			usage.at_items = len(h.session.items)
			session_append_usage(&h.session, usage)
		}
		sync.mutex_unlock(&h.state_mutex)

		if err != "" {
			// Answer any function calls the failed turn left behind so the
			// session remains replayable.
			sync.mutex_lock(&h.state_mutex)
			extra := unanswered_tool_outputs(items)
			for it in extra do append(&h.session.items, it)
			cerr := session_commit(&h.session)
			sync.mutex_unlock(&h.state_mutex)
			if cerr != "" do h_emit_error(h, cerr)
			h_emit_error(h, err)
			turn_info_finish(h, err == "interrupted" ? .Interrupted : .Failed, err)
			h_emit_context(h)
			h_emit(h, Event{kind = .Turn_End})
			delete(items)
			return
		}

		h_emit_context(h)

		if final {
			sync.mutex_lock(&h.state_mutex)
			cerr := session_commit(&h.session)
			sync.mutex_unlock(&h.state_mutex)
			if cerr != "" do h_emit_error(h, cerr)
			turn_info_finish(h, cerr != "" ? .Failed : .Completed, cerr)
			h_emit(h, Event{kind = .Turn_End})
			delete(items)
			return
		}

		for it in items {
			if it.role != "function_call" do continue
			h_emit_assistant_end(h)
			h_emit_reasoning_end(h)
			args := pretty_json(it.arguments)
			h_emit(h, Event{
				kind = .Tool_Start,
				call_id = it.call_id,
				name = it.name,
				text = args,
			})
			delete(args)

			tool := find_tool(h, it.name)
			start := time.tick_now()
			res: Tool_Result
			if tool == nil {
				res = Tool_Result{code = -1, stderr = fmt.aprintf("unknown tool: %s\n", it.name)}
				h_emit_tool_output(h, it.call_id, .Stderr, res.stderr)
			} else {
				res = run_tool(h, &h.config, tool, it.call_id, it.arguments)
			}
			kept_nuggets, skipped_names := select_new_nuggets(res.nuggets, &nugget_digests)
			delete(res.nuggets)
			res.nuggets = kept_nuggets
			skipped_count := len(skipped_names)
			if skipped_count > 0 {
				joined := strings.join(skipped_names, ", ")
				note := fmt.aprintf("duplicate nugget%s skipped: %s\n", skipped_count == 1 ? "" : "s", joined)
				delete(joined)
				if len(res.stderr) > 0 && res.stderr[len(res.stderr) - 1] != '\n' {
					updated := strings.concatenate({res.stderr, "\n"})
					delete(res.stderr)
					res.stderr = updated
				}
				updated := strings.concatenate({res.stderr, note})
				delete(res.stderr)
				res.stderr = updated
				h_emit_tool_output(h, it.call_id, .Stderr, note)
				delete(note)
			}
			for name in skipped_names do delete(name)
			delete(skipped_names)
			if len(res.err) > 0 && len(res.stderr) == 0 {
				h_emit_tool_output(h, it.call_id, .Stderr, fmt.aprintf("%s\n", res.err))
			}
			envelope := tool_envelope(res)
			status := res.code
			meta := fmt.aprintf("%.2fs", time.duration_seconds(time.tick_since(start)))

			if len(res.err) > 0 && res.code != -1 {
				res.code = -1
				status = -1
			}
			h_emit(h, Event{kind = .Tool_End, call_id = it.call_id, code = status, meta = meta})
			turn_info_tool_call(h, it.name)
			delete(meta)
			if len(res.attachments) > 0 {
				h_emit_note(h, fmt.aprintf("attached %d file%s to the tool result",
					len(res.attachments), len(res.attachments) == 1 ? "" : "s"))
			}
			if len(res.nuggets) > 0 {
				h_emit_note(h, fmt.aprintf("preserved %d nugget%s for this session",
					len(res.nuggets), len(res.nuggets) == 1 ? "" : "s"))
			}
			if skipped_count > 0 {
				h_emit_note(h, fmt.aprintf("skipped %d duplicate nugget%s",
					skipped_count, skipped_count == 1 ? "" : "s"))
			}

			sync.mutex_lock(&h.state_mutex)
			append(&h.session.items, StoredItem{
				role = "function_call_output",
				call_id = strings.clone(it.call_id),
				output = envelope,
				attachments = res.attachments,
			})
			for nug in res.nuggets {
				append(&h.session.items, StoredItem{
					role = "nugget",
					name = nug.name,
					content = nug.content,
					source = fmt.aprintf("tool:%s", it.name),
					call_id = strings.clone(it.call_id),
					nugget_id = fmt.aprintf("%s:%s", it.call_id, nug.name),
				})
				delete(nug.mime)
			}
			sync.mutex_unlock(&h.state_mutex)
			delete(res.nuggets)
			// envelope, attachments, and nugget strings were transferred above.
			delete(res.stdout)
			delete(res.stderr)
			if len(res.err) > 0 do delete(res.err)
		}

		sync.mutex_lock(&h.state_mutex)
		cerr := session_commit(&h.session)
		sync.mutex_unlock(&h.state_mutex)
		if cerr != "" {
			h_emit_error(h, cerr)
			turn_info_finish(h, .Failed, cerr)
			h_emit(h, Event{kind = .Turn_End})
			delete(items)
			return
		}
		delete(items)
	}
}

find_tool :: proc(h: ^Harness, name: string) -> ^Tool {
	for &t in h.tools do if t.name == name do return &t
	return nil
}

pretty_json :: proc(s: string) -> string {
	trimmed := strings.trim_space(s)
	if len(trimmed) == 0 do return strings.clone("")
	v, err := json.parse_string(trimmed)
	if err != nil do return strings.clone(trimmed)
	defer json.destroy_value(v)
	data, merr := json.marshal(v, {pretty = true, use_spaces = true, spaces = 4})
	if merr != nil do return strings.clone(trimmed)
	defer delete(data)
	return strings.clone(string(data))
}

TGI_Envelope :: struct {
	exit_code: int    `json:"exit_code"`,
	stdout:    string `json:"stdout"`,
	stderr:    string `json:"stderr"`,
}

tool_envelope :: proc(res: Tool_Result) -> string {
	stderr := res.stderr
	if len(res.err) > 0 {
		if len(stderr) > 0 && stderr[len(stderr) - 1] != '\n' do stderr = strings.concatenate({stderr, "\n"})
		stderr = strings.concatenate({stderr, res.err, "\n"})
	}
	env := TGI_Envelope{exit_code = res.code, stdout = res.stdout, stderr = stderr}
	data, err := json.marshal(env, {pretty = true, use_spaces = true, spaces = 4})
	if err != nil do return fmt.aprintf("{\"exit_code\":%d,\"stdout\":\"\",\"stderr\":\"encoding error\"}\n", res.code)
	defer delete(data)
	return fmt.aprintf("%s\n", string(data))
}

unanswered_tool_outputs :: proc(items: []StoredItem) -> []StoredItem {
	answered := make(map[string]bool, context.temp_allocator)
	for it in items do if it.role == "function_call_output" do answered[it.call_id] = true
	out := make([dynamic]StoredItem, 0, 2)
	for it in items {
		if it.role != "function_call" || len(it.call_id) == 0 || answered[it.call_id] do continue
		answered[it.call_id] = true
		env := tool_envelope(Tool_Result{code = -1, stderr = "not executed: interrupted by signal"})
		append(&out, StoredItem{role = "function_call_output", call_id = strings.clone(it.call_id), output = env})
	}
	return out[:]
}

// with_assistant_text returns items whose assistant message carries answer,
// inserting one after leading reasoning items when the response was tool-calls
// only. It may return a new backing array.
with_assistant_text :: proc(items: []StoredItem, answer: string) -> []StoredItem {
	for &it in items {
		if it.role == "assistant" {
			delete(it.content)
			it.content = strings.clone(answer)
			return items
		}
	}
	if len(answer) == 0 do return items

	at := 0
	for at < len(items) && items[at].role == "reasoning" do at += 1
	out := make([]StoredItem, len(items) + 1)
	copy(out[:at], items[:at])
	out[at] = StoredItem{role = "assistant", content = strings.clone(answer)}
	copy(out[at + 1:], items[at:])
	delete(items)
	return out
}

combined_answer :: proc(carry, attempt_answer, attempt_text: string) -> string {
	answer := attempt_answer
	if len(answer) == 0 do answer = attempt_text
	if len(carry) > 0 && strings.has_prefix(answer, carry) {
		// A provider that repeats the partial answer on a continuation is
		// common enough; do not persist the carried prefix twice.
		return fmt.aprintf("%s", answer)
	}
	return fmt.aprintf("%s%s", carry, answer)
}

// run_model_turn runs one model turn with the CLI's retry/continuation policy.
run_model_turn :: proc(h: ^Harness, conversation_input: []json.Value, tools: []json.Value) -> (
	items: []StoredItem,
	usage: Usage,
	got_usage: bool,
	final: bool,
	err: string,
) {
	carry := strings.builder_make()
	defer delete(carry.buf)
	continuing := false
	continue_prompt: string
	defer delete(continue_prompt)
	retries := 0
	continuations := 0

	for {
		input := conversation_input
		extra: [dynamic]json.Value
		owned: [dynamic]json.Value
		if continuing {
			extra = make([dynamic]json.Value, 0, len(conversation_input) + 2)
			owned = make([dynamic]json.Value, 0, 2)
			append(&extra, ..conversation_input[0:])
			carry_text := strings.to_string(carry)
			if len(carry_text) > 0 {
				v := message_input("assistant", "output_text", carry_text)
				append(&extra, v)
				append(&owned, v)
			}
			if len(continue_prompt) == 0 {
				p, perr := load_optional_prompt(h.config.config_dir, "CONTINUE.md", true)
				if perr != "" {
					err = perr
					items = []StoredItem{}
					return
				}
				continue_prompt = p
			}
			v := message_input("user", "input_text", continue_prompt)
			append(&extra, v)
			append(&owned, v)
			input = extra[:]
		}

		accum, aerr_raw := stream_model_turn(h, input, tools)
		aerr := strings.clone(aerr_raw)
		attempt_text := strings.clone(strings.to_string(accum.assistant))
		attempt_items := take_turn_items(&accum)
		attempt_usage := accum.usage
		attempt_got_usage := accum.got_usage
		attempt_progress := accum.progress
		turn_info_usage(h, attempt_usage, attempt_got_usage)
		turn_accum_destroy(&accum)
		if len(extra) > 0 do delete(extra)
		if len(owned) > 0 {
			for v in owned do json.destroy_value(v)
			delete(owned)
		}

		if aerr == "" {
			answer := combined_answer(strings.to_string(carry), assistant_text_of(attempt_items), attempt_text)
			attempt_items = with_assistant_text(attempt_items, answer)
			// Echo any remainder the display did not see.
			streamed := fmt.aprintf("%s%s", strings.to_string(carry), attempt_text)
			if len(answer) > len(streamed) && strings.has_prefix(answer, streamed) {
				h_emit_assistant_delta(h, answer[len(streamed):])
			}
			delete(attempt_text)
			h_emit_assistant_end(h)
			h_emit_reasoning_end(h)
			final = !turn_has_function_call(attempt_items)
			return attempt_items, attempt_usage, attempt_got_usage, final, ""
		}

		answer := combined_answer(strings.to_string(carry), assistant_text_of(attempt_items), attempt_text)
		attempt_items = with_assistant_text(attempt_items, answer)

		if h_cancelled(h) {
			delete(attempt_text)
			h_emit_assistant_end(h)
			h_emit_reasoning_end(h)
			return attempt_items, attempt_usage, attempt_got_usage, false, "interrupted"
		}

		if attempt_progress {
			if continuations >= MAX_MODEL_CONTINUATIONS {
				delete(attempt_text)
				h_emit_assistant_end(h)
				h_emit_reasoning_end(h)
				return attempt_items, attempt_usage, attempt_got_usage, false,
					fmt.aprintf("model turn did not complete after %d continuation attempts: %s", continuations, aerr)
			}
			continuations += 1
			strings.write_string(&carry, attempt_text)
			delete(attempt_text)
			continuing = true
			retries = 0
			for &it in attempt_items do item_destroy(&it)
			delete(attempt_items)
			continue
		}

		if retries >= MAX_MODEL_RETRIES {
			delete(attempt_text)
			h_emit_assistant_end(h)
			h_emit_reasoning_end(h)
			return attempt_items, attempt_usage, attempt_got_usage, false, aerr
		}
		retries += 1
		delete(attempt_text)
		for &it in attempt_items do item_destroy(&it)
		delete(attempt_items)
	}
}

// --- slash commands --------------------------------------------------------

h_run_command :: proc(h: ^Harness, prompt: string) {
	fields := strings.fields(prompt)
	defer delete(fields)
	if len(fields) == 0 do return
	name := fields[0][1:]
	args := fields[1:]
	switch name {
	case "help":
		h_emit_note(h, "Enter your prompt below. Slash commands:\n" +
			"  /help      list commands\n" +
			"  /context   context size for this session\n" +
			"  /models    list models (not wired up in the desktop app yet)\n" +
			"  /desc      describe the work done in this session\n" +
			"  /compact   summarize older conversation and archive the session\n" +
			"  /new       archive the session and start fresh\n" +
			"  /sessions  list archived sessions\n" +
			"  /load      load an archived session")
	case "context":
		used, measured := session_context(&h.session)
		note := measured ? "" : ", estimated"
		if h.config.context_limit > 0 {
			h_emit_note(h, fmt.aprintf("context: %d / %d tokens (%.1f%%%s)", used, h.config.context_limit,
				100 * f32(used) / f32(h.config.context_limit), note))
		} else {
			h_emit_note(h, fmt.aprintf("context: %d tokens%s (maximum unknown; set MIAGENT_CONTEXT_LIMIT)", used, note))
		}
	case "models":
		if len(args) > 0 {
			h_emit_error(h, "takes no arguments")
			return
		}
		if err := cmd_models(h); err != "" do h_emit_error(h, err)
	case "new":
		if len(args) > 0 {
			h_emit_error(h, "takes no arguments")
			return
		}
		if err := cmd_new(h); err != "" do h_emit_error(h, err)
	case "sessions":
		if err := cmd_sessions(h, args); err != "" do h_emit_error(h, err)
	case "load":
		if err := cmd_load(h, args); err != "" do h_emit_error(h, err)
	case "compact":
		if err := cmd_compact(h, args); err != "" do h_emit_error(h, err)
	case "desc":
		if err := cmd_desc(h, args); err != "" do h_emit_error(h, err)
	case:
		h_emit_note(h, fmt.aprintf("unknown command /%s; run /help for the list", name))
	}
}

load_optional_prompt :: proc(config_dir, name: string, required: bool) -> (string, string) {
	return read_prompt(join_path(config_dir, PROMPTS_DIR, name), required)
}
