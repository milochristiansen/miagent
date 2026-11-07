// MCP server configuration discovery and normalization.
//
// MiAgent itself only knows about TGI tools.  The MCP bridge reads the same
// configuration files described in docs/MCP.md and turns every declared MCP
// server into a tool schema that TGI can consume.
package mcp

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

CONFIG_FILE :: "mcp.json"
CONFIG_ENV :: "MIAGENT_MCP_CONFIG"
CONFIG_DIR_ENV :: "MIAGENT_CONFIG_DIR"
STATE_DIR :: ".miagent"

// DEFAULT_TIMEOUT_MS bounds initialize and tools/list.  Calls have their own,
// longer timeout because a tool may legitimately do slow work.
DEFAULT_TIMEOUT_MS :: 30_000
DEFAULT_CALL_TIMEOUT_MS :: 300_000

Transport_Kind :: enum {
	Stdio,
	Streamable_HTTP,
	SSE,
}

Server_Config :: struct {
	name:       string,
	transport:  Transport_Kind,
	command:    string,
	args:       []string,
	env:        map[string]string,
	cwd:        string,
	url:        string,
	headers:    map[string]string,
	timeout_ms: int,
	source:     string,
}

Config_Load :: struct {
	servers:  []Server_Config,
	warnings: string,
	paths:    []string,
}

Server_File :: struct {
	command:   string            `json:"command"`,
	args:      []string          `json:"args"`,
	env:       map[string]string `json:"env"`,
	cwd:       string            `json:"cwd"`,
	url:       string            `json:"url"`,
	headers:   map[string]string `json:"headers"`,
	transport: string            `json:"transport"`,
	kind:      string            `json:"type"`,
	timeout:   int               `json:"timeout"`,
	timeoutMs: int               `json:"timeoutMs"`,
	disabled:  bool              `json:"disabled"`,
}

Config_File :: struct {
	mcpServers: map[string]Server_File `json:"mcpServers"`,
	servers:    map[string]Server_File `json:"servers"`,
}

join_path :: proc(parts: ..string) -> string {
	b := strings.builder_make()
	for p, i in parts {
		if i > 0 && len(p) > 0 {
			last := strings.to_string(b)
			if len(last) > 0 && last[len(last) - 1] != '/' do strings.write_byte(&b, '/')
		}
		strings.write_string(&b, p)
	}
	return strings.to_string(b)
}

home_dir :: proc() -> string {
	home, err := os.user_home_dir(context.temp_allocator)
	if err != nil do return "."
	return home
}

// config_dir_path mirrors harness.config_dir_path without importing the
// harness package (the host and bridge must stay independent of the UI).
config_dir_path :: proc() -> string {
	if dir, found := os.lookup_env(CONFIG_DIR_ENV, context.temp_allocator); found && len(dir) > 0 {
		return strings.clone(dir)
	}
	base, ok := os.lookup_env("XDG_CONFIG_HOME", context.temp_allocator)
	if !ok || len(base) == 0 || base[0] != '/' {
		base = join_path(home_dir(), ".config")
	}
	return join_path(base, "miagent")
}

abs_path :: proc(path, base: string) -> string {
	if len(path) == 0 do return ""
	if os.is_absolute_path(path) do return strings.clone(path)
	return join_path(base, path)
}

server_destroy :: proc(s: ^Server_Config) {
	delete(s.name)
	delete(s.command)
	for a in s.args do delete(a)
	delete(s.args)
	for k, v in s.env {
		delete(k)
		delete(v)
	}
	delete(s.env)
	delete(s.cwd)
	delete(s.url)
	for k, v in s.headers {
		delete(k)
		delete(v)
	}
	delete(s.headers)
	delete(s.source)
	s^ = {}
}

servers_destroy :: proc(servers: ^[]Server_Config) {
	for &s in servers^ do server_destroy(&s)
	delete(servers^)
	servers^ = nil
}

