// IPC between the MiAgent-side bridge/UI and the background MCP host.
//
// The host listens on a loopback TCP socket (Odin's core:net has no Unix
// domain socket wrapper) and writes a 0600 endpoint file containing its port
// and a random token.  Every request carries the token, so other local users
// cannot drive the host even if they discover the port.
package mcp

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"

ENDPOINT_FILE :: "mcp-host.json"
LOCK_FILE :: "mcp-host.lock"
LOG_FILE :: "mcp-host.log"
RUNTIME_ENV :: "MIAGENT_MCP_RUNTIME_DIR"
HOST_ENV :: "MIAGENT_MCP_HOST"
HOST_BINARY :: "miagent-mcp-host"
HOST_VERSION :: 1

Endpoint :: struct {
	version:    int    `json:"version"`,
	pid:        int    `json:"pid"`,
	port:       int    `json:"port"`,
	token:      string `json:"token"`,
	started_at: i64    `json:"started_at"`,
}

Ipc_Request :: struct {
	id:     int        `json:"id"`,
	method: string     `json:"method"`,
	token:  string     `json:"token"`,
	params: json.Value `json:"params,omitempty"`,
}

Ipc_Response :: struct {
	id:     int        `json:"id"`,
	ok:     bool       `json:"ok"`,
	result: json.Value `json:"result"`,
	error:  string     `json:"error"`,
}

runtime_dir :: proc() -> string {
	if d, ok := os.lookup_env(RUNTIME_ENV, context.temp_allocator); ok && len(strings.trim_space(d)) > 0 {
		return strings.clone(strings.trim_space(d))
	}
	if d, ok := os.lookup_env("XDG_RUNTIME_DIR", context.temp_allocator); ok && len(d) > 0 && d[0] == '/' {
		return join_path(d, "miagent")
	}
	if d, ok := os.lookup_env("XDG_CACHE_HOME", context.temp_allocator); ok && len(d) > 0 && d[0] == '/' {
		return join_path(d, "miagent")
	}
	return join_path(home_dir(), ".cache", "miagent")
}

endpoint_path :: proc() -> string { return join_path(runtime_dir(), ENDPOINT_FILE) }
lock_path :: proc() -> string { return join_path(runtime_dir(), LOCK_FILE) }
log_path :: proc() -> string { return join_path(runtime_dir(), LOG_FILE) }

ensure_runtime_dir :: proc() -> string {
	dir := runtime_dir()
	if err := os.make_directory_all(dir); err != nil && err != .Exist do return fmt.aprintf("creating %s: %v", dir, err)
	return ""
}

read_endpoint :: proc() -> (Endpoint, bool, string) {
	path := endpoint_path()
	defer delete(path)
	if !os.exists(path) do return {}, false, ""
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return {}, false, fmt.aprintf("reading %s: %v", path, err)
	defer delete(data)
	ep: Endpoint
	if uerr := json.unmarshal_string(string(data), &ep); uerr != nil do return {}, false, fmt.aprintf("reading %s: %v", path, uerr)
	if ep.version != HOST_VERSION || ep.port <= 0 || len(ep.token) == 0 {
		delete(ep.token)
		return {}, false, "host endpoint file is invalid"
	}
	return ep, true, ""
}

endpoint_destroy :: proc(ep: ^Endpoint) {
	delete(ep.token)
	ep^ = {}
}

