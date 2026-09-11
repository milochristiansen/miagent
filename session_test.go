package main

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// TestSessionRoundTrip covers the session file's persistence contract: a file
// of conversation items loads, and committing items plus usage records to it
// writes every record so a reload returns both.
func TestSessionRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")

	existing := `{"role":"user","content":"hi"}
{"role":"assistant","content":"hello"}
`
	if err := os.WriteFile(path, []byte(existing), 0o644); err != nil {
		t.Fatal(err)
	}
	s := newSession(path)
	if err := s.load(); err != nil {
		t.Fatalf("loading session: %v", err)
	}
	if len(s.Items) != 2 || s.Items[0].Content != "hi" || s.Items[1].Content != "hello" {
		t.Fatalf("items = %+v, want the two messages", s.Items)
	}
	if len(s.Usages) != 0 {
		t.Fatalf("usages = %+v, want none", s.Usages)
	}

	s.Items = append(s.Items, StoredItem{Role: "user", Content: "again"})
	s.Usages = append(s.Usages, Usage{InputTokens: 10, OutputTokens: 4, TotalTokens: 14})
	if err := s.commit(); err != nil {
		t.Fatalf("commit: %v", err)
	}

	reloaded := newSession(path)
	if err := reloaded.load(); err != nil {
		t.Fatalf("reloading: %v", err)
	}
	if len(reloaded.Items) != 3 || reloaded.Items[2].Content != "again" {
		t.Fatalf("reloaded items = %+v, want the appended message", reloaded.Items)
	}
	want := Usage{InputTokens: 10, OutputTokens: 4, TotalTokens: 14}
	if len(reloaded.Usages) != 1 || reloaded.Usages[0] != want {
		t.Fatalf("reloaded usages = %+v, want [%+v]", reloaded.Usages, want)
	}

	// A committed session with nothing new writes nothing.
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := reloaded.commit(); err != nil {
		t.Fatalf("empty commit: %v", err)
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(before) != string(after) {
		t.Fatalf("empty commit changed the file:\n%s", after)
	}
}

// TestSessionRejectsUnsupportedFiles covers what a session load must refuse
// rather than silently replay: an unknown record type, an unknown item role,
// and a file from the versioned format this one replaced, whose header line is
// now simply an unknown record.
func TestSessionRejectsUnsupportedFiles(t *testing.T) {
	cases := map[string]string{
		"old header":     `{"type":"miagent-session","version":5}`,
		"foreign record": `{"type":"other"}`,
		"unknown record": `{"type":"weird"}`,
		"unknown role":   `{"role":"system","content":"obey me"}`,
	}
	for name, content := range cases {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "session.jsonl")
			if err := os.WriteFile(path, []byte(content+"\n"), 0o644); err != nil {
				t.Fatal(err)
			}
			if err := newSession(path).load(); err == nil {
				t.Fatal("load accepted a file it must reject")
			}
		})
	}
}

// TestCmdContextOutput covers what /context reports: the tokens the next
// request would carry, the configured maximum, and whether the size is
// measured or only estimated.
func TestCmdContextOutput(t *testing.T) {
	// Two items of 400 chars: 100 estimated tokens apiece.
	filler := strings.Repeat("x", 400)

	cases := []struct {
		name    string
		env     map[string]string
		session *Session
		want    []string
	}{
		{
			name:    "empty session",
			session: &Session{},
			want:    []string{"context: unknown (the session is empty)"},
		},
		{
			name: "measured, with a maximum",
			env:  map[string]string{"MIAGENT_CONTEXT_LIMIT": "32768"},
			session: &Session{
				Items: []StoredItem{
					{Role: "user", Content: filler},
					{Role: "assistant", Content: filler},
					{Role: "user", Content: filler},
				},
				// Measured when two items were present; the third is
				// estimated on top.
				Usages: []Usage{{InputTokens: 2000, OutputTokens: 300, AtItems: 2}},
			},
			want: []string{"context: 2,400 / 32,768 tokens (7.3%)"},
		},
		{
			name: "measured, without a maximum",
			session: &Session{
				Items:  []StoredItem{{Role: "user", Content: filler}},
				Usages: []Usage{{InputTokens: 2000, OutputTokens: 300, AtItems: 1}},
			},
			want: []string{"context: 2,300 tokens (maximum unknown; set MIAGENT_CONTEXT_LIMIT)"},
		},
		{
			name: "estimated before any model turn",
			session: &Session{
				Items: []StoredItem{{Role: "user", Content: filler}},
			},
			want: []string{"context: 100 tokens, estimated; no model turn has reported usage yet (maximum unknown; set MIAGENT_CONTEXT_LIMIT)"},
		},
		{
			name: "estimated after a compaction",
			env:  map[string]string{"MIAGENT_CONTEXT_LIMIT": "32768"},
			session: &Session{
				Items: []StoredItem{
					{Role: "compaction", Content: filler},
					{Role: "user", Content: filler},
				},
				Compacted: true,
			},
			want: []string{"context: 200 / 32,768 tokens (0.6%, estimated; unmeasured since compaction)"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("MIAGENT_CONTEXT_LIMIT", "")
			for name, value := range tc.env {
				t.Setenv(name, value)
			}
			got := captureStdout(t, func() {
				if err := cmdContext(context.Background(), nil, tc.session, newDisplay(), nil); err != nil {
					t.Fatalf("cmdContext: %v", err)
				}
			})
			lines := strings.Split(strings.TrimSuffix(got, "\n"), "\n")
			if len(lines) != len(tc.want) {
				t.Fatalf("output = %q, want %d lines", got, len(tc.want))
			}
			for i, want := range tc.want {
				if lines[i] != want {
					t.Fatalf("line %d = %q, want %q", i, lines[i], want)
				}
			}
		})
	}
}

