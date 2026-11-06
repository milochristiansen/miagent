// Read-only introspection for debugging UIs. A snapshot copies everything it
// exposes: the caller owns the strings and slices and must destroy it with
// harness_snapshot_destroy. The snapshot is built with the same locks the
// worker uses, so it is safe to ask for one while a turn is running.
package harness

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"

// --- prompt documents ------------------------------------------------------

Doc_Info :: struct {
	label:    string,
	path:     string,
	content:  string,
	error:    string,
	exists:   bool,
	required: bool,
}

doc_read :: proc(label, path: string, required: bool) -> Doc_Info {
	d := Doc_Info{
		label = strings.clone(label),
		path = strings.clone(path),
		required = required,
	}
	if !os.exists(path) do return d
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		d.exists = true
		d.error = fmt.aprintf("reading %s: %v", path, err)
		return d
	}
	d.exists = true
	d.content = strings.clone(string(data))
	delete(data)
	return d
}

doc_info_destroy :: proc(d: ^Doc_Info) {
	delete(d.label)
	delete(d.path)
	delete(d.content)
	delete(d.error)
	d^ = {}
}

docs_add :: proc(docs: ^[dynamic]Doc_Info, seen: ^map[string]bool, path, label: string, required: bool) {
	if seen[path] do return
	d := doc_read(label, path, required)
	append(docs, d)
	seen[d.path] = true
}

// prompt_docs lists every file the harness can use as prompt text. The
// well-known documents are always present even when missing, so a debug view
// can show that SYSTEM.md or AGENTS.md was not found instead of silently
// omitting it.
prompt_docs :: proc(c: ^Config) -> []Doc_Info {
	docs := make([dynamic]Doc_Info, 0, 8)
	seen := make(map[string]bool, 8)
	defer delete(seen)

	system_path := join_path(c.config_dir, PROMPTS_DIR, "SYSTEM.md")
	defer delete(system_path)
	docs_add(&docs, &seen, system_path, "prompts/SYSTEM.md", true)

	continue_path := join_path(c.config_dir, PROMPTS_DIR, "CONTINUE.md")
	defer delete(continue_path)
	docs_add(&docs, &seen, continue_path, "prompts/CONTINUE.md", false)

	prompts_dir := join_path(c.config_dir, PROMPTS_DIR)
	defer delete(prompts_dir)
	entries, err := os.read_all_directory_by_path(prompts_dir, context.temp_allocator)
	if err == nil {
		for i in 1 ..< len(entries) {
			j := i
			for j > 0 && entries[j].name < entries[j - 1].name {
				entries[j], entries[j - 1] = entries[j - 1], entries[j]
				j -= 1
			}
		}
		for entry in entries {
			if entry.type == .Directory || !strings.has_suffix(entry.name, ".md") do continue
			label := join_path(PROMPTS_DIR, entry.name)
			defer delete(label)
			docs_add(&docs, &seen, entry.fullpath, label, entry.name == "SYSTEM.md")
		}
	}

	project_agents := join_path(c.project_dir, AGENTS_FILE)
	defer delete(project_agents)
	docs_add(&docs, &seen, project_agents, "AGENTS.md · project", false)

	state_agents := join_path(c.state_dir, AGENTS_FILE)
	defer delete(state_agents)
	docs_add(&docs, &seen, state_agents, "AGENTS.md · .miagent", false)

	return docs[:]
}

// --- tools -----------------------------------------------------------------

Tool_Info :: struct {
	name:        string,
	exec_path:   string,
	description: string,
	parameters:  string,
}

tool_info_destroy :: proc(t: ^Tool_Info) {
	delete(t.name)
	delete(t.exec_path)
	delete(t.description)
	delete(t.parameters)
	t^ = {}
}

Nugget_Info :: struct {
	name:      string,
	source:    string,
	content:   string,
	call_id:   string,
	nugget_id: string,
	tokens:    int,
}

nugget_info_destroy :: proc(n: ^Nugget_Info) {
	delete(n.name)
	delete(n.source)
	delete(n.content)
	delete(n.call_id)
	delete(n.nugget_id)
	n^ = {}
}

nugget_infos :: proc(items: []StoredItem) -> []Nugget_Info {
	out := make([dynamic]Nugget_Info, 0, 8)
	for it in items {
		if it.role != "nugget" do continue
		append(&out, Nugget_Info{
			name = strings.clone(it.name),
			source = strings.clone(it.source),
			content = strings.clone(it.content),
			call_id = strings.clone(it.call_id),
			nugget_id = strings.clone(it.nugget_id),
			tokens = estimate_item_tokens(it),
		})
	}
	return out[:]
}

