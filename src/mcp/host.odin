// The background MCP host.  One host per user/runtime directory keeps every
// configured MCP server alive across MiAgent/GUI restarts and serves requests
// over the small JSON-lines IPC in ipc.odin.
package mcp

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

HOST_IDLE_ENV :: "MIAGENT_MCP_HOST_IDLE_SECONDS"
DEFAULT_IDLE_SECONDS :: 24 * 60 * 60
SESSION_RESTART_COOLDOWN :: 2 * time.Second
HOST_SESSION_BUDGET :: 60 * time.Second

RESOURCE_LIST_TOOL_NAME :: "resources_list"
RESOURCE_READ_TOOL_NAME :: "resources_read"
MAX_RESOURCE_LIST_ENTRIES :: 200
MAX_RESOURCE_TEXT_BYTES :: 256 * 1024
MAX_RESOURCE_TOTAL_TEXT :: 1024 * 1024
MAX_RESOURCE_IMAGE_B64 :: 48 << 20

Wire_Server :: struct {
	name:       string            `json:"name"`,
	transport:  string            `json:"transport"`,
	command:    string            `json:"command"`,
	args:       []string          `json:"args"`,
	env:        map[string]string `json:"env"`,
	cwd:        string            `json:"cwd"`,
	url:        string            `json:"url"`,
	headers:    map[string]string `json:"headers"`,
	timeout_ms: int               `json:"timeout_ms"`,
}

Discover_Params :: struct {
	project: string            `json:"project"`,
	servers: []Wire_Server     `json:"servers"`,
	env:     map[string]string `json:"env"`,
}

Call_Params :: struct {
	project:   string            `json:"project"`,
	servers:   []Wire_Server     `json:"servers"`,
	env:       map[string]string `json:"env"`,
	name:      string            `json:"name"`,
	arguments: string            `json:"arguments"`,
}

Status_Params :: struct {
	project: string `json:"project"`,
}

wire_server_destroy :: proc(w: ^Wire_Server) {
	delete(w.name)
	delete(w.transport)
	delete(w.command)
	for a in w.args do delete(a)
	delete(w.args)
	for k, v in w.env {
		delete(k)
		delete(v)
	}
	delete(w.env)
	delete(w.cwd)
	delete(w.url)
	for k, v in w.headers {
		delete(k)
		delete(v)
	}
	delete(w.headers)
	w^ = {}
}

free_string_map :: proc(m: ^map[string]string) {
	for k, v in m^ {
		delete(k)
		delete(v)
	}
	delete(m^)
	m^ = nil
}

discover_params_destroy :: proc(p: ^Discover_Params) {
	delete(p.project)
	for &s in p.servers do wire_server_destroy(&s)
	delete(p.servers)
	free_string_map(&p.env)
	p^ = {}
}

call_params_destroy :: proc(p: ^Call_Params) {
	delete(p.project)
	for &s in p.servers do wire_server_destroy(&s)
	delete(p.servers)
	free_string_map(&p.env)
	delete(p.name)
	delete(p.arguments)
	p^ = {}
}

status_params_destroy :: proc(p: ^Status_Params) {
	delete(p.project)
	p^ = {}
}

decode_params :: proc(params: json.Value, dst: ^$T) -> string {
	if params == nil do return ""
	data, err := json.marshal(params)
	if err != nil do return fmt.aprintf("decoding params: %v", err)
	defer delete(data)
	if uerr := json.unmarshal(data, dst); uerr != nil do return fmt.aprintf("decoding params: %v", uerr)
	return ""
}

server_to_wire :: proc(s: ^Server_Config) -> Wire_Server {
	w := Wire_Server{
		name = strings.clone(s.name),
		transport = strings.clone(transport_string(s.transport)),
		command = strings.clone(s.command),
		cwd = strings.clone(s.cwd),
		url = strings.clone(s.url),
		env = clone_string_map(s.env),
		headers = clone_string_map(s.headers),
		timeout_ms = s.timeout_ms,
	}
	args := make([]string, len(s.args))
	for a, i in s.args do args[i] = strings.clone(a)
	w.args = args
	return w
}

