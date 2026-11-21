package harness

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

test_policy_config :: proc() -> Config {
	return Config{
		attachment_small_bytes = DEFAULT_ATTACHMENT_SMALL_BYTES,
		attachment_send_budget = DEFAULT_ATTACHMENT_SEND_BUDGET,
		attachment_max_active = DEFAULT_ATTACHMENT_MAX_ACTIVE,
		attachment_recent_items = DEFAULT_ATTACHMENT_RECENT_ITEMS,
		attachment_pressure_count = DEFAULT_ATTACHMENT_PRESSURE_COUNT,
		attachment_pressure_bytes = DEFAULT_ATTACHMENT_PRESSURE_BYTES,
		attachment_pressure_recent = DEFAULT_ATTACHMENT_PRESSURE_RECENT,
		recall_headroom = DEFAULT_RECALL_HEADROOM,
		request_hard_bytes = DEFAULT_REQUEST_HARD_BYTES,
		cache_sweep = true,
		sweep_aggression = DEFAULT_SWEEP_AGGRESSION,
		sweep_low_watermark = DEFAULT_SWEEP_LOW_WATERMARK,
		sweep_horizon = DEFAULT_SWEEP_HORIZON,
		tool_body_small_bytes = DEFAULT_TOOL_BODY_SMALL_BYTES,
		tool_body_blob_threshold = DEFAULT_TOOL_BODY_BLOB_THRESHOLD,
		tool_body_send_budget = DEFAULT_TOOL_BODY_SEND_BUDGET,
		shake_body_threshold = DEFAULT_SHAKE_BODY_THRESHOLD,
	}
}

fake_blob :: proc(seed: int) -> string {
	b := strings.builder_make()
	defer delete(b.buf)
	digits := "0123456789abcdef"
	for i in 0 ..< 64 do strings.write_byte(&b, digits[(seed + i) % 16])
	return strings.clone(strings.to_string(b))
}

test_temp_root :: proc(prefix: string) -> string {
	return fmt.aprintf("/tmp/miagent-%s-%d", prefix, time.to_unix_nanoseconds(time.now()))
}

@(test)
test_parse_size_env_classic_units :: proc(t: ^testing.T) {
	c := Config{}
	c.env = make(map[string]string)
	defer {
		for key, value in c.env {
			delete(key)
			delete(value)
		}
		delete(c.env)
	}
	inputs := [5]string{"65536", "64KB", "16MB", "2GB", "1TB"}
	wants := [5]i64{65536, 65536, 16777216, 2147483648, 1099511627776}
	for input, i in inputs {
		delete_key(&c.env, "MIAGENT_TEST_SIZE")
		c.env[strings.clone("MIAGENT_TEST_SIZE")] = strings.clone(input)
		got, err := parse_size_env(&c, "MIAGENT_TEST_SIZE", 0)
		testing.expect_value(t, err, "")
		testing.expect_value(t, got, wants[i])
	}
	delete_key(&c.env, "MIAGENT_TEST_SIZE")
	c.env[strings.clone("MIAGENT_TEST_SIZE")] = strings.clone("64XB")
	_, err := parse_size_env(&c, "MIAGENT_TEST_SIZE", 0)
	testing.expect(t, len(err) > 0)
	delete(err)
}

@(test)
test_attachment_store_roundtrip :: proc(t: ^testing.T) {
	root := test_temp_root("store")
	defer delete(root)
	if !testing.expectf(t, os.make_directory_all(root) == nil, "creating %s", root) do return
	defer os.remove_all(root)

	store := attachment_store_init(join_path(root, "session.jsonl"))
	defer attachment_store_destroy(&store)
	payload_text := "hello attachment"
	payload := transmute([]byte)payload_text
	id, err := attachment_store_put(&store, payload)
	if !testing.expect_value(t, err, "") do return
	defer delete(id)
	if !testing.expect(t, attachment_store_valid_id(id)) do return
	testing.expect(t, attachment_store_has(&store, id))
	again, aerr := attachment_store_put(&store, payload)
	testing.expect_value(t, aerr, "")
	testing.expect_value(t, again, id)
	delete(again)
	data, derr := attachment_store_get(&store, id)
	if !testing.expect_value(t, derr, "") do return
	defer delete(data)
	testing.expect_value(t, string(data), "hello attachment")
	testing.expect(t, !attachment_store_valid_id("not-a-blob"))
}

