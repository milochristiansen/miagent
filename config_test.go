package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// unsetEnv unsets name for the duration of the test, restoring its original
// value afterwards. Unlike t.Setenv it leaves the variable truly unset, which a
// dotenv value needs in order to be applied.
func unsetEnv(t *testing.T, name string) {
	t.Helper()
	old, ok := os.LookupEnv(name)
	if err := os.Unsetenv(name); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if ok {
			_ = os.Setenv(name, old)
			return
		}
		_ = os.Unsetenv(name)
	})
}

// TestConfigDir covers the config directory resolution: MIAGENT_CONFIG_DIR when
// it is set, XDG_CONFIG_HOME when it holds an absolute path, and ~/.config
// otherwise — the XDG rule being that an empty or relative value is ignored
// rather than resolved against the working directory.
func TestConfigDir(t *testing.T) {
	t.Run("MIAGENT_CONFIG_DIR wins", func(t *testing.T) {
		override := t.TempDir()
		t.Setenv(configDirEnv, override)
		t.Setenv("XDG_CONFIG_HOME", t.TempDir())
		got, err := configDir()
		if err != nil {
			t.Fatalf("configDir: %v", err)
		}
		if got != override {
			t.Fatalf("configDir = %q, want the override %q", got, override)
		}
	})

	t.Run("absolute XDG_CONFIG_HOME", func(t *testing.T) {
		t.Setenv(configDirEnv, "")
		dir := t.TempDir()
		t.Setenv("XDG_CONFIG_HOME", dir)
		got, err := configDir()
		if err != nil {
			t.Fatalf("configDir: %v", err)
		}
		if want := filepath.Join(dir, configName); got != want {
			t.Fatalf("configDir = %q, want %q", got, want)
		}
	})

	t.Run("unset falls back to ~/.config", func(t *testing.T) {
		t.Setenv(configDirEnv, "")
		t.Setenv("XDG_CONFIG_HOME", "")
		home := t.TempDir()
		t.Setenv("HOME", home)
		got, err := configDir()
		if err != nil {
			t.Fatalf("configDir: %v", err)
		}
		if want := filepath.Join(home, ".config", configName); got != want {
			t.Fatalf("configDir = %q, want %q", got, want)
		}
	})

	t.Run("relative is ignored", func(t *testing.T) {
		t.Setenv(configDirEnv, "")
		t.Setenv("XDG_CONFIG_HOME", "relative/path")
		home := t.TempDir()
		t.Setenv("HOME", home)
		got, err := configDir()
		if err != nil {
			t.Fatalf("configDir: %v", err)
		}
		if want := filepath.Join(home, ".config", configName); got != want {
			t.Fatalf("configDir = %q, want the default, not a working-directory path", got)
		}
	})
}

// TestCanonicalConfigDir covers the recording step: an unset MIAGENT_CONFIG_DIR
// is set to the resolved directory so tools inherit it, and an explicit one is
// left as the caller gave it.
func TestCanonicalConfigDir(t *testing.T) {
	t.Run("records the resolved path", func(t *testing.T) {
		root := t.TempDir()
		t.Setenv("XDG_CONFIG_HOME", root)
		t.Setenv(configDirEnv, "")

		got, err := canonicalConfigDir()
		if err != nil {
			t.Fatalf("canonicalConfigDir: %v", err)
		}
		want := filepath.Join(root, configName)
		if got != want {
			t.Fatalf("canonicalConfigDir = %q, want %q", got, want)
		}
		if env := os.Getenv(configDirEnv); env != want {
			t.Fatalf("%s = %q, want the recorded %q", configDirEnv, env, want)
		}
		// configDir now resolves to the recorded value, whatever the XDG
		// variables say.
		t.Setenv("XDG_CONFIG_HOME", t.TempDir())
		if again, err := configDir(); err != nil || again != want {
			t.Fatalf("configDir = %q, %v; want the recorded %q", again, err, want)
		}
	})

	t.Run("keeps an explicit path", func(t *testing.T) {
		override := t.TempDir()
		t.Setenv(configDirEnv, override)
		t.Setenv("XDG_CONFIG_HOME", t.TempDir())

		got, err := canonicalConfigDir()
		if err != nil {
			t.Fatalf("canonicalConfigDir: %v", err)
		}
		want := filepath.Clean(override)
		if got != want {
			t.Fatalf("canonicalConfigDir = %q, want %q", got, want)
		}
		if env := os.Getenv(configDirEnv); env != want {
			t.Fatalf("%s = %q, want it left as given", configDirEnv, env)
		}
	})
}