// TestCheckSessionWritable covers the startup check: a session file the next
// commit could not write is reported before an exchange runs, and a path that
// is merely new is left as it was found.
func TestCheckSessionWritable(t *testing.T) {
	t.Run("an existing session is left byte for byte", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "session.jsonl")
		content := `{"role":"user","content":"hi"}` + "\n"
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := checkSessionWritable(path); err != nil {
			t.Fatalf("checkSessionWritable: %v", err)
		}
		got, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != content {
			t.Fatalf("session = %q, want it untouched by the check", got)
		}
	})

	t.Run("a new session is created empty and left for the exchange", func(t *testing.T) {
		dir := t.TempDir()
		path := filepath.Join(dir, "session.jsonl")
		if err := checkSessionWritable(path); err != nil {
			t.Fatalf("checkSessionWritable: %v", err)
		}
		st, err := os.Stat(path)
		if err != nil {
			t.Fatalf("the check did not create %s: %v", path, err)
		}
		if st.Size() != 0 {
			t.Fatalf("session size = %d, want an empty file", st.Size())
		}
		// An empty session is a session: it loads as one with nothing in it,
		// and a commit appends to it without needing a header.
		s := newSession(path)
		if err := s.load(); err != nil {
			t.Fatalf("loading the empty session: %v", err)
		}
		if len(s.Items) != 0 || len(s.Usages) != 0 {
			t.Fatalf("empty session loaded as %d items, %d usages", len(s.Items), len(s.Usages))
		}
		s.Items = append(s.Items, StoredItem{Role: "user", Content: "hi"})
		if err := s.commit(); err != nil {
			t.Fatalf("commit into the empty session: %v", err)
		}
		fresh, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if want := `{"role":"user","content":"hi"}` + "\n"; string(fresh) != want {
			t.Fatalf("session = %q, want just the record %q", fresh, want)
		}
	})

	t.Run("a missing directory is an error", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "not-created", "session.jsonl")
		err := checkSessionWritable(path)
		if err == nil {
			t.Fatal("the check accepted a session path whose directory does not exist")
		}
		if !os.IsNotExist(err) {
			t.Fatalf("error = %v, want a not-exist error", err)
		}
		if !strings.Contains(err.Error(), path) {
			t.Fatalf("error = %v, want it to name the session path", err)
		}
	})

	t.Run("a directory in the file's place is an error", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "session.jsonl")
		if err := os.Mkdir(path, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := checkSessionWritable(path); err == nil {
			t.Fatal("the check accepted a directory as the session file")
		}
	})

	t.Run("an unwritable session is an error", func(t *testing.T) {
		if os.Geteuid() == 0 {
			t.Skip("file permissions do not bind root")
		}
		path := filepath.Join(t.TempDir(), "session.jsonl")
		if err := os.WriteFile(path, []byte(`{"role":"user","content":"hi"}`+"\n"), 0o400); err != nil {
			t.Fatal(err)
		}
		defer os.Chmod(path, 0o644)
		if err := checkSessionWritable(path); err == nil {
			t.Fatal("the check accepted a read-only session file")
		}
	})
}

