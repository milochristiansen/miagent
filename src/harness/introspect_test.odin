package harness

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

// The details view must be able to say that a required prompt is missing, so
// prompt_docs lists well-known documents whether or not they exist, and adds
// the project's and .miagent's AGENTS.md files.
@(test)
test_prompt_docs_list_known_and_missing_documents :: proc(t: ^testing.T) {
	dir := fmt.aprintf("/tmp/miagent-introspect-test-%d", time.to_unix_nanoseconds(time.now()))
	defer delete(dir)
	if !testing.expectf(t, os.make_directory_all(dir) == nil, "creating %s", dir) do return
	defer os.remove_all(dir)

	config_dir := join_path(dir, "config")
	project_dir := join_path(dir, "project")
	state_dir := join_path(project_dir, STATE_DIR)
	prompts_dir := join_path(config_dir, PROMPTS_DIR)
	defer {
		delete(config_dir)
		delete(project_dir)
		delete(state_dir)
		delete(prompts_dir)
	}
	if !testing.expect(t, os.make_directory_all(prompts_dir) == nil) do return
	if !testing.expect(t, os.make_directory_all(state_dir) == nil) do return

	system_path := join_path(prompts_dir, "SYSTEM.md")
	project_agents := join_path(project_dir, AGENTS_FILE)
	state_agents := join_path(state_dir, AGENTS_FILE)
	defer {
		delete(system_path)
		delete(project_agents)
		delete(state_agents)
	}
	if err := os.write_entire_file_from_string(system_path, "system prompt"); err != nil {
		testing.fail_now(t, fmt.aprintf("writing SYSTEM.md: %v", err))
	}
	if err := os.write_entire_file_from_string(project_agents, "project agents"); err != nil {
		testing.fail_now(t, fmt.aprintf("writing project AGENTS.md: %v", err))
	}
	if err := os.write_entire_file_from_string(state_agents, "state agents"); err != nil {
		testing.fail_now(t, fmt.aprintf("writing state AGENTS.md: %v", err))
	}

	c := Config{config_dir = config_dir, project_dir = project_dir, state_dir = state_dir}
	docs := prompt_docs(&c)
	defer {
		for &d in docs do doc_info_destroy(&d)
		delete(docs)
	}

	system_found, project_found, state_found, continue_found := false, false, false, false
	for d in docs {
		switch d.label {
		case "prompts/SYSTEM.md":
			system_found = true
			testing.expect_value(t, d.content, "system prompt")
			testing.expect(t, d.exists)
			testing.expect(t, d.required)
		case "AGENTS.md · project":
			project_found = true
			testing.expect_value(t, d.content, "project agents")
		case "AGENTS.md · .miagent":
			state_found = true
			testing.expect_value(t, d.content, "state agents")
		case "prompts/CONTINUE.md":
			continue_found = true
			testing.expect(t, !d.exists)
		}
	}
	testing.expect(t, system_found)
	testing.expect(t, project_found)
	testing.expect(t, state_found)
	testing.expect(t, continue_found)
}

// Turn metrics are consumed by the details page even when the UI has already
// drained the event queue, so they need their own copy and lifecycle.
@(test)
test_turn_info_tracks_requests_tools_and_usage :: proc(t: ^testing.T) {
	h := Harness{}
	defer turn_info_destroy(&h.turn)

	turn_info_begin(&h, "inspect the repository")
	turn_info_request(&h, "test-model", "https://example.test/v1/responses", 7, 3, 4096, 1200)
	turn_info_usage(&h, Usage{input_tokens = 100, cached_tokens = 80, output_tokens = 20, total_tokens = 120}, true)
	turn_info_tool_call(&h, "bash")
	turn_info_finish(&h, .Completed, "")

	testing.expect(t, !h.turn.active)
	testing.expect_value(t, h.turn.status, Turn_State.Completed)
	testing.expect_value(t, h.turn.prompt, "inspect the repository")
	testing.expect_value(t, h.turn.model_calls, 1)
	testing.expect_value(t, h.turn.tool_calls, 1)
	testing.expect_value(t, h.turn.last_tool, "bash")
	testing.expect_value(t, h.turn.request.input_items, 7)
	testing.expect_value(t, h.turn.request.tools, 3)
	testing.expect_value(t, h.turn.request.body_bytes, 4096)
	testing.expect_value(t, h.turn.request.instructions_bytes, 1200)
	testing.expect_value(t, h.turn.request.usage.total_tokens, 120)
	testing.expect_value(t, h.turn.turn_usage.total_tokens, 120)
}
