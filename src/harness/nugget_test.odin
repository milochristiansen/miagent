package harness

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

free_attachments_test :: proc(attachments: []Attachment) {
	for &att in attachments {
		delete(att.name)
		delete(att.mime)
		delete(att.kind)
		delete(att.text)
		delete(att.url)
	}
	delete(attachments)
}

free_nuggets_test :: proc(nuggets: []Tool_Nugget) {
	for &n in nuggets do tool_nugget_destroy(&n)
	delete(nuggets)
}

free_notes_test :: proc(notes: []string) {
	for n in notes do delete(n)
	delete(notes)
}

@(test)
test_collect_tool_attachments_and_nuggets :: proc(t: ^testing.T) {
	root := fmt.aprintf("/tmp/miagent-nugget-test-%d", time.to_unix_nanoseconds(time.now()))
	defer delete(root)
	if !testing.expectf(t, os.make_directory_all(root) == nil, "creating %s", root) do return
	defer os.remove_all(root)

	skills := join_path(root, "nuggets", "skills")
	defer delete(skills)
	if !testing.expectf(t, os.make_directory_all(skills) == nil, "creating %s", skills) do return

	png_bytes := []u8{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0}
	blob_bytes := []u8{0, 1, 2, 3}
	bad_bytes := []u8{0, 1, 2}
	png := string(png_bytes)
	blob := string(blob_bytes)
	bad := string(bad_bytes)
	files := [5][2]string{
		{join_path(root, "01.png"), png},
		{join_path(root, "notes.md"), "# Notes\nhello\n"},
		{join_path(root, "blob.bin"), blob},
		{join_path(skills, "skill.md"), "# Skill\nexact text\n"},
		{join_path(root, "nuggets", "bad.bin"), bad},
	}
	defer {
		for f in files do delete(f[0])
	}
	for f in files {
		if err := os.write_entire_file_from_string(f[0], f[1]); err != nil {
			testing.fail_now(t, fmt.aprintf("writing %s: %v", f[0], err))
		}
	}

	attachments, nuggets, notes := collect_tool_attachments(root)
	defer free_attachments_test(attachments)
	defer free_nuggets_test(nuggets)
	defer free_notes_test(notes)

	if !testing.expect_value(t, len(attachments), 3) do return
	if !testing.expect_value(t, len(nuggets), 1) do return
	if !testing.expect_value(t, len(notes) > 0, true) do return

	kinds := make(map[string]int, context.temp_allocator)
	for att in attachments do kinds[att.kind] += 1
	testing.expect_value(t, kinds["image"], 1)
	testing.expect_value(t, kinds["text"], 1)
	testing.expect_value(t, kinds["binary"], 1)
	testing.expect_value(t, nuggets[0].name, "skills/skill.md")
	testing.expect_value(t, nuggets[0].content, "# Skill\nexact text\n")
}

@(test)
test_nugget_input_wrapper :: proc(t: ^testing.T) {
	items := []StoredItem{
		{role = "nugget", name = "skills/pdf.md", source = "tool:bash", content = "# PDF skill\n"},
	}
	input := build_input(items)
	defer {
		for v in input do json.destroy_value(v)
		delete(input)
	}
	if !testing.expect_value(t, len(input), 1) do return
	data, err := json.marshal(input[0])
	if !testing.expectf(t, err == nil, "marshalling input: %v", err) do return
	defer delete(data)
	text := string(data)
	testing.expect(t, strings.contains(text, "<miagent-nugget"))
	testing.expect(t, strings.contains(text, "# PDF skill"))
	testing.expect(t, strings.contains(text, "tool:bash"))
}

