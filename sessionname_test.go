package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// sessionNameItems is a session with user prompts mixed with the assistant,
// reasoning, and tool traffic that must not reach the naming request. The
// fourth prompt is past sessionNamePromptLimit and is only there to prove the
// limit holds.
func sessionNameItems() []StoredItem {
	return []StoredItem{
		{Role: "compaction", Content: "Earlier work on the parser."},
		{Role: "user", Content: "First prompt."},
		{Role: "assistant", Content: "An answer."},
		{Role: "user", Content: "   "}, // blank: contributes nothing
		{Role: "reasoning", Reasoning: &reasoning{
			Content: []ReasoningPart{{Type: "reasoning_text", Text: "private thinking"}},
		}},
		{Role: "function_call", CallID: "c1", Name: "bash", Arguments: `{"command":"ls"}`},
		{Role: "function_call_output", CallID: "c1", Output: "private tool output"},
		{Role: "user", Content: "Second prompt."},
		{Role: "user", Content: "Third prompt."},
		{Role: "user", Content: "Fourth prompt (past the limit)."},
	}
}

// TestSessionNameConversation covers the reduction: the first few user prompts
// only, blank ones dropped, in order, with the assistant side, reasoning, tool
// traffic, and the compaction summary left out.
func TestSessionNameConversation(t *testing.T) {
	got := sessionNameConversation(sessionNameItems())
	want := "User: First prompt.\n\nUser: Second prompt.\n\nUser: Third prompt."
	if got != want {
		t.Fatalf("sessionNameConversation() = %q, want %q", got, want)
	}
	for _, bad := range []string{
		"Earlier work", "An answer.", "private thinking", "private tool output",
		"bash", "Fourth prompt",
	} {
		if strings.Contains(got, bad) {
			t.Fatalf("conversation carried %q:\n%s", bad, got)
		}
	}
	if got := sessionNameConversation(nil); got != "" {
		t.Fatalf("sessionNameConversation(nil) = %q, want empty", got)
	}
}

// TestSessionName checks the whole naming call: it reads SESSION-NAME.md, sends
// the first few user prompts with it, and returns the model's reply.
func TestSessionName(t *testing.T) {
	prompts := promptsFixture(t)
	promptText := "Name the work in the following session."
	if err := os.WriteFile(filepath.Join(prompts, sessionNamePromptName), []byte(promptText+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	var got struct {
		Model        string `json:"model"`
		Instructions string `json:"instructions"`
		Input        []struct {
			Role    string `json:"role"`
			Content []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
		} `json:"input"`
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &got)
		_, _ = w.Write([]byte(`{"status":"completed","output":[{"type":"message","role":"assistant",` +
			`"content":[{"type":"output_text","text":"Adding session naming to /new"}]}]}`))
	}))
	t.Cleanup(srv.Close)

	prov := &provider{client: newTestClient(srv.URL), model: "stub"}
	name, err := sessionName(context.Background(), prov, sessionNameItems())
	if err != nil {
		t.Fatalf("sessionName: %v", err)
	}
	if name != "Adding session naming to /new" {
		t.Fatalf("name = %q, want the model's reply", name)
	}
	if got.Model != "stub" {
		t.Fatalf("model = %q, want stub", got.Model)
	}
	if got.Instructions != promptText {
		t.Fatalf("instructions = %q, want the SESSION-NAME.md text %q", got.Instructions, promptText)
	}
	if len(got.Input) != 1 || got.Input[0].Role != "user" || len(got.Input[0].Content) == 0 {
		t.Fatalf("input = %+v, want one user message", got.Input)
	}
	input := got.Input[0].Content[0].Text
	for _, want := range []string{
		"<conversation>",
		"User: First prompt.",
		"User: Second prompt.",
		"User: Third prompt.",
	} {
		if !strings.Contains(input, want) {
			t.Fatalf("request input missing %q:\n%s", want, input)
		}
	}
	for _, bad := range []string{
		"Earlier work", "An answer.", "private thinking", "private tool output",
		"bash", "Fourth prompt",
	} {
		if strings.Contains(input, bad) {
			t.Fatalf("request input carried %q:\n%s", bad, input)
		}
	}
}

// TestSessionNameEmptySession covers a session with no user prompts: there is
// nothing to name, so the model is not called and no prompt file is needed.
func TestSessionNameEmptySession(t *testing.T) {
	name, err := sessionName(context.Background(), &provider{}, []StoredItem{
		{Role: "assistant", Content: "hi"},
	})
	if err != nil {
		t.Fatalf("sessionName: %v", err)
	}
	if name != "" {
		t.Fatalf("name = %q, want empty", name)
	}
}

// TestSessionNameMissingPrompt reports a missing SESSION-NAME.md rather than
// archiving a session with no name.
func TestSessionNameMissingPrompt(t *testing.T) {
	promptsFixture(t) // no SESSION-NAME.md written
	_, err := sessionName(context.Background(), &provider{}, sessionNameItems())
	if err == nil || !strings.Contains(err.Error(), sessionNamePromptName) {
		t.Fatalf("sessionName error = %v, want it to name %s", err, sessionNamePromptName)
	}
}

// TestCmdNewNamingFailureLeavesFiles covers the promise that a failed naming
// call archives nothing: the session is untouched, no archive is written, and
// the in-memory session is not reset.
func TestCmdNewNamingFailureLeavesFiles(t *testing.T) {
	dir := t.TempDir()
	prompts := promptsFixture(t)
	if err := os.WriteFile(filepath.Join(prompts, sessionNamePromptName), []byte("Name this session.\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	t.Cleanup(srv.Close)
	prov := &provider{client: newTestClient(srv.URL), model: "stub"}

	sessionPath := filepath.Join(dir, "session.jsonl")
	s := newSession(sessionPath)
	s.Items = []StoredItem{{Role: "user", Content: "hello"}}
	if err := s.commit(); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(sessionPath)
	if err != nil {
		t.Fatal(err)
	}
	prepak := filepath.Join(dir, "prepak-20260101T000000Z-session.jsonl")
	if err := os.WriteFile(prepak, []byte("archived\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := cmdNew(context.Background(), prov, s, newDisplay(), nil); err == nil {
		t.Fatal("cmdNew succeeded although naming failed")
	}

	if after, err := os.ReadFile(sessionPath); err != nil {
		t.Fatalf("session file gone after a failed /new: %v", err)
	} else if string(after) != string(before) {
		t.Fatal("session file changed after a failed /new")
	}
	if _, err := os.Stat(prepak); err != nil {
		t.Fatalf("compaction archive gone after a failed /new: %v", err)
	}
	if archives, _ := filepath.Glob(filepath.Join(dir, "archive-*.tar.gz")); len(archives) != 0 {
		t.Fatalf("a failed /new left an archive behind: %v", archives)
	}
	if len(s.Items) != 1 || s.Items[0].Content != "hello" {
		t.Fatalf("in-memory session changed after a failed /new: %+v", s.Items)
	}
}