@(test)
test_inline_attachment_migration_and_request :: proc(t: ^testing.T) {
	root := test_temp_root("migrate")
	defer delete(root)
	if !testing.expectf(t, os.make_directory_all(root) == nil, "creating %s", root) do return
	defer os.remove_all(root)
	store := attachment_store_init(join_path(root, "session.jsonl"))
	defer attachment_store_destroy(&store)

	png := []u8{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4}
	session := Session{}
	session.items = make([dynamic]StoredItem, 0, 4)
	defer session_destroy(&session)
	first_atts := make([]Attachment, 1)
	first_atts[0] = Attachment{
		name = strings.clone("tiny.png"),
		mime = strings.clone("image/png"),
		kind = strings.clone("image"),
		url = strings.clone("data:image/png;base64,iVBORw0KGgoBAgME"),
		size = len(png),
	}
	append(&session.items, StoredItem{
		role = "user",
		content = strings.clone("look"),
		attachments = first_atts,
	})

	changed, err := attachments_externalize(&session, &store, DEFAULT_TOOL_BODY_BLOB_THRESHOLD)
	if !testing.expect_value(t, err, "") do return
	testing.expect(t, changed)
	att := session.items[0].attachments[0]
	testing.expect(t, attachment_store_valid_id(att.blob))
	testing.expect_value(t, att.url, "")
	data, derr := attachment_store_get(&store, att.blob)
	if !testing.expect_value(t, derr, "") do return
	defer delete(data)
	testing.expect_value(t, len(data), len(png))
	for b, i in png do testing.expect_value(t, data[i], b)

	input := build_input_with_store(session.items[:], &store)
	defer {
		for v in input do json.destroy_value(v)
		delete(input)
	}
	if !testing.expect_value(t, len(input), 1) do return
	obj, ok := jobj(input[0])
	if !testing.expect(t, ok) do return
	parts, pok := jarr(jget(obj, "content"))
	if !testing.expect(t, pok) do return
	if !testing.expect_value(t, len(parts), 2) do return
	img, iok := jobj(parts[1])
	if !testing.expect(t, iok) do return
	testing.expect_value(t, jstr(jget(img, "type")), "input_image")
	testing.expect(t, strings.has_prefix(jstr(jget(img, "image_url")), "data:image/png;base64,"))
}

@(test)
test_policy_prunes_large_and_cache_sweeps_newer :: proc(t: ^testing.T) {
	cfg := test_policy_config()
	session := Session{}
	session.items = make([dynamic]StoredItem, 0, 8)
	defer session_destroy(&session)

	large1 := fake_blob(1)
	large2 := fake_blob(2)
	large3 := fake_blob(3)
	tiny := fake_blob(4)
	append(&session.items, StoredItem{role = "user", content = strings.clone("first")})
	c1_atts := make([]Attachment, 1)
	c1_atts[0] = Attachment{blob = large1, kind = strings.clone("image"), size = 5 * 1024 * 1024}
	append(&session.items, StoredItem{
		role = "function_call_output",
		call_id = strings.clone("c1"),
		attachments = c1_atts,
	})
	c2_atts := make([]Attachment, 1)
	c2_atts[0] = Attachment{blob = large2, kind = strings.clone("image"), size = 5 * 1024 * 1024}
	append(&session.items, StoredItem{
		role = "function_call_output",
		call_id = strings.clone("c2"),
		attachments = c2_atts,
	})
	append(&session.items, StoredItem{role = "user", content = strings.clone("latest")})
	c3_atts := make([]Attachment, 2)
	c3_atts[0] = Attachment{blob = large3, kind = strings.clone("image"), size = 5 * 1024 * 1024}
	c3_atts[1] = Attachment{blob = tiny, kind = strings.clone("image"), size = 1024}
	append(&session.items, StoredItem{
		role = "function_call_output",
		call_id = strings.clone("c3"),
		attachments = c3_atts,
	})

	changed, notes := attachment_policy_apply(&cfg, &session)
	testing.expect(t, changed)
	delete(notes)
	testing.expect_value(t, session.items[1].attachments[0].omitted, true)
	testing.expect_value(t, session.items[2].attachments[0].omitted, true)
	testing.expect_value(t, session.items[4].attachments[0].omitted, false)
	testing.expect_value(t, session.items[4].attachments[1].omitted, false)

	// Pressure is based on known unique blobs, including omitted ones.
	infos := collect_attachment_infos(session.items[:], cfg.attachment_small_bytes, cfg.attachment_recent_items, nil)
	defer delete(infos)
	pressure_before := attachment_pressure(&cfg, infos)
	for &it in session.items {
		for &att in it.attachments do att.omitted = false
	}
	infos2 := collect_attachment_infos(session.items[:], cfg.attachment_small_bytes, cfg.attachment_recent_items, nil)
	defer delete(infos2)
	testing.expect_value(t, attachment_pressure(&cfg, infos2), pressure_before)
}

