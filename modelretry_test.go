// Tests for the resilience of a model turn: retrying a call that produced
// nothing, continuing one that was cut off mid-answer, and the idle timeout
// that turns a stalled connection into one of those two cases.
package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// sseScript is one request's scripted reply. It writes the response body.
type sseScript func(w http.ResponseWriter, r *http.Request)

// scriptedProvider serves one scripted reply per request, in order, and
// records every request body. A request past the end of the scripts gets a
// 500, which is enough to fail the call before anything is streamed.
func scriptedProvider(t *testing.T, scripts ...sseScript) (*provider, func() []string) {
	t.Helper()
	var mu sync.Mutex
	var bodies []string
	index := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		mu.Lock()
		bodies = append(bodies, string(body))
		i := index
		index++
		mu.Unlock()

		w.Header().Set("Content-Type", "text/event-stream")
		if i >= len(scripts) {
			http.Error(w, "unscripted request", http.StatusInternalServerError)
			return
		}
		scripts[i](w, r)
	}))
	t.Cleanup(srv.Close)
	return &provider{client: newTestClient(srv.URL), model: "stub"}, func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), bodies...)
	}
}

// sse writes the given events followed by the stream terminator.
func sse(w http.ResponseWriter, events ...string) {
	for _, e := range events {
		fmt.Fprintf(w, "data: %s\n\n", e)
	}
	io.WriteString(w, "data: [DONE]\n\n")
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}
}