config_load_destroy :: proc(l: ^Config_Load) {
	servers_destroy(&l.servers)
	delete(l.warnings)
	for p in l.paths do delete(p)
	delete(l.paths)
	l^ = {}
}

clone_string_map :: proc(src: map[string]string) -> map[string]string {
	if src == nil do return nil
	dst := make(map[string]string, len(src))
	for k, v in src do dst[strings.clone(k)] = strings.clone(v)
	return dst
}

// config_paths returns the files that may contribute servers, in precedence
// order.  MIAGENT_MCP_CONFIG may name one or more files, separated by ':'.
config_paths :: proc(project_dir, config_dir: string) -> []string {
	out := make([dynamic]string, 0, 4)
	if raw, ok := os.lookup_env(CONFIG_ENV, context.temp_allocator); ok && len(strings.trim_space(raw)) > 0 {
		pieces := strings.split(raw, ":", context.temp_allocator)
		for piece in pieces {
			p := strings.trim_space(piece)
			if len(p) == 0 do continue
			append(&out, abs_path(p, project_dir))
		}
	} else {
		append(&out, join_path(config_dir, CONFIG_FILE))
		append(&out, join_path(project_dir, STATE_DIR, CONFIG_FILE))
	}
	return out[:]
}

// config_files_present is the cheap check used by the harness and UI to decide
// whether the bridge is relevant.  It intentionally does not parse the files.
config_files_present :: proc(project_dir, config_dir: string) -> bool {
	paths := config_paths(project_dir, config_dir)
	defer {
		for p in paths do delete(p)
		delete(paths)
	}
	for p in paths do if os.exists(p) do return true
	return false
}

normalize_transport :: proc(s: ^Server_File) -> (Transport_Kind, string) {
	raw := s.transport
	if len(strings.trim_space(raw)) == 0 do raw = s.kind
	t := strings.to_lower(strings.trim_space(raw))
	switch t {
	case "":
		if len(strings.trim_space(s.url)) > 0 && len(strings.trim_space(s.command)) == 0 do return .Streamable_HTTP, ""
		if len(strings.trim_space(s.command)) > 0 && len(strings.trim_space(s.url)) == 0 do return .Stdio, ""
		return .Stdio, "must set exactly one of command or url"
	case "stdio":
		if len(strings.trim_space(s.command)) == 0 do return .Stdio, "stdio transport requires command"
		return .Stdio, ""
	case "http", "streamable-http", "streamable_http", "streamable":
		if len(strings.trim_space(s.url)) == 0 do return .Streamable_HTTP, "http transport requires url"
		return .Streamable_HTTP, ""
	case "sse":
		if len(strings.trim_space(s.url)) == 0 do return .SSE, "sse transport requires url"
		return .SSE, ""
	case:
		return .Stdio, fmt.aprintf("unknown transport %q", s.transport)
	}
}

