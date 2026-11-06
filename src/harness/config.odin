// Configuration for a harness run: the same directory, dotenv files, prompts,
// environment variables, and session path the MiAgent CLI uses. A GUI may load
// several of these at once, one per project, so dotenv values are kept in a
// per-Config map instead of being written into the process environment.
package harness

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

CONFIG_DIR_ENV :: "MIAGENT_CONFIG_DIR"
SESSION_ENV :: "MIAGENT_SESSION"
STATE_DIR :: ".miagent"
PROMPTS_DIR :: "prompts"
TOOLS_DIR :: "tools"
AGENTS_FILE :: "AGENTS.md"

Config :: struct {
	project_dir: string,
	config_dir:  string,
	state_dir:   string,
	session_path: string,

	// env holds dotenv values only. Exported process variables are looked up
	// first, then this map, which gives the CLI's precedence: process
	// environment > project .env > installation .env.
	env: map[string]string,

	api_key:          string,
	base_url:         string,
	model:            string,
	reasoning_effort: string,

	instructions: string,

	context_limit:    int,
	context_headroom: int,
	tool_call_size:   int,

	// setup_error is a non-fatal problem found while loading configuration.
	// The GUI shows it as a note and keeps running.
	setup_error: string,
}

config_destroy :: proc(c: ^Config) {
	delete(c.project_dir)
	delete(c.config_dir)
	delete(c.state_dir)
	delete(c.session_path)
	delete(c.api_key)
	delete(c.base_url)
	delete(c.model)
	delete(c.reasoning_effort)
	delete(c.instructions)
	delete(c.setup_error)
	for key, value in c.env {
		delete(key)
		delete(value)
	}
	delete(c.env)
	c^ = {}
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

getenv :: proc(key: string) -> (string, bool) {
	v, found := os.lookup_env(key, context.temp_allocator)
	return v, found
}

home_dir :: proc() -> string {
	home, err := os.user_home_dir(context.temp_allocator)
	if err != nil do return strings.clone(".")
	return strings.clone(home)
}

// lookup_env gives the exported process environment priority over dotenv
// values, then consults this Config's files. The returned string is owned by
// either the process environment or the config, so callers clone when storing.
lookup_env :: proc(c: ^Config, key: string) -> (string, bool) {
	if v, ok := getenv(key); ok do return v, true
	if v, ok := c.env[key]; ok do return v, true
	return "", false
}

config_env_or :: proc(c: ^Config, key, fallback: string) -> string {
	if v, ok := lookup_env(c, key); ok && len(v) > 0 do return strings.clone(v)
	return strings.clone(fallback)
}

env_set_if_absent :: proc(env: ^map[string]string, key, value: string) {
	if _, exists := env^[key]; exists do return
	env^[strings.clone(key)] = strings.clone(value)
}

env_value :: proc(env: ^map[string]string, key: string) -> (string, bool) {
	if v, ok := getenv(key); ok do return v, true
	if v, ok := env^[key]; ok do return v, true
	return "", false
}

// expand_env_vars substitutes $NAME and ${NAME} from the process environment
// or, failing that, from earlier entries in the dotenv file being parsed.
expand_env_vars :: proc(s: string, env: ^map[string]string) -> string {
	if !strings.contains(s, "$") do return s
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
				if v, ok := env_value(env, name); ok {
					strings.write_string(&b, v)
					i += close + 3
					continue
				}
			}
		} else if is_env_ident_start(s[i + 1]) {
			j := i + 1
			for j < len(s) && is_env_ident_char(s[j]) do j += 1
			name := s[i + 1:j]
			if v, ok := env_value(env, name); ok {
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

is_env_ident_start :: proc(c: u8) -> bool {
	return c == '_' || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
}

is_env_ident_char :: proc(c: u8) -> bool {
	return is_env_ident_start(c) || (c >= '0' && c <= '9')
}

// load_dotenv_into adds KEY=VALUE pairs from a dotenv file to env, leaving
// keys that are already present alone. A missing file is fine; malformed
// syntax is reported by name. It never mutates the process environment.
load_dotenv_into :: proc(path: string, env: ^map[string]string) -> string {
	if !os.exists(path) do return ""
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return fmt.aprintf("reading %s: %v", path, err)
	defer delete(data)

	line_no := 0
	lines := strings.split(string(data), "\n")
	defer delete(lines)
	for raw in lines {
		line_no += 1
		line := strings.trim_space(raw)
		if len(line) == 0 || line[0] == '#' do continue
		if strings.has_prefix(line, "export ") do line = strings.trim_space(line[7:])
		eq := strings.index_byte(line, '=')
		if eq <= 0 do return fmt.aprintf("%s:%d: expected KEY=VALUE", path, line_no)
		key := strings.trim_space(line[:eq])
		value := strings.trim_space(line[eq + 1:])
		if !valid_env_name(key) do return fmt.aprintf("%s:%d: invalid key %q", path, line_no, key)
		single_quoted := false
		if len(value) >= 2 {
			if (value[0] == '"' && value[len(value) - 1] == '"') || (value[0] == '\'' && value[len(value) - 1] == '\'') {
				quote := value[0]
				value = value[1:len(value) - 1]
				if quote == '"' {
					value = unescape_double_quoted(value)
				} else {
					single_quoted = true
				}
			} else if i := strings.index(value, " #"); i >= 0 {
				value = strings.trim_space(value[:i])
			}
		}
		if !single_quoted do value = expand_env_vars(value, env)
		env_set_if_absent(env, key, value)
	}
	return ""
}

valid_env_name :: proc(s: string) -> bool {
	if len(s) == 0 do return false
	for ch, i in s {
		ok := ch == '_' || (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || (i > 0 && ch >= '0' && ch <= '9')
		if !ok do return false
	}
	return true
}

unescape_double_quoted :: proc(s: string) -> string {
	if !strings.contains(s, "\\") do return s
	b := strings.builder_make()
	i := 0
	for i < len(s) {
		if s[i] == '\\' && i + 1 < len(s) {
			switch s[i + 1] {
			case 'n': strings.write_byte(&b, '\n')
			case 'r': strings.write_byte(&b, '\r')
			case 't': strings.write_byte(&b, '\t')
			case '"': strings.write_byte(&b, '"')
			case '\\': strings.write_byte(&b, '\\')
			case: strings.write_byte(&b, s[i + 1])
			}
			i += 2
		} else {
			strings.write_byte(&b, s[i])
			i += 1
		}
	}
	return strings.to_string(b)
}

parse_nonneg_env :: proc(c: ^Config, key: string, fallback: int) -> (int, string) {
	v, ok := lookup_env(c, key)
	if !ok || len(strings.trim_space(v)) == 0 do return fallback, ""
	n, parsed_ok := strconv.parse_int(strings.trim_space(v))
	if !parsed_ok || n < 0 do return 0, fmt.aprintf("%s must be a non-negative integer (got %q)", key, v)
	return n, ""
}

parse_positive_env :: proc(c: ^Config, key: string, fallback: int) -> (int, string) {
	v, ok := lookup_env(c, key)
	if !ok || len(strings.trim_space(v)) == 0 do return fallback, ""
	n, parsed_ok := strconv.parse_int(strings.trim_space(v))
	if !parsed_ok || n <= 0 do return 0, fmt.aprintf("%s must be a positive integer (got %q)", key, v)
	return n, ""
}

// config_dir_path resolves the installation configuration directory without
// loading any dotenv file: MIAGENT_CONFIG_DIR when set, otherwise
// $XDG_CONFIG_HOME/miagent or ~/.config/miagent. The GUI uses it for its own
// gui.json, which lives beside the agent's .env.
config_dir_path :: proc() -> string {
	if dir, found := getenv(CONFIG_DIR_ENV); found && len(dir) > 0 {
		return strings.clone(dir)
	}
	base, xdg_ok := getenv("XDG_CONFIG_HOME")
	if !xdg_ok || len(base) == 0 || base[0] != '/' {
		base = join_path(home_dir(), ".config")
	}
	return join_path(base, "miagent")
}

// config_load loads configuration for the process's current directory.
config_load :: proc() -> Config {
	project_dir, err := os.get_working_directory(context.allocator)
	if err != nil || len(project_dir) == 0 {
		delete(project_dir)
		return config_load_for(".")
	}
	cfg := config_load_for(project_dir)
	delete(project_dir)
	return cfg
}

// config_load_for loads a project's .env, then the installation .env. The
// project directory is also the working directory for tools and the base for
// relative session paths.
config_load_for :: proc(project_dir: string) -> Config {
	c := Config{}
	c.env = make(map[string]string, 32)

	abs, abs_err := filepath.abs(project_dir, context.allocator)
	if abs_err != nil {
		c.project_dir = strings.clone(project_dir)
		c.setup_error = join_notes(c.setup_error, fmt.aprintf("resolving project %s: %v", project_dir, abs_err))
	} else {
		c.project_dir = abs
	}
	c.state_dir = join_path(c.project_dir, STATE_DIR)

	local_env := join_path(c.state_dir, ".env")
	defer delete(local_env)
	if err := load_dotenv_into(local_env, &c.env); err != "" {
		c.setup_error = join_notes(c.setup_error, err)
	}

	// A project's local .env may point at a different installation, exactly
	// as it can for the CLI. The process environment still wins.
	if v, ok := lookup_env(&c, CONFIG_DIR_ENV); ok && len(v) > 0 {
		if os.is_absolute_path(v) {
			c.config_dir = strings.clone(v)
		} else {
			c.config_dir = join_path(c.project_dir, v)
		}
	} else {
		c.config_dir = config_dir_path()
		env_set_if_absent(&c.env, CONFIG_DIR_ENV, c.config_dir)
	}

	global_env := join_path(c.config_dir, ".env")
	defer delete(global_env)
	if err := load_dotenv_into(global_env, &c.env); err != "" {
		c.setup_error = join_notes(c.setup_error, err)
	}

	c.api_key = config_env_or(&c, "OPENAI_API_KEY", "")
	c.base_url = config_env_or(&c, "OPENAI_BASE_URL", "")
	c.model = config_env_or(&c, "OPENAI_MODEL", "")
	c.reasoning_effort = strings.to_lower(strings.trim_space(config_env_or(&c, "OPENAI_REASONING_EFFORT", "")))

	if v, ok := lookup_env(&c, SESSION_ENV); ok && len(v) > 0 {
		if os.is_absolute_path(v) {
			c.session_path = strings.clone(v)
		} else {
			c.session_path = join_path(c.project_dir, v)
		}
	} else {
		c.session_path = join_path(c.state_dir, "session.jsonl")
		os.make_directory_all(c.state_dir)
	}

	value: int
	err: string
	value, err = parse_positive_env(&c, "MIAGENT_CONTEXT_LIMIT", 0)
	if err != "" do c.setup_error = join_notes(c.setup_error, err)
	c.context_limit = value
	value, err = parse_nonneg_env(&c, "MIAGENT_CONTEXT_HEADROOM", 10)
	if err != "" do c.setup_error = join_notes(c.setup_error, err)
	c.context_headroom = value
	value, err = parse_nonneg_env(&c, "MIAGENT_TOOLCALL_SIZE", 10)
	if err != "" do c.setup_error = join_notes(c.setup_error, err)
	c.tool_call_size = value

	instructions, instr_err := load_instructions(c.config_dir, c.project_dir, c.state_dir)
	if instr_err != "" {
		c.setup_error = join_notes(c.setup_error, instr_err)
	}
	c.instructions = instructions

	return c
}

join_notes :: proc(a, b: string) -> string {
	if len(a) == 0 do return strings.clone(b)
	if len(b) == 0 do return a
	return fmt.aprintf("%s\n%s", a, b)
}

read_prompt :: proc(path: string, required: bool) -> (string, string) {
	if !os.exists(path) {
		if required do return "", fmt.aprintf("missing prompt %s", path)
		return "", ""
	}
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return "", fmt.aprintf("reading %s: %v", path, err)
	defer delete(data)
	text := strings.trim_space(string(data))
	if required && len(text) == 0 do return "", fmt.aprintf("%s is empty", path)
	return strings.clone(text), ""
}

// load_instructions builds the request instructions: SYSTEM.md followed by
// optional AGENTS.md files from the project and its state directory.
load_instructions :: proc(config_dir, project_dir, state_dir: string) -> (string, string) {
	system_path := join_path(config_dir, PROMPTS_DIR, "SYSTEM.md")
	system, err := read_prompt(system_path, true)
	if err != "" do return "", err

	agents := strings.builder_make()
	project_agents := join_path(project_dir, AGENTS_FILE)
	state_agents := join_path(state_dir, AGENTS_FILE)
	defer delete(project_agents)
	defer delete(state_agents)
	paths := [2]string{project_agents, state_agents}
	for path in paths {
		text, perr := read_prompt(path, false)
		if perr != "" do return "", perr
		if len(text) > 0 {
			if strings.builder_len(agents) > 0 do strings.write_string(&agents, "\n\n")
			strings.write_string(&agents, text)
		}
		delete(text)
	}
	agent_text := strings.to_string(agents)
	if len(agent_text) == 0 do return system, ""
	return fmt.aprintf("%s\n\n%s", system, agent_text), ""
}
