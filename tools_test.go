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

// fakeMultiTool writes an executable that answers TGI SCHEMA with one JSON
// schema per line, so a single binary can expose several tools. On INVOKE it
// prints the TGI_TOOL it was called with, which lets a test confirm that each
// declared name dispatches back to the same executable.
func fakeMultiTool(t *testing.T, dir, file string, names ...string) string {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, file)
	script := "#!/bin/sh\n" +
		"if [ \"$TGI_METHOD\" = SCHEMA ]; then\n"
	for _, name := range names {
		script += fmt.Sprintf(`  printf '{"name":"%s","description":"fake","parameters":{"type":"object"}}\n'`+"\n", name)
	}
	script += "elif [ \"$TGI_METHOD\" = INVOKE ]; then\n" +
		"  printf '%s' \"$TGI_TOOL\"\n" +
		"fi\n"
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

// TestBashToolGivesGoAWritableBuildCache covers the XDG cache default: Go's
// build cache lives under the user's cache home, which the sandbox mounts
// read-only, so a build would fail before it starts. The tool binds that home
// writable, so Go's own default cache works and is shared between calls.
// XDG_CACHE_HOME points at a temp directory so the test does not disturb the
// runner's cache.
func TestBashToolGivesGoAWritableBuildCache(t *testing.T) {
	for _, dep := range []string{"bwrap", "jq", "go"} {
		if _, err := exec.LookPath(dep); err != nil {
			t.Skipf("%s is not installed", dep)
		}
	}
	tool, err := filepath.Abs(filepath.Join(toolsDir, "bash"))
	if err != nil {
		t.Fatal(err)
	}
	cacheHome := t.TempDir()
	t.Setenv("XDG_CACHE_HOME", cacheHome)
	// Let Go resolve its own default rather than inheriting a cache the runner
	// happens to name.
	t.Setenv("GOCACHE", "")
	t.Chdir(t.TempDir())

	res := RunTGITool(context.Background(), "bash", tool, "INVOKE",
		strings.NewReader(`{"command":"cache=$(go env GOCACHE) && mkdir -p \"$cache\" && : > \"$cache/probe\" && printf '%s' \"$cache\""}`), nil, nil)
	if res.Err != nil {
		t.Fatalf("running the bash tool: %v", res.Err)
	}
	if res.Code != 0 {
		t.Fatalf("bash tool exited %d: %s", res.Code, res.Stderr)
	}
	want := filepath.Join(cacheHome, "go-build")
	if got := strings.TrimSpace(res.Stdout); got != want {
		t.Fatalf("GOCACHE = %q, want the cache under the bound home %q", got, want)
	}
	// The probe was written inside the sandbox; finding it on the host proves
	// the cache home was bound writable.
	if _, err := os.Stat(filepath.Join(want, "probe")); err != nil {
		t.Fatalf("the cache home was not writable from the sandbox: %v", err)
	}
}

// TestBashToolBindsConfiguredCaches covers MIAGENT_BASH_RW: its colon-separated
// entries replace the built-in language list, a leading ~ is expanded, and each
// is created and bound writable. The XDG cache home is bound regardless.
func TestBashToolBindsConfiguredCaches(t *testing.T) {
	for _, dep := range []string{"bwrap", "jq"} {
		if _, err := exec.LookPath(dep); err != nil {
			t.Skipf("%s is not installed", dep)
		}
	}
	tool, err := filepath.Abs(filepath.Join(toolsDir, "bash"))
	if err != nil {
		t.Fatal(err)
	}
	cacheA := filepath.Join(t.TempDir(), "a") // left missing for the tool to create
	home := t.TempDir()
	cacheB := filepath.Join(home, ".rw-cache")
	cacheHome := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("MIAGENT_BASH_RW", cacheA+":~/.rw-cache")
	t.Setenv("TEST_CACHE_A", cacheA)
	t.Setenv("TEST_CACHE_B", cacheB)
	t.Setenv("XDG_CACHE_HOME", cacheHome)
	t.Setenv("GOCACHE", "")
	t.Chdir(t.TempDir())

	res := RunTGITool(context.Background(), "bash", tool, "INVOKE",
		strings.NewReader(`{"command":"printf a > \"$TEST_CACHE_A/a\" && printf b > \"$TEST_CACHE_B/b\" && printf x > \"$XDG_CACHE_HOME/x\""}`), nil, nil)
	if res.Err != nil {
		t.Fatalf("running the bash tool: %v", res.Err)
	}
	if res.Code != 0 {
		t.Fatalf("bash tool exited %d: %s", res.Code, res.Stderr)
	}
	for _, f := range []string{
		filepath.Join(cacheA, "a"),
		filepath.Join(cacheB, "b"),
		filepath.Join(cacheHome, "x"),
	} {
		if _, err := os.Stat(f); err != nil {
			t.Fatalf("%s was not writable from the sandbox: %v", f, err)
		}
	}
}

