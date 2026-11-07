// One live MCP server session.  Stdio servers keep a child process and its
// pipes for as long as the host runs; streamable-HTTP servers keep only the
// session id and headers.  The session layer is transport agnostic above the
// rpc boundary, which is what lets the bridge expose both kinds as TGI tools.
package mcp

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

Session_State :: enum {
	New,
	Starting,
	Ready,
	Failed,
	Closed,
}

state_string :: proc(s: Session_State) -> string {
	switch s {
	case .New: return "new"
	case .Starting: return "starting"
	case .Ready: return "ready"
	case .Failed: return "failed"
	case .Closed: return "closed"
	}
	return "unknown"
}

transport_string :: proc(t: Transport_Kind) -> string {
	switch t {
	case .Stdio: return "stdio"
	case .Streamable_HTTP: return "http"
	case .SSE: return "sse"
	}
	return "unknown"
}

Pending :: struct {
	raw:  string,
	err:  string,
	done: bool,
}

Mcp_Session :: struct {
	project:     string,
	config:      Server_Config,
	base_env:    map[string]string,
	fingerprint: string,

	status_mu: sync.Mutex,
	state:     Session_State,
	error:     string,
	logs:      string,
	tools:     []Advertised_Tool,
	failed_at: time.Tick,
	stopping:  bool,

	// Capabilities from initialize. They are set before the session becomes
	// Ready and are read under status_mu.
	supports_resources:     bool,
	resources_subscribe:    bool,
	resources_list_changed: bool,

	init_mu:      sync.Mutex,
	init_cond:    sync.Cond,
	initializing: bool,
	initialized:  bool,
	// Serializes transport start and teardown. It is deliberately separate
	// from init_mu: waiters must be able to observe initialization without
	// blocking a shutdown that needs to clean up the transport.
	lifecycle_mu: sync.Mutex,

	rpc_mu:   sync.Mutex,
	rpc_cond: sync.Cond,
	next_id:  int,
	pending:  map[int]^Pending,

	write_mu: sync.Mutex,

	process:         os.Process,
	process_started: bool,
	stdin:           ^os.File,
	stdout_r:        ^os.File,
	stderr_r:        ^os.File,
	reader:          ^thread.Thread,
	stderr_reader:   ^thread.Thread,
	waiter:          ^thread.Thread,

	http_mu:              sync.Mutex,
	http_session_id:      string,
	http_protocol_version: string,

	last_used: time.Tick,
}

server_clone :: proc(src: ^Server_Config) -> Server_Config {
	dst := Server_Config{
		name = strings.clone(src.name),
		transport = src.transport,
		command = strings.clone(src.command),
		cwd = strings.clone(src.cwd),
		url = strings.clone(src.url),
		env = clone_string_map(src.env),
		headers = clone_string_map(src.headers),
		timeout_ms = src.timeout_ms,
		source = strings.clone(src.source),
	}
	args := make([]string, len(src.args))
	for a, i in src.args do args[i] = strings.clone(a)
	dst.args = args
	return dst
}

session_new :: proc(project: string, cfg: ^Server_Config, base_env: map[string]string) -> ^Mcp_Session {
	s := new(Mcp_Session)
	s.project = strings.clone(project)
	s.config = server_clone(cfg)
	s.base_env = clone_string_map(base_env)
	s.fingerprint = server_fingerprint(cfg)
	s.state = .New
	s.rpc_mu = {}
	s.rpc_cond = {}
	s.pending = make(map[int]^Pending, 8)
	s.last_used = time.tick_now()
	return s
}

session_set_state :: proc(s: ^Mcp_Session, state: Session_State, err: string) -> bool {
	sync.mutex_lock(&s.status_mu)
	current := s.state
	// Closed is terminal. Failed may only go to Closed (or stay Failed), so a
	// late pipe write cannot resurrect a failed/closed session as Starting or
	// Ready.
	if current == .Closed && state != .Closed {
		sync.mutex_unlock(&s.status_mu)
		return false
	}
	if current == .Failed && state != .Closed && state != .Failed {
		sync.mutex_unlock(&s.status_mu)
		return false
	}
	if state == .Starting && current != .New {
		sync.mutex_unlock(&s.status_mu)
		return false
	}
	s.state = state
	delete(s.error)
	s.error = strings.clone(err)
	if state == .Failed || state == .Closed do s.failed_at = time.tick_now()
	sync.mutex_unlock(&s.status_mu)
	return true
}

LOG_CAP :: 8192
TOOLS_LIST_BUDGET :: 45 * time.Second
RESOURCE_LIST_BUDGET :: 45 * time.Second
SESSION_INIT_TIMEOUT_MS :: 30_000

session_append_log :: proc(s: ^Mcp_Session, text: string) {
	if len(text) == 0 do return
	sync.mutex_lock(&s.status_mu)
	combined := strings.concatenate({s.logs, text})
	delete(s.logs)
	if len(combined) > LOG_CAP {
		// Keep the tail, but never free an interior pointer. `combined` owns
		// the whole allocation, so clone the tail before releasing it.
		s.logs = strings.clone(combined[len(combined) - LOG_CAP:])
		delete(combined)
	} else {
		s.logs = combined
	}
	sync.mutex_unlock(&s.status_mu)
}