read_config_file :: proc(path: string, project_dir: string, servers: ^map[string]Server_Config, warnings: ^string) {
	if !os.exists(path) do return
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		warnings^ = append_note(warnings^, fmt.aprintf("%s: %v", path, err))
		return
	}
	defer delete(data)

	cf: Config_File
	if uerr := json.unmarshal_string(string(data), &cf); uerr != nil {
		warnings^ = append_note(warnings^, fmt.aprintf("%s: %v", path, uerr))
		return
	}
	raw := cf.mcpServers
	if len(raw) == 0 do raw = cf.servers
	for name, &s in raw {
		if s.disabled do continue
		if len(strings.trim_space(name)) == 0 {
			warnings^ = append_note(warnings^, fmt.aprintf("%s: server with empty name", path))
			continue
		}
		transport, terr := normalize_transport(&s)
		if len(terr) > 0 {
			warnings^ = append_note(warnings^, fmt.aprintf("%s: server %q: %s", path, name, terr))
			continue
		}
		if transport == .SSE {
			warnings^ = append_note(warnings^, fmt.aprintf("%s: server %q: legacy SSE transport is not supported yet; use a streamable HTTP endpoint", path, name))
			continue
		}

		cfg := Server_Config{
			name = strings.clone(name),
			transport = transport,
			command = strings.clone(strings.trim_space(s.command)),
			cwd = abs_path(s.cwd, project_dir),
			url = strings.clone(strings.trim_space(s.url)),
			env = clone_string_map(s.env),
			headers = clone_string_map(s.headers),
			timeout_ms = DEFAULT_TIMEOUT_MS,
			source = strings.clone(path),
		}
		if len(cfg.cwd) == 0 do cfg.cwd = strings.clone(project_dir)
		if s.timeoutMs > 0 do cfg.timeout_ms = s.timeoutMs
		else if s.timeout > 0 do cfg.timeout_ms = s.timeout * 1000
		if cfg.timeout_ms < 1000 do cfg.timeout_ms = 1000
		if cfg.timeout_ms > 3_600_000 do cfg.timeout_ms = 3_600_000

		args := make([]string, len(s.args))
		for a, i in s.args do args[i] = strings.clone(a)
		cfg.args = args

		if old, ok := servers^[name]; ok do server_destroy(&old)
		servers^[strings.clone(name)] = cfg
	}
}

append_note :: proc(a, b: string) -> string {
	if len(a) == 0 do return strings.clone(b)
	if len(b) == 0 do return a
	return fmt.aprintf("%s\n%s", a, b)
}

// load_servers reads every configured file.  Project-local files are loaded
// after the installation file, so a project can override or add a server.
load_servers :: proc(project_dir, config_dir: string) -> Config_Load {
	load := Config_Load{}
	paths := config_paths(project_dir, config_dir)
	load.paths = paths

	by_name := make(map[string]Server_Config, 8)
	defer delete(by_name)
	for path in paths {
		read_config_file(path, project_dir, &by_name, &load.warnings)
	}

	out := make([dynamic]Server_Config, 0, len(by_name))
	// Deterministic order: server name ascending.
	names := make([dynamic]string, 0, len(by_name))
	for name in by_name do append(&names, name)
	for i in 1 ..< len(names) {
		j := i
		for j > 0 && names[j] < names[j - 1] {
			names[j], names[j - 1] = names[j - 1], names[j]
			j -= 1
		}
	}
	for name in names {
		s := by_name[name]
		delete(name)
		append(&out, s)
	}
	delete(names)
	load.servers = out[:]
	return load
}