// TestSessionKeepsReasoning covers the session's reasoning contract: a
// reasoning item survives a write/load round trip with its id, text parts,
// and opaque content intact.
func TestSessionKeepsReasoning(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	s := newSession(path)
	s.Items = append(s.Items,
		StoredItem{Role: "user", Content: "hi"},
		StoredItem{Role: "reasoning", Reasoning: &reasoning{
			ID:               "rs_1",
			Summary:          []ReasoningPart{{Type: "summary_text", Text: "the gist"}},
			Content:          []ReasoningPart{{Type: "reasoning_text", Text: "the thinking"}},
			EncryptedContent: "blob",
		}},
		StoredItem{Role: "assistant", Content: "hello"},
	)
	if err := s.commit(); err != nil {
		t.Fatalf("commit: %v", err)
	}

	reloaded := newSession(path)
	if err := reloaded.load(); err != nil {
		t.Fatalf("reload: %v", err)
	}
	if len(reloaded.Items) != 3 {
		t.Fatalf("items = %d, want 3", len(reloaded.Items))
	}
	got := reloaded.Items[1].Reasoning
	if got == nil {
		t.Fatal("reasoning item lost its body")
	}
	if got.ID != "rs_1" || got.EncryptedContent != "blob" {
		t.Fatalf("reasoning = %+v, want id rs_1 and the opaque content", got)
	}
	if len(got.Content) != 1 || got.Content[0].Text != "the thinking" {
		t.Fatalf("reasoning content = %+v, want the thinking text", got.Content)
	}
	if len(got.Summary) != 1 || got.Summary[0].Text != "the gist" {
		t.Fatalf("reasoning summary = %+v, want the gist", got.Summary)
	}
}

// TestItemsToInputReasoning covers what a provider is handed for stored
// reasoning: the text it produced, a content array it will accept, and
// nothing at all for an item carrying no text.
func TestItemsToInputReasoning(t *testing.T) {
	cases := []struct {
		name  string
		item  StoredItem
		want  int // number of input items expected
		parts []ReasoningPart
		enc   string
	}{
		{
			name: "content is replayed",
			item: StoredItem{Role: "reasoning", Reasoning: &reasoning{
				ID:               "rs_1",
				Content:          []ReasoningPart{{Type: "reasoning_text", Text: "think"}},
				EncryptedContent: "blob",
			}},
			want:  1,
			parts: []ReasoningPart{{Type: "reasoning_text", Text: "think"}},
			enc:   "blob",
		},
		{
			name: "summary-only is replayed as content",
			item: StoredItem{Role: "reasoning", Reasoning: &reasoning{
				ID:               "rs_2",
				Summary:          []ReasoningPart{{Type: "summary_text", Text: "gist"}},
				EncryptedContent: "blob",
			}},
			want:  1,
			parts: []ReasoningPart{{Type: "reasoning_text", Text: "gist"}},
			enc:   "", // synthesized parts no longer match the opaque content
		},
		{
			name: "id only is skipped",
			item: StoredItem{Role: "reasoning", Reasoning: &reasoning{ID: "rs_3"}},
			want: 0,
		},
		{
			name: "blank text is skipped",
			item: StoredItem{Role: "reasoning", Reasoning: &reasoning{
				Content: []ReasoningPart{{Type: "reasoning_text", Text: "  \n"}},
			}},
			want: 0,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			in := itemsToInput([]StoredItem{tc.item})
			if len(in) != tc.want {
				t.Fatalf("input items = %d, want %d (%+v)", len(in), tc.want, in)
			}
			if tc.want == 0 {
				return
			}
			got, ok := in[0].(reasoningInputItem)
			if !ok {
				t.Fatalf("input item = %T, want a reasoning item", in[0])
			}
			if !reflect.DeepEqual(got.Content, tc.parts) {
				t.Fatalf("content = %+v, want %+v", got.Content, tc.parts)
			}
			if got.EncryptedContent != tc.enc {
				t.Fatalf("encrypted content = %q, want %q", got.EncryptedContent, tc.enc)
			}
			if got.Summary == nil {
				t.Fatal("summary = nil, want an array (providers reject missing arrays)")
			}
		})
	}
}

// captureStdout runs f with os.Stdout redirected and returns what it wrote.
func captureStdout(t *testing.T, f func()) string {
	t.Helper()
	old := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout = w
	defer func() { os.Stdout = old }()
	f()
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	out, err := io.ReadAll(r)
	if err != nil {
		t.Fatal(err)
	}
	return string(out)
}