session_stopping :: proc(s: ^Mcp_Session) -> bool {
	sync.mutex_lock(&s.status_mu)
	defer sync.mutex_unlock(&s.status_mu)
	return s.stopping
}

session_wake_pending :: proc(s: ^Mcp_Session, message: string) {
	sync.mutex_lock(&s.rpc_mu)
	for _, p in s.pending {
		if !p.done {
			p.done = true
			p.err = strings.clone(message)
		}
	}
	sync.cond_broadcast(&s.rpc_cond)
	sync.mutex_unlock(&s.rpc_mu)
}

session_fail :: proc(s: ^Mcp_Session, message: string) {
	if !session_set_state(s, .Failed, message) do return
	session_wake_pending(s, message)
}

session_closed :: proc(s: ^Mcp_Session, message: string) {
	if !session_set_state(s, .Closed, message) do return
	session_wake_pending(s, message)
}

session_ready_error :: proc(s: ^Mcp_Session, timed_out: bool) -> string {
	if err := session_error(s); err != "" do return err
	state := session_state(s)
	if state == .Ready do return ""
	if timed_out do return "timed out waiting for MCP session initialization"
	return fmt.aprintf("MCP session is not ready (%s)", state_string(state))
}

session_ensure_ready :: proc(s: ^Mcp_Session) -> string {
	sync.mutex_lock(&s.init_mu)
	if s.initialized {
		sync.mutex_unlock(&s.init_mu)
		return session_error(s)
	}
	if s.initializing {
		deadline := min(s.config.timeout_ms, SESSION_INIT_TIMEOUT_MS) + 15_000
		timed_out := false
		for !s.initialized {
			state := session_state(s)
			if state == .Failed || state == .Closed do break
			if !sync.cond_wait_with_timeout(&s.init_cond, &s.init_mu, 100 * time.Millisecond) {
				deadline -= 100
				if deadline <= 0 {
					timed_out = true
					break
				}
			}
		}
		initialized := s.initialized
		sync.mutex_unlock(&s.init_mu)
		if !initialized && timed_out do return "timed out waiting for MCP session initialization"
		return session_ready_error(s, false)
	}
	s.initializing = true
	sync.mutex_unlock(&s.init_mu)

	serr := session_start(s)
	if serr != "" do session_fail(s, serr)

	sync.mutex_lock(&s.init_mu)
	s.initialized = true
	s.initializing = false
	sync.cond_broadcast(&s.init_cond)
	sync.mutex_unlock(&s.init_mu)
	if serr != "" do return serr
	return session_ready_error(s, false)
}


session_error :: proc(s: ^Mcp_Session) -> string {
	sync.mutex_lock(&s.status_mu)
	defer sync.mutex_unlock(&s.status_mu)
	if s.state == .Failed || s.state == .Closed {
		if len(s.error) > 0 do return strings.clone(s.error)
		return strings.clone(state_string(s.state))
	}
	return ""
}

session_state :: proc(s: ^Mcp_Session) -> Session_State {
	sync.mutex_lock(&s.status_mu)
	defer sync.mutex_unlock(&s.status_mu)
	return s.state
}

session_tools_copy :: proc(s: ^Mcp_Session) -> []Advertised_Tool {
	sync.mutex_lock(&s.status_mu)
	defer sync.mutex_unlock(&s.status_mu)
	out := make([]Advertised_Tool, len(s.tools))
	for t, i in s.tools {
		out[i] = Advertised_Tool{
			server = strings.clone(t.server),
			name = strings.clone(t.name),
			function_name = strings.clone(t.function_name),
			title = strings.clone(t.title),
			description = strings.clone(t.description),
			parameters = json.clone_value(t.parameters),
			kind = t.kind,
		}
	}
	return out
}

session_tool_count :: proc(s: ^Mcp_Session) -> int {
	sync.mutex_lock(&s.status_mu)
	defer sync.mutex_unlock(&s.status_mu)
	return len(s.tools) + (s.supports_resources ? 2 : 0)
}

session_logs :: proc(s: ^Mcp_Session) -> string {
	sync.mutex_lock(&s.status_mu)
	defer sync.mutex_unlock(&s.status_mu)
	return strings.clone(s.logs)
}

session_capture_capabilities :: proc(s: ^Mcp_Session, result: json.Value) {
	ro, ok := jobj(result)
	if !ok do return
	caps, cok := jobj(jget(ro, "capabilities"))
	if !cok do return
	rv := jget(caps, "resources")
	ro_res, rok := jobj(rv)
	sync.mutex_lock(&s.status_mu)
	s.supports_resources = rok
	if rok {
		s.resources_subscribe = jbool(jget(ro_res, "subscribe"))
		s.resources_list_changed = jbool(jget(ro_res, "listChanged"))
	}
	sync.mutex_unlock(&s.status_mu)
}

session_supports_resources :: proc(s: ^Mcp_Session) -> bool {
	sync.mutex_lock(&s.status_mu)
	defer sync.mutex_unlock(&s.status_mu)
	return s.supports_resources
}

// --- stdio transport --------------------------------------------------------

