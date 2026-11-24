package harness

import "core:fmt"
import "core:os"
import "base:runtime"
import "core:strings"
import "core:testing"
import "core:time"

// Regression test for the attachment-directory lifetime in run_tool.
//
// `defer` is block-scoped in Odin: `if cond do defer delete(x)` frees x as soon
// as the if body ends, not when the procedure returns. That made every tool
// call pass a dangling TGI_ATTACHMENT_DIR to the child and then try to collect
// attachments from freed memory, which surfaced as bogus bwrap mount paths and
// "<garbage>: Not_Exist" notes on every tool result.
@(test)
test_run_tool_keeps_attachment_dir_alive :: proc(t: ^testing.T) {
	root := fmt.aprintf("/tmp/miagent-run-tool-test-%d", time.to_unix_nanoseconds(time.now()))
	defer delete(root)
	if !testing.expectf(t, os.make_directory_all(root) == nil, "creating %s", root) do return
	defer os.remove_all(root)

	tool_path := join_path(root, "fake-tool")
	defer delete(tool_path)
	script := `#!/bin/sh
case "$TGI_METHOD" in
  INVOKE)
    printf 'hello from tool\n'
    printf 'payload\n' > "$TGI_ATTACHMENT_DIR/greeting.txt"
    ;;
  SCHEMA)
    printf '{"name":"fake"}\n'
    ;;
esac
`
	if !testing.expectf(t, os.write_entire_file_from_string(tool_path, script) == nil, "writing %s", tool_path) do return
	if !testing.expectf(t, os.chmod(tool_path, os.Permissions_All) == nil, "chmod %s", tool_path) do return

	state_dir := join_path(root, ".miagent")
	defer delete(state_dir)
	session_path := join_path(root, "session-lifetime.jsonl")
	defer delete(session_path)

	config := Config{
		project_dir = root,
		state_dir = state_dir,
		session_path = session_path,
	}
	tool := Tool{
		name = "fake-tool",
		exec_path = tool_path,
		kind = .TGI,
	}
	h := Harness{}
	defer {
		// The tool's reader threads run with the default (heap) allocator, not
		// the test runner's tracking allocator, so free their events with the
		// matching allocator.
		heap := runtime.heap_allocator()
		for ev in h.events {
			if len(ev.text) > 0 do delete(ev.text, heap)
			if len(ev.name) > 0 do delete(ev.name, heap)
			if len(ev.meta) > 0 do delete(ev.meta, heap)
			if len(ev.call_id) > 0 do delete(ev.call_id, heap)
		}
		delete(h.events)
	}

	res := run_tool(&h, &config, &tool, "call_lifetime", "{}")
	defer {
		if len(res.stdout) > 0 do delete(res.stdout)
		if len(res.stderr) > 0 do delete(res.stderr)
		if len(res.err) > 0 do delete(res.err)
		if len(res.raw_output) > 0 do delete(res.raw_output)
		for &att in res.attachments do attachment_destroy(&att)
		delete(res.attachments)
		delete(res.nuggets)
	}

	if !testing.expect_value(t, res.code, 0) do return
	testing.expect_value(t, strings.trim_space(res.stdout), "hello from tool")
	// Before the fix this contained the corrupted attachment-directory note.
	testing.expect_value(t, res.stderr, "")
	if !testing.expect_value(t, len(res.attachments), 1) do return
	testing.expect_value(t, res.attachments[0].name, "greeting.txt")
}
