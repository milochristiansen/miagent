// TGI tool discovery and execution: run tools as subprocesses, stream their
// stdout/stderr while they run, and collect tool-returned files.
package harness

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:thread"
import "core:time"
import "core:unicode/utf8"

Tool :: struct {
	name:        string,
	exec_path:   string,
	description: string,
	parameters:  json.Value,
}

Tool_Stream :: enum {
	Stdout,
	Stderr,
}

Tool_Nugget :: struct {
	name:    string,
	content: string,
	mime:    string,
}

tool_nugget_destroy :: proc(n: ^Tool_Nugget) {
	delete(n.name)
	delete(n.content)
	delete(n.mime)
	n^ = {}
}

// select_new_nuggets transfers the non-duplicate nuggets into a fresh slice and
// frees the duplicates. The digest map is updated with every kept nugget, so
// two identical nuggets in one tool result are caught as well. The caller owns
// both returned slices.
select_new_nuggets :: proc(nuggets: []Tool_Nugget, digests: ^map[Nugget_Digest]bool) -> (
	kept: []Tool_Nugget,
	skipped: []string,
) {
	out := make([dynamic]Tool_Nugget, 0, len(nuggets))
	skipped_names := make([dynamic]string, 0, 4)
	for i in 0 ..< len(nuggets) {
		nug := nuggets[i]
		digest := nugget_digest(nug.content)
		if digests[digest] {
			append(&skipped_names, strings.clone(nug.name))
			tool_nugget_destroy(&nug)
			continue
		}
		digests[digest] = true
		append(&out, nug)
	}
	return out[:], skipped_names[:]
}

Tool_Result :: struct {
	code:        int,
	stdout:      string,
	stderr:      string,
	attachments: []Attachment,
	nuggets:     []Tool_Nugget,
	err:         string,
}

TGI_VERSION :: "1"
TOOL_CALL_TIMEOUT :: 5 * time.Minute

MCP_CONFIG_ENV :: "MIAGENT_MCP_CONFIG"
MCP_BRIDGE_ENV :: "MIAGENT_MCP_BRIDGE"
MCP_CONFIG_FILE :: "mcp.json"
MCP_BRIDGE_BINARY :: "miagent-mcp"

// mcp_bridge_configured is a cheap check: if no MCP configuration exists the
// built-in bridge is not added at all, so installations that do not use MCP
// pay neither a process spawn nor a daemon start.
mcp_bridge_configured :: proc(config: ^Config) -> bool {
	if raw, ok := os.lookup_env(MCP_CONFIG_ENV, context.temp_allocator); ok && len(strings.trim_space(raw)) > 0 {
		pieces := strings.split(raw, ":", context.temp_allocator)
		for piece in pieces {
			p := strings.trim_space(piece)
			if len(p) == 0 do continue
			resolved := os.is_absolute_path(p) ? p : join_path(config.project_dir, p)
			found := os.exists(resolved)
			if resolved != p do delete(resolved)
			if found do return true
		}
		return false
	}
	global := join_path(config.config_dir, MCP_CONFIG_FILE)
	local := join_path(config.state_dir, MCP_CONFIG_FILE)
	defer delete(global)
	defer delete(local)
	return os.exists(global) || os.exists(local)
}

executable_file :: proc(path: string) -> bool {
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil || fi.type != .Regular do return false
	return .Execute_User in fi.mode || .Execute_Group in fi.mode || .Execute_Other in fi.mode
}

find_on_path :: proc(name: string) -> string {
	path, ok := os.lookup_env("PATH", context.temp_allocator)
	if !ok do return ""
	dirs := strings.split(path, ":", context.temp_allocator)
	for d in dirs {
		if len(d) == 0 do continue
		candidate := join_path(d, name)
		if executable_file(candidate) do return candidate
		delete(candidate)
	}
	return ""
}

// mcp_bridge_path finds the bridge next to this executable (the normal build
// layout), beside the config, or on PATH. MIAGENT_MCP_BRIDGE overrides all.
mcp_bridge_path :: proc(config: ^Config) -> string {
	if p, ok := os.lookup_env(MCP_BRIDGE_ENV, context.temp_allocator); ok && len(strings.trim_space(p)) > 0 {
		return strings.clone(strings.trim_space(p))
	}
	if dir, err := os.get_executable_directory(context.temp_allocator); err == nil {
		candidate := join_path(dir, MCP_BRIDGE_BINARY)
		if executable_file(candidate) do return candidate
		delete(candidate)
	}
	tools_base := join_path(config.config_dir, "tools")
	bin_base := join_path(config.config_dir, "bin")
	candidate := join_path(tools_base, MCP_BRIDGE_BINARY)
	if executable_file(candidate) {
		delete(tools_base)
		delete(bin_base)
		return candidate
	}
	delete(candidate)
	candidate = join_path(bin_base, MCP_BRIDGE_BINARY)
	if executable_file(candidate) {
		delete(tools_base)
		delete(bin_base)
		return candidate
	}
	delete(candidate)
	delete(tools_base)
	delete(bin_base)
	return find_on_path(MCP_BRIDGE_BINARY)
}