// find_executable_on_env_path resolves a bare command against the PATH in the
// environment that will be passed to the child. Odin's process_start searches
// the *host process* PATH instead, which is stale when the long-lived host was
// started before the bridge's PATH changed (and ignores an env.PATH override).
// Returns "" when a bare command is not found; commands containing a slash are
// left to process_start.
find_executable_on_env_path :: proc(name, working_dir: string, env: []string) -> string {
	path := ""
	has_path := false
	for item in env {
		if strings.has_prefix(item, "PATH=") {
			path = item[len("PATH="):]
			has_path = true
			break
		}
	}
	// execvp falls back to a default path when PATH is absent. An explicitly
	// empty PATH still means one empty entry, i.e. the working directory.
	if !has_path do path = "/usr/local/bin:/usr/bin:/bin"
	base := len(working_dir) > 0 ? working_dir : "."
	dirs := strings.split(path, ":", context.temp_allocator)
	for dir in dirs {
		d := dir
		if len(d) == 0 do d = "."
		candidate: string
		if os.is_absolute_path(d) {
			candidate = join_path(d, name)
		} else {
			rel := join_path(base, d)
			candidate = join_path(rel, name)
			delete(rel)
		}
		if executable_ok(candidate) do return candidate
		delete(candidate)
	}
	return ""
}

session_env :: proc(s: ^Mcp_Session) -> []string {
	merged := make(map[string]string, 32)
	if len(s.base_env) > 0 {
		for k, v in s.base_env do merged[strings.clone(k)] = strings.clone(v)
	} else {
		base, _ := os.environ(context.allocator)
		defer {
			for item in base do delete(item)
			delete(base)
		}
		for item in base {
			eq := strings.index_byte(item, '=')
			if eq <= 0 do continue
			merged[strings.clone(item[:eq])] = strings.clone(item[eq + 1:])
		}
	}
	for k, v in s.config.env {
		if old, ok := merged[k]; ok do delete(old)
		merged[strings.clone(k)] = strings.clone(v)
	}
	out := make([dynamic]string, 0, len(merged))
	for k, v in merged {
		append(&out, fmt.aprintf("%s=%s", k, v))
		delete(k)
		delete(v)
	}
	delete(merged)
	return out[:]
}

free_env_strings :: proc(env: []string) {
	for s in env do delete(s)
	delete(env)
}

// session_close_transport_locked tears down the transport. The caller must
// hold lifecycle_mu. It is used by both normal shutdown and every failed start
// path so a failed session cannot leak pipes, threads, or a child process.
session_close_transport_locked :: proc(s: ^Mcp_Session) {
	switch s.config.transport {
	case .Stdio:
		if s.stdin != nil {
			os.close(s.stdin)
			s.stdin = nil
		}
		if s.process_started {
			_ = os.process_terminate(s.process)
			time.sleep(200 * time.Millisecond)
			_ = os.process_kill(s.process)
			s.process_started = false
		}
		// Close the descriptors but keep the fields valid until the reader
		// threads have observed the close. Nilling them first races a reader
		// that is between `os.read` calls and dereferences a nil file.
		if s.stdout_r != nil do os.close(s.stdout_r)
		if s.stderr_r != nil do os.close(s.stderr_r)
		if s.reader != nil { thread.destroy(s.reader); s.reader = nil }
		if s.stderr_reader != nil { thread.destroy(s.stderr_reader); s.stderr_reader = nil }
		if s.waiter != nil { thread.destroy(s.waiter); s.waiter = nil }
		s.stdout_r = nil
		s.stderr_r = nil
	case .Streamable_HTTP:
		sync.mutex_lock(&s.http_mu)
		has_id := len(s.http_session_id) > 0
		sync.mutex_unlock(&s.http_mu)
		if has_id {
			headers := http_headers(s)
			defer delete(headers)
			res, _, _ := http_request("DELETE", s.config.url, headers, "", 2_000)
			http_result_free(&res)
			sync.mutex_lock(&s.http_mu)
			delete(s.http_session_id)
			s.http_session_id = ""
			sync.mutex_unlock(&s.http_mu)
		}
	case .SSE:
	}
}

session_start :: proc(s: ^Mcp_Session) -> string {
	sync.mutex_lock(&s.lifecycle_mu)
	defer sync.mutex_unlock(&s.lifecycle_mu)
	if session_stopping(s) do return "session is stopping"
	if !session_set_state(s, .Starting, "") {
		return fmt.aprintf("cannot start MCP session from %s", state_string(session_state(s)))
	}
	switch s.config.transport {
	case .Stdio:
		return session_start_stdio(s)
	case .Streamable_HTTP:
		return session_start_http(s)
	case .SSE:
		return "legacy SSE transport is not supported"
	}
	return "unknown transport"
}

