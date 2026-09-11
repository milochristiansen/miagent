package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestLoadAgents covers which AGENTS.md files are read and in what order: the
// working directory's first, then the state directory's, both optional, joined
// with a blank line.
func TestLoadAgents(t *testing.T) {
	cases := []struct {
		name    string
		cwdFile string // "" means no file
		state   string
		want    []string // substrings, in the order they must appear
		absent  []string
	}{
		{
			name:    "both, current directory first",
			cwdFile: "from the working directory",
			state:   "from the state directory",
			want:    []string{"from the working directory", "from the state directory"},
		},
		{
			name:    "only the working directory",
			cwdFile: "cwd only",
			want:    []string{"cwd only"},
			absent:  []string{"state"},
		},
		{
			name:  "only the state directory",
			state: "state only",
			want:  []string{"state only"},
		},
		{
			name: "neither",
		},
		{
			name:    "a blank file contributes nothing",
			cwdFile: "   \n\n\t\n",
			state:   "real instructions",
			want:    []string{"real instructions"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			t.Chdir(root)
			stateDir := filepath.Join(root, "state")
			if err := os.Mkdir(stateDir, 0o755); err != nil {
				t.Fatal(err)
			}
			if tc.cwdFile != "" {
				if err := os.WriteFile(filepath.Join(root, agentsFile), []byte(tc.cwdFile+"\n"), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			if tc.state != "" {
				if err := os.WriteFile(filepath.Join(stateDir, agentsFile), []byte(tc.state+"\n"), 0o644); err != nil {
					t.Fatal(err)
				}
			}

			got, err := loadAgents(stateDir)
			if err != nil {
				t.Fatalf("loadAgents: %v", err)
			}
			at := -1
			for _, want := range tc.want {
				i := strings.Index(got, want)
				if i < 0 {
					t.Fatalf("loadAgents = %q, missing %q", got, want)
				}
				if i <= at {
					t.Fatalf("loadAgents = %q, %q is out of order", got, want)
				}
				at = i
			}
			if len(tc.want) == 0 && got != "" {
				t.Fatalf("loadAgents = %q, want empty", got)
			}
			for _, unwanted := range tc.absent {
				if strings.Contains(got, unwanted) {
					t.Fatalf("loadAgents = %q, unexpected %q", got, unwanted)
				}
			}
		})
	}
}

// TestSessionInstructions covers the assembled instructions and their
// priority order: the system prompt first, then the AGENTS.md files — the
// working directory's, then the state directory's — with the system prompt
// alone when there are no agent files.
func TestSessionInstructions(t *testing.T) {
	// The project: a working directory with a state directory, and a
	// separate configuration directory holding the prompts. The two are
	// independent, which is the point of the split.
	root := t.TempDir()
	t.Chdir(root)
	prompts := promptsFixture(t)
	state := filepath.Join(root, "state")
	if err := os.Mkdir(state, 0o755); err != nil {
		t.Fatal(err)
	}
	const system = "SYSTEM-PROMPT-TEXT"
	if err := os.WriteFile(filepath.Join(prompts, "SYSTEM.md"), []byte(system+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	// No AGENTS.md anywhere: the system prompt goes as it is. This is also
	// what keeps a project without an AGENTS.md working unchanged.
	got, err := sessionInstructions(state)
	if err != nil {
		t.Fatalf("sessionInstructions: %v", err)
	}
	if got != system {
		t.Fatalf("instructions = %q, want the system prompt alone", got)
	}

	if err := os.WriteFile(filepath.Join(root, agentsFile), []byte("CWD-INSTRUCTIONS\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(state, agentsFile), []byte("STATE-INSTRUCTIONS\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err = sessionInstructions(state)
	if err != nil {
		t.Fatalf("sessionInstructions: %v", err)
	}
	i, j, k := strings.Index(got, system), strings.Index(got, "CWD-INSTRUCTIONS"), strings.Index(got, "STATE-INSTRUCTIONS")
	if i != 0 {
		t.Fatalf("instructions = %q, want the system prompt first", got)
	}
	if !(i < j && j < k) {
		t.Fatalf("instructions = %q, want system, then the working directory, then the state directory", got)
	}

	// A malformed system prompt is an error, exactly as before: the agent
	// files are the optional half, not the system prompt.
	if err := os.WriteFile(filepath.Join(prompts, "SYSTEM.md"), []byte("  \n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := sessionInstructions(state); err == nil {
		t.Fatal("sessionInstructions accepted an empty SYSTEM.md")
	}
}

// TestLoadAgentsReportsUnreadableFile covers the failure the user cannot see
// otherwise: a file that exists but cannot be read fails the load rather than
// silently dropping instructions.
func TestLoadAgentsReportsUnreadableFile(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("file permissions do not bind root")
	}
	root := t.TempDir()
	t.Chdir(root)
	state := filepath.Join(root, "state")
	if err := os.Mkdir(state, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(state, agentsFile)
	if err := os.WriteFile(path, []byte("instructions\n"), 0o000); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(path, 0o644)

	if _, err := loadAgents(state); err == nil {
		t.Fatal("loadAgents accepted an unreadable AGENTS.md")
	}
}

// TestLoadPromptStillRequiresContent covers the one difference between the two
// readers: a prompt file must have content, while an AGENTS.md may be absent.
func TestLoadPromptStillRequiresContent(t *testing.T) {
	dir := t.TempDir()
	blank := filepath.Join(dir, "SYSTEM.md")
	if err := os.WriteFile(blank, []byte("\n  \n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := loadPrompt(blank); err == nil {
		t.Fatal("loadPrompt accepted a blank file")
	} else if !strings.Contains(err.Error(), "is empty") {
		t.Fatalf("blank file error = %v, want it to say the file is empty", err)
	}

	missing := filepath.Join(dir, "missing.md")
	_, err := loadPrompt(missing)
	if err == nil {
		t.Fatal("loadPrompt accepted a missing file")
	}
	// A missing prompt must not be reported as an empty one: the two need
	// different fixes, and the config directory is easy to get wrong.
	if strings.Contains(err.Error(), "empty") {
		t.Fatalf("missing file error = %v, want a not-found error", err)
	}
	if !strings.Contains(err.Error(), missing) {
		t.Fatalf("missing file error = %v, want it to name the path", err)
	}

	real := filepath.Join(dir, "real.md")
	if err := os.WriteFile(real, []byte("text\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := loadPrompt(real)
	if err != nil {
		t.Fatalf("loadPrompt: %v", err)
	}
	if got != "text" {
		t.Fatalf("loadPrompt = %q, want the trimmed text", got)
	}

	// The optional reader is the one that tolerates absence.
	if text, err := readOptionalPrompt(missing); err != nil || text != "" {
		t.Fatalf("readOptionalPrompt(missing) = %q, %v; want empty and no error", text, err)
	}
}