base_name :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' do return path[i + 1:]
	}
	return path
}

tool_destroy :: proc(t: ^Tool) {
	delete(t.name)
	delete(t.exec_path)
	delete(t.description)
	json.destroy_value(t.parameters)
	t.parameters = nil
}

tools_destroy :: proc(tools: ^[]Tool) {
	for &t in tools^ do tool_destroy(&t)
	delete(tools^)
	tools^ = nil
}

tool_env :: proc(config: ^Config, method, name, attachment_dir: string) -> []string {
	// Build one key/value namespace per tool process. Dotenv values come first
	// and exported process variables overwrite them, matching the harness. The
	// map avoids duplicate environment keys, which execve handles unpredictably.
	merged := make(map[string]string, 32)
	defer delete(merged)
	for key, value in config.env do merged[key] = value

	base, _ := os.environ(context.allocator)
	defer {
		for item in base do delete(item)
		delete(base)
	}
	for item in base {
		eq := strings.index_byte(item, '=')
		if eq <= 0 do continue
		merged[item[:eq]] = item[eq + 1:]
	}

	merged["TGI_VERSION"] = TGI_VERSION
	merged["TGI_METHOD"] = method
	merged["TGI_TOOL"] = name
	if method == "INVOKE" do merged["TGI_ATTACHMENT_DIR"] = attachment_dir

	out := make([dynamic]string, 0, len(merged))
	for key, value in merged {
		append(&out, fmt.aprintf("%s=%s", key, value))
	}
	return out[:]
}

free_env :: proc(env: []string) {
	for s in env do delete(s)
	delete(env)
}

// --- discovery -------------------------------------------------------------

Meta_Record :: struct {
	name:        string               `json:"name"`,
	description: string               `json:"description"`,
	parameters:  json.Value           `json:"parameters"`,
}

// split_json_stream splits input into top-level JSON values. It handles both a
// single pretty-printed object and JSON Lines, which is what TGI SCHEMA allows.
split_json_stream :: proc(input: string) -> []string {
	values := make([dynamic]string, 0, 4)
	depth := 0
	start := -1
	in_string := false
	escape := false
	for i in 0 ..< len(input) {
		ch := input[i]
		if in_string {
			if escape {
				escape = false
			} else if ch == '\\' {
				escape = true
			} else if ch == '"' {
				in_string = false
			}
			continue
		}
		switch ch {
		case '"':
			if depth > 0 do in_string = true
			if depth == 0 && start < 0 do start = i
		case '{', '[':
			if depth == 0 do start = i
			depth += 1
		case '}', ']':
			if depth > 0 do depth -= 1
			if depth == 0 && start >= 0 {
				append(&values, input[start:i + 1])
				start = -1
			}
		case:
			// Whitespace and separators between top-level values.
		}
	}
	return values[:]
}

