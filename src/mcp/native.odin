package mcp


foreign import mcp_native "../../build/libmcp.a"

@(default_calling_convention = "c")
foreign mcp_native {
	mi_mcp_spawn_detached :: proc(argv: [^]cstring, log_path: cstring) -> i32 ---
	mi_mcp_random_hex :: proc(out: [^]u8, bytes: i32) -> i32 ---
	mi_mcp_watch_signals :: proc(fd: i32) ---
	mi_mcp_shutdown_requested :: proc() -> i32 ---
	mi_mcp_http_request :: proc(
		method: cstring,
		url: cstring,
		headers_nl: cstring,
		body: cstring,
		body_len: uint,
		timeout_ms: i64,
		out: rawptr,
	) -> i32 ---
	mi_mcp_http_free :: proc(out: rawptr) ---
}

// This layout must match mi_mcp_http_result in transport.c.
HTTP_Result :: struct {
	body:         cstring,
	len:          uint,
	cap:          uint,
	content_type: [256]u8,
	session_id:   [512]u8,
	status:       i64,
	curl_code:    i64,
	error:        [512]u8,
}

http_request :: proc(method, url, headers_nl, body: string, timeout_ms: int) -> (res: HTTP_Result, body_text: string, error: string) {
	c_method := cstring_copy(method)
	c_url := cstring_copy(url)
	c_headers := cstring_copy(headers_nl)
	c_body := cstring_copy(body)
	rc := mi_mcp_http_request(c_method, c_url, c_headers, c_body, uint(len(body)), i64(timeout_ms), &res)
	if rc != 0 {
		return res, "", cstring_string(res.error[:])
	}
	if res.body != nil {
		ptr := cast([^]u8)res.body
		body_text = string(ptr[:res.len])
	}
	return res, body_text, ""
}

http_result_free :: proc(res: ^HTTP_Result) {
	mi_mcp_http_free(res)
}

cstring_string :: proc(buf: []u8) -> string {
	n := 0
	for n < len(buf) && buf[n] != 0 do n += 1
	return string(buf[:n])
}

cstring_copy :: proc(s: string) -> cstring {
	b := make([]u8, len(s) + 1, context.temp_allocator)
	copy(b, s)
	b[len(s)] = 0
	return cstring(raw_data(b))
}

spawn_detached :: proc(argv: []string, log_path: string) -> string {
	if len(argv) == 0 do return "empty command"
	cargs := make([]cstring, len(argv) + 1, context.temp_allocator)
	for a, i in argv do cargs[i] = cstring_copy(a)
	cargs[len(argv)] = nil
	rc := mi_mcp_spawn_detached(raw_data(cargs), cstring_copy(log_path))
	if rc != 0 do return "fork failed"
	return ""
}

watch_signals :: proc(fd: i32) {
	mi_mcp_watch_signals(fd)
}

shutdown_requested :: proc() -> bool {
	return mi_mcp_shutdown_requested() != 0
}

random_token :: proc(bytes: int = 24) -> string {
	buf := make([]u8, bytes * 2 + 1, context.temp_allocator)
	if mi_mcp_random_hex(raw_data(buf), i32(bytes)) != 0 do return ""
	return string(buf[:bytes * 2])
}