sanitize_function_part :: proc(s: string, max_len: int) -> string {
	b := strings.builder_make()
	n := 0
	for ch in s {
		if n >= max_len do break
		ok := ch == '_' || ch == '-' || (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')
		if ok {
			strings.write_rune(&b, ch)
		} else {
			strings.write_byte(&b, '_')
		}
		n += 1
	}
	if n == 0 do return "tool"
	return strings.to_string(b)
}

fnv1a :: proc(s: string) -> u32 {
	h: u32 = 2166136261
	for ch in s {
		h ~= u32(ch)
		h *= 16777619
	}
	return h
}

// function_name builds a model-safe function name from an MCP server and tool.
// The mcp__ prefix is also what the desktop status card looks for when it
// decides whether the bridge is in use.
FUNCTION_PREFIX :: "mcp__"

function_name :: proc(server, tool: string) -> string {
	s := sanitize_function_part(server, 24)
	t := sanitize_function_part(tool, 40)
	name := fmt.aprintf("%s%s__%s", FUNCTION_PREFIX, s, t)
	if len(name) <= 64 do return name
	h := fnv1a(name)
	return fmt.aprintf("%s%s__%.*s_%08x", FUNCTION_PREFIX, s, 12, t, h)
}

// expand_env_refs substitutes $NAME and ${NAME} from the process environment.
// The bridge calls this with the TGI tool environment (which already contains
// the project's dotenv values), so config headers and env values can refer to
// secrets without embedding them.
expand_env_refs :: proc(s: string) -> string {
	if !strings.contains(s, "$") do return strings.clone(s)
	b := strings.builder_make()
	i := 0
	for i < len(s) {
		if s[i] != '$' || i + 1 >= len(s) {
			strings.write_byte(&b, s[i])
			i += 1
			continue
		}
		if s[i + 1] == '{' {
			close := strings.index_byte(s[i + 2:], '}')
			if close >= 0 {
				name := s[i + 2:i + 2 + close]
				if v, ok := os.lookup_env(name, context.temp_allocator); ok {
					strings.write_string(&b, v)
					i += close + 3
					continue
				}
			}
		} else if is_ident_start(s[i + 1]) {
			j := i + 1
			for j < len(s) && is_ident_char(s[j]) do j += 1
			name := s[i + 1:j]
			if v, ok := os.lookup_env(name, context.temp_allocator); ok {
				strings.write_string(&b, v)
				i = j
				continue
			}
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	return strings.to_string(b)
}

is_ident_start :: proc(c: u8) -> bool {
	return c == '_' || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
}
is_ident_char :: proc(c: u8) -> bool {
	return is_ident_start(c) || (c >= '0' && c <= '9')
}

replace_owned :: proc(dst: ^string, value: string) {
	delete(dst^)
	dst^ = value
}

// expand_server_config resolves environment references in the fields that are
// commonly configured from dotenv files. env map values are expanded too.
expand_server_config :: proc(s: ^Server_Config) {
	replace_owned(&s.command, expand_env_refs(s.command))
	replace_owned(&s.cwd, expand_env_refs(s.cwd))
	replace_owned(&s.url, expand_env_refs(s.url))
	for i in 0 ..< len(s.args) do replace_owned(&s.args[i], expand_env_refs(s.args[i]))
	for k, v in s.env {
		out := expand_env_refs(v)
		delete(v)
		s.env[k] = out
	}
	for k, v in s.headers {
		out := expand_env_refs(v)
		delete(v)
		s.headers[k] = out
	}
}

// server_fingerprint gives the host a stable way to notice a changed config
// without depending on map iteration order.
server_fingerprint :: proc(s: ^Server_Config) -> string {
	b := strings.builder_make()
	fmt.sbprintf(&b, "%s\n%d\n%s\n%s\n%s\n%d\n", s.name, int(s.transport), s.command, s.url, s.cwd, s.timeout_ms)
	for a in s.args do fmt.sbprintf(&b, "a:%s\n", a)
	keys := make([dynamic]string, 0, len(s.env))
	for k in s.env do append(&keys, k)
	for i in 1 ..< len(keys) {
		j := i
		for j > 0 && keys[j] < keys[j - 1] {
			keys[j], keys[j - 1] = keys[j - 1], keys[j]
			j -= 1
		}
	}
	for k in keys do fmt.sbprintf(&b, "e:%s=%s\n", k, s.env[k])
	clear(&keys)
	for k in s.headers do append(&keys, k)
	for i in 1 ..< len(keys) {
		j := i
		for j > 0 && keys[j] < keys[j - 1] {
			keys[j], keys[j - 1] = keys[j - 1], keys[j]
			j -= 1
		}
	}
	for k in keys do fmt.sbprintf(&b, "h:%s=%s\n", k, s.headers[k])
	delete(keys)
	return strings.to_string(b)
}

// find_server returns the normalized config for a name.
find_server :: proc(servers: []Server_Config, name: string) -> ^Server_Config {
	for &s in servers do if s.name == name do return &s
	return nil
}

// parse_timeout_env is used by the host for its own idle shutdown.
parse_int_env :: proc(key: string, fallback: int) -> int {
	if v, ok := os.lookup_env(key, context.temp_allocator); ok {
		if n, parsed := strconv.parse_int(strings.trim_space(v)); parsed && n >= 0 do return n
	}
	return fallback
}