discover_tools :: proc(config: ^Config) -> (tools: []Tool, warnings: string) {
	dirs := [2]string{
		join_path(config.config_dir, TOOLS_DIR),
		join_path(config.state_dir, TOOLS_DIR),
	}
	index := make(map[string]int)
	scanned := make([dynamic]string, 0, 4)
	out := make([dynamic]Tool, 0, 8)
	defer {
		for p in scanned do delete(p)
		delete(scanned)
	}

	for dir in dirs {
		entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil {
			if !os.exists(dir) do continue
			warnings = join_notes(warnings, fmt.aprintf("reading %s: %v", dir, err))
			continue
		}
		// os.ReadDir in the Go CLI sorts by name; do the same so duplicate
		// tool names resolve deterministically.
		for i in 1 ..< len(entries) {
			j := i
			for j > 0 && entries[j].name < entries[j - 1].name {
				entries[j], entries[j - 1] = entries[j - 1], entries[j]
				j -= 1
			}
		}
		for entry in entries {
			if entry.type == .Directory do continue
			exec_path := strings.clone(entry.fullpath)
			if !(.Execute_User in entry.mode) && !(.Execute_Group in entry.mode) && !(.Execute_Other in entry.mode) {
				delete(exec_path)
				continue
			}
			append(&scanned, strings.clone(exec_path))
			defs, schema_warnings, derr := fetch_tool_metas(config, exec_path)
			if len(schema_warnings) > 0 {
				warnings = join_notes(warnings, schema_warnings)
				delete(schema_warnings)
			}
			if derr != "" {
				warnings = join_notes(warnings, fmt.aprintf("tool %q: %s", entry.name, derr))
				delete(exec_path)
				continue
			}
			for &def in defs {
				def.exec_path = strings.clone(exec_path)
				if idx, exists := index[def.name]; exists {
					tool_destroy(&out[idx])
					out[idx] = def
				} else {
					index[strings.clone(def.name)] = len(out)
					append(&out, def)
				}
			}
			delete(defs)
			delete(exec_path)
		}
	}
	// If MCP servers are configured, fold the bridge in as one more TGI tool
	// executable. It declares every MCP tool under a namespaced name, so the
	// model sees MCP and ordinary TGI tools in the same tools array.
	if mcp_bridge_configured(config) {
		bridge := mcp_bridge_path(config)
		if len(bridge) == 0 {
			warnings = join_notes(warnings, "MCP servers are configured but the miagent-mcp bridge was not found (build it with make, set MIAGENT_MCP_BRIDGE, or run make install-mcp)")
		} else {
			already_scanned := false
			for p in scanned do if p == bridge do already_scanned = true
			if !already_scanned {
				defs, schema_warnings, derr := fetch_tool_metas(config, bridge)
				if len(schema_warnings) > 0 {
					warnings = join_notes(warnings, schema_warnings)
					delete(schema_warnings)
				}
				if derr != "" {
					warnings = join_notes(warnings, fmt.aprintf("MCP bridge: %s", derr))
				} else {
					for &def in defs {
						def.exec_path = strings.clone(bridge)
						if idx, exists := index[def.name]; exists {
							tool_destroy(&out[idx])
							out[idx] = def
						} else {
							index[strings.clone(def.name)] = len(out)
							append(&out, def)
						}
					}
					delete(defs)
				}
			}
		}
		delete(bridge)
	}

	for key in index do delete(key)
	delete(index)
	return out[:], warnings
}

fetch_tool_metas :: proc(config: ^Config, exec_path: string) -> (
	tools:    []Tool,
	warnings: string,
	err:      string,
) {
	env := tool_env(config, "SCHEMA", base_name(exec_path), "")
	defer free_env(env)
	state, stdout, stderr, exec_err := os.process_exec(
		{command = []string{exec_path}, env = env, working_dir = config.project_dir},
		context.allocator,
	)
	defer delete(stdout)
	defer delete(stderr)
	if exec_err != nil do return nil, "", fmt.aprintf("running schema: %v", exec_err)
	if state.exit_code != 0 {
		detail := strings.trim_space(string(stderr))
		if len(detail) == 0 do return nil, "", fmt.aprintf("tool exited %d", state.exit_code)
		return nil, "", fmt.aprintf("tool exited %d: %s", state.exit_code, detail)
	}
	// Schema stderr is a warning channel: a tool can report a shadowed entry or
	// a skipped definition while still declaring the tools that are valid.
	trimmed_stderr := strings.trim_space(string(stderr))
	if len(trimmed_stderr) > 0 do warnings = strings.clone(trimmed_stderr)
	parsed, perr := parse_tool_metas(string(stdout))
	if perr != "" {
		delete(warnings)
		return nil, "", perr
	}
	return parsed, warnings, ""
}

parse_tool_metas :: proc(text: string) -> ([]Tool, string) {
	if len(strings.trim_space(text)) == 0 do return make([]Tool, 0), ""
	chunks := split_json_stream(text)
	defer delete(chunks)
	defs := make([dynamic]Tool, 0, 4)
	for chunk, i in chunks {
		m: Meta_Record
		if err := json.unmarshal_string(chunk, &m); err != nil {
			return nil, fmt.aprintf("bad JSON in schema %d: %v", i + 1, err)
		}
		if len(m.name) == 0 {
			delete(m.name)
			delete(m.description)
			json.destroy_value(m.parameters)
			return nil, fmt.aprintf("missing 'name' field in schema %d", i + 1)
		}
		if m.parameters == nil do m.parameters = json.Null(nil)
		append(&defs, Tool{
			name = strings.clone(m.name),
			description = strings.clone(m.description),
			parameters = json.clone_value(m.parameters),
		})
		delete(m.name)
		delete(m.description)
		json.destroy_value(m.parameters)
	}
	if len(defs) == 0 do return nil, "no tool definitions in output"
	return defs[:], ""
}