@(test)
test_shake_omits_attachments_and_large_bodies :: proc(t: ^testing.T) {
	root := test_temp_root("shake")
	defer delete(root)
	if !testing.expectf(t, os.make_directory_all(root) == nil, "creating %s", root) do return
	defer os.remove_all(root)
	store := attachment_store_init(join_path(root, "session.jsonl"))
	defer attachment_store_destroy(&store)

	session := Session{}
	session.items = make([dynamic]StoredItem, 0, 4)
	defer session_destroy(&session)
	shake_atts := make([]Attachment, 1)
	shake_atts[0] = Attachment{
		name = strings.clone("note.txt"),
		mime = strings.clone("text/plain"),
		kind = strings.clone("text"),
		text = strings.clone("inline attachment"),
		size = 17,
	}
	append(&session.items, StoredItem{
		role = "user",
		content = strings.clone("prompt"),
		attachments = shake_atts,
	})
	big := strings.repeat("x", 100 * 1024)
	small := strings.repeat("y", 1024)
	defer delete(big)
	defer delete(small)
	append(&session.items, StoredItem{
		role = "function_call_output",
		call_id = strings.clone("big"),
		output = strings.clone(big),
	})
	append(&session.items, StoredItem{
		role = "function_call_output",
		call_id = strings.clone("small"),
		output = strings.clone(small),
	})

	attachments, _, bodies, _, changed, err := attachments_shake(
		&session, &store, DEFAULT_SHAKE_BODY_THRESHOLD, DEFAULT_TOOL_BODY_BLOB_THRESHOLD)
	if !testing.expect_value(t, err, "") do return
	testing.expect(t, changed)
	testing.expect_value(t, attachments, 1)
	testing.expect_value(t, bodies, 1)
	testing.expect_value(t, session.items[0].attachments[0].omitted, true)
	testing.expect(t, attachment_store_valid_id(session.items[0].attachments[0].blob))
	testing.expect_value(t, session.items[1].output_omitted, true)
	testing.expect(t, attachment_store_valid_id(session.items[1].output_blob))
	testing.expect_value(t, session.items[2].output_omitted, false)
	testing.expect_value(t, session.items[2].output_blob, "")
}

@(test)
test_session_rewrite_preserves_compaction_record :: proc(t: ^testing.T) {
	root := test_temp_root("rewrite")
	defer delete(root)
	if !testing.expectf(t, os.make_directory_all(root) == nil, "creating %s", root) do return
	defer os.remove_all(root)
	path := join_path(root, "session.jsonl")
	defer delete(path)

	session := session_init(path)
	session.compaction_record = compaction_record{
		kind = "compaction",
		archived = strings.clone("archive.tar.gz"),
		created = strings.clone("2026-01-01T00:00:00Z"),
		tokens_before = 100,
		tokens_after = 10,
	}
	append(&session.items, StoredItem{role = "user", content = strings.clone("hello")})
	append(&session.usages, Usage{input_tokens = 10, output_tokens = 2})
	der := session_rewrite(&session)
	testing.expect_value(t, der, "")
	session_destroy(&session)

	loaded := session_init(path)
	defer session_destroy(&loaded)
	lerr := session_load(&loaded)
	testing.expect_value(t, lerr, "")
	rec, has := loaded.compaction_record.?
	testing.expect(t, has)
	testing.expect_value(t, rec.archived, "archive.tar.gz")
	testing.expect_value(t, len(loaded.items), 1)
	testing.expect_value(t, len(loaded.usages), 1)
}

