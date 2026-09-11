package main

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// streamStub serves one SSE response built from raw event payloads, so a test
// can shape exactly which events a provider sends.
func streamStub(t *testing.T, events ...string) *provider {
	t.Helper()
	var body strings.Builder
	for _, e := range events {
		body.WriteString("data: " + e + "\n\n")
	}
	body.WriteString("data: [DONE]\n\n")

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = io.WriteString(w, body.String())
	}))
	t.Cleanup(srv.Close)
	return &provider{client: newTestClient(srv.URL), model: "stub"}
}

// completedText is the response.completed event for a text answer.
func completedText(text string) string {
	return `{"type":"response.completed","response":{"id":"r","status":"completed","output":[` +
		`{"id":"m","type":"message","role":"assistant","content":[{"type":"output_text","text":` +
		quote(text) + `}]}],"usage":{"input_tokens":10,"output_tokens":3,"total_tokens":13}}}`
}

// textDelta is one response.output_text.delta event.
func textDelta(delta string) string {
	return `{"type":"response.output_text.delta","item_id":"m","output_index":0,"content_index":0,"delta":` +
		quote(delta) + `}`
}

// quote renders s as a JSON string.
func quote(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String()
}

// TestRunModelTurnShowsTheAnswer covers what a reader sees of a turn: the
// display is fed deltas, so an answer that arrives whole in response.completed
// (or that was only partly streamed) still has to appear, exactly once.
func TestRunModelTurnShowsTheAnswer(t *testing.T) {
	cases := []struct {
		name   string
		events []string
		want   string
	}{
		{
			name:   "no deltas at all",
			events: []string{completedText("All done.")},
			want:   "All done.\n",
		},
		{
			name:   "streamed in full",
			events: []string{textDelta("All "), textDelta("done."), completedText("All done.")},
			want:   "All done.\n",
		},
		{
			name:   "streamed in part",
			events: []string{textDelta("All "), completedText("All done.")},
			want:   "All done.\n",
		},
		{
			name:   "streamed past the completed text",
			events: []string{textDelta("All done. Extra"), completedText("All done.")},
			want:   "All done. Extra\n",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			prov := streamStub(t, tc.events...)
			var out string
			var items []StoredItem
			var final bool
			out = captureStdout(t, func() {
				var err error
				items, _, final, err = runModelTurn(context.Background(), prov, "instructions", nil, nil, newDisplay())
				if err != nil {
					t.Fatalf("runModelTurn: %v", err)
				}
			})
			if !final {
				t.Fatal("final = false, want the turn to be final")
			}
			if out != tc.want {
				t.Fatalf("stdout = %q, want %q", out, tc.want)
			}
			// What is displayed and what is stored are the same answer.
			if got := assistantText(items); got != strings.TrimSuffix(tc.want, "\n") && tc.name != "streamed past the completed text" {
				t.Fatalf("stored answer = %q, want the displayed %q", got, strings.TrimSuffix(tc.want, "\n"))
			}
		})
	}
}

// TestStreamedRemainder covers the arithmetic behind the echo directly, since
// duplicating an answer is as wrong as dropping one.
func TestStreamedRemainder(t *testing.T) {
	cases := []struct {
		streamed, answer, want string
	}{
		{"", "answer", "answer"},
		{"answer", "answer", ""},
		{"an", "answer", "swer"},
		{"", "", ""},
		{"something else", "answer", ""}, // not an extension: print nothing twice
	}
	for _, tc := range cases {
		if got := streamedRemainder(tc.streamed, tc.answer); got != tc.want {
			t.Fatalf("streamedRemainder(%q, %q) = %q, want %q", tc.streamed, tc.answer, got, tc.want)
		}
	}
}
