// Tests for the resilience of a model turn: retrying a call that produced
// nothing, continuing one that was cut off mid-answer, and the idle timeout
// that turns a stalled connection into one of those two cases.
package main

import (
	"bytes"
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
	// The streamed text is carried as a partial item, so a caller that
	// keeps the turn does not lose output the display already showed.
	if got := assistantText(attempt.items); got != "partial" {
		t.Fatalf("attempt.items = %+v, want the streamed text as an assistant item", attempt.items)
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

// functionCallAdded is a response.output_item.added event for a function call.
func functionCallAdded(id, callID, name string) string {
	return `{"type":"response.output_item.added","item":{"id":` + quote(id) +
		`,"type":"function_call","call_id":` + quote(callID) + `,"name":` + quote(name) + `}}`
}

// functionArgsDelta is one response.function_call_arguments.delta event.
func functionArgsDelta(id, delta string) string {
	return `{"type":"response.function_call_arguments.delta","item_id":` + quote(id) + `,"delta":` + quote(delta) + `}`
}

// reasoningDelta is one response.reasoning_text.delta event.
func reasoningDelta(id, delta string) string {
	return `{"type":"response.reasoning_text.delta","item_id":` + quote(id) + `,"content_index":0,"delta":` + quote(delta) + `}`
}

// TestStreamModelTurnKeepsPartialFunctionCall covers what a stream that dies
// mid-call carries: the call's identity and the arguments that arrived before
// the failure, so an interrupted turn can still record what the model asked
// for.
func TestStreamModelTurnKeepsPartialFunctionCall(t *testing.T) {
	release := make(chan struct{})
	prov, _ := scriptedProvider(t, func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintf(w, "data: %s\n\n", functionCallAdded("fc_1", "call_1", "bash"))
		fmt.Fprintf(w, "data: %s\n\n", functionArgsDelta("fc_1", `{"command":`))
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		<-release
	})
	t.Cleanup(func() { close(release) })

	attempt, err := streamModelTurn(context.Background(), prov, "instructions", nil, nil, newDisplay(), 150*time.Millisecond)
	if err == nil {
		t.Fatal("streamModelTurn = nil error, want the idle timeout reported")
	}
	var call *StoredItem
	for i := range attempt.items {
		if attempt.items[i].Role == "function_call" {
			call = &attempt.items[i]
		}
	}
	if call == nil {
		t.Fatalf("attempt.items = %+v, want the partial function call", attempt.items)
	}
	if call.CallID != "call_1" || call.Name != "bash" || call.Arguments != `{"command":` {
		t.Fatalf("call = %+v, want the partial arguments and the call's identity", call)
	}
}

// TestStreamModelTurnKeepsPartialReasoning covers the thinking an interrupted
// stream produced: it is carried as a reasoning item, so the context the model
// already established survives even though the reply never finished.
func TestStreamModelTurnKeepsPartialReasoning(t *testing.T) {
	release := make(chan struct{})
	prov, _ := scriptedProvider(t, func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintf(w, "data: %s\n\n", reasoningDelta("rs_1", "thinking"))
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		<-release
	})
	t.Cleanup(func() { close(release) })

	var (
		attempt streamAttempt
		err     error
	)
	_ = captureStderr(t, func() {
		attempt, err = streamModelTurn(context.Background(), prov, "instructions", nil, nil, newDisplay(), 150*time.Millisecond)
	})
	if err == nil {
		t.Fatal("streamModelTurn = nil error, want the idle timeout reported")
	}
	var rs *StoredItem
	for i := range attempt.items {
		if attempt.items[i].Role == "reasoning" {
			rs = &attempt.items[i]
		}
	}
	if rs == nil || rs.Reasoning == nil || len(rs.Reasoning.Content) != 1 || rs.Reasoning.Content[0].Text != "thinking" {
		t.Fatalf("attempt.items = %+v, want the partial reasoning text", attempt.items)
	}
}

// TestRunModelTurnKeepsTextStreamedBeforeGivingUp covers a turn that streamed
// part of an answer, lost the connection, and then could not be resumed: the
// text already shown is returned so the caller persists it rather than losing
// an answer the reader has seen.
func TestRunModelTurnKeepsTextStreamedBeforeGivingUp(t *testing.T) {
	prov, bodies := scriptedProvider(t,
		func(w http.ResponseWriter, _ *http.Request) {
			// Half an answer, then the connection ends without completing.
			fmt.Fprintf(w, "data: %s\n\n", textDelta("kept "))
		},
		// Every later attempt is an unscripted request, which fails before
		// streaming anything.
	)

	items := []StoredItem(nil)
	err := error(nil)
	_ = captureStdout(t, func() {
		items, _, _, err = runModelTurn(context.Background(), prov, "instructions", nil, nil, newDisplay())
	})
	if err == nil {
		t.Fatal("runModelTurn = nil error, want the failure reported")
	}
	if got := assistantText(items); got != "kept " {
		t.Fatalf("stored answer = %q, want the text streamed before the failure", got)
	}
	if got, want := len(bodies()), maxModelRetries+2; got != want {
		t.Fatalf("provider saw %d requests, want %d (the streamed attempt plus the retries)", got, want)
	}
}