@(test)
test_compaction_keeps_tail_nugget_in_place :: proc(t: ^testing.T) {
	items := make([]StoredItem, 7)
	defer harness_free_items(items)
	items[0] = StoredItem{role = "user", content = strings.clone("old prompt")}
	items[1] = StoredItem{role = "nugget", name = strings.clone("a.md"), content = strings.clone("nugget A")}
	items[2] = StoredItem{role = "assistant", content = strings.clone("old answer")}
	items[3] = StoredItem{role = "nugget", name = strings.clone("b.md"), content = strings.clone("nugget B")}
	items[4] = StoredItem{role = "user", content = strings.clone("kept prompt")}
	items[5] = StoredItem{role = "nugget", name = strings.clone("c.md"), content = strings.clone("nugget C")}
	items[6] = StoredItem{role = "assistant", content = strings.clone("kept answer")}

	summary := StoredItem{role = "compaction", content = strings.clone("summary")}
	new_items, moved, tail := build_compacted_items(items, 4, summary)
	defer harness_free_items(new_items)

	if !testing.expect_value(t, moved, 2) do return
	if !testing.expect_value(t, tail, 1) do return
	if !testing.expect_value(t, len(new_items), 6) do return
	testing.expect_value(t, new_items[0].role, "compaction")
	testing.expect_value(t, new_items[1].name, "a.md")
	testing.expect_value(t, new_items[2].name, "b.md")
	testing.expect_value(t, new_items[3].content, "kept prompt")
	testing.expect_value(t, new_items[4].name, "c.md")
	testing.expect_value(t, new_items[5].content, "kept answer")
}

@(test)
test_serialize_conversation_skips_nuggets :: proc(t: ^testing.T) {
	items := make([]StoredItem, 3)
	defer harness_free_items(items)
	items[0] = StoredItem{role = "user", content = strings.clone("visible prompt")}
	items[1] = StoredItem{role = "nugget", name = strings.clone("secret.md"), content = strings.clone("DO NOT SUMMARIZE")}
	items[2] = StoredItem{role = "assistant", content = strings.clone("visible answer")}

	text := serialize_conversation(items)
	defer delete(text)
	testing.expect(t, strings.contains(text, "visible prompt"))
	testing.expect(t, strings.contains(text, "visible answer"))
	testing.expect(t, !strings.contains(text, "DO NOT SUMMARIZE"))
}

@(test)
test_nugget_infos_clone_content :: proc(t: ^testing.T) {
	items := make([]StoredItem, 2)
	defer harness_free_items(items)
	items[0] = StoredItem{role = "nugget", name = strings.clone("a.md"), source = strings.clone("tool:bash"), content = strings.clone("alpha")}
	items[1] = StoredItem{role = "nugget", name = strings.clone("b.md"), source = strings.clone("internal:skill"), content = strings.clone("beta")}

	infos := nugget_infos(items)
	defer {
		for &info in infos do nugget_info_destroy(&info)
		delete(infos)
	}
	if !testing.expect_value(t, len(infos), 2) do return
	testing.expect_value(t, infos[0].name, "a.md")
	testing.expect_value(t, infos[0].content, "alpha")
	testing.expect_value(t, infos[1].source, "internal:skill")
}

@(test)
test_session_parse_nugget_and_attachments :: proc(t: ^testing.T) {
	text := `{"role":"function_call_output","call_id":"call_1","output":"{}","attachments":[{"name":"notes.md","mime":"text/markdown","kind":"text","text":"hello","size":5}]}` + "\n" +
		`{"role":"nugget","name":"skills/pdf.md","content":"# PDF skill","source":"tool:bash","call_id":"call_1","nugget_id":"call_1:skills/pdf.md"}` + "\n"

	s := Session{}
	s.items = make([dynamic]StoredItem, 0, 8)
	s.usages = make([dynamic]Usage, 0, 4)
	defer session_destroy(&s)
	if err := session_parse(&s, text); err != "" {
		testing.fail_now(t, err)
	}
	if !testing.expect_value(t, len(s.items), 2) do return
	testing.expect_value(t, s.items[0].attachments[0].kind, "text")
	testing.expect_value(t, s.items[0].attachments[0].text, "hello")
	testing.expect_value(t, s.items[1].role, "nugget")
	testing.expect_value(t, s.items[1].source, "tool:bash")
	testing.expect_value(t, s.items[1].nugget_id, "call_1:skills/pdf.md")
}

