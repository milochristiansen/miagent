// miagent-mcp: the MiAgent side of the bridge.
//
// In TGI mode (TGI_METHOD is set by the harness) this deliberately looks like
// an ordinary TGI tool: SCHEMA prints one JSON tool definition per line, and
// INVOKE reads the model's arguments on stdin.  Behind that facade it talks to
// the long-lived background host, which owns the actual MCP sessions.
package main

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "../mcp"

MAX_STDIN :: 32 << 20

EXIT_OK :: 0
EXIT_TOOL_ERROR :: 1
EXIT_USAGE :: 2
EXIT_BRIDGE_ERROR :: 3

read_stdin_all :: proc(limit: int) -> (string, string) {
	b := strings.builder_make()
	buf: [8192]u8
	for {
		n, err := os.read(os.stdin, buf[:])
		if n > 0 {
			strings.write_bytes(&b, buf[:n])
			if strings.builder_len(b) > limit do return "", "standard input is too large"
		}
		if err != nil || n == 0 do break
	}
	return strings.to_string(b), ""
}

project_dir :: proc() -> string {
	cwd, err := os.get_working_directory(context.allocator)
	if err != nil || len(cwd) == 0 {
		delete(cwd)
		return strings.clone(".")
	}
	return cwd
}

current_env_map :: proc() -> map[string]string {
	env := make(map[string]string, 64)
	base, _ := os.environ(context.allocator)
	defer {
		for item in base do delete(item)
		delete(base)
	}
	for item in base {
		eq := strings.index_byte(item, '=')
		if eq <= 0 do continue
		key := item[:eq]
		// TGI_METHOD/TGI_TOOL/TGI_ATTACHMENT_DIR differ between discovery and every
		// invocation. They are transport details, not project configuration,
		// and must not become part of the long-lived session identity.
		if strings.has_prefix(key, "TGI_") do continue
		env[strings.clone(key)] = strings.clone(item[eq + 1:])
	}
	return env
}

free_env_map :: proc(env: ^map[string]string) {
	for k, v in env^ {
		delete(k)
		delete(v)
	}
	delete(env^)
	env^ = nil
}

env_map_json :: proc(env: map[string]string) -> json.Value {
	o := make(json.Object, len(env))
	for k, v in env do mcp.obj_set(&o, k, mcp.str_value(v))
	return o
}

wire_servers_json :: proc(servers: []mcp.Server_Config) -> json.Array {
	arr := make(json.Array, 0, len(servers))
	for &s in servers {
		w := mcp.server_to_wire(&s)
		data, err := json.marshal(w)
		if err == nil {
			v, perr := json.parse_string(string(data))
			if perr == nil do append(&arr, v)
			delete(data)
		}
		// server_to_wire owns everything; free the temporary wire form.
		mcp.wire_server_destroy(&w)
	}
	return arr
}

params_for_discover :: proc(project: string, servers: []mcp.Server_Config) -> json.Value {
	o := make(json.Object)
	mcp.obj_set(&o, "project", mcp.str_value(project))
	mcp.obj_set(&o, "servers", wire_servers_json(servers))
	env := current_env_map()
	defer free_env_map(&env)
	mcp.obj_set(&o, "env", env_map_json(env))
	return o
}

params_for_call :: proc(project: string, servers: []mcp.Server_Config, name, arguments: string) -> json.Value {
	o := make(json.Object)
	mcp.obj_set(&o, "project", mcp.str_value(project))
	mcp.obj_set(&o, "servers", wire_servers_json(servers))
	env := current_env_map()
	defer free_env_map(&env)
	mcp.obj_set(&o, "env", env_map_json(env))
	mcp.obj_set(&o, "name", mcp.str_value(name))
	mcp.obj_set(&o, "arguments", mcp.str_value(arguments))
	return o
}

print_schema :: proc(name, description: string, parameters: json.Value) {
	params := parameters
	if params == nil || mcp.is_null(params) {
		o := make(json.Object)
		mcp.obj_set(&o, "type", mcp.str_value("object"))
		mcp.obj_set(&o, "properties", make(json.Object))
		params = o
	}
	schema: struct {
		name:        string     `json:"name"`,
		description: string     `json:"description,omitempty"`,
		parameters:  json.Value `json:"parameters"`,
	}
	schema.name = name
	schema.description = description
	schema.parameters = json.clone_value(params)
	data, err := json.marshal(schema)
	json.destroy_value(schema.parameters)
	if err != nil do return
	defer delete(data)
	fmt.print(string(data))
	fmt.print("\n")
}