wire_to_server :: proc(w: ^Wire_Server, project: string) -> (Server_Config, string) {
	cfg := Server_Config{
		name = strings.clone(w.name),
		command = strings.clone(strings.trim_space(w.command)),
		cwd = strings.clone(strings.trim_space(w.cwd)),
		url = strings.clone(strings.trim_space(w.url)),
		env = clone_string_map(w.env),
		headers = clone_string_map(w.headers),
		timeout_ms = w.timeout_ms,
		source = strings.clone("ipc"),
	}
	if len(cfg.name) == 0 {
		server_destroy(&cfg)
		return {}, strings.clone("server name is empty")
	}
	switch strings.to_lower(w.transport) {
	case "", "stdio": cfg.transport = .Stdio
	case "http", "streamable-http", "streamable_http": cfg.transport = .Streamable_HTTP
	case "sse": cfg.transport = .SSE
	case:
		server_destroy(&cfg)
		return {}, fmt.aprintf("server %q has unknown transport %q", w.name, w.transport)
	}
	if cfg.transport == .Stdio && len(cfg.command) == 0 {
		server_destroy(&cfg)
		return {}, fmt.aprintf("server %q has no command", w.name)
	}
	if cfg.transport != .Stdio && len(cfg.url) == 0 {
		server_destroy(&cfg)
		return {}, fmt.aprintf("server %q has no url", w.name)
	}
	if len(cfg.cwd) == 0 do cfg.cwd = strings.clone(project)
	else if !os.is_absolute_path(cfg.cwd) {
		old := cfg.cwd
		cfg.cwd = join_path(project, cfg.cwd)
		delete(old)
	}
	if cfg.timeout_ms <= 0 do cfg.timeout_ms = DEFAULT_TIMEOUT_MS
	args := make([]string, len(w.args))
	for a, i in w.args do args[i] = strings.clone(a)
	cfg.args = args
	return cfg, ""
}

Host :: struct {
	sessions: map[string]^Mcp_Session,
	all:      [dynamic]^Mcp_Session,
	mu:       sync.Mutex,
	// Serializes session creation/replacement so two callers cannot race on
	// the same server key.
	session_mu: sync.Mutex,

	clients:    int,
	clients_mu: sync.Mutex,

	start_tick:    time.Tick,
	last_activity: time.Tick,
	activity_mu:   sync.Mutex,

	listener: net.TCP_Socket,
	stop:     bool,
	stop_mu:  sync.Mutex,
	token:    string,
}

session_key :: proc(project, name: string) -> string {
	return fmt.aprintf("%d:%s%s", len(project), project, name)
}

// host_remove_endpoint removes only the endpoint file owned by this host.
// A stale host that exits later must not delete a newer host's endpoint.
host_remove_endpoint :: proc(h: ^Host) {
	ep, ok, _ := read_endpoint()
	if !ok do return
	defer endpoint_destroy(&ep)
	if ep.pid != os.get_pid() do return
	if len(h.token) > 0 && ep.token != h.token do return
	remove_endpoint()
}

host_is_stopping :: proc(h: ^Host) -> bool {
	sync.mutex_lock(&h.mu)
	defer sync.mutex_unlock(&h.mu)
	return h.stop
}

host_all_remove_locked :: proc(h: ^Host, session: ^Mcp_Session) {
	for existing, i in h.all {
		if existing == session {
			ordered_remove(&h.all, i)
			return
		}
	}
}

host_get_session :: proc(h: ^Host, project: string, cfg: ^Server_Config, base_env: map[string]string) -> ^Mcp_Session {
	sync.mutex_lock(&h.session_mu)
	defer sync.mutex_unlock(&h.session_mu)

	key := session_key(project, cfg.name)
	fp := server_fingerprint(cfg)

	sync.mutex_lock(&h.mu)
	if h.stop {
		sync.mutex_unlock(&h.mu)
		delete(fp)
		delete(key)
		return nil
	}
	existing := h.sessions[key]
	sync.mutex_unlock(&h.mu)

	if existing != nil && existing.fingerprint == fp {
		state := session_state(existing)
		if state != .Failed && state != .Closed {
			delete(fp)
			delete(key)
			return existing
		}
		// A failed/closed server may be restarted, but not in a tight loop.
		if !session_retry_allowed(existing, SESSION_RESTART_COOLDOWN) {
			delete(fp)
			delete(key)
			return existing
		}
	}

	if existing != nil {
		// Never leave a replaced process running invisibly in h.all.
		session_shutdown(existing)
		sync.mutex_lock(&h.mu)
		host_all_remove_locked(h, existing)
		sync.mutex_unlock(&h.mu)
	}

	s := session_new(project, cfg, base_env)
	sync.mutex_lock(&h.mu)
	if h.stop {
		sync.mutex_unlock(&h.mu)
		delete(fp)
		delete(key)
		session_shutdown(s)
		return nil
	}
	// The map owns the key string; do not free it here.
	h.sessions[key] = s
	append(&h.all, s)
	sync.mutex_unlock(&h.mu)
	delete(fp)
	return s
}

host_shutdown_all :: proc(h: ^Host) {
	sync.mutex_lock(&h.mu)
	// Set stopping and snapshot in the same critical section that
	// host_get_session uses to append. A session created after this point sees
	// stop and refuses to start, so host exit cannot orphan a child.
	h.stop = true
	sessions := make([]^Mcp_Session, len(h.all))
	copy(sessions, h.all[:])
	sync.mutex_unlock(&h.mu)
	for s in sessions do session_shutdown(s)
	delete(sessions)
}

host_touch :: proc(h: ^Host) {
	sync.mutex_lock(&h.activity_mu)
	h.last_activity = time.tick_now()
	sync.mutex_unlock(&h.activity_mu)
}