session_start_stdio :: proc(s: ^Mcp_Session) -> string {
	if len(s.config.command) == 0 do return "server command is empty"
	if session_stopping(s) do return "session is stopping"

	env := session_env(s)
	defer free_env_strings(env)

	// Resolve bare commands against the child environment's PATH before
	// process_start, which only knows the host process PATH.
	command := s.config.command
	resolved := ""
	defer {
		if len(resolved) > 0 do delete(resolved)
	}
	if !strings.contains(command, "/") {
		resolved = find_executable_on_env_path(command, s.config.cwd, env)
		if len(resolved) == 0 {
			return fmt.aprintf("starting %s: executable not found on PATH", command)
		}
		command = resolved
	}

	stdin_r, stdin_w, stdin_err := os.pipe()
	if stdin_err != nil do return fmt.aprintf("creating stdin pipe: %v", stdin_err)
	stdout_r, stdout_w, stdout_err := os.pipe()
	if stdout_err != nil {
		os.close(stdin_r); os.close(stdin_w)
		return fmt.aprintf("creating stdout pipe: %v", stdout_err)
	}
	stderr_r, stderr_w, stderr_err := os.pipe()
	if stderr_err != nil {
		os.close(stdin_r); os.close(stdin_w)
		os.close(stdout_r); os.close(stdout_w)
		return fmt.aprintf("creating stderr pipe: %v", stderr_err)
	}

	cmd := make([]string, len(s.config.args) + 1)
	cmd[0] = command
	for a, i in s.config.args do cmd[i + 1] = a

	process, perr := os.process_start({
		command = cmd,
		env = env,
		working_dir = s.config.cwd,
		stdin = stdin_r,
		stdout = stdout_w,
		stderr = stderr_w,
	})
	os.close(stdin_r)
	os.close(stdout_w)
	os.close(stderr_w)
	delete(cmd)
	if perr != nil {
		os.close(stdin_w)
		os.close(stdout_r)
		os.close(stderr_r)
		return fmt.aprintf("starting %s: %v", s.config.command, perr)
	}

	s.process = process
	s.process_started = true
	s.stdin = stdin_w
	s.stdout_r = stdout_r
	s.stderr_r = stderr_r
	s.reader = thread.create_and_start_with_poly_data(s, session_stdout_reader)
	s.stderr_reader = thread.create_and_start_with_poly_data(s, session_stderr_reader)
	s.waiter = thread.create_and_start_with_poly_data(s, session_waiter)
	if s.reader == nil || s.stderr_reader == nil || s.waiter == nil {
		session_close_transport_locked(s)
		return "could not start MCP transport threads"
	}
	if session_stopping(s) {
		session_close_transport_locked(s)
		return "session is stopping"
	}

	res, err := session_rpc(s, "initialize", initialize_params(), min(s.config.timeout_ms, SESSION_INIT_TIMEOUT_MS))
	if err != "" {
		session_close_transport_locked(s)
		return err
	}
	ro, ok := jobj(res)
	if ok {
		session_capture_capabilities(s, res)
		if v := jstr(jget(ro, "protocolVersion")); len(v) > 0 {
			sync.mutex_lock(&s.http_mu)
			delete(s.http_protocol_version)
			s.http_protocol_version = strings.clone(v)
			sync.mutex_unlock(&s.http_mu)
		}
	}
	json.destroy_value(res)

	if session_stopping(s) {
		session_close_transport_locked(s)
		return "session is stopping"
	}
	notify := jsonrpc_notification("notifications/initialized", nil)
	defer delete(notify)
	if nerr := session_send_line(s, notify); nerr != "" {
		session_close_transport_locked(s)
		return nerr
	}

	lerr := session_load_tools(s)
	if lerr != "" || session_stopping(s) {
		session_close_transport_locked(s)
		if lerr != "" do return lerr
		return "session is stopping"
	}
	return ""
}

session_stdout_reader :: proc(s: ^Mcp_Session) {
	b := strings.builder_make()
	defer delete(b.buf)
	buf: [8192]u8
	for {
		n, err := os.read(s.stdout_r, buf[:])
		if n > 0 {
			strings.write_bytes(&b, buf[:n])
			session_consume_lines(s, &b)
		}
		if err != nil || n == 0 do break
	}
	session_closed(s, "MCP server closed its stdout")
}

session_stderr_reader :: proc(s: ^Mcp_Session) {
	buf: [4096]u8
	for {
		n, err := os.read(s.stderr_r, buf[:])
		if n > 0 do session_append_log(s, string(buf[:n]))
		if err != nil || n == 0 do break
	}
}

session_waiter :: proc(s: ^Mcp_Session) {
	state, err := os.process_wait(s.process)
	if err != nil do return
	if s.process_started && !state.exited do return
	message := fmt.aprintf("MCP server exited (%d)", state.exit_code)
	session_closed(s, message)
	delete(message)
}

session_consume_lines :: proc(s: ^Mcp_Session, b: ^strings.Builder) {
	text := strings.to_string(b^)
	start := 0
	for {
		nl := strings.index_byte(text[start:], '\n')
		if nl < 0 do break
		line := text[start:start + nl]
		if len(line) > 0 && line[len(line) - 1] == '\r' do line = line[:len(line) - 1]
		start += nl + 1
		if len(strings.trim_space(line)) > 0 do session_handle_line(s, line)
	}
	if start > 0 {
		remaining := strings.clone(text[start:])
		strings.builder_reset(b)
		strings.write_string(b, remaining)
		delete(remaining)
	}
}