mcp_schema :: proc() -> int {
	project := project_dir()
	defer delete(project)
	config_dir := mcp.config_dir_path()
	defer delete(config_dir)
	load := mcp.load_servers(project, config_dir)
	defer mcp.config_load_destroy(&load)
	for &srv in load.servers do mcp.expand_server_config(&srv)
	if len(load.servers) == 0 {
		if len(load.warnings) > 0 do fmt.eprintln(load.warnings)
		return EXIT_OK
	}

	params := params_for_discover(project, load.servers)
	defer json.destroy_value(params)
	result, err := mcp.host_call("mcp.discover", params, 120_000)
	if err != "" {
		fmt.eprintln("miagent-mcp:", err)
		return EXIT_BRIDGE_ERROR
	}
	defer json.destroy_value(result)
	ro, ok := mcp.jobj(result)
	if !ok {
		fmt.eprintln("miagent-mcp: invalid discovery result")
		return EXIT_BRIDGE_ERROR
	}
	if warning := mcp.jstr(mcp.jget(ro, "warning")); len(warning) > 0 do fmt.eprintln(warning)
	if servers, sok := mcp.jarr(mcp.jget(ro, "servers")); sok {
		for raw in servers {
			so, ook := mcp.jobj(raw)
			if !ook do continue
			err_text := mcp.jstr(mcp.jget(so, "error"))
			if len(err_text) > 0 {
				fmt.eprintf("miagent-mcp: %s: %s\n", mcp.jstr(mcp.jget(so, "name")), err_text)
			}
		}
	}
	tools, tok := mcp.jarr(mcp.jget(ro, "tools"))
	if !tok do return EXIT_OK
	for raw in tools {
		to, ook := mcp.jobj(raw)
		if !ook do continue
		name := mcp.jstr(mcp.jget(to, "function_name"))
		if len(name) == 0 do continue
		server := mcp.jstr(mcp.jget(to, "server"))
		tool_name := mcp.jstr(mcp.jget(to, "name"))
		description := mcp.jstr(mcp.jget(to, "description"))
		prefix := fmt.aprintf("MCP tool %q from server %q.", tool_name, server)
		full := len(description) > 0 ? fmt.aprintf("%s %s", prefix, description) : prefix
		print_schema(name, full, mcp.jget(to, "parameters"))
		delete(prefix)
		delete(full)
	}
	return EXIT_OK
}

attachment_extension :: proc(mime: string) -> string {
	lower := strings.to_lower(mime)
	defer delete(lower)
	switch {
	case lower == "image/png": return ".png"
	case lower == "image/jpeg", lower == "image/jpg": return ".jpg"
	case lower == "image/gif": return ".gif"
	case lower == "image/webp": return ".webp"
	case lower == "application/pdf": return ".pdf"
	case lower == "application/json": return ".json"
	case lower == "text/markdown": return ".md"
	case lower == "text/plain": return ".txt"
	case lower == "text/html": return ".html"
	case lower == "application/xml", lower == "text/xml": return ".xml"
	case lower == "application/zip": return ".zip"
	case: return ".bin"
	}
}

write_tgi_attachment :: proc(index: int, data_b64, mime: string, notes: ^[dynamic]string) -> bool {
	dir, ok := os.lookup_env("TGI_ATTACHMENT_DIR", context.temp_allocator)
	if !ok || len(dir) == 0 do return false
	raw, derr := base64.decode(data_b64)
	if derr != nil {
		append(notes, fmt.aprintf("MCP attachment %d could not be decoded", index))
		return false
	}
	defer delete(raw)
	if len(raw) > 32 << 20 {
		append(notes, fmt.aprintf("MCP attachment %d is too large", index))
		return false
	}
	if mkerr := os.make_directory_all(dir); mkerr != nil && mkerr != .Exist {
		append(notes, fmt.aprintf("could not create TGI_ATTACHMENT_DIR: %v", mkerr))
		return false
	}
	name := fmt.aprintf("%02d%s", index, attachment_extension(mime))
	path := fmt.aprintf("%s/%s", dir, name)
	defer delete(path)
	if werr := os.write_entire_file(path, raw); werr != nil {
		append(notes, fmt.aprintf("writing MCP attachment %d: %v", index, werr))
		delete(name)
		return false
	}
	delete(name)
	return true
}