tool_infos :: proc(tools: []Tool) -> []Tool_Info {
	out := make([]Tool_Info, len(tools))
	for t, i in tools {
		params := "{}"
		if t.parameters != nil {
			if data, err := json.marshal(t.parameters, {
				pretty = true,
				use_spaces = true,
				spaces = 2,
				sort_maps_by_key = true,
			}); err == nil {
				params = strings.clone(string(data))
				delete(data)
			} else {
				params = fmt.aprintf("<could not encode parameters: %v>", err)
			}
		} else {
			params = strings.clone(params)
		}
		out[i] = Tool_Info{
			name = strings.clone(t.name),
			exec_path = strings.clone(t.exec_path),
			description = strings.clone(t.description),
			parameters = params,
		}
	}
	return out
}

// --- turn internals --------------------------------------------------------

Turn_State :: enum {
	Idle,
	Running,
	Completed,
	Failed,
	Interrupted,
}

Turn_Request_Info :: struct {
	model:              string,
	endpoint:           string,
	input_items:        int,
	tools:              int,
	body_bytes:         int,
	instructions_bytes: int,
	context_tokens:     int,
	context_limit:      int,
	context_measured:   bool,
	usage:              Usage,
	got_usage:          bool,
}

Turn_Info :: struct {
	active:      bool,
	status:      Turn_State,
	prompt:      string,
	started:     string,
	finished:    string,
	error:       string,
	last_tool:   string,
	model_calls: int,
	tool_calls:  int,
	request:     Turn_Request_Info,
	turn_usage:  Usage,
	got_usage:   bool,
}

turn_info_destroy :: proc(t: ^Turn_Info) {
	delete(t.prompt)
	delete(t.started)
	delete(t.finished)
	delete(t.error)
	delete(t.last_tool)
	delete(t.request.model)
	delete(t.request.endpoint)
	t^ = {}
}

turn_info_clear :: proc(t: ^Turn_Info) {
	turn_info_destroy(t)
}

// turn_info_reset forgets the previous turn. /new and /load replace the
// session, so reporting the old session's last turn on the details page would
// be misleading.
turn_info_reset :: proc(h: ^Harness) {
	sync.mutex_lock(&h.turn_mutex)
	defer sync.mutex_unlock(&h.turn_mutex)
	turn_info_destroy(&h.turn)
}

turn_info_begin :: proc(h: ^Harness, prompt: string) {
	sync.mutex_lock(&h.turn_mutex)
	defer sync.mutex_unlock(&h.turn_mutex)
	turn_info_destroy(&h.turn)
	h.turn.active = true
	h.turn.status = .Running
	h.turn.prompt = strings.clone(prompt)
	h.turn.started = clock_string()
}

// turn_info_request records one actual Responses API request. It is called for
// retries and continuations too, so model_calls is higher than the number of
// assistant replies when the provider made the harness retry.
turn_info_request :: proc(
	h: ^Harness,
	model, endpoint: string,
	input_items, tool_count, body_bytes, instructions_bytes: int,
) {
	ctx := harness_context(h)
	sync.mutex_lock(&h.turn_mutex)
	defer sync.mutex_unlock(&h.turn_mutex)
	t := &h.turn
	delete(t.request.model)
	t.request.model = strings.clone(model)
	delete(t.request.endpoint)
	t.request.endpoint = strings.clone(endpoint)
	t.request.input_items = input_items
	t.request.tools = tool_count
	t.request.body_bytes = body_bytes
	t.request.instructions_bytes = instructions_bytes
	t.request.context_tokens = ctx.tokens
	t.request.context_limit = ctx.limit
	t.request.context_measured = ctx.measured
	t.model_calls += 1
}

turn_info_usage :: proc(h: ^Harness, usage: Usage, got: bool) {
	if !got do return
	sync.mutex_lock(&h.turn_mutex)
	defer sync.mutex_unlock(&h.turn_mutex)
	h.turn.request.usage = usage
	h.turn.request.got_usage = true
	h.turn.turn_usage = usage_add(h.turn.turn_usage, usage)
	h.turn.got_usage = true
}

turn_info_tool_call :: proc(h: ^Harness, name: string) {
	sync.mutex_lock(&h.turn_mutex)
	defer sync.mutex_unlock(&h.turn_mutex)
	h.turn.tool_calls += 1
	delete(h.turn.last_tool)
	h.turn.last_tool = strings.clone(name)
}

turn_info_finish :: proc(h: ^Harness, status: Turn_State, err: string) {
	sync.mutex_lock(&h.turn_mutex)
	defer sync.mutex_unlock(&h.turn_mutex)
	if !h.turn.active do return
	h.turn.active = false
	h.turn.status = status
	h.turn.finished = clock_string()
	delete(h.turn.error)
	h.turn.error = strings.clone(err)
}