host_client_count :: proc(h: ^Host) -> int {
	sync.mutex_lock(&h.clients_mu)
	defer sync.mutex_unlock(&h.clients_mu)
	return h.clients
}

// --- results ----------------------------------------------------------------

tool_to_json :: proc(t: ^Advertised_Tool) -> json.Value {
	o := make(json.Object)
	obj_set(&o, "server", str_value(t.server))
	obj_set(&o, "name", str_value(t.name))
	obj_set(&o, "function_name", str_value(t.function_name))
	if len(t.title) > 0 do obj_set(&o, "title", str_value(t.title))
	if len(t.description) > 0 do obj_set(&o, "description", str_value(t.description))
	param := t.parameters
	if param == nil do param = json.Null(nil)
	obj_set(&o, "parameters", json.clone_value(param))
	return o
}

server_status_json :: proc(s: ^Mcp_Session) -> json.Value {
	o := make(json.Object)
	obj_set(&o, "project", str_value(s.project))
	obj_set(&o, "name", str_value(s.config.name))
	obj_set(&o, "transport", str_value(transport_string(s.config.transport)))
	sync.mutex_lock(&s.status_mu)
	obj_set(&o, "state", str_value(state_string(s.state)))
	err := s.error
	if len(err) > 2000 do err = err[:2000]
	obj_set(&o, "error", str_value(err))
	logs := s.logs
	if len(logs) > 4000 do logs = logs[len(logs) - 4000:]
	obj_set(&o, "log_tail", str_value(logs))
	obj_set(&o, "resources", bool_value(s.supports_resources))
	obj_set(&o, "tool_count", int_value(len(s.tools) + (s.supports_resources ? 2 : 0)))
	sync.mutex_unlock(&s.status_mu)
	return o
}

empty_parameters_schema :: proc() -> json.Value {
	o := make(json.Object)
	obj_set(&o, "type", str_value("object"))
	obj_set(&o, "properties", make(json.Object))
	return o
}

resource_read_schema :: proc() -> json.Value {
	o := make(json.Object)
	obj_set(&o, "type", str_value("object"))
	props := make(json.Object)
	uri := make(json.Object)
	obj_set(&uri, "type", str_value("string"))
	obj_set(&uri, "description", str_value("Absolute resource URI, exactly as returned by resources_list or a resource template."))
	props[strings.clone("uri")] = uri
	obj_set(&o, "properties", props)
	required := make(json.Array, 0, 1)
	append(&required, str_value("uri"))
	obj_set(&o, "required", required)
	return o
}

append_resource_tools :: proc(all: ^[dynamic]Advertised_Tool, s: ^Mcp_Session) {
	server := s.config.name
	list_desc := fmt.aprintf(
		"List MCP resources and resource templates exposed by server %q. Call this before %s when you do not already have a resource URI.",
		server, RESOURCE_READ_TOOL_NAME)
	append(all, Advertised_Tool{
		server = strings.clone(server),
		name = strings.clone(RESOURCE_LIST_TOOL_NAME),
		function_name = function_name(server, RESOURCE_LIST_TOOL_NAME),
		title = strings.clone("List MCP resources"),
		description = list_desc,
		parameters = empty_parameters_schema(),
		kind = .Resources_List,
	})
	read_desc := fmt.aprintf(
		"Read one MCP resource by its URI from server %q. The URI may come from %s, a resource template, a tool result, or the user. Text is returned directly; image resources are attached to the tool result.",
		server, RESOURCE_LIST_TOOL_NAME)
	append(all, Advertised_Tool{
		server = strings.clone(server),
		name = strings.clone(RESOURCE_READ_TOOL_NAME),
		function_name = function_name(server, RESOURCE_READ_TOOL_NAME),
		title = strings.clone("Read MCP resource"),
		description = read_desc,
		parameters = resource_read_schema(),
		kind = .Resources_Read,
	})
}

clamp_function_name :: proc(name: string) -> string {
	if len(name) <= 64 do return name
	out := strings.clone(name[:64])
	delete(name)
	return out
}

// Tool_Projection is the deterministic function-name projection shared by
// discovery and invocation.  Colliding sanitized names get a stable hash
// suffix, so a model call always resolves to the same server tool.
Tool_Projection :: struct {
	tools:   []Advertised_Tool,
	by_name: map[string]int,
}

projection_destroy :: proc(p: ^Tool_Projection) {
	advertised_tools_destroy(&p.tools)
	for k in p.by_name do delete(k)
	delete(p.by_name)
	p^ = {}
}

