package harness

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// The GUI resumes a preview by passing its absolute archive path straight to
// the harness, so the load path must not depend on the slash command's
// whitespace splitting.
@(test)
test_harness_archive_load_accepts_path_with_spaces :: proc(t: ^testing.T) {
	dir := fmt.aprintf("/tmp/miagent-load-test-%d", time.to_unix_nanoseconds(time.now()))
	defer delete(dir)
	if !testing.expectf(t, os.make_directory_all(dir) == nil, "creating %s", dir) do return
	defer os.remove_all(dir)

	session_path := join_path(dir, "session.jsonl")
	defer delete(session_path)
	target := join_path(dir, "archive with spaces.tar.gz")
	defer delete(target)

	content := `{"role":"user","content":"hello"}` + "\n" +
		`{"role":"assistant","content":"hi"}` + "\n"
	entries := make([]Archive_Entry, 1)
	entries[0] = Archive_Entry{name = strings.clone("session.jsonl"), content = strings.clone(content)}
	defer archive_entries_destroy(entries)
	if err := archive_pack(target, nil, entries); err != "" {
		testing.fail_now(t, err)
	}

	h := Harness{}
	h.session = session_init(session_path)
	defer session_destroy(&h.session)
	defer {
		for &ev in h.events do event_destroy(&ev)
		delete(h.events)
	}
	defer {
		for &w in h.work {
			delete(w.prompt)
			delete(w.archive)
		}
		delete(h.work)
	}

	if !testing.expect(t, harness_load_archive(&h, target), "archive load must queue") do return
	if !testing.expect_value(t, len(h.work), 1) do return
	item := h.work[0]
	ordered_remove(&h.work, 0)
	defer delete(item.archive)

	if err := cmd_load_target(&h, item.archive); err != "" {
		testing.fail_now(t, err)
	}
	if !testing.expect_value(t, len(h.session.items), 2) do return
	testing.expect_value(t, h.session.items[0].role, "user")
	testing.expect_value(t, h.session.items[0].content, "hello")
	testing.expect_value(t, h.session.items[1].role, "assistant")
	testing.expect_value(t, h.session.items[1].content, "hi")

	data, rerr := os.read_entire_file(session_path, context.allocator)
	if !testing.expectf(t, rerr == nil, "reading loaded session: %v", rerr) do return
	defer delete(data)
	testing.expect_value(t, string(data), content)
}
