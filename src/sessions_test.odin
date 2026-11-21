package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
test_session_names_round_trip_and_new_file_naming :: proc(t: ^testing.T) {
	root := fmt.aprintf("/tmp/miagent-tabs-test-%d", time.to_unix_nanoseconds(time.now()))
	defer delete(root)
	if !testing.expectf(t, os.make_directory_all(root) == nil, "creating %s", root) do return
	defer os.remove_all(root)

	state_dir := fmt.aprintf("%s/.miagent", root)
	defer delete(state_dir)
	if !testing.expect(t, os.make_directory_all(state_dir) == nil) do return

	p := Project{path = root, active_tab = 0}
	p.tabs = make([dynamic]^Conversation_Tab, 0, 2)
	defer {
		for tab in p.tabs {
			delete(tab.session_path)
			delete(tab.name)
			free(tab)
		}
		delete(p.tabs)
	}

	default_path := fmt.aprintf("%s/session.jsonl", state_dir)
	defer delete(default_path)
	second_path := fmt.aprintf("%s/session-2.jsonl", state_dir)
	defer delete(second_path)
	default_tab := new(Conversation_Tab)
	default_tab.session_path = strings.clone(default_path)
	default_tab.name = strings.clone("Work notes")
	second_tab := new(Conversation_Tab)
	second_tab.session_path = strings.clone(second_path)
	second_tab.name = strings.clone("Research")
	append(&p.tabs, default_tab, second_tab)

	if err := project_session_names_save(&p); err != "" {
		testing.fail_now(t, err)
	}
	names, err := project_session_names_load(&p)
	if err != "" {
		testing.fail_now(t, err)
	}
	defer gui_session_names_destroy(&names)
	if !testing.expect_value(t, len(names.sessions), 2) do return
	testing.expect_value(t, names.sessions[0].file, "session.jsonl")
	testing.expect_value(t, names.sessions[0].name, "Work notes")
	testing.expect_value(t, names.sessions[1].file, "session-2.jsonl")
	testing.expect_value(t, names.sessions[1].name, "Research")

	// session.jsonl exists, so the next tab is session-2.jsonl (which does not
	// exist yet in this test), not a collision with the default file.
	if write_err := os.write_entire_file_from_string(default_path, ""); write_err != nil {
		testing.fail_now(t, fmt.aprintf("creating default session: %v", write_err))
	}
	next := project_next_session_path(&p)
	defer delete(next)
	next_name := session_name_from_path(next, false)
	defer delete(next_name)
	testing.expect_value(t, os.base(next), "session-3.jsonl")
	testing.expect_value(t, next_name, "Session 3")
}

// Closing a tab removes its GUI name and keeps the project's active index
// coherent. Preview mode is used here so the test does not need to start a
// harness worker for the replacement tab.
@(test)
test_project_close_tab_removes_names_and_selects_neighbor :: proc(t: ^testing.T) {
	root := fmt.aprintf("/tmp/miagent-close-tab-test-%d", time.to_unix_nanoseconds(time.now()))
	defer delete(root)
	if !testing.expectf(t, os.make_directory_all(root) == nil, "creating %s", root) do return
	defer os.remove_all(root)
	state_dir := fmt.aprintf("%s/.miagent", root)
	defer delete(state_dir)
	if !testing.expect(t, os.make_directory_all(state_dir) == nil) do return

	first_path := fmt.aprintf("%s/session.jsonl", state_dir)
	defer delete(first_path)
	second_path := fmt.aprintf("%s/session-2.jsonl", state_dir)
	defer delete(second_path)

	p := Project{path = root, active_tab = 0}
	p.tabs = make([dynamic]^Conversation_Tab, 0, 2)
	defer {
		for tab in p.tabs do conversation_tab_destroy(tab)
		delete(p.tabs)
	}
	first := new(Conversation_Tab)
	conversation_tab_init(first, first_path, "First")
	second := new(Conversation_Tab)
	conversation_tab_init(second, second_path, "Second")
	append(&p.tabs, first, second)

	app := App{selected_project = 0, preview_active = true}
	app.projects = make([dynamic]^Project, 1)
	defer delete(app.projects)
	app.projects[0] = &p

	project_close_tab(&app, &p, 0)
	if !testing.expect_value(t, len(p.tabs), 1) do return
	if !testing.expect(t, p.tabs[0] == second, "the second tab must become active") do return
	testing.expect_value(t, p.active_tab, 0)

	names, err := project_session_names_load(&p)
	if len(err) > 0 {
		testing.fail_now(t, err)
	}
	defer gui_session_names_destroy(&names)
	if !testing.expect_value(t, len(names.sessions), 1) do return
	testing.expect_value(t, names.sessions[0].file, "session-2.jsonl")

	project_close_tab(&app, &p, 0)
	testing.expect_value(t, len(p.tabs), 0)
	testing.expect_value(t, p.active_tab, -1)

	names_after, err_after := project_session_names_load(&p)
	if len(err_after) > 0 {
		testing.fail_now(t, err_after)
	}
	defer gui_session_names_destroy(&names_after)
	testing.expect_value(t, len(names_after.sessions), 0)
}