@(test)
test_internal_recall_tools :: proc(t: ^testing.T) {
	root := test_temp_root("recall")
	defer delete(root)
	if !testing.expectf(t, os.make_directory_all(root) == nil, "creating %s", root) do return
	defer os.remove_all(root)
	path := join_path(root, "session.jsonl")
	defer delete(path)
	store := attachment_store_init(path)
	defer attachment_store_destroy(&store)

	att_text := "attachment bytes"
	att_blob, aerr := attachment_store_put(&store, transmute([]byte)att_text)
	testing.expect_value(t, aerr, "")
	defer delete(att_blob)
	out_text := "original tool output"
	out_blob, oerr := attachment_store_put(&store, transmute([]byte)out_text)
	testing.expect_value(t, oerr, "")
	defer delete(out_blob)

	h: Harness
	h.config.session_path = strings.clone(path)
	defer delete(h.config.session_path)
	h.session.path = strings.clone(path)
	defer delete(h.session.path)
	h.session.items = make([dynamic]StoredItem, 0, 2)
	defer {
		for &it in h.session.items do item_destroy(&it)
		delete(h.session.items)
	}
	recall_atts := make([]Attachment, 1)
	recall_atts[0] = Attachment{
		name = strings.clone("image.png"),
		mime = strings.clone("image/png"),
		kind = strings.clone("image"),
		size = 16,
		blob = strings.clone(att_blob),
	}
	append(&h.session.items, StoredItem{
		role = "function_call_output",
		call_id = strings.clone("call_1"),
		attachments = recall_atts,
		output_blob = strings.clone(out_blob),
		output_size = 20,
		output_omitted = true,
	})

	tool := Tool{name = strings.clone(RECALL_ATTACHMENT_TOOL), kind = .Recall_Attachment}
	attach_args := strings.concatenate({`{"blob":"`, att_blob, `"}`})
	res := run_internal_tool(&h, &h.config, &tool, "call_2", attach_args)
	delete(attach_args)
	testing.expect_value(t, res.code, 0)
	testing.expect_value(t, len(res.attachments), 1)
	testing.expect_value(t, res.attachments[0].omitted, false)
	for &att in res.attachments do attachment_destroy(&att)
	delete(res.attachments)
	delete(res.stdout)
	delete(res.err)
	delete(tool.name)

	tool2 := Tool{name = strings.clone(RECALL_OUTPUT_TOOL), kind = .Recall_Output}
	res2 := run_internal_tool(&h, &h.config, &tool2, "call_3", `{"call_id":"call_1"}`)
	testing.expect_value(t, res2.code, 0)
	testing.expect_value(t, res2.raw_output, "original tool output")
	delete(res2.raw_output)
	delete(res2.stdout)
	delete(res2.err)
	delete(tool2.name)
}

@(test)
test_build_input_omits_and_dedupes_blobs :: proc(t: ^testing.T) {
	root := test_temp_root("input")
	defer delete(root)
	if !testing.expectf(t, os.make_directory_all(root) == nil, "creating %s", root) do return
	defer os.remove_all(root)
	store := attachment_store_init(join_path(root, "session.jsonl"))
	defer attachment_store_destroy(&store)
	png_text := "PNGDATA"
	blob, berr := attachment_store_put(&store, transmute([]byte)png_text)
	if !testing.expect_value(t, berr, "") do return
	defer delete(blob)

	items := make([]StoredItem, 3)
	items[0].role = "user"
	items[0].content = strings.clone("first")
	items[0].attachments = make([]Attachment, 1)
	items[0].attachments[0] = Attachment{
		name = strings.clone("a.png"), mime = strings.clone("image/png"),
		kind = strings.clone("image"), size = len(png_text), blob = strings.clone(blob),
	}
	items[1].role = "user"
	items[1].content = strings.clone("second")
	items[1].attachments = make([]Attachment, 1)
	items[1].attachments[0] = Attachment{
		name = strings.clone("a.png"), mime = strings.clone("image/png"),
		kind = strings.clone("image"), size = len(png_text), blob = strings.clone(blob),
	}
	items[2].role = "user"
	items[2].content = strings.clone("third")
	items[2].attachments = make([]Attachment, 1)
	items[2].attachments[0] = Attachment{
		name = strings.clone("old.png"), kind = strings.clone("image"),
		size = 1234, blob = strings.clone(blob), omitted = true,
	}
	defer harness_free_items(items)

	input := build_input_with_store(items, &store)
	defer {
		for v in input do json.destroy_value(v)
		delete(input)
	}
	if !testing.expect_value(t, len(input), 3) do return
	second, _ := jobj(input[1])
	second_parts, _ := jarr(jget(second, "content"))
	if !testing.expect_value(t, len(second_parts), 2) do return
	second_img, _ := jobj(second_parts[1])
	testing.expect_value(t, jstr(jget(second_img, "type")), "input_image")
	third, _ := jobj(input[2])
	third_parts, _ := jarr(jget(third, "content"))
	if !testing.expect_value(t, len(third_parts), 2) do return
	omit, _ := jobj(third_parts[1])
	testing.expect_value(t, jstr(jget(omit, "type")), "input_text")
	testing.expect(t, strings.contains(jstr(jget(omit, "text")), "omitted"))
}