render_content :: proc(content: json.Array, notes: ^[dynamic]string) -> (text: string, attachments: int) {
	b := strings.builder_make()
	for part in content {
		po, ok := mcp.jobj(part)
		if !ok do continue
		switch strings.to_lower(mcp.jstr(mcp.jget(po, "type"))) {
		case "text":
			text_part := mcp.jstr(mcp.jget(po, "text"))
			if len(text_part) > 0 {
				if strings.builder_len(b) > 0 do strings.write_string(&b, "\n")
				strings.write_string(&b, text_part)
			}
		case "image":
			attachments += 1
			mime := mcp.jstr(mcp.jget(po, "mimeType"))
			if !write_tgi_attachment(attachments, mcp.jstr(mcp.jget(po, "data")), mime, notes) {
				append(notes, fmt.aprintf("MCP returned an image (%s) that could not be attached", mime))
			}
		case "audio":
			append(notes, "MCP returned audio content; MiAgent does not attach audio tool results")
		case "resource":
			ro, rok := mcp.jobj(mcp.jget(po, "resource"))
			if !rok do continue
			if rtext := mcp.jstr(mcp.jget(ro, "text")); len(rtext) > 0 {
				if strings.builder_len(b) > 0 do strings.write_string(&b, "\n")
				strings.write_string(&b, rtext)
			} else if blob := mcp.jstr(mcp.jget(ro, "blob")); len(blob) > 0 {
				mime := mcp.jstr(mcp.jget(ro, "mimeType"))
				attachments += 1
				if !write_tgi_attachment(attachments, blob, mime, notes) {
					append(notes, fmt.aprintf("MCP resource (%s) could not be attached", mime))
				}
			}
		case "resource_link":
			uri := mcp.jstr(mcp.jget(po, "uri"))
			name := mcp.jstr(mcp.jget(po, "name"))
			if strings.builder_len(b) > 0 do strings.write_string(&b, "\n")
			if len(name) > 0 do fmt.sbprintf(&b, "%s: ", name)
			strings.write_string(&b, uri)
		}
	}
	return strings.to_string(b), attachments
}

mcp_invoke :: proc() -> int {
	project := project_dir()
	defer delete(project)
	config_dir := mcp.config_dir_path()
	defer delete(config_dir)
	load := mcp.load_servers(project, config_dir)
	defer mcp.config_load_destroy(&load)
	for &srv in load.servers do mcp.expand_server_config(&srv)
	if len(load.servers) == 0 {
		fmt.eprintln("miagent-mcp: no MCP servers are configured")
		return EXIT_BRIDGE_ERROR
	}
	name := os.get_env("TGI_TOOL", context.temp_allocator)
	if len(name) == 0 {
		fmt.eprintln("miagent-mcp: TGI_TOOL is not set")
		return EXIT_USAGE
	}
	arguments, rerr := read_stdin_all(MAX_STDIN)
	if rerr != "" {
		fmt.eprintln("miagent-mcp:", rerr)
		return EXIT_BRIDGE_ERROR
	}
	defer delete(arguments)

	params := params_for_call(project, load.servers, name, arguments)
	defer json.destroy_value(params)
	result, err := mcp.host_call("mcp.call", params, DEFAULT_CALL_TIMEOUT_MS + 30_000)
	if err != "" {
		fmt.eprintln("miagent-mcp:", err)
		return EXIT_BRIDGE_ERROR
	}
	defer json.destroy_value(result)
	ro, ok := mcp.jobj(result)
	if !ok {
		fmt.eprintln("miagent-mcp: invalid call result")
		return EXIT_BRIDGE_ERROR
	}

	notes := make([dynamic]string, 0, 4)
	defer {
		for n in notes do delete(n)
		delete(notes)
	}

	text := ""
	attachments := 0
	if content, cok := mcp.jarr(mcp.jget(ro, "content")); cok {
		text, attachments = render_content(content, &notes)
	}
	if len(strings.trim_space(text)) == 0 {
		if structured := mcp.jget(ro, "structuredContent"); structured != nil {
			if data, merr := json.marshal(structured, {pretty = true, use_spaces = true, spaces = 2}); merr == nil {
				delete(text)
				text = strings.clone(string(data))
				delete(data)
			}
		}
	}
	for note in notes do fmt.eprintf("miagent-mcp: %s\n", note)
	if len(text) > 0 {
		fmt.print(text)
		if text[len(text) - 1] != '\n' do fmt.print("\n")
	}
	is_error := mcp.jbool(mcp.jget(ro, "isError"))
	delete(text)
	if is_error {
		fmt.eprintln("miagent-mcp: the MCP tool reported an error (see its output above)")
		return EXIT_TOOL_ERROR
	}
	return EXIT_OK
}