write_endpoint :: proc(ep: Endpoint) -> string {
	dir := runtime_dir()
	if err := os.make_directory_all(dir); err != nil && err != .Exist do return fmt.aprintf("creating %s: %v", dir, err)
	data, err := json.marshal(ep)
	if err != nil do return fmt.aprintf("encoding endpoint: %v", err)
	defer delete(data)
	path := endpoint_path()
	tmp := fmt.aprintf("%s.tmp.%d", path, os.get_pid())
	f, oerr := os.open(tmp, {.Read, .Write, .Create, .Trunc}, os.Permissions{.Read_User, .Write_User})
	if oerr != nil {
		delete(path)
		delete(tmp)
		return fmt.aprintf("writing %s: %v", tmp, oerr)
	}
	_, werr := os.write(f, data)
	os.close(f)
	if werr != nil {
		os.remove(tmp)
		delete(path)
		delete(tmp)
		return fmt.aprintf("writing %s: %v", path, werr)
	}
	if rerr := os.rename(tmp, path); rerr != nil {
		os.remove(tmp)
		delete(path)
		delete(tmp)
		return fmt.aprintf("renaming endpoint: %v", rerr)
	}
	delete(path)
	delete(tmp)
	return ""
}

remove_endpoint :: proc() {
	path := endpoint_path()
	defer delete(path)
	os.remove(path)
}

dial_endpoint :: proc(ep: Endpoint, timeout_ms: int) -> (net.TCP_Socket, string) {
	sock, err := net.dial_tcp_from_hostname_with_port_override("127.0.0.1", ep.port)
	if err != nil do return 0, fmt.aprintf("connecting to MCP host: %v", err)
	t := time.Duration(timeout_ms) * time.Millisecond
	if t <= 0 do t = 2 * time.Second
	_ = net.set_option(sock, .Receive_Timeout, t)
	_ = net.set_option(sock, .Send_Timeout, t)
	return sock, ""
}

// ipc_call_once sends one request to an already-discovered host.
ipc_call_once :: proc(ep: Endpoint, method: string, params: json.Value, timeout_ms: int) -> (json.Value, string) {
	sock, derr := dial_endpoint(ep, timeout_ms)
	if derr != "" do return nil, derr
	defer net.close(sock)

	req := Ipc_Request{id = 1, method = method, token = ep.token, params = params}
	payload, merr := json.marshal(req)
	if merr != nil do return nil, fmt.aprintf("encoding request: %v", merr)
	defer delete(payload)
	send_buf := make([]u8, len(payload) + 1, context.temp_allocator)
	copy(send_buf, payload)
	send_buf[len(payload)] = '\n'
	if _, serr := net.send_tcp(sock, send_buf); serr != nil do return nil, fmt.aprintf("sending request: %v", serr)

	b := strings.builder_make()
	defer delete(b.buf)
	buf: [8192]u8
	for {
		n, rerr := net.recv_tcp(sock, buf[:])
		if n > 0 {
			strings.write_bytes(&b, buf[:n])
			if strings.contains(strings.to_string(b), "\n") do break
			if strings.builder_len(b) > 64 << 20 do return nil, "host response is too large"
		}
		if rerr != nil do return nil, fmt.aprintf("reading response: %v", rerr)
		if n == 0 do return nil, "host closed the connection"
	}
	text := strings.to_string(b)
	nl := strings.index_byte(text, '\n')
	if nl >= 0 do text = text[:nl]
	resp: Ipc_Response
	if uerr := json.unmarshal_string(text, &resp); uerr != nil do return nil, fmt.aprintf("decoding response: %v", uerr)
	if !resp.ok {
		msg := resp.error
		if len(msg) == 0 do msg = "MCP host returned an error"
		out := strings.clone(msg)
		delete(resp.error)
		json.destroy_value(resp.result)
		return nil, out
	}
	delete(resp.error)
	return resp.result, ""
}

host_ping :: proc(timeout_ms := 500) -> bool {
	ep, ok, _ := read_endpoint()
	if !ok do return false
	defer endpoint_destroy(&ep)
	_, err := ipc_call_once(ep, "host.ping", nil, timeout_ms)
	return err == ""
}

// ipc_call talks to the host if it is already running.  It never starts one;
// callers that need that (the bridge) use host_call.
ipc_call :: proc(method: string, params: json.Value, timeout_ms := 5_000) -> (json.Value, string) {
	ep, ok, err := read_endpoint()
	if !ok {
		if len(err) > 0 do return nil, err
		return nil, "MCP host is not running"
	}
	defer endpoint_destroy(&ep)
	return ipc_call_once(ep, method, params, timeout_ms)
}