turn_info_auto_finish :: proc(h: ^Harness) {
	sync.mutex_lock(&h.turn_mutex)
	active := h.turn.active
	sync.mutex_unlock(&h.turn_mutex)
	if active do turn_info_finish(h, .Completed, "")
}

turn_info_snapshot_locked :: proc(src: ^Turn_Info, dst: ^Turn_Info) {
	dst^ = src^
	dst.prompt = strings.clone(src.prompt)
	dst.started = strings.clone(src.started)
	dst.finished = strings.clone(src.finished)
	dst.error = strings.clone(src.error)
	dst.last_tool = strings.clone(src.last_tool)
	dst.request.model = strings.clone(src.request.model)
	dst.request.endpoint = strings.clone(src.request.endpoint)
	dst.turn_usage = src.turn_usage
	dst.request.usage = src.request.usage
}

// --- whole-harness snapshot ------------------------------------------------

Harness_Snapshot :: struct {
	project_dir:        string,
	config_dir:         string,
	state_dir:          string,
	session_path:       string,
	model:              string,
	base_url:           string,
	reasoning_effort:   string,
	api_key_set:        bool,
	context_limit:      int,
	context_headroom:   int,
	tool_call_size:     int,
	instructions_bytes: int,

	context_tokens:   int,
	context_items:    int,
	context_measured: bool,
	session_compacted: bool,
	session_file_bytes: int,

	startup_notes: string,
	last_turn:     Turn_Info,
	total_usage:   Usage,
	recent_usages: []Usage,
	tools:         []Tool_Info,
	prompts:       []Doc_Info,
	nuggets:       []Nugget_Info,
}

harness_snapshot_destroy :: proc(s: ^Harness_Snapshot) {
	delete(s.project_dir)
	delete(s.config_dir)
	delete(s.state_dir)
	delete(s.session_path)
	delete(s.model)
	delete(s.base_url)
	delete(s.reasoning_effort)
	delete(s.startup_notes)
	turn_info_destroy(&s.last_turn)
	delete(s.recent_usages)
	for &t in s.tools do tool_info_destroy(&t)
	delete(s.tools)
	for &d in s.prompts do doc_info_destroy(&d)
	delete(s.prompts)
	for &n in s.nuggets do nugget_info_destroy(&n)
	delete(s.nuggets)
	s^ = {}
}

// harness_snapshot is the one call a debug UI needs. It copies configuration,
// prompt files, discovered tools, usage records, and the last (or currently
// running) turn's request metadata.
harness_snapshot :: proc(h: ^Harness) -> Harness_Snapshot {
	s := Harness_Snapshot{}
	sync.mutex_lock(&h.runtime_mutex)
	s.project_dir = strings.clone(h.config.project_dir)
	s.config_dir = strings.clone(h.config.config_dir)
	s.state_dir = strings.clone(h.config.state_dir)
	s.session_path = strings.clone(h.config.session_path)
	s.model = strings.clone(h.config.model)
	s.base_url = strings.clone(h.config.base_url)
	s.reasoning_effort = strings.clone(h.config.reasoning_effort)
	s.api_key_set = len(h.config.api_key) > 0
	s.context_limit = h.config.context_limit
	s.context_headroom = h.config.context_headroom
	s.tool_call_size = h.config.tool_call_size
	s.instructions_bytes = len(h.config.instructions)
	s.startup_notes = strings.clone(h.startup_notes)
	s.tools = tool_infos(h.tools)
	sync.mutex_unlock(&h.runtime_mutex)

	// Prompt files are read after releasing the runtime lock: the snapshot owns
	// the directory paths, and a slow disk read should not block the worker's
	// next bounded reload.
	cfg := Config{project_dir = s.project_dir, config_dir = s.config_dir, state_dir = s.state_dir}
	s.prompts = prompt_docs(&cfg)

	ctx := harness_context(h)
	s.context_tokens = ctx.tokens
	s.context_items = ctx.items
	s.context_measured = ctx.measured

	if st, err := os.stat(s.session_path, context.temp_allocator); err == nil {
		s.session_file_bytes = int(st.size)
	}

	sync.mutex_lock(&h.state_mutex)
	s.session_compacted = h.session.compacted
	s.nuggets = nugget_infos(h.session.items[:])
	s.total_usage = session_total(&h.session)
	recent := 12
	first := len(h.session.usages) - recent
	if first < 0 do first = 0
	s.recent_usages = make([]Usage, len(h.session.usages) - first)
	copy(s.recent_usages, h.session.usages[first:])
	sync.mutex_unlock(&h.state_mutex)

	sync.mutex_lock(&h.turn_mutex)
	turn_info_snapshot_locked(&h.turn, &s.last_turn)
	sync.mutex_unlock(&h.turn_mutex)

	return s
}