session_handle_line :: proc(s: ^Mcp_Session, line: string) {
	msg: Rpc_Incoming
	if err := json.unmarshal_string(line, &msg); err != nil {
		note := fmt.aprintf("invalid JSON from MCP server: %v\n", err)
		session_append_log(s, note)
		delete(note)
		return
	}
	defer {
		json.destroy_value(msg.id)
		json.destroy_value(msg.params)
		json.destroy_value(msg.result)
		json.destroy_value(msg.error.data)
	}
	if len(msg.method) > 0 {
		// A request or notification initiated by the server.  MiAgent does not
		// offer sampling or roots, so answer requests we can and reject the rest.
		if msg.id != nil {
			response := ""
			switch msg.method {
			case "ping":
				empty := make(json.Object)
				response = jsonrpc_result_response(msg.id, empty)
				json.destroy_value(empty)
			case "roots/list":
				o := make(json.Object)
				o[strings.clone("roots")] = make(json.Array, 0, 0)
				response = jsonrpc_result_response(msg.id, o)
				json.destroy_value(o)
			case:
				detail := fmt.aprintf("unsupported method: %s", msg.method)
				response = jsonrpc_error_response(msg.id, -32601, detail)
				delete(detail)
			}
			if len(response) > 0 do _ = session_send_line(s, response)
		}
		return
	}

	id, ok := id_int(msg.id)
	if !ok do return
	sync.mutex_lock(&s.rpc_mu)
	p, found := s.pending[id]
	if found && !p.done {
		p.raw = strings.clone(line)
		p.done = true
		sync.cond_broadcast(&s.rpc_cond)
	}
	sync.mutex_unlock(&s.rpc_mu)
}

session_send_line :: proc(s: ^Mcp_Session, line: string) -> string {
	if s.stdin == nil do return "MCP server stdin is closed"
	payload := strings.concatenate({line, "\n"})
	defer delete(payload)
	sync.mutex_lock(&s.write_mu)
	defer sync.mutex_unlock(&s.write_mu)
	if _, err := os.write(s.stdin, transmute([]byte)payload); err != nil {
		msg := fmt.aprintf("writing to MCP server: %v", err)
		session_fail(s, msg)
		return msg
	}
	return ""
}

next_request_id :: proc(s: ^Mcp_Session) -> int {
	sync.mutex_lock(&s.rpc_mu)
	defer sync.mutex_unlock(&s.rpc_mu)
	s.next_id += 1
	return s.next_id
}

session_rpc :: proc(s: ^Mcp_Session, method: string, params: json.Value, timeout_ms: int) -> (json.Value, string) {
	id := next_request_id(s)
	payload := jsonrpc_request(id, method, params)
	if len(payload) == 0 do return nil, "could not encode MCP request"
	defer delete(payload)

	p := new(Pending)
	sync.mutex_lock(&s.rpc_mu)
	s.pending[id] = p
	sync.mutex_unlock(&s.rpc_mu)

	if serr := session_send_line(s, payload); serr != "" {
		sync.mutex_lock(&s.rpc_mu)
		delete_key(&s.pending, id)
		sync.mutex_unlock(&s.rpc_mu)
		free(p)
		return nil, serr
	}

	deadline := time.Duration(timeout_ms) * time.Millisecond
	start := time.tick_now()
	sync.mutex_lock(&s.rpc_mu)
	for !p.done {
		remaining := deadline - time.tick_since(start)
		if remaining <= 0 {
			if !p.done {
				p.done = true
				p.err = "timed out waiting for MCP server"
			}
			break
		}
		sync.cond_wait_with_timeout(&s.rpc_cond, &s.rpc_mu, min(remaining, 100 * time.Millisecond))
	}
	raw := p.raw
	err := p.err
	delete_key(&s.pending, id)
	sync.mutex_unlock(&s.rpc_mu)
	free(p)

	if len(err) > 0 {
		delete(raw)
		return nil, err
	}
	if len(raw) == 0 do return nil, "MCP server returned no response"
	result, perr := parse_rpc_result(raw)
	delete(raw)
	return result, perr
}

// session_request dispatches an RPC over whichever transport the session uses.
session_request :: proc(s: ^Mcp_Session, method: string, params: json.Value, timeout_ms: int) -> (json.Value, string) {
	if s.config.transport == .Streamable_HTTP do return session_http_rpc(s, method, params, timeout_ms)
	return session_rpc(s, method, params, timeout_ms)
}

parse_rpc_result :: proc(raw: string) -> (json.Value, string) {
	resp: Rpc_Response
	if err := json.unmarshal_string(raw, &resp); err != nil do return nil, fmt.aprintf("decoding MCP response: %v", err)
	if len(resp.error.message) > 0 {
		msg := fmt.aprintf("MCP error %d: %s", resp.error.code, resp.error.message)
		delete(resp.error.message)
		json.destroy_value(resp.error.data)
		json.destroy_value(resp.result)
		return nil, msg
	}
	if resp.result == nil {
		json.destroy_value(resp.error.data)
		return make(json.Object), ""
	}
	result := json.clone_value(resp.result)
	json.destroy_value(resp.result)
	json.destroy_value(resp.error.data)
	return result, ""
}