// writeContinuePrompt installs the continuation prompt in the fixture config
// directory, which is where loadContinuePrompt reads it from.
func writeContinuePrompt(t *testing.T, text string) {
	t.Helper()
	dir := promptsFixture(t)
	if err := os.WriteFile(filepath.Join(dir, continuePromptName), []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

// TestRunModelTurnContinuesAfterTruncation covers the main path: the provider
// closes the stream after half an answer, so the next request replays what was
// streamed, asks the model to continue, and the two halves are displayed and
// stored as one answer.
func TestRunModelTurnContinuesAfterTruncation(t *testing.T) {
	writeContinuePrompt(t, "please continue where you left off")
	prov, bodies := scriptedProvider(t,
		func(w http.ResponseWriter, _ *http.Request) {
			// Half an answer, then the connection ends without completing.
			fmt.Fprintf(w, "data: %s\n\n", textDelta("Hello, "))
		},
		func(w http.ResponseWriter, _ *http.Request) {
			sse(w, textDelta("world!"), completedText("world!"))
		},
	)

	var (
		items []StoredItem
		final bool
		err   error
	)
	out := captureStdout(t, func() {
		items, _, final, err = runModelTurn(context.Background(), prov, "instructions", nil, nil, newDisplay())
	})
	if err != nil {
		t.Fatalf("runModelTurn: %v", err)
	}
	if !final {
		t.Fatal("final = false, want the turn to be final")
	}
	if out != "Hello, world!\n" {
		t.Fatalf("stdout = %q, want the answer stitched together", out)
	}
	if got := assistantText(items); got != "Hello, world!" {
		t.Fatalf("stored answer = %q, want %q", got, "Hello, world!")
	}

	reqs := bodies()
	if len(reqs) != 2 {
		t.Fatalf("provider saw %d requests, want 2", len(reqs))
	}
	if !strings.Contains(reqs[1], "Hello, ") {
		t.Fatalf("continuation request did not replay the partial answer:\n%s", reqs[1])
	}
	if !strings.Contains(reqs[1], "please continue where you left off") {
		t.Fatalf("continuation request did not carry the continuation prompt:\n%s", reqs[1])
	}
}

// TestRunModelTurnRetriesTotalFailure covers a call that produced nothing: it
// is retried, and the turn succeeds once the provider answers.
func TestRunModelTurnRetriesTotalFailure(t *testing.T) {
	prov, bodies := scriptedProvider(t,
		func(w http.ResponseWriter, _ *http.Request) {
			http.Error(w, "boom", http.StatusInternalServerError)
		},
		func(w http.ResponseWriter, _ *http.Request) {
			sse(w, textDelta("recovered"), completedText("recovered"))
		},
	)

	var (
		items []StoredItem
		err   error
	)
	_ = captureStdout(t, func() {
		items, _, _, err = runModelTurn(context.Background(), prov, "instructions", nil, nil, newDisplay())
	})
	if err != nil {
		t.Fatalf("runModelTurn: %v", err)
	}
	if got := assistantText(items); got != "recovered" {
		t.Fatalf("stored answer = %q, want %q", got, "recovered")
	}
	if got := len(bodies()); got != 2 {
		t.Fatalf("provider saw %d requests, want the failure retried once", got)
	}
}

// TestRunModelTurnGivesUpAfterRetries covers the bound on total failures: a
// provider that never answers is tried once and retried maxModelRetries times,
// then the turn fails.
func TestRunModelTurnGivesUpAfterRetries(t *testing.T) {
	prov, bodies := scriptedProvider(t) // every request fails

	err := error(nil)
	_ = captureStdout(t, func() {
		_, _, _, err = runModelTurn(context.Background(), prov, "instructions", nil, nil, newDisplay())
	})
	if err == nil {
		t.Fatal("runModelTurn = nil error, want the failure reported")
	}
	if got, want := len(bodies()), maxModelRetries+1; got != want {
		t.Fatalf("provider saw %d requests, want %d (the call plus %d retries)", got, want, maxModelRetries)
	}
}

// TestStreamModelTurnIdleTimeout covers the idle limit directly: a stream that
// sends something and then goes quiet is cancelled, and what it already sent
// is reported as progress so the caller continues rather than retries.
func TestStreamModelTurnIdleTimeout(t *testing.T) {
	release := make(chan struct{})
	prov, _ := scriptedProvider(t, func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintf(w, "data: %s\n\n", textDelta("partial"))
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		<-release // hold the connection open and silent
	})
	t.Cleanup(func() { close(release) })

	var (
		attempt streamAttempt
		err     error
	)
	_ = captureStdout(t, func() {
		attempt, err = streamModelTurn(context.Background(), prov, "instructions", nil, nil, newDisplay(), 150*time.Millisecond)
	})
	if err == nil {
		t.Fatal("streamModelTurn = nil error, want the idle timeout reported")
	}
	if !strings.Contains(err.Error(), "idle") {
		t.Fatalf("error = %v, want an idle-timeout error", err)
	}
	if !attempt.progress || attempt.text != "partial" {
		t.Fatalf("attempt = %+v, want progress and the streamed text", attempt)
	}
	if len(attempt.items) != 0 {
		t.Fatalf("attempt.items = %v, want none before completion", attempt.items)
	}
}

// TestStreamModelTurnIdleTimeoutIgnoresLifecycle covers what counts as
// activity: a provider that only sends "still working" lifecycle events,
// without ever producing output, is still treated as idle, so a stalled
// request is not kept alive forever by chatter.
func TestStreamModelTurnIdleTimeoutIgnoresLifecycle(t *testing.T) {
	prov, _ := scriptedProvider(t, func(w http.ResponseWriter, r *http.Request) {
		ticker := time.NewTicker(30 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-r.Context().Done():
				return
			case <-ticker.C:
				if _, err := io.WriteString(w, "data: {\"type\":\"response.in_progress\"}\n\n"); err != nil {
					return
				}
				if f, ok := w.(http.Flusher); ok {
					f.Flush()
				}
			}
		}
	})

	type result struct {
		attempt streamAttempt
		err     error
	}
	ch := make(chan result, 1)
	start := time.Now()
	go func() {
		attempt, err := streamModelTurn(context.Background(), prov, "instructions", nil, nil, newDisplay(), 200*time.Millisecond)
		ch <- result{attempt, err}
	}()

	select {
	case res := <-ch:
		if res.err == nil {
			t.Fatal("streamModelTurn = nil error, want the idle timeout enforced despite lifecycle events")
		}
		if !strings.Contains(res.err.Error(), "idle") {
			t.Fatalf("error = %v, want an idle-timeout error", res.err)
		}
		if res.attempt.progress {
			t.Fatalf("progress = true, want no output to have arrived: %+v", res.attempt)
		}
		if elapsed := time.Since(start); elapsed > time.Second {
			t.Fatalf("idle timeout took %v, want it near the 200ms limit", elapsed)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("the idle timeout never fired")
	}
}