// TestLoadConfig covers the run's environment: the local .env is read before
// the configuration directory is resolved and the core .env after it, and
// precedence is the process environment, then the local file, then the core.
func TestLoadConfig(t *testing.T) {
	root := t.TempDir()
	t.Chdir(root)
	config := configFixture(t)
	if err := os.Mkdir(stateDir, 0o755); err != nil {
		t.Fatal(err)
	}
	write := func(path, content string) {
		t.Helper()
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write(filepath.Join(config, ".env"), "MIAGENT_TEST_A=core\nMIAGENT_TEST_B=core\n")
	write(filepath.Join(stateDir, ".env"), "MIAGENT_TEST_B=state\nMIAGENT_TEST_C=state\n")

	for _, name := range []string{"MIAGENT_TEST_A", "MIAGENT_TEST_B", "MIAGENT_TEST_C"} {
		unsetEnv(t, name)
	}

	if err := loadConfig(stateDir); err != nil {
		t.Fatalf("loadConfig: %v", err)
	}
	if got := os.Getenv("MIAGENT_TEST_A"); got != "core" {
		t.Fatalf("A = %q, want the configuration directory's value", got)
	}
	if got := os.Getenv("MIAGENT_TEST_B"); got != "state" {
		t.Fatalf("B = %q, want the local file to override the core file", got)
	}
	if got := os.Getenv("MIAGENT_TEST_C"); got != "state" {
		t.Fatalf("C = %q, want the local file's own value", got)
	}
	// The directory is resolved and recorded between the two files.
	if got := os.Getenv(configDirEnv); got != config {
		t.Fatalf("%s = %q, want the resolved %q", configDirEnv, got, config)
	}

	// An exported variable wins over both files.
	if err := os.Setenv("MIAGENT_TEST_B", "exported"); err != nil {
		t.Fatal(err)
	}
	if err := loadConfig(stateDir); err != nil {
		t.Fatalf("loadConfig: %v", err)
	}
	if got := os.Getenv("MIAGENT_TEST_B"); got != "exported" {
		t.Fatalf("B = %q, want the exported value to survive", got)
	}
}

// TestLoadConfigLocalEnvSelectsConfigDir covers the reason the local file is
// read first: it can point MIAGENT_CONFIG_DIR at another installation, and the
// core .env is then read from that directory rather than the default.
func TestLoadConfigLocalEnvSelectsConfigDir(t *testing.T) {
	root := t.TempDir()
	t.Chdir(root)

	// The default installation, whose core .env must not be read.
	xdg := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", xdg)
	defaultConfig := filepath.Join(xdg, configName)
	if err := os.MkdirAll(defaultConfig, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(defaultConfig, ".env"), []byte("MIAGENT_TEST_WHERE=default\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	// The installation the local .env chooses.
	chosen := t.TempDir()
	if err := os.WriteFile(filepath.Join(chosen, ".env"),
		[]byte("MIAGENT_TEST_WHERE=chosen\nMIAGENT_TEST_CORE=core\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := os.Mkdir(stateDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stateDir, ".env"),
		[]byte(configDirEnv+"="+chosen+"\nMIAGENT_TEST_LOCAL=local\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	unsetEnv(t, configDirEnv)
	for _, name := range []string{"MIAGENT_TEST_WHERE", "MIAGENT_TEST_CORE", "MIAGENT_TEST_LOCAL"} {
		unsetEnv(t, name)
	}

	if err := loadConfig(stateDir); err != nil {
		t.Fatalf("loadConfig: %v", err)
	}
	if got := os.Getenv(configDirEnv); got != chosen {
		t.Fatalf("%s = %q, want the local .env's %q", configDirEnv, got, chosen)
	}
	if got := os.Getenv("MIAGENT_TEST_WHERE"); got != "chosen" {
		t.Fatalf("WHERE = %q, want the chosen installation's core .env, not the default's", got)
	}
	if got := os.Getenv("MIAGENT_TEST_CORE"); got != "core" {
		t.Fatalf("CORE = %q, want the chosen installation's core .env", got)
	}
	if got := os.Getenv("MIAGENT_TEST_LOCAL"); got != "local" {
		t.Fatalf("LOCAL = %q, want the local .env applied", got)
	}
}

// TestLoadConfigExportedConfigDirWins covers precedence over the local file: an
// exported MIAGENT_CONFIG_DIR is the directory the core .env is read from, and
// the local file's value is ignored.
func TestLoadConfigExportedConfigDirWins(t *testing.T) {
	root := t.TempDir()
	t.Chdir(root)

	exported := t.TempDir()
	if err := os.WriteFile(filepath.Join(exported, ".env"), []byte("MIAGENT_TEST_WHERE=exported\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	chosen := t.TempDir()
	if err := os.WriteFile(filepath.Join(chosen, ".env"), []byte("MIAGENT_TEST_WHERE=chosen\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := os.Mkdir(stateDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stateDir, ".env"), []byte(configDirEnv+"="+chosen+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	t.Setenv(configDirEnv, exported)
	unsetEnv(t, "MIAGENT_TEST_WHERE")

	if err := loadConfig(stateDir); err != nil {
		t.Fatalf("loadConfig: %v", err)
	}
	if got := os.Getenv(configDirEnv); got != filepath.Clean(exported) {
		t.Fatalf("%s = %q, want the exported %q", configDirEnv, got, exported)
	}
	if got := os.Getenv("MIAGENT_TEST_WHERE"); got != "exported" {
		t.Fatalf("WHERE = %q, want the exported installation's core .env", got)
	}
}

// TestLoadConfigMissingFiles covers the ordinary case: neither .env exists, and
// the run is configured from the process environment and the XDG default.
func TestLoadConfigMissingFiles(t *testing.T) {
	root := t.TempDir()
	t.Chdir(root)
	configFixture(t)

	if err := loadConfig(stateDir); err != nil {
		t.Fatalf("loadConfig with no env files: %v", err)
	}
}

// TestLoadConfigMalformed covers a typo in either file: it is reported, and the
// error names the file so the user can find it.
func TestLoadConfigMalformed(t *testing.T) {
	t.Run("local", func(t *testing.T) {
		root := t.TempDir()
		t.Chdir(root)
		configFixture(t)
		if err := os.Mkdir(stateDir, 0o755); err != nil {
			t.Fatal(err)
		}
		local := filepath.Join(stateDir, ".env")
		if err := os.WriteFile(local, []byte("this line has no assignment\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		err := loadConfig(stateDir)
		if err == nil {
			t.Fatal("loadConfig accepted a malformed local .env")
		}
		if !strings.Contains(err.Error(), local) {
			t.Fatalf("error = %v, want it to name %s", err, local)
		}
	})

	t.Run("core", func(t *testing.T) {
		root := t.TempDir()
		t.Chdir(root)
		config := configFixture(t)
		core := filepath.Join(config, ".env")
		if err := os.WriteFile(core, []byte("this line has no assignment\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		err := loadConfig(stateDir)
		if err == nil {
			t.Fatal("loadConfig accepted a malformed core .env")
		}
		if !strings.Contains(err.Error(), core) {
			t.Fatalf("error = %v, want it to name %s", err, core)
		}
	})
}