initialize_params :: proc() -> json.Value {
	o := make(json.Object)
	obj_set(&o, "protocolVersion", str_value(PROTOCOL_VERSION))
	caps := make(json.Object)
	obj_set(&o, "capabilities", caps)
	info := make(json.Object)
	obj_set(&info, "name", str_value(CLIENT_NAME))
	obj_set(&info, "version", str_value(CLIENT_VERSION))
	obj_set(&o, "clientInfo", info)
	return o
}

session_load_tools :: proc(s: ^Mcp_Session) -> string {
	tools := make([dynamic]Advertised_Tool, 0, 16)
	tool_index := make(map[string]int, 16)
	defer {
		for k in tool_index do delete(k)
		delete(tool_index)
	}
	start := time.tick_now()
	cursor := ""
	pages := 0
	abort_reason := ""
	for {
		if session_stopping(s) {
			abort_reason = "session is stopping"
			break
		}
		if time.tick_since(start) > TOOLS_LIST_BUDGET {
			abort_reason = "tools/list exceeded the initialization budget"
			break
		}
		params := make(json.Object)
		if len(cursor) > 0 do obj_set(&params, "cursor", str_value(cursor))
		res, err := session_request(s, "tools/list", params, min(s.config.timeout_ms, SESSION_INIT_TIMEOUT_MS))
		json.destroy_value(params)
		if err != "" {
			// A server without tools is still useful for resources/prompts;
			// tolerate method-not-found and report zero tools.
			if strings.contains(err, "-32601") || strings.contains(strings.to_lower(err), "method not found") {
				break
			}
			session_fail(s, err)
			abort_reason = err
			break
		}
		ro, ok := jobj(res)
		if !ok {
			json.destroy_value(res)
			break
		}
		if arr, aok := jarr(jget(ro, "tools")); aok {
			for raw in arr {
				to, tok := jobj(raw)
				if !tok do continue
				name := jstr(jget(to, "name"))
				if len(name) == 0 do continue
				params_val := jget(to, "inputSchema")
				if params_val == nil do params_val = json.Null(nil)
				description := jstr(jget(to, "description"))
				if len(description) == 0 do description = jstr(jget(to, "title"))
				tool := Advertised_Tool{
					server = strings.clone(s.config.name),
					name = strings.clone(name),
					function_name = function_name(s.config.name, name),
					title = strings.clone(jstr(jget(to, "title"))),
					description = strings.clone(description),
					parameters = json.clone_value(params_val),
				}
				// A paginated server can repeat a tool (and a buggy server can
				// list the same name twice). Keep one entry per server tool;
				// the last definition wins.
				if idx, exists := tool_index[name]; exists {
					advertised_tool_destroy(&tools[idx])
					tools[idx] = tool
				} else {
					tool_index[strings.clone(name)] = len(tools)
					append(&tools, tool)
				}
			}
		}
		// `nextCursor` is a view into `res`; clone it before destroying the
		// JSON value. This was a use-after-free that produced garbage cursors.
		next := strings.clone(jstr(jget(ro, "nextCursor")))
		json.destroy_value(res)
		pages += 1
		if len(next) == 0 || pages >= 100 {
			delete(next)
			break
		}
		delete(cursor)
		cursor = next
	}
	delete(cursor)

	if abort_reason != "" {
		for &t in tools do advertised_tool_destroy(&t)
		delete(tools)
		return abort_reason
	}

	sync.mutex_lock(&s.status_mu)
	if s.stopping || s.state == .Closed || s.state == .Failed {
		sync.mutex_unlock(&s.status_mu)
		for &t in tools do advertised_tool_destroy(&t)
		delete(tools)
		return "session is stopping"
	}
	for &t in s.tools do advertised_tool_destroy(&t)
	delete(s.tools)
	s.tools = tools[:]
	s.state = .Ready
	delete(s.error)
	s.error = ""
	sync.mutex_unlock(&s.status_mu)
	return ""
}

// --- resources --------------------------------------------------------------

session_collect_list :: proc(s: ^Mcp_Session, method, key: string, limit, timeout_ms: int) -> (json.Array, string) {
	out := make(json.Array, 0, 16)
	start := time.tick_now()
	cursor := ""
	pages := 0
	for {
		if session_stopping(s) || time.tick_since(start) > RESOURCE_LIST_BUDGET do break
		params := make(json.Object)
		if len(cursor) > 0 do obj_set(&params, "cursor", str_value(cursor))
		res, err := session_request(s, method, params, timeout_ms)
		json.destroy_value(params)
		if err != "" {
			// Some servers implement one of the two list methods but not the
			// other. Treat method-not-found as an empty list.
			if strings.contains(err, "-32601") || strings.contains(strings.to_lower(err), "method not found") {
				delete(cursor)
				return out, ""
			}
			for v in out do json.destroy_value(v)
			delete(out)
			delete(cursor)
			return nil, err
		}
		ro, ok := jobj(res)
		if !ok {
			json.destroy_value(res)
			break
		}
		if arr, aok := jarr(jget(ro, key)); aok {
			for raw in arr {
				if len(out) >= limit do break
				append(&out, json.clone_value(raw))
			}
		}
		next := strings.clone(jstr(jget(ro, "nextCursor")))
		json.destroy_value(res)
		pages += 1
		if len(next) == 0 || pages >= 50 || len(out) >= limit {
			delete(next)
			break
		}
		delete(cursor)
		cursor = next
	}
	delete(cursor)
	return out, ""
}

