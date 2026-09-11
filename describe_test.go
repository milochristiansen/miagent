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

// describeSession is a session exercising every item kind: the compaction
// summary, user prompts, and assistant answers may reach the description
// request, while reasoning and tool traffic may not.
func describeSession() *Session {
	return &Session{Items: []StoredItem{
		{Role: "compaction", Content: "Set up the project scaffolding."},
		{Role: "user", Content: "Add a /desc command."},
		{Role: "reasoning", Reasoning: &reasoning{
			Content: []ReasoningPart{{Type: "reasoning_text", Text: "private thinking"}},
		}},
		{Role: "assistant", Content: "Working on it."},
		{Role: "function_call", CallID: "c1", Name: "bash", Arguments: `{"command":"ls"}`},
		{Role: "function_call_output", CallID: "c1", Output: "private tool output"},
		{Role: "user", Content: "   "}, // blank: contributes nothing
		{Role: "assistant", Content: "Done."},
	}}
}

// TestDescribeConversation covers the reduction: user prompts and assistant
// answers in order, blank ones dropped, and reasoning, tool calls, and tool
// results left out.
func TestDescribeConversation(t *testing.T) {
	got := describeConversation(describeSession().Items)
	want := "Summary of earlier work: Set up the project scaffolding.\n\n" +
		"User: Add a /desc command.\n\nAssistant: Working on it.\n\nAssistant: Done."
	if got != want {
		t.Fatalf("describeConversation() = %q, want %q", got, want)
	}
	for _, bad := range []string{"private thinking", "private tool output", "bash", `"command"`} {
		if strings.Contains(got, bad) {
			t.Fatalf("conversation carried %q:\n%s", bad, got)
		}
	}
	if got := describeConversation(nil); got != "" {
		t.Fatalf("describeConversation(nil) = %q, want empty", got)
	}
}

// TestCmdDescribe checks the whole command: it reads DESCRIPTION.md, sends the
// reduced conversation with it, and prints the model's description.
func TestCmdDescribe(t *testing.T) {
	dir := configFixture(t)
	promptText := "Describe the following conversation in one or two sentences."
	if err := os.WriteFile(filepath.Join(dir, describePromptName), []byte(promptText+"\n"), 0o644); err != nil {
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
			`"content":[{"type":"output_text","text":"Added a /desc command that summarizes a session."}]}],` +
			`"usage":{"input_tokens":5,"output_tokens":8,"total_tokens":13}}`))
	}))
	t.Cleanup(srv.Close)

	prov := &provider{client: newTestClient(srv.URL), model: "stub"}
	var out string
	var err error
	out = captureStdout(t, func() {
		err = cmdDescribe(context.Background(), prov, describeSession(), newDisplay(), nil)
	})
	if err != nil {
		t.Fatalf("cmdDescribe: %v", err)
	}
	if !strings.Contains(out, "Added a /desc command that summarizes a session.") {
		t.Fatalf("stdout = %q, want the model description", out)
	}
	// The description goes through the output path, which terminates the line
	// even though the model's text carries no trailing newline.
	if !strings.HasSuffix(out, "\n") {
		t.Fatalf("stdout = %q, want the line terminated", out)
	}

	if got.Model != "stub" {
		t.Fatalf("model = %q, want stub", got.Model)
	}
	if got.Instructions != promptText {
		t.Fatalf("instructions = %q, want the DESCRIPTION.md text %q", got.Instructions, promptText)
	}
	if len(got.Input) != 1 || got.Input[0].Role != "user" || len(got.Input[0].Content) == 0 {
		t.Fatalf("input = %+v, want one user message", got.Input)
	}
	input := got.Input[0].Content[0].Text
	for _, want := range []string{
		"<conversation>",
		"Summary of earlier work: Set up the project scaffolding.",
		"User: Add a /desc command.",
		"Assistant: Working on it.",
		"Assistant: Done.",
	} {
		if !strings.Contains(input, want) {
			t.Fatalf("request input missing %q:\n%s", want, input)
		}
	}
	for _, bad := range []string{"private thinking", "private tool output", "bash", `"command"`} {
		if strings.Contains(input, bad) {
			t.Fatalf("request input carried %q:\n%s", bad, input)
		}
	}
}

// TestCmdDescribeEmptySession is the ordinary first run: there is nothing to
// describe, and the command says so without reading DESCRIPTION.md or calling
// the model.
func TestCmdDescribeEmptySession(t *testing.T) {
	var out string
	var err error
	out = captureStdout(t, func() {
		err = cmdDescribe(context.Background(), &provider{}, &Session{}, newDisplay(), nil)
	})
	if err != nil {
		t.Fatalf("cmdDescribe: %v", err)
	}
	if !strings.Contains(out, "nothing to describe") {
		t.Fatalf("stdout = %q, want the nothing-to-describe note", out)
	}
}

// TestCmdDescribeMissingPrompt reports a missing DESCRIPTION.md rather than
// sending the model an undescribed conversation.
func TestCmdDescribeMissingPrompt(t *testing.T) {
	configFixture(t) // no DESCRIPTION.md written
	err := cmdDescribe(context.Background(), &provider{}, describeSession(), newDisplay(), nil)
	if err == nil || !strings.Contains(err.Error(), describePromptName) {
		t.Fatalf("cmdDescribe error = %v, want it to name %s", err, describePromptName)
	}
}

// TestCmdDescribeRejectsArguments keeps the command's contract with the
// dispatcher: it takes none.
func TestCmdDescribeRejectsArguments(t *testing.T) {
	if err := cmdDescribe(context.Background(), &provider{}, describeSession(), newDisplay(), []string{"x"}); err == nil {
		t.Fatal("cmdDescribe accepted an argument, want an error")
	}
}