DEFAULT_CALL_TIMEOUT_MS :: 300_000

cli_status :: proc() -> int {
	status := mcp.host_status()
	defer mcp.host_status_destroy(&status)
	if !status.running {
		fmt.println("MCP host: not running")
		return EXIT_OK
	}
	fmt.printfln("MCP host: running (pid %d, uptime %ds, %d tool(s))", status.pid, status.uptime_seconds, status.tool_count)
	for s in status.servers {
		fmt.printfln("  %s [%s] %s, %d tool(s)%s", s.name, s.transport, s.state, s.tool_count, s.resources ? " + resources" : "")
		if len(s.error) > 0 do fmt.println("    error:", s.error)
		else if len(s.log_tail) > 0 do fmt.printfln("    log: %s", s.log_tail)
	}
	return EXIT_OK
}

cli_tools :: proc() -> int {
	return mcp_schema()
}

cli_call :: proc(name, arguments: string) -> int {
	project := project_dir()
	defer delete(project)
	config_dir := mcp.config_dir_path()
	defer delete(config_dir)
	load := mcp.load_servers(project, config_dir)
	defer mcp.config_load_destroy(&load)
	for &srv in load.servers do mcp.expand_server_config(&srv)
	if len(load.servers) == 0 {
		fmt.eprintln("miagent-mcp: no MCP servers are configured")
		return EXIT_BRIDGE_ERROR
	}
	params := params_for_call(project, load.servers, name, arguments)
	defer json.destroy_value(params)
	result, err := mcp.host_call("mcp.call", params, DEFAULT_CALL_TIMEOUT_MS + 30_000)
	if err != "" {
		fmt.eprintln("miagent-mcp:", err)
		return EXIT_BRIDGE_ERROR
	}
	defer json.destroy_value(result)
	data, merr := json.marshal(result, {pretty = true, use_spaces = true, spaces = 2})
	if merr != nil {
		fmt.eprintln("miagent-mcp: could not render result")
		return EXIT_BRIDGE_ERROR
	}
	defer delete(data)
	fmt.println(string(data))
	return EXIT_OK
}

main :: proc() {
	if method := os.get_env("TGI_METHOD", context.temp_allocator); len(method) > 0 {
		switch method {
		case "SCHEMA":
			os.exit(mcp_schema())
		case "INVOKE":
			os.exit(mcp_invoke())
		case:
			fmt.eprintf("miagent-mcp: unknown TGI_METHOD %q\n", method)
			os.exit(EXIT_USAGE)
		}
	}

	args := os.args
	command := len(args) > 1 ? args[1] : "--help"
	switch command {
	case "--help", "-h", "help":
		fmt.printfln(`miagent-mcp - adapt MCP servers to MiAgent's TGI tools

Usage:
  miagent-mcp                     run as a TGI tool (TGI_METHOD is set by MiAgent)
  miagent-mcp status              show the background host
  miagent-mcp tools               print the discovered TGI schemas
  miagent-mcp call NAME [JSON]    invoke one tool by its mcp__... name
  miagent-mcp host-status         alias for status
  miagent-mcp host-stop           stop the background host
  miagent-mcp --help              show this help

Configuration is read from $MIAGENT_CONFIG_DIR/mcp.json and
<project>/.miagent/mcp.json.`)
	case "status", "host-status":
		os.exit(cli_status())
	case "tools":
		os.exit(cli_tools())
	case "call":
		if len(args) < 3 {
			fmt.eprintln("miagent-mcp: call requires a tool name")
			os.exit(EXIT_USAGE)
		}
		args_text := len(args) > 3 ? args[3] : "{}"
		os.exit(cli_call(args[2], args_text))
	case "host-stop":
		if err := mcp.shutdown_host(); err != "" {
			fmt.eprintln("miagent-mcp:", err)
			os.exit(EXIT_BRIDGE_ERROR)
		}
		os.exit(EXIT_OK)
	case:
		fmt.eprintln("miagent-mcp: unknown argument", command)
		os.exit(EXIT_USAGE)
	}
}