// --- invocation ------------------------------------------------------------

Tool_Reader :: struct {
	file:    ^os.File,
	buf:     ^strings.Builder,
	h:       ^Harness,
	call_id: string,
	stream:  Tool_Stream,
}

tool_reader :: proc(r: ^Tool_Reader) {
	tmp: [8192]u8
	for {
		n, err := os.read(r.file, tmp[:])
		if n > 0 {
			strings.write_string(r.buf, string(tmp[:n]))
			h_emit_tool_output(r.h, r.call_id, r.stream, string(tmp[:n]))
		}
		if err != nil || n == 0 do break
	}
}

run_tool :: proc(h: ^Harness, config: ^Config, tool: ^Tool, call_id, arguments: string) -> Tool_Result {
	res := Tool_Result{code = -1}
	if h_cancelled(h) {
		res.err = "not executed: interrupted"
		return res
	}

	attachment_dir, attachment_note := make_tool_attachment_dir(config)
	if len(attachment_note) > 0 {
		res.stderr = fmt.aprintf("%s\n", attachment_note)
		h_emit_tool_output(h, call_id, .Stderr, res.stderr)
	}

	env := tool_env(config, "INVOKE", tool.name, attachment_dir)
	defer free_env(env)

	stdin_r, stdin_w, stdin_err := os.pipe()
	if stdin_err != nil {
		res.err = "creating stdin pipe"
		return res
	}
	stdout_r, stdout_w, stdout_err := os.pipe()
	if stdout_err != nil {
		res.err = "creating stdout pipe"
		return res
	}
	stderr_r, stderr_w, stderr_err := os.pipe()
	if stderr_err != nil {
		res.err = "creating stderr pipe"
		return res
	}

	process, perr := os.process_start({
		command = []string{tool.exec_path},
		env = env,
		working_dir = config.project_dir,
		stdin = stdin_r,
		stdout = stdout_w,
		stderr = stderr_w,
	})
	os.close(stdin_r)
	os.close(stdout_w)
	os.close(stderr_w)
	if perr != nil {
		os.close(stdin_w)
		os.close(stdout_r)
		os.close(stderr_r)
		res.err = fmt.aprintf("starting tool: %v", perr)
		return res
	}

	// Feed arguments and close the child's stdin.
	if len(arguments) > 0 {
		_, _ = os.write(stdin_w, transmute([]byte)arguments)
	}
	os.close(stdin_w)

	out_buf := strings.builder_make()
	err_buf := strings.builder_make()
	out_ctx := Tool_Reader{file = stdout_r, buf = &out_buf, h = h, call_id = call_id, stream = .Stdout}
	err_ctx := Tool_Reader{file = stderr_r, buf = &err_buf, h = h, call_id = call_id, stream = .Stderr}
	out_thread := thread.create_and_start_with_poly_data(&out_ctx, tool_reader)
	err_thread := thread.create_and_start_with_poly_data(&err_ctx, tool_reader)

	start := time.tick_now()
	state: os.Process_State
	stop_requested := false
	stop_time := start
	for {
		s, werr := os.process_wait(process, 100 * time.Millisecond)
		if werr == nil && s.exited {
			state = s
			break
		}
		now := time.tick_now()
		if h_cancelled(h) || time.tick_since(start) > TOOL_CALL_TIMEOUT {
			if !stop_requested {
				_ = os.process_terminate(process)
				stop_requested = true
				stop_time = now
			} else if time.tick_since(stop_time) > 5 * time.Second {
				_ = os.process_kill(process)
			}
		}
	}

	thread.join(out_thread)
	thread.join(err_thread)
	os.close(stdout_r)
	os.close(stderr_r)

	res.code = state.exit_code
	res.stdout = strings.to_string(out_buf)
	res.stderr = strings.to_string(err_buf)
	if h_cancelled(h) do res.err = "interrupted"
	if time.tick_since(start) > TOOL_CALL_TIMEOUT {
		note := fmt.aprintf("tool call timed out after %s\n", "5m")
		res.stderr = strings.concatenate({res.stderr, note})
		h_emit_tool_output(h, call_id, .Stderr, note)
		res.code = -1
	}

	if len(attachment_dir) > 0 {
		attachments, nuggets, notes := collect_tool_attachments(attachment_dir)
		if len(notes) > 0 {
			note := strings.join(notes, "\n")
			if len(res.stderr) > 0 && res.stderr[len(res.stderr) - 1] != '\n' do res.stderr = strings.concatenate({res.stderr, "\n"})
			res.stderr = strings.concatenate({res.stderr, note, "\n"})
			h_emit_tool_output(h, call_id, .Stderr, fmt.aprintf("%s\n", note))
			delete(note)
		}
		res.attachments = attachments
		res.nuggets = nuggets
		os.remove_all(attachment_dir)
	}
	return res
}