host_call :: proc(method: string, params: json.Value, timeout_ms := 30_000) -> (json.Value, string) {
	if err := ensure_host(); err != "" do return nil, err
	return ipc_call(method, params, timeout_ms)
}

executable_ok :: proc(path: string) -> bool {
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil || fi.type != .Regular do return false
	return .Execute_User in fi.mode || .Execute_Group in fi.mode || .Execute_Other in fi.mode
}

find_in_path :: proc(name: string) -> string {
	path, ok := os.lookup_env("PATH", context.temp_allocator)
	if !ok do return ""
	dirs := strings.split(path, ":", context.temp_allocator)
	for d in dirs {
		if len(d) == 0 do continue
		candidate := join_path(d, name)
		if executable_ok(candidate) do return candidate
		delete(candidate)
	}
	return ""
}

absolute_from_cwd :: proc(p: string) -> string {
	if os.is_absolute_path(p) do return strings.clone(p)
	cwd, err := os.get_working_directory(context.temp_allocator)
	if err != nil do return strings.clone(p)
	return join_path(cwd, p)
}

find_host_binary :: proc() -> string {
	if p, ok := os.lookup_env(HOST_ENV, context.temp_allocator); ok && len(strings.trim_space(p)) > 0 {
		return absolute_from_cwd(strings.trim_space(p))
	}
	if dir, err := os.get_executable_directory(context.temp_allocator); err == nil {
		candidate := join_path(dir, HOST_BINARY)
		if executable_ok(candidate) do return candidate
		delete(candidate)
	}
	cfg := config_dir_path()
	candidate := join_path(cfg, "bin", HOST_BINARY)
	if executable_ok(candidate) {
		delete(cfg)
		return candidate
	}
	delete(candidate)
	delete(cfg)
	return find_in_path(HOST_BINARY)
}

acquire_start_lock :: proc() -> (held: bool, wait_needed: bool, err: string) {
	if derr := ensure_runtime_dir(); derr != "" do return false, false, derr
	path := lock_path()
	defer delete(path)
	for _ in 0 ..< 2 {
		f, oerr := os.open(path, {.Read, .Write, .Create, .Excl}, os.Permissions{.Read_User, .Write_User})
		if oerr == nil {
			pid_text := fmt.aprintf("%d\n", os.get_pid())
			_, _ = os.write(f, transmute([]byte)pid_text)
			os.close(f)
			delete(pid_text)
			return true, false, ""
		}
		// A killed starter leaves the lock behind.  Treat an old lock as stale.
		fi, serr := os.stat(path, context.temp_allocator)
		if serr == nil && time.since(fi.modification_time) > 20 * time.Second {
			os.remove(path)
			continue
		}
		return false, true, ""
	}
	return false, true, ""
}

wait_for_host :: proc(timeout: time.Duration) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < timeout {
		if host_ping(250) do return true
		time.sleep(50 * time.Millisecond)
	}
	return false
}