// TestRunModelTurnKeepsPartialAnswerOnInterrupt covers the interrupt path: a
// turn whose stream is cancelled returns the text streamed before the signal
// instead of dropping it, so the caller can persist an incomplete turn.
func TestRunModelTurnKeepsPartialAnswerOnInterrupt(t *testing.T) {
	prov, _ := scriptedProvider(t, func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "data: %s\n\n", textDelta("Half an "))
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		<-r.Context().Done()
	})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// The turn runs in the background so the test can cancel it once the
	// streamed text has reached the display, which is when the delta is
	// safely in the turn's accumulators too.
	seen, stop := watchStdout(t)
	type turn struct {
		items []StoredItem
		final bool
		err   error
	}
	ch := make(chan turn, 1)
	go func() {
		items, _, final, err := runModelTurn(ctx, prov, "instructions", nil, nil, newDisplay())
		ch <- turn{items, final, err}
	}()

	waitForOutput(t, seen, "Half an ")
	cancel()

	select {
	case got := <-ch:
		stop()
		if got.err == nil {
			t.Fatal("runModelTurn = nil error, want the interrupt reported")
		}
		if got.final {
			t.Fatal("final = true, want the turn reported as unfinished")
		}
		if text := assistantText(got.items); text != "Half an " {
			t.Fatalf("stored answer = %q, want the streamed prefix", text)
		}
	case <-time.After(5 * time.Second):
		stop()
		t.Fatal("runModelTurn did not return after the interrupt")
	}
}

// TestUnansweredToolOutputs covers the repair an interrupted turn applies
// before it is saved: every function call the model made gets an output, so
// the partial turn is still a conversation the provider accepts.
func TestUnansweredToolOutputs(t *testing.T) {
	items := []StoredItem{
		{Role: "assistant", Content: "let me look"},
		{Role: "function_call", CallID: "c0", Name: "bash", Arguments: `{"command":"ls"}`},
		{Role: "function_call_output", CallID: "c0", Output: "done"},
		{Role: "function_call", CallID: "c1", Name: "bash", Arguments: `{"command":`},
	}
	out := unansweredToolOutputs(items)
	if len(out) != 1 {
		t.Fatalf("unansweredToolOutputs = %+v, want one output for the unanswered call", out)
	}
	if out[0].Role != "function_call_output" || out[0].CallID != "c1" {
		t.Fatalf("output = %+v, want a function_call_output for c1", out[0])
	}
	if !strings.Contains(out[0].Output, "interrupted") {
		t.Fatalf("output = %q, want it to say the call was interrupted", out[0].Output)
	}
}

// watchStdout redirects os.Stdout to a pipe while a turn runs and returns a
// predicate that reports whether the output so far contains a string, plus a
// stop function that restores os.Stdout and returns everything written.
func watchStdout(t *testing.T) (seen func(string) bool, stop func() string) {
	t.Helper()
	old := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout = w

	var mu sync.Mutex
	var buf bytes.Buffer
	done := make(chan struct{})
	go func() {
		defer close(done)
		b := make([]byte, 4096)
		for {
			n, err := r.Read(b)
			if n > 0 {
				mu.Lock()
				buf.Write(b[:n])
				mu.Unlock()
			}
			if err != nil {
				return
			}
		}
	}()

	seen = func(sub string) bool {
		mu.Lock()
		defer mu.Unlock()
		return strings.Contains(buf.String(), sub)
	}
	stop = func() string {
		os.Stdout = old
		_ = w.Close()
		<-done
		_ = r.Close()
		mu.Lock()
		defer mu.Unlock()
		return buf.String()
	}
	// Restore os.Stdout even if a test fails before calling stop, so a
	// leaked pipe cannot swallow the output of every later test.
	t.Cleanup(func() { stop() })
	return seen, stop
}

// waitForOutput waits until seen reports sub, or fails the test.
func waitForOutput(t *testing.T, seen func(string) bool, sub string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !seen(sub) {
		if time.Now().After(deadline) {
			t.Fatalf("output never contained %q", sub)
		}
		time.Sleep(2 * time.Millisecond)
	}
}