session_list_resources :: proc(s: ^Mcp_Session) -> (json.Value, string) {
	resources, err := session_collect_list(s, "resources/list", "resources", 500, s.config.timeout_ms)
	if err != "" do return nil, err
	templates, terr := session_collect_list(s, "resources/templates/list", "resourceTemplates", 200, s.config.timeout_ms)
	if terr != "" {
		// Templates are optional; keep the concrete resources rather than
		// failing the whole list.
		for v in templates do json.destroy_value(v)
		delete(templates)
		delete(terr)
		templates = make(json.Array, 0, 0)
	}
	out := make(json.Object)
	obj_set(&out, "resources", resources)
	obj_set(&out, "resourceTemplates", templates)
	return out, ""
}

session_read_resource :: proc(s: ^Mcp_Session, uri: string) -> (json.Value, string) {
	if len(strings.trim_space(uri)) == 0 do return nil, "resource uri is required"
	params := make(json.Object)
	obj_set(&params, "uri", str_value(uri))
	defer json.destroy_value(params)
	timeout := DEFAULT_CALL_TIMEOUT_MS
	if s.config.timeout_ms > DEFAULT_TIMEOUT_MS do timeout = s.config.timeout_ms
	return session_request(s, "resources/read", params, timeout)
}

// --- streamable HTTP transport ---------------------------------------------

session_start_http :: proc(s: ^Mcp_Session) -> string {
	if len(s.config.url) == 0 do return "server url is empty"
	if session_stopping(s) do return "session is stopping"
	res, err := session_http_rpc(s, "initialize", initialize_params(), min(s.config.timeout_ms, SESSION_INIT_TIMEOUT_MS))
	if err != "" {
		session_close_transport_locked(s)
		return err
	}
	ro, ok := jobj(res)
	if ok {
		session_capture_capabilities(s, res)
		if v := jstr(jget(ro, "protocolVersion")); len(v) > 0 {
			sync.mutex_lock(&s.http_mu)
			delete(s.http_protocol_version)
			s.http_protocol_version = strings.clone(v)
			sync.mutex_unlock(&s.http_mu)
		}
	}
	json.destroy_value(res)
	if session_stopping(s) {
		session_close_transport_locked(s)
		return "session is stopping"
	}

	payload := jsonrpc_notification("notifications/initialized", nil)
	defer delete(payload)
	if nerr := session_http_send(s, payload, s.config.timeout_ms); nerr != "" {
		session_close_transport_locked(s)
		return nerr
	}
	lerr := session_load_tools(s)
	if lerr != "" || session_stopping(s) {
		session_close_transport_locked(s)
		if lerr != "" do return lerr
		return "session is stopping"
	}
	return ""
}

