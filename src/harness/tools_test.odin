package harness

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// A tool can declare valid schemas and still report warnings on stderr. Those
// warnings must reach the user instead of being discarded with the schema
// process's output.
@(test)
test_fetch_tool_metas_returns_success_stderr_as_warnings :: proc(t: ^testing.T) {
	root := fmt.aprintf("/tmp/miagent-tool-warning-test-%d", time.to_unix_nanoseconds(time.now()))
	defer delete(root)
	if !testing.expectf(t, os.make_directory_all(root) == nil, "creating %s", root) do return
	defer os.remove_all(root)

	tool_path := join_path(root, "warning-tool")
	defer delete(tool_path)
	script := `#!/bin/sh
printf '%s\n' '{"name":"warning-tool","description":"declares one tool","parameters":{"type":"object"}}'
printf '%s\n' 'shadowed skill warning' >&2
exit 0
`
	if err := os.write_entire_file_from_string(tool_path, script,
		os.Permissions_Read_All + {.Write_User, .Execute_User}); err != nil {
		testing.fail_now(t, fmt.aprintf("writing %s: %v", tool_path, err))
	}

	cfg := Config{
		project_dir = strings.clone(root),
		config_dir = strings.clone(root),
		state_dir = join_path(root, STATE_DIR),
		env = make(map[string]string, 0),
	}
	defer config_destroy(&cfg)

	tools, warnings, err := fetch_tool_metas(&cfg, tool_path)
	defer tools_destroy(&tools)
	defer delete(warnings)
	if !testing.expect_value(t, err, "") do return
	if !testing.expect_value(t, len(tools), 1) do return
	testing.expect_value(t, tools[0].name, "warning-tool")
	testing.expect(t, strings.contains(warnings, "shadowed skill warning"))
}