@(test)
test_internal_tools_are_registered :: proc(t: ^testing.T) {
	tools := internal_tools()
	defer tools_destroy(&tools)
	if !testing.expect_value(t, len(tools), 2) do return
	found_attach := false
	found_output := false
	for tool in tools {
		if tool.name == RECALL_ATTACHMENT_TOOL && tool.kind == .Recall_Attachment do found_attach = true
		if tool.name == RECALL_OUTPUT_TOOL && tool.kind == .Recall_Output do found_output = true
	}
	testing.expect(t, found_attach)
	testing.expect(t, found_output)
}

@(test)
test_archive_packs_and_reads_attachment_blobs :: proc(t: ^testing.T) {
	root := test_temp_root("archive")
	defer delete(root)
	if !testing.expectf(t, os.make_directory_all(root) == nil, "creating %s", root) do return
	defer os.remove_all(root)
	path := join_path(root, "session.jsonl")
	defer delete(path)
	store := attachment_store_init(path)
	defer attachment_store_destroy(&store)

	att_text := "attachment data"
	att_blob, aerr := attachment_store_put(&store, transmute([]byte)att_text)
	if !testing.expect_value(t, aerr, "") do return
	defer delete(att_blob)
	out_text := "tool output data"
	out_blob, oerr := attachment_store_put(&store, transmute([]byte)out_text)
	if !testing.expect_value(t, oerr, "") do return
	defer delete(out_blob)

	s := session_init(path)
	s.items = make([dynamic]StoredItem, 0, 2)
	append(&s.items, StoredItem{
		role = "user",
		content = strings.clone("hello"),
		attachments = make([]Attachment, 1),
	})
	s.items[0].attachments[0] = Attachment{
		name = strings.clone("a.txt"), mime = strings.clone("text/plain"),
		kind = strings.clone("text"), size = len(att_text), blob = strings.clone(att_blob),
	}
	append(&s.items, StoredItem{
		role = "function_call",
		call_id = strings.clone("c1"),
		name = strings.clone("probe"),
		arguments = strings.clone("{}"),
	})
	append(&s.items, StoredItem{
		role = "function_call_output",
		call_id = strings.clone("c1"),
		output_blob = strings.clone(out_blob),
		output_size = len(out_text),
		output_omitted = true,
	})
	testing.expect_value(t, session_rewrite(&s), "")
	session_destroy(&s)

	entries := make([dynamic]Archive_Entry, 0, 4)
	defer archive_entries_destroy(entries[:])
	cerr := archive_collect_blobs([]string{path}, &store, &entries)
	if !testing.expect_value(t, cerr, "") do return
	testing.expect_value(t, len(entries), 2)
	target := join_path(root, "archive.tar.gz")
	defer delete(target)
	testing.expect_value(t, archive_pack(target, []string{path}, entries[:]), "")

	read, aerr2 := archive_read(target)
	if !testing.expect_value(t, aerr2, "") do return
	defer archive_entries_destroy(read)
	found := false
	for e in read {
		id, is_blob := archive_attachment_id(e.name)
		if !is_blob do continue
		found = true
		if id == att_blob do testing.expect_value(t, e.content, att_text)
		if id == out_blob do testing.expect_value(t, e.content, out_text)
	}
	testing.expect(t, found)

	items, rerr := harness_read_archive_items(target)
	if !testing.expect_value(t, rerr, "") do return
	defer harness_free_items(items)
	testing.expect_value(t, len(items), 3)
}

@(test)
test_policy_protects_whole_current_tool_batch :: proc(t: ^testing.T) {
	cfg := test_policy_config()
	session := Session{}
	session.items = make([dynamic]StoredItem, 0, 3)
	defer session_destroy(&session)
	blob1 := fake_blob(21)
	blob2 := fake_blob(22)
	append(&session.items, StoredItem{role = "user", content = strings.clone("prompt")})
	atts1 := make([]Attachment, 1)
	atts1[0] = Attachment{blob = blob1, kind = strings.clone("image"), size = 5 * 1024 * 1024}
	append(&session.items, StoredItem{
		role = "function_call_output",
		call_id = strings.clone("r1"),
		attachments = atts1,
		recalled = true,
	})
	atts2 := make([]Attachment, 1)
	atts2[0] = Attachment{blob = blob2, kind = strings.clone("image"), size = 5 * 1024 * 1024}
	append(&session.items, StoredItem{
		role = "function_call_output",
		call_id = strings.clone("r2"),
		attachments = atts2,
	})

	changed, notes := attachment_policy_apply(&cfg, &session)
	testing.expect(t, !changed)
	delete(notes)
	testing.expect_value(t, session.items[1].attachments[0].omitted, false)
	testing.expect_value(t, session.items[2].attachments[0].omitted, false)
}
