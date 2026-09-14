package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	openai "github.com/sashabaranov/go-openai"
)

// fakeTool writes an executable that answers TGI SCHEMA with the given tool
// name, so discovery can be exercised without a provider or a real tool.
func fakeTool(t *testing.T, dir, file, name string) string {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, file)
	script := fmt.Sprintf("#!/bin/sh\n"+
		"if [ \"$TGI_METHOD\" = SCHEMA ]; then\n"+
		"  printf '{\"name\":\"%s\",\"description\":\"fake\",\"parameters\":{\"type\":\"object\"}}'\n"+
		"fi\n", name)
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

// TestDiscoverToolsDirs covers which directories tools come from and which
// definition survives a name collision: the project-local tool wins over the
// installed one, and the tool is advertised once.
func TestDiscoverToolsDirs(t *testing.T) {
	config := configFixture(t)
	root := t.TempDir()
	t.Chdir(root)
	state := filepath.Join(root, stateDir)

	// The base set: two tools, one of which the project will override. The
	// override is by the name the tool declares, not by its file name, so
	// both files declare "bash" and the later directory wins.
	base := filepath.Join(config, toolsDir)
	fakeTool(t, base, "bash", "bash")
	fakeTool(t, base, "search", "search")

	// The project set: an override of bash, and a tool of its own. Also a
	// non-executable file and a subdirectory, neither of which is a tool.
	local := filepath.Join(state, toolsDir)
	fakeTool(t, local, "bash", "bash")
	fakeTool(t, local, "deploy", "deploy")
	if err := os.WriteFile(filepath.Join(local, "README.md"), []byte("not a tool\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(local, "nested"), 0o755); err != nil {
		t.Fatal(err)
	}

	discoveredTools = map[string]ToolDef{}
	defs := discoverTools(context.Background())

	names := map[string]int{}
	for _, d := range defs {
		names[toolName(d)]++
	}
	for _, want := range []string{"bash", "search", "deploy"} {
		if names[want] != 1 {
			t.Fatalf("tool %q seen %d times in %v, want once", want, names[want], names)
		}
	}
	if len(defs) != 3 {
		t.Fatalf("discovered %d tools (%v), want 3", len(defs), names)
	}

	// Execution follows the same precedence: the name the model calls
	// resolves to the project-local file, not the installed one.
	def, ok := discoveredTools["bash"]
	if !ok {
		t.Fatal("bash is not callable")
	}
	// The project-local directory is the project's .miagent, so the recorded
	// path is relative to the working directory (the test chdirs into it).
	if want := filepath.Join(stateDir, toolsDir, "bash"); def.ExecPath != want {
		t.Fatalf("bash executes %q, want the project-local %q", def.ExecPath, want)
	}
	if def.ExecPath == filepath.Join(config, toolsDir, "bash") {
		t.Fatal("bash still points at the installed copy")
	}
}

// TestDiscoverToolsWithoutLocalDir covers the ordinary cases: no project-local
// directory at all, and neither directory present.
func TestDiscoverToolsWithoutLocalDir(t *testing.T) {
	config := configFixture(t)
	root := t.TempDir()
	t.Chdir(root)

	t.Run("base only", func(t *testing.T) {
		fakeTool(t, filepath.Join(config, toolsDir), "bash", "bash")
		discoveredTools = map[string]ToolDef{}
		defs := discoverTools(context.Background())
		if len(defs) != 1 || toolName(defs[0]) != "bash" {
			t.Fatalf("defs = %v, want the one base tool", defs)
		}
	})

	t.Run("neither directory", func(t *testing.T) {
		if err := os.RemoveAll(filepath.Join(config, toolsDir)); err != nil {
			t.Fatal(err)
		}
		discoveredTools = map[string]ToolDef{}
		if defs := discoverTools(context.Background()); len(defs) != 0 {
			t.Fatalf("defs = %v, want none, and no error", defs)
		}
	})
}

// TestDiscoverToolsSkipsBrokenTool covers a tool that cannot describe itself:
// it is reported and skipped, and the tools beside it still load.
func TestDiscoverToolsSkipsBrokenTool(t *testing.T) {
	config := configFixture(t)
	t.Chdir(t.TempDir())

	base := filepath.Join(config, toolsDir)
	fakeTool(t, base, "good", "good")
	if err := os.WriteFile(filepath.Join(base, "broken"), []byte("#!/bin/sh\nexit 3\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	discoveredTools = map[string]ToolDef{}
	defs := discoverTools(context.Background())
	if len(defs) != 1 || toolName(defs[0]) != "good" {
		t.Fatalf("defs = %v, want just the working tool", defs)
	}
}

// TestToolsDirs covers the directories themselves and their order, since the
// order is what gives the project-local set its precedence.
func TestToolsDirs(t *testing.T) {
	config := configFixture(t)
	t.Chdir(t.TempDir())

	dirs, err := toolsDirs(stateDir)
	if err != nil {
		t.Fatalf("toolsDirs: %v", err)
	}
	if len(dirs) != 2 {
		t.Fatalf("toolsDirs = %v, want two directories", dirs)
	}
	if want := filepath.Join(config, toolsDir); dirs[0] != want {
		t.Fatalf("first dir = %q, want the configuration directory %q", dirs[0], want)
	}
	if want := filepath.Join(stateDir, toolsDir); dirs[1] != want {
		t.Fatalf("second dir = %q, want the state directory %q", dirs[1], want)
	}
	if !strings.HasPrefix(dirs[0], config) || !strings.HasSuffix(dirs[1], filepath.Join(stateDir, toolsDir)) {
		t.Fatalf("dirs = %v, want base then project-local", dirs)
	}
}

// TestRunTGIToolPassesConfigDir covers the canonical path reaching tools: a
// tool inherits the harness environment, so MIAGENT_CONFIG_DIR is available
// without the tool repeating the XDG resolution.
func TestRunTGIToolPassesConfigDir(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "printconfig")
	script := "#!/bin/sh\nprintf '%s' \"$MIAGENT_CONFIG_DIR\"\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv(configDirEnv, "/some/canonical/config")

	r := RunTGITool(context.Background(), "printconfig", path, "INVOKE", nil, nil, nil)
	if r.Err != nil {
		t.Fatalf("RunTGITool: %v", r.Err)
	}
	if r.Code != 0 || r.Stdout != "/some/canonical/config" {
		t.Fatalf("stdout = %q, code = %d; want the config dir", r.Stdout, r.Code)
	}
}

// toolName reads a Responses tool's name back out of its parameters, which is
// where the SDK's inline function representation carries it.
func toolName(t openai.ResponseTool) string {
	name, _ := t.Parameters["name"].(string)
	return name
}

// TestBashToolRunsInItsWorkingDirectory covers the shipped tool where it is
// easiest to get wrong: the sandbox mounts a fresh /tmp, and bwrap applies its
// mounts in order, so that mount has to come before the working directory is
// bound. The other way round, a working directory under /tmp — which is where
// TMPDIR points on Linux — is shadowed by the tmpfs and the tool cannot even
// chdir into it.
func TestBashToolRunsInItsWorkingDirectory(t *testing.T) {
	for _, dep := range []string{"bwrap", "jq"} {
		if _, err := exec.LookPath(dep); err != nil {
			t.Skipf("%s is not installed", dep)
		}
	}
	tool, err := filepath.Abs(filepath.Join(toolsDir, "bash"))
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir() // under TMPDIR, i.e. /tmp on Linux
	t.Chdir(dir)

	res := RunTGITool(context.Background(), "bash", tool, "INVOKE",
		strings.NewReader(`{"command":"pwd"}`), nil, nil)
	if res.Err != nil {
		t.Fatalf("running the bash tool: %v", res.Err)
	}
	if res.Code != 0 {
		t.Fatalf("bash tool exited %d: %s", res.Code, res.Stderr)
	}
	want, err := filepath.EvalSymlinks(dir)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(res.Stdout); got != want {
		t.Fatalf("the tool ran in %q, want %q", got, want)
	}
}