project_tools :: proc(h: ^Host, project: string, servers: []Server_Config) -> (Tool_Projection, []json.Value, string) {
	_ = h
	all := make([dynamic]Advertised_Tool, 0, 16)
	statuses := make([dynamic]json.Value, 0, len(servers))
	for &cfg in servers {
		key := session_key(project, cfg.name)
		sync.mutex_lock(&h.mu)
		session, ok := h.sessions[key]
		sync.mutex_unlock(&h.mu)
		delete(key)
		if !ok {
			o := make(json.Object)
			obj_set(&o, "project", str_value(project))
			obj_set(&o, "name", str_value(cfg.name))
			obj_set(&o, "transport", str_value(transport_string(cfg.transport)))
			obj_set(&o, "state", str_value("missing"))
			obj_set(&o, "error", str_value("server was not started"))
			obj_set(&o, "tool_count", int_value(0))
			append(&statuses, o)
			continue
		}
		err := session_ensure_ready(session)
		append(&statuses, server_status_json(session))
		if err != "" do continue
		tools := session_tools_copy(session)
		for &t in tools do append(&all, t)
		delete(tools)
		if session_supports_resources(session) do append_resource_tools(&all, session)
	}

	// Collapse duplicate (server, tool) entries before assigning function
	// names. A paginated or buggy server can repeat a tool; that is the same
	// tool, not a name collision. Keep the last definition.
	deduped := make([dynamic]Advertised_Tool, 0, len(all))
	tool_index := make(map[string]int, len(all))
	defer {
		for k in tool_index do delete(k)
		delete(tool_index)
	}
	for &t in all {
		key := fmt.aprintf("%s\x00%s", t.server, t.name)
		if idx, exists := tool_index[key]; exists {
			advertised_tool_destroy(&deduped[idx])
			deduped[idx] = t
			delete(key)
		} else {
			tool_index[key] = len(deduped)
			append(&deduped, t)
		}
	}
	delete(all)
	all = deduped

	// Stable sort by server then tool before assigning collision suffixes.
	for i in 1 ..< len(all) {
		j := i
		for j > 0 {
			a := &all[j - 1]
			b := &all[j]
			if a.server < b.server || (a.server == b.server && a.name <= b.name) do break
			all[j - 1], all[j] = all[j], all[j - 1]
			j -= 1
		}
	}
	seen := make(map[string]bool, len(all))
	for &t in all {
		n := t.function_name
		if _, exists := seen[n]; exists {
			h := fnv1a(fmt.aprintf("%s\x00%s", t.server, t.name))
			base := strings.clone(t.function_name)
			if len(base) > 54 {
				trimmed := strings.clone(base[:54])
				delete(base)
				base = trimmed
			}
			delete(t.function_name)
			t.function_name = clamp_function_name(fmt.aprintf("%s_%08x", base, h))
			for k in 0 ..< 100 {
				if !seen[t.function_name] do break
				delete(t.function_name)
				t.function_name = clamp_function_name(fmt.aprintf("%s_%08x_%d", base, h, k))
			}
			delete(base)
		}
		seen[strings.clone(t.function_name)] = true
	}
	for k in seen do delete(k)
	delete(seen)

	by_name := make(map[string]int, len(all))
	for &t, i in all do by_name[strings.clone(t.function_name)] = i
	return Tool_Projection{tools = all[:], by_name = by_name}, statuses[:], ""
}

ensure_sessions :: proc(
	h: ^Host,
	project: string,
	servers: []Server_Config,
	base_env: map[string]string,
	budget: time.Duration = 0,
) -> ([]^Mcp_Session, string) {
	out := make([]^Mcp_Session, len(servers))
	start := time.tick_now()
	for &cfg, i in servers {
		if host_is_stopping(h) {
			delete(out)
			return nil, "host is shutting down"
		}
		// Bound discovery even when several servers are slow to initialize.
		// A single ensure_ready call is already capped by
		// SESSION_INIT_TIMEOUT_MS; this prevents N slow servers from
		// multiplying that budget.
		if budget > 0 && time.tick_since(start) > budget {
			delete(out)
			return nil, "MCP discovery deadline exceeded"
		}
		out[i] = host_get_session(h, project, &cfg, base_env)
		if out[i] == nil {
			delete(out)
			return nil, "host is shutting down"
		}
		if err := session_ensure_ready(out[i]); err != "" {
			// A single failed server must not hide the healthy ones.
			continue
		}
	}
	return out, ""
}

