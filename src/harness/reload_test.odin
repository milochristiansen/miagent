package harness

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

request_body_for_test :: proc(h: ^Harness) -> []byte {
	input := build_input(h.session.items[:])
	tools := build_tools(h.tools)
	request := Request{
		model = h.config.model,
		instructions = h.config.instructions,
		input = input,
		tools = tools,
		stream = true,
	}
	body, err := marshal_request(request)
	for v in tools do json.destroy_value(v)
	delete(tools)
	for v in input do json.destroy_value(v)
	delete(input)
	if err != nil do return nil
	return body
}

// A long-lived harness must pick up prompt and tool changes at the next turn.
// The active session path is deliberately preserved so a changed
// MIAGENT_SESSION cannot switch conversations under the caller's feet.
@(test)
test_reload_refreshes_instructions_and_tools_but_keeps_session :: proc(t: ^testing.T) {
	root := fmt.aprintf("/tmp/miagent-reload-test-%d", time.to_unix_nanoseconds(time.now()))
	defer delete(root)
	if !testing.expectf(t, os.make_directory_all(root) == nil, "creating %s", root) do return
	defer os.remove_all(root)

	config_dir := join_path(root, "config")
	project_dir := join_path(root, "project")
	tools_dir := join_path(config_dir, TOOLS_DIR)
	prompts_dir := join_path(config_dir, PROMPTS_DIR)
	state_dir := join_path(project_dir, STATE_DIR)
	defer {
		delete(config_dir)
		delete(project_dir)
		delete(tools_dir)
		delete(prompts_dir)
		delete(state_dir)
	}
	if !testing.expect(t, os.make_directory_all(tools_dir) == nil) do return
	if !testing.expect(t, os.make_directory_all(prompts_dir) == nil) do return
	if !testing.expect(t, os.make_directory_all(state_dir) == nil) do return

	system_path := join_path(prompts_dir, "SYSTEM.md")
	tool_path := join_path(tools_dir, "reload-tool")
	defer {
		delete(system_path)
		delete(tool_path)
	}
	if err := os.write_entire_file_from_string(system_path, "first system prompt"); err != nil {
		testing.fail_now(t, fmt.aprintf("writing SYSTEM.md: %v", err))
	}

	// Point this harness at the temporary installation. No other harness test
	// reads MIAGENT_CONFIG_DIR, so changing it for the duration is safe.
	old_config_dir, had_config_dir := os.lookup_env(CONFIG_DIR_ENV, context.temp_allocator)
	os.set_env(CONFIG_DIR_ENV, config_dir)
	defer {
		if had_config_dir {
			os.set_env(CONFIG_DIR_ENV, old_config_dir)
		} else {
			os.unset_env(CONFIG_DIR_ENV)
		}
	}

	h: Harness
	if err := harness_init_project(&h, project_dir); err != "" {
		testing.fail_now(t, fmt.aprintf("harness_init_project: %s", err))
	}
	defer harness_destroy(&h)

	original_session := strings.clone(h.session.path)
	defer delete(original_session)
	testing.expect(t, strings.contains(h.config.instructions, "first system prompt"))
	testing.expect_value(t, harness_tool_count(&h), 0)

	// Change both a prompt document and the tool directory between turns.
	if err := os.write_entire_file_from_string(system_path, "second system prompt"); err != nil {
		testing.fail_now(t, fmt.aprintf("rewriting SYSTEM.md: %v", err))
	}
	tool_schema := `#!/bin/sh
printf '%s\n' '{"name":"reload-tool","description":"freshly discovered","parameters":{"type":"object"}}'
`
	if err := os.write_entire_file_from_string(tool_path, tool_schema,
		os.Permissions_Read_All + {.Write_User, .Execute_User}); err != nil {
		testing.fail_now(t, fmt.aprintf("writing tool: %v", err))
	}

	h_reload_runtime(&h, true)

	testing.expect(t, strings.contains(h.config.instructions, "second system prompt"))
	testing.expect_value(t, harness_tool_count(&h), 1)
	testing.expect_value(t, h.config.session_path, original_session)
	testing.expect_value(t, h.session.path, original_session)

	// Reloading with nothing changed must not perturb the request cache prefix:
	// identical instructions, tool order, schemas, and sorted JSON keys.
	session_append_item(&h.session, StoredItem{role = "user", content = strings.clone("hello")})
	session_append_item(&h.session, StoredItem{role = "assistant", content = strings.clone("hi")})
	first_body := request_body_for_test(&h)
	defer delete(first_body)
	h_reload_runtime(&h, true)
	second_body := request_body_for_test(&h)
	defer delete(second_body)
	testing.expect(t, first_body != nil && second_body != nil)
	testing.expectf(t, string(first_body) == string(second_body),
		"request body changed across identical reloads")
}
