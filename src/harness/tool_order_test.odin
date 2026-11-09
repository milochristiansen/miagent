package harness

import "core:encoding/json"
import "core:testing"

input_kind_for_test :: proc(v: json.Value) -> string {
	o, ok := jobj(v)
	if !ok do return ""
	return jstr(jget(o, "type"))
}

input_call_id_for_test :: proc(v: json.Value) -> string {
	o, ok := jobj(v)
	if !ok do return ""
	return jstr(jget(o, "call_id"))
}

input_text_for_test :: proc(v: json.Value) -> string {
	o, ok := jobj(v)
	if !ok do return ""
	parts, pok := jarr(jget(o, "content"))
	if !pok || len(parts) == 0 do return ""
	part, qok := jobj(parts[0])
	if !qok do return ""
	return jstr(jget(part, "text"))
}

// Strict Responses API implementations require every function_call to be
// followed immediately by its function_call_output. A nugget is sent as a user
// message, so it must not be emitted between a call block and the later call's
// output.
@(test)
test_nugget_does_not_split_calls_from_outputs :: proc(t: ^testing.T) {
	items := []StoredItem{
		{role = "function_call", call_id = "call_a", name = "first", arguments = "{}"},
		{role = "function_call", call_id = "call_b", name = "second", arguments = "{}"},
		{role = "function_call_output", call_id = "call_a", output = "result A"},
		{role = "nugget", name = "skills/test.md", content = "# Skill"},
		{role = "function_call_output", call_id = "call_b", output = "result B"},
	}
	input := build_input(items)
	defer {
		for v in input do json.destroy_value(v)
		delete(input)
	}

	if !testing.expect_value(t, len(input), 5) do return
	want_call_ids := [4]string{"call_a", "call_b", "call_a", "call_b"}
	for i in 0 ..< 4 {
		testing.expect_value(t, input_kind_for_test(input[i]), i < 2 ? "function_call" : "function_call_output")
		testing.expect_value(t, input_call_id_for_test(input[i]), want_call_ids[i])
	}
	testing.expect_value(t, input_kind_for_test(input[4]), "message")
	testing.expect(t, len(input_text_for_test(input[4])) > 0)
}

// A call whose output never reached the session (crash, kill, partial write)
// must not poison every later request.
@(test)
test_missing_tool_output_is_synthesized :: proc(t: ^testing.T) {
	items := []StoredItem{
		{role = "function_call", call_id = "call_orphan", name = "probe", arguments = "{}"},
		{role = "user", content = "continue"},
	}
	input := build_input(items)
	defer {
		for v in input do json.destroy_value(v)
		delete(input)
	}

	if !testing.expect_value(t, len(input), 3) do return
	testing.expect_value(t, input_kind_for_test(input[0]), "function_call")
	testing.expect_value(t, input_kind_for_test(input[1]), "function_call_output")
	testing.expect_value(t, input_call_id_for_test(input[1]), "call_orphan")
	testing.expect_value(t, input_kind_for_test(input[2]), "message")
}

// A session that already has the valid call -> output -> call -> output shape
// must keep it: normalization only moves misplaced outputs.
@(test)
test_tool_order_preserves_valid_shape :: proc(t: ^testing.T) {
	items := []StoredItem{
		{role = "function_call", call_id = "call_a", name = "first", arguments = "{}"},
		{role = "function_call_output", call_id = "call_a", output = "result A"},
		{role = "assistant", content = "thinking"},
		{role = "function_call", call_id = "call_b", name = "second", arguments = "{}"},
		{role = "function_call_output", call_id = "call_b", output = "result B"},
	}
	input := build_input(items)
	defer {
		for v in input do json.destroy_value(v)
		delete(input)
	}
	if !testing.expect_value(t, len(input), 5) do return
	want := [5]string{"call_a", "call_a", "", "call_b", "call_b"}
	for i in 0 ..< 5 {
		if i == 2 {
			testing.expect_value(t, input_kind_for_test(input[i]), "message")
		} else {
			testing.expect_value(t, input_call_id_for_test(input[i]), want[i])
		}
	}
}