host_handle_discover :: proc(h: ^Host, params: json.Value) -> (json.Value, string) {
	p: Discover_Params
	if err := decode_params(params, &p); err != "" do return nil, err
	defer discover_params_destroy(&p)
	if len(p.project) == 0 do return nil, "project is required"

	servers := make([dynamic]Server_Config, 0, len(p.servers))
	var_err := ""
	for &w in p.servers {
		cfg, err := wire_to_server(&w, p.project)
		if err != "" {
			var_err = append_note(var_err, err)
			delete(err)
			continue
		}
		append(&servers, cfg)
	}
	defer {
		for &cfg in servers do server_destroy(&cfg)
		delete(servers)
	}
	sessions, serr := ensure_sessions(h, p.project, servers[:], p.env, HOST_SESSION_BUDGET)
	defer delete(sessions)
	if serr != "" do return nil, serr
	proj, statuses, _ := project_tools(h, p.project, servers[:])
	defer projection_destroy(&proj)
	defer {
		for st in statuses do json.destroy_value(st)
		delete(statuses)
	}

	out := make(json.Object)
	tools := make(json.Array, 0, len(proj.tools))
	for &t in proj.tools do append(&tools, tool_to_json(&t))
	obj_set(&out, "tools", tools)
	st := make(json.Array, 0, len(statuses))
	for v in statuses do append(&st, json.clone_value(v))
	obj_set(&out, "servers", st)
	if len(var_err) > 0 do obj_set(&out, "warning", str_value(var_err))
	delete(var_err)
	return out, ""
}

tool_result_from_content :: proc(content: json.Array) -> json.Value {
	o := make(json.Object)
	obj_set(&o, "content", content)
	obj_set(&o, "isError", bool_value(false))
	return o
}

tool_result_text :: proc(text: string) -> json.Value {
	content := make(json.Array, 0, 1)
	part := make(json.Object)
	obj_set(&part, "type", str_value("text"))
	obj_set(&part, "text", str_value(text))
	append(&content, part)
	return tool_result_from_content(content)
}

append_text_content :: proc(content: ^json.Array, text: string) {
	part := make(json.Object)
	obj_set(&part, "type", str_value("text"))
	obj_set(&part, "text", str_value(text))
	append(content, part)
	// append stores the Object value; the temporary map must not be freed as
	// a separate owner.
}

resource_list_text :: proc(s: ^Mcp_Session, result: json.Value) -> string {
	ro, _ := jobj(result)
	resources, _ := jarr(jget(ro, "resources"))
	templates, _ := jarr(jget(ro, "resourceTemplates"))
	b := strings.builder_make()
	fmt.sbprintf(&b, "MCP resources from server %q:\n", s.config.name)
	shown := 0
	for raw in resources {
		if shown >= MAX_RESOURCE_LIST_ENTRIES {
			fmt.sbprintf(&b, "\n... resource list truncated at %d entries\n", MAX_RESOURCE_LIST_ENTRIES)
			break
		}
		o, ok := jobj(raw)
		if !ok do continue
		uri := jstr(jget(o, "uri"))
		if len(uri) == 0 do continue
		fmt.sbprintf(&b, "\n- %s\n", uri)
		if v := jstr(jget(o, "name")); len(v) > 0 do fmt.sbprintf(&b, "  name: %s\n", v)
		if v := jstr(jget(o, "title")); len(v) > 0 do fmt.sbprintf(&b, "  title: %s\n", v)
		if v := jstr(jget(o, "mimeType")); len(v) > 0 do fmt.sbprintf(&b, "  type: %s\n", v)
		if v := jint(jget(o, "size")); v > 0 do fmt.sbprintf(&b, "  size: %d bytes\n", v)
		if v := jstr(jget(o, "description")); len(v) > 0 {
			if len(v) > 500 do v = v[:500]
			fmt.sbprintf(&b, "  description: %s\n", v)
		}
		shown += 1
	}
	if len(templates) > 0 {
		fmt.sbprintf(&b, "\nResource templates:\n")
		tcount := 0
		for raw in templates {
			if tcount >= MAX_RESOURCE_LIST_ENTRIES {
				fmt.sbprintf(&b, "\n... template list truncated at %d entries\n", MAX_RESOURCE_LIST_ENTRIES)
				break
			}
			o, ok := jobj(raw)
			if !ok do continue
			tmpl := jstr(jget(o, "uriTemplate"))
			if len(tmpl) == 0 do continue
			fmt.sbprintf(&b, "\n- %s\n", tmpl)
			if v := jstr(jget(o, "name")); len(v) > 0 do fmt.sbprintf(&b, "  name: %s\n", v)
			if v := jstr(jget(o, "mimeType")); len(v) > 0 do fmt.sbprintf(&b, "  type: %s\n", v)
			if v := jstr(jget(o, "description")); len(v) > 0 {
				if len(v) > 500 do v = v[:500]
				fmt.sbprintf(&b, "  description: %s\n", v)
			}
			tcount += 1
		}
	}
	if shown == 0 && len(templates) == 0 {
		fmt.sbprintf(&b, "No resources or resource templates are currently listed.\n")
	}
	return strings.to_string(b)
}

text_mime :: proc(mime: string) -> bool {
	m := strings.to_lower(mime)
	if strings.has_prefix(m, "text/") do return true
	if strings.has_prefix(m, "application/") {
		suffixes := [6]string{"json", "xml", "yaml", "toml", "javascript", "x-ndjson"}
		for suffix in suffixes {
			if strings.contains(m, suffix) do return true
		}
	}
	if strings.has_suffix(m, "+json") || strings.has_suffix(m, "+xml") do return true
	return false
}