http_headers :: proc(s: ^Mcp_Session) -> string {
	b := strings.builder_make()
	sync.mutex_lock(&s.http_mu)
	defer sync.mutex_unlock(&s.http_mu)
	for k, v in s.config.headers {
		strings.write_string(&b, k)
		strings.write_string(&b, ": ")
		strings.write_string(&b, v)
		strings.write_byte(&b, '\n')
	}
	if len(s.http_session_id) > 0 {
		strings.write_string(&b, "Mcp-Session-Id: ")
		strings.write_string(&b, s.http_session_id)
		strings.write_byte(&b, '\n')
	}
	if len(s.http_protocol_version) > 0 {
		strings.write_string(&b, "MCP-Protocol-Version: ")
		strings.write_string(&b, s.http_protocol_version)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

session_http_send :: proc(s: ^Mcp_Session, payload: string, timeout_ms: int) -> string {
	headers := http_headers(s)
	defer delete(headers)
	res, body, err := http_request("POST", s.config.url, headers, payload, timeout_ms)
	defer http_result_free(&res)
	if err != "" do return fmt.aprintf("HTTP request to MCP server: %s", err)
	if res.status < 200 || res.status >= 300 {
		detail := strings.trim_space(body)
		if len(detail) > 800 do detail = detail[:800]
		return fmt.aprintf("MCP HTTP server returned %d: %s", res.status, detail)
	}
	return ""
}

session_http_rpc :: proc(s: ^Mcp_Session, method: string, params: json.Value, timeout_ms: int) -> (json.Value, string) {
	id := next_request_id(s)
	payload := jsonrpc_request(id, method, params)
	defer delete(payload)
	headers := http_headers(s)
	defer delete(headers)
	res, body, err := http_request("POST", s.config.url, headers, payload, timeout_ms)
	defer http_result_free(&res)
	if err != "" do return nil, fmt.aprintf("HTTP request to MCP server: %s", err)
	if res.status < 200 || res.status >= 300 {
		detail := strings.trim_space(body)
		if len(detail) > 800 do detail = detail[:800]
		return nil, fmt.aprintf("MCP HTTP server returned %d: %s", res.status, detail)
	}
	if len(res.session_id) > 0 && res.session_id[0] != 0 {
		sync.mutex_lock(&s.http_mu)
		delete(s.http_session_id)
		s.http_session_id = strings.clone(cstring_string(res.session_id[:]))
		sync.mutex_unlock(&s.http_mu)
	}

	ctype := strings.to_lower(cstring_string(res.content_type[:]))
	defer delete(ctype)
	if strings.contains(ctype, "text/event-stream") {
		events := sse_data_events(body)
		defer {
			for e in events do delete(e)
			delete(events)
		}
		for event in events {
			resp: Rpc_Response
			if json.unmarshal_string(event, &resp) == nil {
				if rid, ok := id_int(resp.id); ok && rid == id {
					if len(resp.error.message) > 0 {
						msg := fmt.aprintf("MCP error %d: %s", resp.error.code, resp.error.message)
						delete(resp.error.message)
						json.destroy_value(resp.error.data)
						json.destroy_value(resp.result)
						return nil, msg
					}
					result := json.clone_value(resp.result)
					json.destroy_value(resp.error.data)
					json.destroy_value(resp.result)
					return result, ""
				}
				json.destroy_value(resp.error.data)
				json.destroy_value(resp.result)
			}
		}
		return nil, "MCP HTTP server sent no response for the request"
	}

	resp: Rpc_Response
	if uerr := json.unmarshal_string(body, &resp); uerr != nil do return nil, fmt.aprintf("decoding MCP HTTP response: %v", uerr)
	if len(resp.error.message) > 0 {
		msg := fmt.aprintf("MCP error %d: %s", resp.error.code, resp.error.message)
		delete(resp.error.message)
		json.destroy_value(resp.error.data)
		json.destroy_value(resp.result)
		return nil, msg
	}
	result := json.clone_value(resp.result)
	json.destroy_value(resp.error.data)
	json.destroy_value(resp.result)
	if result == nil do result = make(json.Object)
	return result, ""
}

// sse_data_events returns the concatenated data payload of each SSE event.
sse_data_events :: proc(body: string) -> []string {
	out := make([dynamic]string, 0, 4)
	b := strings.builder_make()
	defer delete(b.buf)
	lines := strings.split(body, "\n")
	defer delete(lines)
	flush := proc(out: ^[dynamic]string, b: ^strings.Builder) {
		if strings.builder_len(b^) == 0 do return
		append(out, strings.clone(strings.to_string(b^)))
		strings.builder_reset(b)
	}
	for raw in lines {
		line := raw
		if len(line) > 0 && line[len(line) - 1] == '\r' do line = line[:len(line) - 1]
		if len(line) == 0 {
			flush(&out, &b)
			continue
		}
		if strings.has_prefix(line, "data:") {
			value := line[5:]
			if len(value) > 0 && value[0] == ' ' do value = value[1:]
			if strings.builder_len(b) > 0 do strings.write_byte(&b, '\n')
			strings.write_string(&b, value)
		}
	}
	flush(&out, &b)
	return out[:]
}

// --- calls ------------------------------------------------------------------

session_call_tool :: proc(s: ^Mcp_Session, tool_name, arguments: string) -> (json.Value, string) {
	args: json.Value
	trimmed := strings.trim_space(arguments)
	if len(trimmed) == 0 {
		args = make(json.Object)
	} else {
		v, err := json.parse_string(trimmed)
		if err != nil do return nil, fmt.aprintf("tool arguments are not valid JSON: %v", err)
		if _, ok := jobj(v); !ok {
			json.destroy_value(v)
			return nil, "tool arguments must be a JSON object"
		}
		args = v
	}
	defer json.destroy_value(args)

	params := make(json.Object)
	obj_set(&params, "name", str_value(tool_name))
	obj_set(&params, "arguments", json.clone_value(args))
	defer json.destroy_value(params)

	sync.mutex_lock(&s.status_mu)
	s.last_used = time.tick_now()
	sync.mutex_unlock(&s.status_mu)

	timeout := DEFAULT_CALL_TIMEOUT_MS
	if s.config.timeout_ms > DEFAULT_TIMEOUT_MS do timeout = s.config.timeout_ms
	return session_request(s, "tools/call", params, timeout)
}

session_refresh_tools :: proc(s: ^Mcp_Session) -> string {
	return session_load_tools(s)
}

// --- shutdown ---------------------------------------------------------------

session_retry_allowed :: proc(s: ^Mcp_Session, cooldown: time.Duration) -> bool {
	sync.mutex_lock(&s.status_mu)
	defer sync.mutex_unlock(&s.status_mu)
	if s.state != .Failed && s.state != .Closed do return false
	if s.failed_at._nsec == 0 do return true
	return time.tick_since(s.failed_at) >= cooldown
}

session_shutdown :: proc(s: ^Mcp_Session) {
	sync.mutex_lock(&s.status_mu)
	s.stopping = true
	sync.mutex_unlock(&s.status_mu)
	if session_set_state(s, .Closed, "host shut down") {
		session_wake_pending(s, "host shut down")
	}

	sync.mutex_lock(&s.lifecycle_mu)
	defer sync.mutex_unlock(&s.lifecycle_mu)
	session_close_transport_locked(s)
}