make_tool_attachment_dir :: proc(config: ^Config) -> (dir: string, note: string) {
	parent := join_path(config.state_dir, "tool-attachments")
	// TGI_ATTACHMENT_DIR is bind-mounted by tools like bash; bwrap needs an
	// absolute destination or it tries to create the relative path under its
	// read-only root.
	if !os.is_absolute_path(parent) {
		if cwd, err := os.get_working_directory(context.temp_allocator); err == nil {
			parent = join_path(cwd, parent)
		}
	}
	if !os.exists(parent) {
		if err := os.make_directory_all(parent); err != nil {
			return "", fmt.aprintf("tool attachments unavailable: %v", err)
		}
	}
	base := strings.concatenate({parent, fmt.aprintf("/%d-%d", os.get_pid(), time.to_unix_nanoseconds(time.now()))})
	for i in 0 ..< 100 {
		candidate := i == 0 ? base : fmt.aprintf("%s-%d", base, i)
		if !os.exists(candidate) {
			if err := os.make_directory(candidate); err != nil {
				return "", fmt.aprintf("tool attachments unavailable: %v", err)
			}
			return candidate, ""
		}
	}
	return "", "tool attachments unavailable: could not find a free directory"
}

Attachment_Collector :: struct {
	attachments: [dynamic]Attachment,
	nuggets:     [dynamic]Tool_Nugget,
	notes:       [dynamic]string,
	total:       i64,
	count:       int,
	limit_noted: bool,
}

collect_tool_attachments :: proc(dir: string) -> ([]Attachment, []Tool_Nugget, []string) {
	c := Attachment_Collector{
		attachments = make([dynamic]Attachment, 0, 8),
		nuggets = make([dynamic]Tool_Nugget, 0, 4),
		notes = make([dynamic]string, 0, 4),
	}
	collect_attachment_dir(&c, dir, "", false)
	nuggets_dir := join_path(dir, "nuggets")
	defer delete(nuggets_dir)
	if os.exists(nuggets_dir) {
		collect_attachment_dir(&c, nuggets_dir, "", true)
	}
	return c.attachments[:], c.nuggets[:], c.notes[:]
}

collect_attachment_dir :: proc(c: ^Attachment_Collector, dir, rel: string, nugget: bool) {
	entries, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {
		append(&c.notes, fmt.aprintf("%s: %v", dir, err))
		return
	}
	defer {
		for e in entries do os.file_info_delete(e, context.allocator)
		delete(entries)
	}
	// Lexical order, as the old image collector documented.
	for i in 1 ..< len(entries) {
		j := i
		for j > 0 && entries[j].name < entries[j - 1].name {
			entries[j], entries[j - 1] = entries[j - 1], entries[j]
			j -= 1
		}
	}

	for e in entries {
		name := len(rel) > 0 ? join_path(rel, e.name) : strings.clone(e.name)
		#partial switch e.type {
		case .Directory:
			if nugget do collect_attachment_dir(c, e.fullpath, name, true)
		case .Regular:
			collect_attachment_file(c, e, name, nugget)
		case:
			// Ignore sockets, symlinks, and other non-regular entries.
		}
		delete(name)
	}
}