resource_read_result :: proc(s: ^Mcp_Session, uri: string, result: json.Value) -> json.Value {
	ro, _ := jobj(result)
	contents, _ := jarr(jget(ro, "contents"))
	content := make(json.Array, 0, len(contents) + 1)
	budget := MAX_RESOURCE_TOTAL_TEXT
	omitted := 0
	for raw in contents {
		o, ok := jobj(raw)
		if !ok do continue
		part_uri := jstr(jget(o, "uri"))
		if len(part_uri) == 0 do part_uri = uri
		mime := jstr(jget(o, "mimeType"))
		if len(mime) == 0 do mime = "text/plain"

		if text := jstr(jget(o, "text")); len(text) > 0 || jget(o, "text") != nil {
			allowed := text
			truncated := false
			if len(allowed) > budget {
				allowed = allowed[:max(budget, 0)]
				truncated = true
			}
			header := fmt.aprintf("--- %s (%s) ---\n", part_uri, mime)
			body := strings.concatenate({header, allowed})
			if truncated do body = strings.concatenate({body, "\n[resource text truncated]\n"})
			append_text_content(&content, body)
			budget -= len(body)
			if len(header) > 0 do delete(header)
			delete(body)
			continue
		}

		blob := jstr(jget(o, "blob"))
		if len(blob) > 0 {
			lower := strings.to_lower(mime)
			if strings.has_prefix(lower, "image/") {
				if len(blob) <= MAX_RESOURCE_IMAGE_B64 {
					header := fmt.aprintf("--- %s (%s) ---\n", part_uri, mime)
					append_text_content(&content, header)
					delete(header)
					image := make(json.Object)
					obj_set(&image, "type", str_value("image"))
					obj_set(&image, "data", str_value(blob))
					obj_set(&image, "mimeType", str_value(mime))
					append(&content, image)
				} else {
					note := fmt.aprintf("--- %s (%s) ---\n[image resource omitted: %d bytes of base64 exceeds the limit]\n", part_uri, mime, len(blob))
					append_text_content(&content, note)
					delete(note)
				}
				continue
			}
			if text_mime(mime) {
				estimated := len(blob) * 3 / 4
				if estimated > budget || estimated > MAX_RESOURCE_TEXT_BYTES {
					note := fmt.aprintf("--- %s (%s) ---\n[text resource omitted: approximately %d bytes exceeds the limit]\n", part_uri, mime, estimated)
					append_text_content(&content, note)
					delete(note)
				} else if decoded, derr := base64.decode(blob); derr != nil {
					note := fmt.aprintf("--- %s (%s) ---\n[resource blob could not be decoded]\n", part_uri, mime)
					append_text_content(&content, note)
					delete(note)
				} else {
					header := fmt.aprintf("--- %s (%s) ---\n", part_uri, mime)
					body := strings.concatenate({header, string(decoded)})
					append_text_content(&content, body)
					budget -= len(body)
					delete(header)
					delete(body)
					delete(decoded)
				}
				continue
			}
			note := fmt.aprintf("--- %s (%s) ---\n[binary resource omitted: %d bytes of base64]\n", part_uri, mime, len(blob))
			append_text_content(&content, note)
			delete(note)
			continue
		}
		omitted += 1
	}

	if len(content) == 0 {
		text := fmt.aprintf("Resource %s returned no readable contents.", uri)
		out := tool_result_text(text)
		delete(text)
		return out
	}
	if omitted > 0 {
		note := fmt.aprintf("[%d resource content part(s) had neither text nor blob data]\n", omitted)
		append_text_content(&content, note)
		delete(note)
	}
	return tool_result_from_content(content)
}

resource_uri_from_arguments :: proc(arguments: string) -> (string, string) {
	trimmed := strings.trim_space(arguments)
	if len(trimmed) == 0 do return "", strings.clone("resources_read requires {\"uri\": \"...\"}")
	v, err := json.parse_string(trimmed)
	if err != nil do return "", fmt.aprintf("resource arguments are not valid JSON: %v", err)
	defer json.destroy_value(v)
	o, ok := jobj(v)
	if !ok do return "", strings.clone("resource arguments must be a JSON object")
	uri := strings.trim_space(jstr(jget(o, "uri")))
	if len(uri) == 0 do return "", strings.clone("resource uri is missing or empty")
	return strings.clone(uri), ""
}