@(test)
test_nugget_digest_is_content_only :: proc(t: ^testing.T) {
	a := nugget_digest("same content")
	b := nugget_digest("same content")
	c := nugget_digest("same content ")
	testing.expect(t, a == b)
	testing.expect(t, a != c)
}

@(test)
test_session_nugget_digests_skips_non_nuggets :: proc(t: ^testing.T) {
	items := []StoredItem{
		{role = "nugget", content = "alpha"},
		{role = "user", content = "alpha"},
		{role = "nugget", content = "beta"},
	}
	digests := session_nugget_digests(items)
	defer delete(digests)
	testing.expect_value(t, len(digests), 2)
	testing.expect(t, digests[nugget_digest("alpha")])
	testing.expect(t, digests[nugget_digest("beta")])
}

@(test)
test_select_new_nuggets_discards_duplicate_content :: proc(t: ^testing.T) {
	nuggets := make([]Tool_Nugget, 3)
	nuggets[0] = Tool_Nugget{name = strings.clone("a.md"), content = strings.clone("same"), mime = strings.clone("text/markdown")}
	nuggets[1] = Tool_Nugget{name = strings.clone("b.md"), content = strings.clone("same"), mime = strings.clone("text/markdown")}
	nuggets[2] = Tool_Nugget{name = strings.clone("c.md"), content = strings.clone("other"), mime = strings.clone("text/markdown")}
	defer delete(nuggets)

	digests := make(map[Nugget_Digest]bool, 4)
	defer delete(digests)

	kept, skipped := select_new_nuggets(nuggets, &digests)
	defer free_nuggets_test(kept)
	defer {
		for name in skipped do delete(name)
		delete(skipped)
	}

	if !testing.expect_value(t, len(kept), 2) do return
	if !testing.expect_value(t, len(skipped), 1) do return
	testing.expect_value(t, kept[0].name, "a.md")
	testing.expect_value(t, kept[1].name, "c.md")
	testing.expect_value(t, skipped[0], "b.md")
	testing.expect(t, digests[nugget_digest("same")])
	testing.expect(t, digests[nugget_digest("other")])
}

@(test)
test_select_new_nuggets_skips_content_already_in_session :: proc(t: ^testing.T) {
	nuggets := make([]Tool_Nugget, 1)
	nuggets[0] = Tool_Nugget{name = strings.clone("skills/pdf.md"), content = strings.clone("already active"), mime = strings.clone("text/markdown")}
	defer delete(nuggets)

	digests := make(map[Nugget_Digest]bool, 2)
	defer delete(digests)
	digests[nugget_digest("already active")] = true

	kept, skipped := select_new_nuggets(nuggets, &digests)
	defer free_nuggets_test(kept)
	defer {
		for name in skipped do delete(name)
		delete(skipped)
	}

	if !testing.expect_value(t, len(kept), 0) do return
	if !testing.expect_value(t, len(skipped), 1) do return
	testing.expect_value(t, skipped[0], "skills/pdf.md")
}

@(test)
test_select_new_nuggets_keeps_changed_content_with_same_name :: proc(t: ^testing.T) {
	nuggets := make([]Tool_Nugget, 2)
	nuggets[0] = Tool_Nugget{name = strings.clone("skills/pdf.md"), content = strings.clone("old body"), mime = strings.clone("text/markdown")}
	nuggets[1] = Tool_Nugget{name = strings.clone("skills/pdf.md"), content = strings.clone("new body"), mime = strings.clone("text/markdown")}
	defer delete(nuggets)

	digests := make(map[Nugget_Digest]bool, 2)
	defer delete(digests)

	kept, skipped := select_new_nuggets(nuggets, &digests)
	defer free_nuggets_test(kept)
	defer {
		for name in skipped do delete(name)
		delete(skipped)
	}

	if !testing.expect_value(t, len(kept), 2) do return
	testing.expect_value(t, len(skipped), 0)
	testing.expect_value(t, kept[0].content, "old body")
	testing.expect_value(t, kept[1].content, "new body")
}