// TestBashToolBindsDefaultLanguageCaches covers the built-in list: a language
// cache directory, here CARGO_HOME pointing at an existing directory, is bound
// writable with MIAGENT_BASH_RW unset.
func TestBashToolBindsDefaultLanguageCaches(t *testing.T) {
	for _, dep := range []string{"bwrap", "jq"} {
		if _, err := exec.LookPath(dep); err != nil {
			t.Skipf("%s is not installed", dep)
		}
	}
	tool, err := filepath.Abs(filepath.Join(toolsDir, "bash"))
	if err != nil {
		t.Fatal(err)
	}
	cargoHome := t.TempDir()
	t.Setenv("MIAGENT_BASH_RW", "")
	t.Setenv("CARGO_HOME", cargoHome)
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	t.Chdir(t.TempDir())

	res := RunTGITool(context.Background(), "bash", tool, "INVOKE",
		strings.NewReader(`{"command":"printf c > \"$CARGO_HOME/c\""}`), nil, nil)
	if res.Err != nil {
		t.Fatalf("running the bash tool: %v", res.Err)
	}
	if res.Code != 0 {
		t.Fatalf("bash tool exited %d: %s", res.Code, res.Stderr)
	}
	if _, err := os.Stat(filepath.Join(cargoHome, "c")); err != nil {
		t.Fatalf("the language cache was not writable from the sandbox: %v", err)
	}
}

// TestDiscoverToolsMultiplePerBinary covers one binary declaring several tools
// as JSON Lines: every declared name becomes callable, and each points back at
// the single executable that provides them.
func TestDiscoverToolsMultiplePerBinary(t *testing.T) {
	config := configFixture(t)
	t.Chdir(t.TempDir())

	path := fakeMultiTool(t, filepath.Join(config, toolsDir), "multi", "alpha", "beta")

	discoveredTools = map[string]ToolDef{}
	defs := discoverTools(context.Background())
	if len(defs) != 2 {
		t.Fatalf("discovered %d tools, want 2", len(defs))
	}

	for _, name := range []string{"alpha", "beta"} {
		def, ok := discoveredTools[name]
		if !ok {
			t.Fatalf("tool %q not discovered", name)
		}
		if def.ExecPath != path {
			t.Fatalf("tool %q executes %q, want %q", name, def.ExecPath, path)
		}
	}
}

// TestExecuteToolDispatchesByName covers the call half of a multi-tool binary:
// the harness passes the declared name in TGI_TOOL, so the one executable can
// tell its own tools apart.
func TestExecuteToolDispatchesByName(t *testing.T) {
	config := configFixture(t)
	t.Chdir(t.TempDir())

	fakeMultiTool(t, filepath.Join(config, toolsDir), "multi", "alpha", "beta")

	discoveredTools = map[string]ToolDef{}
	discoverTools(context.Background())

	for _, name := range []string{"alpha", "beta"} {
		r, _ := executeTool(context.Background(), name, "{}", nil, nil)
		if r.Err != nil {
			t.Fatalf("%s: %v", name, r.Err)
		}
		if r.Code != 0 || r.Stdout != name {
			t.Fatalf("%s: stdout = %q, code = %d; want the declared name", name, r.Stdout, r.Code)
		}
	}
}

// TestDiscoverToolsPrettyPrintedSchema covers the documented single-schema
// form, a pretty-printed JSON object spanning several lines. It must keep
// working now that output is otherwise read as JSON Lines.
func TestDiscoverToolsPrettyPrintedSchema(t *testing.T) {
	config := configFixture(t)
	t.Chdir(t.TempDir())

	base := filepath.Join(config, toolsDir)
	if err := os.MkdirAll(base, 0o755); err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/sh\n" +
		"if [ \"$TGI_METHOD\" = SCHEMA ]; then\n" +
		"  cat <<'EOF'\n" +
		"{\n" +
		"  \"name\": \"pretty\",\n" +
		"  \"description\": \"fake\",\n" +
		"  \"parameters\": {\"type\": \"object\"}\n" +
		"}\n" +
		"EOF\n" +
		"fi\n"
	if err := os.WriteFile(filepath.Join(base, "pretty"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}

	discoveredTools = map[string]ToolDef{}
	defs := discoverTools(context.Background())
	if len(defs) != 1 || toolName(defs[0]) != "pretty" {
		t.Fatalf("defs = %v, want the one pretty-printed tool", defs)
	}
}

// TestDiscoverToolsRejectsBadBatch covers a binary whose JSONL batch contains a
// declaration without a name: the batch is rejected whole, so the binary
// contributes none of its tools, while a well-formed binary beside it loads.
func TestDiscoverToolsRejectsBadBatch(t *testing.T) {
	config := configFixture(t)
	t.Chdir(t.TempDir())

	base := filepath.Join(config, toolsDir)
	fakeMultiTool(t, base, "good", "alpha", "beta")

	bad := filepath.Join(base, "bad")
	script := "#!/bin/sh\n" +
		"if [ \"$TGI_METHOD\" = SCHEMA ]; then\n" +
		"  printf '{\"name\":\"gamma\"}\\n{\"description\":\"no name\"}\\n'\n" +
		"fi\n"
	if err := os.WriteFile(bad, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}

	discoveredTools = map[string]ToolDef{}
	defs := discoverTools(context.Background())
	if len(defs) != 2 || toolName(defs[0]) != "alpha" || toolName(defs[1]) != "beta" {
		t.Fatalf("defs = %v, want only the well-formed binary's tools", defs)
	}
	if _, ok := discoveredTools["gamma"]; ok {
		t.Fatal("gamma was loaded from a batch that should have been rejected")
	}
}