host_handle_call :: proc(h: ^Host, params: json.Value) -> (json.Value, string) {
	p: Call_Params
	if err := decode_params(params, &p); err != "" do return nil, err
	defer call_params_destroy(&p)
	if len(p.project) == 0 do return nil, "project is required"
	if len(p.name) == 0 do return nil, "tool name is required"

	servers := make([dynamic]Server_Config, 0, len(p.servers))
	for &w in p.servers {
		cfg, err := wire_to_server(&w, p.project)
		if err != "" {
			delete(err)
			continue
		}
		append(&servers, cfg)
	}
	defer {
		for &cfg in servers do server_destroy(&cfg)
		delete(servers)
	}
	sessions, serr := ensure_sessions(h, p.project, servers[:], p.env, HOST_SESSION_BUDGET)
	defer delete(sessions)
	if serr != "" do return nil, serr

	proj, statuses, _ := project_tools(h, p.project, servers[:])
	for st in statuses do json.destroy_value(st)
	delete(statuses)
	defer projection_destroy(&proj)

	idx, found := proj.by_name[p.name]
	if !found {
		// The server may have added a tool since discovery.  Refresh once.
		for s in sessions {
			if s != nil && session_state(s) == .Ready do _ = session_refresh_tools(s)
		}
		proj2, statuses2, _ := project_tools(h, p.project, servers[:])
		for st in statuses2 do json.destroy_value(st)
		delete(statuses2)
		projection_destroy(&proj)
		proj = proj2
		idx, found = proj.by_name[p.name]
	}
	if !found do return nil, fmt.aprintf("unknown MCP tool: %s", p.name)
	tool := &proj.tools[idx]
	key := session_key(p.project, tool.server)
	sync.mutex_lock(&h.mu)
	session := h.sessions[key]
	sync.mutex_unlock(&h.mu)
	delete(key)
	if session == nil do return nil, fmt.aprintf("MCP server %q is not running", tool.server)
	if err := session_ensure_ready(session); err != "" do return nil, err

	switch tool.kind {
	case .Resources_List:
		result, err := session_list_resources(session)
		if err != "" do return nil, err
		defer json.destroy_value(result)
		text := resource_list_text(session, result)
		out := tool_result_text(text)
		delete(text)
		return out, ""
	case .Resources_Read:
		uri, uerr := resource_uri_from_arguments(p.arguments)
		if uerr != "" do return nil, uerr
		defer delete(uri)
		result, err := session_read_resource(session, uri)
		if err != "" do return nil, err
		defer json.destroy_value(result)
		return resource_read_result(session, uri, result), ""
	case .Mcp_Tool:
		return session_call_tool(session, tool.name, p.arguments)
	}
	return nil, "unknown tool kind"
}

host_handle_status :: proc(h: ^Host, params: json.Value) -> (json.Value, string) {
	p: Status_Params
	if err := decode_params(params, &p); err != "" do return nil, err
	defer status_params_destroy(&p)

	out := make(json.Object)
	obj_set(&out, "pid", int_value(os.get_pid()))
	obj_set(&out, "uptime_seconds", int_value(int(time.duration_seconds(time.tick_since(h.start_tick)))))
	obj_set(&out, "clients", int_value(host_client_count(h)))
	servers := make(json.Array, 0, len(h.all))
	tool_count := 0
	sync.mutex_lock(&h.mu)
	current := make([dynamic]^Mcp_Session, 0, len(h.sessions))
	for _, s in h.sessions do append(&current, s)
	sync.mutex_unlock(&h.mu)
	for s in current {
		if len(p.project) > 0 && s.project != p.project do continue
		append(&servers, server_status_json(s))
		tool_count += session_tool_count(s)
	}
	delete(current)
	obj_set(&out, "servers", servers)
	obj_set(&out, "tool_count", int_value(tool_count))
	return out, ""
}

host_handle :: proc(h: ^Host, req: Ipc_Request) -> (json.Value, string) {
	switch req.method {
	case "host.ping":
		o := make(json.Object)
		obj_set(&o, "pong", bool_value(true))
		obj_set(&o, "version", int_value(HOST_VERSION))
		return o, ""
	case "host.status":
		return host_handle_status(h, req.params)
	case "mcp.discover":
		return host_handle_discover(h, req.params)
	case "mcp.call":
		return host_handle_call(h, req.params)
	case "host.shutdown":
		return make(json.Object), ""
	}
	return nil, fmt.aprintf("unknown method: %s", req.method)
}

// --- server loop ------------------------------------------------------------

send_response :: proc(sock: net.TCP_Socket, resp: Ipc_Response) -> bool {
	data, err := json.marshal(resp)
	if err != nil do return false
	defer delete(data)
	buf := make([]u8, len(data) + 1, context.temp_allocator)
	copy(buf, data)
	buf[len(data)] = '\n'
	_, serr := net.send_tcp(sock, buf)
	return serr == nil
}