ensure_host :: proc() -> string {
	if host_ping(300) do return ""

	held, wait_needed, lerr := acquire_start_lock()
	if lerr != "" do return lerr
	if !held {
		if wait_needed && wait_for_host(20 * time.Second) do return ""
		return "timed out waiting for the MCP host to start"
	}

	// Another starter may have finished between our ping and the lock.
	if host_ping(300) {
		lp := lock_path()
		os.remove(lp)
		delete(lp)
		return ""
	}

	host := find_host_binary()
	defer delete(host)
	if len(host) == 0 {
		lp := lock_path()
		os.remove(lp)
		delete(lp)
		return fmt.aprintf("MCP host binary %q not found (build it with make, or set %s)", HOST_BINARY, HOST_ENV)
	}
	_ = ensure_runtime_dir()
	log := log_path()
	defer delete(log)
	argv := []string{host}
	if serr := spawn_detached(argv, log); serr != "" {
		lp := lock_path()
		os.remove(lp)
		delete(lp)
		return fmt.aprintf("starting MCP host: %s", serr)
	}

	if wait_for_host(20 * time.Second) {
		lp := lock_path()
		os.remove(lp)
		delete(lp)
		return ""
	}

	lp := lock_path()
	os.remove(lp)
	delete(lp)
	detail := ""
	if data, rerr := os.read_entire_file(log, context.allocator); rerr == nil {
		defer delete(data)
		text := strings.trim_space(string(data))
		if len(text) > 4000 do text = text[len(text) - 4000:]
		if len(text) > 0 do detail = fmt.aprintf(": %s", text)
	}
	return fmt.aprintf("MCP host did not become ready%s", detail)
}

shutdown_host :: proc() -> string {
	ep, ok, err := read_endpoint()
	if !ok {
		if len(err) > 0 do return err
		return ""
	}
	defer endpoint_destroy(&ep)
	_, call_err := ipc_call_once(ep, "host.shutdown", nil, 2_000)
	if call_err != "" do return call_err
	for _ in 0 ..< 40 {
		if !host_ping(100) do return ""
		time.sleep(50 * time.Millisecond)
	}
	return "MCP host did not exit"
}

// --- status -----------------------------------------------------------------

Server_Status :: struct {
	project:    string,
	name:       string,
	transport:  string,
	state:      string,
	error:      string,
	log_tail:   string,
	resources:  bool,
	tool_count: int,
}

Host_Status :: struct {
	running:        bool,
	pid:            int,
	uptime_seconds: int,
	clients:        int,
	tool_count:     int,
	servers:        []Server_Status,
	error:          string,
}

host_status_destroy :: proc(s: ^Host_Status) {
	for &srv in s.servers {
		delete(srv.project)
		delete(srv.name)
		delete(srv.transport)
		delete(srv.state)
		delete(srv.error)
		delete(srv.log_tail)
	}
	delete(s.servers)
	delete(s.error)
	s^ = {}
}

// host_status queries a running host without starting one.  An optional
// project filters the server list, which is what the desktop status card uses.
host_status :: proc(project := "") -> Host_Status {
	status := Host_Status{}
	params: json.Value = nil
	if len(project) > 0 {
		o := make(json.Object)
		obj_set(&o, "project", str_value(project))
		params = o
	}
	result, err := ipc_call("host.status", params, 1_500)
	json.destroy_value(params)
	if err != "" {
		status.error = strings.clone(err)
		return status
	}
	defer json.destroy_value(result)
	ro, ok := jobj(result)
	if !ok {
		status.error = strings.clone("invalid host status")
		return status
	}
	status.running = true
	status.pid = jint(jget(ro, "pid"))
	status.uptime_seconds = jint(jget(ro, "uptime_seconds"))
	status.clients = jint(jget(ro, "clients"))
	status.tool_count = jint(jget(ro, "tool_count"))
	if arr, aok := jarr(jget(ro, "servers")); aok {
		servers := make([dynamic]Server_Status, 0, len(arr))
		for raw in arr {
			so, sok := jobj(raw)
			if !sok do continue
			append(&servers, Server_Status{
				project = strings.clone(jstr(jget(so, "project"))),
				name = strings.clone(jstr(jget(so, "name"))),
				transport = strings.clone(jstr(jget(so, "transport"))),
				state = strings.clone(jstr(jget(so, "state"))),
				error = strings.clone(jstr(jget(so, "error"))),
				log_tail = strings.clone(jstr(jget(so, "log_tail"))),
				resources = jbool(jget(so, "resources")),
				tool_count = jint(jget(so, "tool_count")),
			})
		}
		status.servers = servers[:]
	}
	return status
}