collect_attachment_file :: proc(c: ^Attachment_Collector, e: os.File_Info, name: string, nugget: bool) {
	if c.count >= 600 {
		if !c.limit_noted {
			append(&c.notes, "attachment limit reached; further files skipped")
			c.limit_noted = true
		}
		return
	}
	if e.size > 32 << 20 {
		append(&c.notes, fmt.aprintf("%s: file too large", name))
		return
	}
	if c.total + e.size > 48 << 20 {
		append(&c.notes, fmt.aprintf("%s: attachment result too large", name))
		return
	}
	data, rerr := os.read_entire_file(e.fullpath, context.allocator)
	if rerr != nil {
		append(&c.notes, fmt.aprintf("%s: %v", name, rerr))
		return
	}
	defer delete(data)

	if nugget {
		if !is_text_data(data) {
			append(&c.notes, fmt.aprintf("%s: nugget is not UTF-8 text", name))
			return
		}
		text := strings.clone(string(data))
		if len(strings.trim_space(text)) == 0 {
			delete(text)
			append(&c.notes, fmt.aprintf("%s: empty nugget skipped", name))
			return
		}
		append(&c.nuggets, Tool_Nugget{
			name = strings.clone(name),
			content = text,
			mime = strings.clone(text_mime(name)),
		})
		c.total += e.size
		c.count += 1
		return
	}

	if mime := image_mime(data); len(mime) > 0 {
		encoded, enc_err := base64.encode(data)
		if enc_err != nil {
			append(&c.notes, fmt.aprintf("%s: %v", name, enc_err))
			return
		}
		append(&c.attachments, Attachment{
			name = strings.clone(name),
			mime = strings.clone(mime),
			kind = strings.clone("image"),
			url = fmt.aprintf("data:%s;base64,%s", mime, encoded),
			size = int(e.size),
		})
		delete(encoded)
		c.total += e.size
		c.count += 1
		return
	}

	if is_text_data(data) {
		append(&c.attachments, Attachment{
			name = strings.clone(name),
			mime = strings.clone(text_mime(name)),
			kind = strings.clone("text"),
			text = strings.clone(string(data)),
			size = int(e.size),
		})
		c.total += e.size
		c.count += 1
		return
	}

	encoded, enc_err := base64.encode(data)
	if enc_err != nil {
		append(&c.notes, fmt.aprintf("%s: %v", name, enc_err))
		return
	}
	mime := binary_mime(name)
	append(&c.attachments, Attachment{
		name = strings.clone(name),
		mime = strings.clone(mime),
		kind = strings.clone("binary"),
		url = fmt.aprintf("data:%s;base64,%s", mime, encoded),
		size = int(e.size),
	})
	delete(encoded)
	c.total += e.size
	c.count += 1
}

is_text_data :: proc(data: []byte) -> bool {
	for b in data {
		if b == 0 do return false
	}
	return utf8.valid_string(string(data))
}

text_mime :: proc(name: string) -> string {
	lower := strings.to_lower(name)
	defer delete(lower)
	switch {
	case strings.has_suffix(lower, ".md"), strings.has_suffix(lower, ".markdown"):
		return "text/markdown"
	case strings.has_suffix(lower, ".json"):
		return "application/json"
	case strings.has_suffix(lower, ".jsonl"):
		return "application/x-ndjson"
	case strings.has_suffix(lower, ".html"), strings.has_suffix(lower, ".htm"):
		return "text/html"
	case strings.has_suffix(lower, ".xml"):
		return "application/xml"
	case strings.has_suffix(lower, ".csv"):
		return "text/csv"
	case strings.has_suffix(lower, ".yaml"), strings.has_suffix(lower, ".yml"):
		return "application/yaml"
	case strings.has_suffix(lower, ".toml"):
		return "application/toml"
	case strings.has_suffix(lower, ".css"):
		return "text/css"
	case strings.has_suffix(lower, ".js"):
		return "text/javascript"
	case strings.has_suffix(lower, ".ts"):
		return "text/typescript"
	case:
		return "text/plain"
	}
}

binary_mime :: proc(name: string) -> string {
	lower := strings.to_lower(name)
	defer delete(lower)
	switch {
	case strings.has_suffix(lower, ".pdf"):
		return "application/pdf"
	case strings.has_suffix(lower, ".zip"):
		return "application/zip"
	case strings.has_suffix(lower, ".gz"):
		return "application/gzip"
	case strings.has_suffix(lower, ".tar"):
		return "application/x-tar"
	case strings.has_suffix(lower, ".wasm"):
		return "application/wasm"
	case:
		return "application/octet-stream"
	}
}

image_mime :: proc(data: []byte) -> string {
	if len(data) >= 8 && data[0] == 0x89 && data[1] == 'P' && data[2] == 'N' && data[3] == 'G' do return "image/png"
	if len(data) >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF do return "image/jpeg"
	if len(data) >= 6 && (string(data[:6]) == "GIF87a" || string(data[:6]) == "GIF89a") do return "image/gif"
	if len(data) >= 12 && string(data[0:4]) == "RIFF" && string(data[8:12]) == "WEBP" do return "image/webp"
	return ""
}