host_client :: proc(h: ^Host, sock: net.TCP_Socket) {
	defer net.close(sock)
	defer {
		sync.mutex_lock(&h.clients_mu)
		h.clients -= 1
		sync.mutex_unlock(&h.clients_mu)
	}

	b := strings.builder_make()
	defer delete(b.buf)
	buf: [8192]u8
	for {
		n, err := net.recv_tcp(sock, buf[:])
		if n > 0 {
			strings.write_bytes(&b, buf[:n])
			if strings.contains(strings.to_string(b), "\n") do break
			if strings.builder_len(b) > 64 << 20 do return
		}
		if err != nil || n == 0 do return
	}
	text := strings.to_string(b)
	nl := strings.index_byte(text, '\n')
	if nl >= 0 do text = text[:nl]
	if len(strings.trim_space(text)) == 0 do return

	req: Ipc_Request
	if err := json.unmarshal_string(text, &req); err != nil do return
	defer {
		delete(req.method)
		delete(req.token)
		json.destroy_value(req.params)
	}
	ep, ok, _ := read_endpoint()
	if !ok || req.token != ep.token {
		if ok do endpoint_destroy(&ep)
		_ = send_response(sock, Ipc_Response{id = req.id, ok = false, error = "unauthorized"})
		return
	}
	defer endpoint_destroy(&ep)

	host_touch(h)
	result, err := host_handle(h, req)
	response := Ipc_Response{id = req.id, ok = len(err) == 0}
	if len(err) > 0 {
		response.error = err
	} else {
		response.result = result
	}
	sent := send_response(sock, response)
	if result != nil do json.destroy_value(result)

	if req.method == "host.shutdown" && sent {
		// Let the kernel deliver the response, then stop the children and the
		// daemon.  Exiting here also wakes the blocked accept loop.
		time.sleep(100 * time.Millisecond)
		host_shutdown_all(h)
		host_remove_endpoint(h)
		os.exit(0)
	}
}

host_listen :: proc(h: ^Host) -> (net.TCP_Socket, string) {
	sock, err := net.listen_tcp(net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = 0}, 128)
	if err != nil do return 0, fmt.aprintf("listening: %v", err)
	return sock, ""
}

host_run :: proc() -> int {
	// Refuse to start a second daemon for the same runtime directory.
	if host_ping(200) {
		fmt.eprintln("miagent-mcp-host: already running")
		return 0
	}
	if err := ensure_runtime_dir(); err != "" {
		fmt.eprintln("miagent-mcp-host:", err)
		return 1
	}

	h := new(Host)
	h.start_tick = time.tick_now()
	h.last_activity = h.start_tick
	h.sessions = make(map[string]^Mcp_Session, 8)
	h.all = make([dynamic]^Mcp_Session, 0, 8)

	sock, lerr := host_listen(h)
	if lerr != "" {
		fmt.eprintln("miagent-mcp-host:", lerr)
		return 1
	}
	h.listener = sock
	watch_signals(i32(sock))
	bound, berr := net.bound_endpoint(sock)
	if berr != nil {
		fmt.eprintln("miagent-mcp-host: resolving port:", berr)
		net.close(sock)
		return 1
	}
	token := random_token(24)
	if len(token) == 0 {
		fmt.eprintln("miagent-mcp-host: could not generate a token")
		net.close(sock)
		return 1
	}
	h.token = strings.clone(token)
	ep := Endpoint{
		version = HOST_VERSION,
		pid = os.get_pid(),
		port = bound.port,
		token = token,
		started_at = i64(time.to_unix_nanoseconds(time.now()) / 1_000_000_000),
	}
	if err := write_endpoint(ep); err != "" {
		fmt.eprintln("miagent-mcp-host:", err)
		net.close(sock)
		return 1
	}
	fmt.printfln("miagent-mcp-host: listening on 127.0.0.1:%d (pid %d)", ep.port, ep.pid)

	idle_seconds := parse_int_env(HOST_IDLE_ENV, DEFAULT_IDLE_SECONDS)
	if idle_seconds > 0 {
		thread.create_and_start_with_poly_data2(h, idle_seconds, host_idle_watchdog, nil, .Normal, true)
	}

	for {
		client, _, aerr := net.accept_tcp(sock)
		if aerr != nil {
			if h.stop || shutdown_requested() do break
			// A transient accept failure should not kill the daemon.
			time.sleep(50 * time.Millisecond)
			continue
		}
		sync.mutex_lock(&h.clients_mu)
		h.clients += 1
		sync.mutex_unlock(&h.clients_mu)
		host_touch(h)
		thread.create_and_start_with_poly_data2(h, client, host_client, nil, .Normal, true)
	}
	host_shutdown_all(h)
	host_remove_endpoint(h)
	net.close(sock)
	return 0
}

host_idle_watchdog :: proc(h: ^Host, idle_seconds: int) {
	for {
		time.sleep(15 * time.Second)
		sync.mutex_lock(&h.activity_mu)
		idle := time.tick_since(h.last_activity)
		sync.mutex_unlock(&h.activity_mu)
		if host_client_count(h) == 0 && idle >= time.Duration(idle_seconds) * time.Second {
			fmt.eprintln("miagent-mcp-host: idle timeout, shutting down")
			host_shutdown_all(h)
			host_remove_endpoint(h)
			os.exit(0)
		}
	}
}
