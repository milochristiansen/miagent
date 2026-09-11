package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	openai "github.com/sashabaranov/go-openai"
)

// modelsStub serves a fixed /models document, so the tests can shape exactly
// what an endpoint reports.
func modelsStub(t *testing.T, body string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/models" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, body)
	}))
	t.Cleanup(srv.Close)
	return srv
}

// TestCmdModelsReportsEndpointMetadata covers the direct-read path: the harness
// knows the base URL, so it reads /models itself and uses the reasoning levels
// the endpoint reports, falling back to its own table for models that report
// none. The configured model is marked and its effort is named.
func TestCmdModelsReportsEndpointMetadata(t *testing.T) {
	body := `{"object":"list","data":[
		{"id":"alpha","reasoning":{"supported_efforts":["HIGH","low"]}},
		{"id":"gpt-4o"},
		{"id":"mystery"}
	]}`
	srv := modelsStub(t, body)
	prov := &provider{
		client:          newTestClient(srv.URL),
		baseURL:         srv.URL,
		apiKey:          "test-key",
		model:           "alpha",
		reasoningEffort: "high",
	}

	var out string
	var err error
	out = captureStdout(t, func() {
		err = cmdModels(context.Background(), prov, nil, newDisplay(), nil)
	})
	if err != nil {
		t.Fatalf("cmdModels: %v", err)
	}

	for _, want := range []string{
		"models at " + srv.URL + " (3):",
		"* alpha",
		"reasoning: low, high",
		"gpt-4o",
		"reasoning: none",
		"mystery",
		"reasoning: unknown",
		`configured: alpha, reasoning effort "high"`,
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("output missing %q:\n%s", want, out)
		}
	}
}

// TestCmdModelsFallsBackToSDK covers an endpoint whose base URL the harness
// does not hold — the SDK path, which yields only ids and leaves the reasoning
// levels to the built-in table.
func TestCmdModelsFallsBackToSDK(t *testing.T) {
	body := `{"object":"list","data":[{"id":"gpt-5"},{"id":"llama-3"}]}`
	srv := modelsStub(t, body)
	prov := &provider{client: newTestClient(srv.URL)}

	var out string
	var err error
	out = captureStdout(t, func() {
		err = cmdModels(context.Background(), prov, nil, newDisplay(), nil)
	})
	if err != nil {
		t.Fatalf("cmdModels: %v", err)
	}

	for _, want := range []string{
		"models at " + defaultBaseURL + " (2):",
		"gpt-5",
		"reasoning: minimal, low, medium, high",
		"llama-3",
		"reasoning: unknown",
		"no model configured; set OPENAI_MODEL",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("output missing %q:\n%s", want, out)
		}
	}
}

// TestCmdModelsRejectsArguments keeps the command's contract with the
// dispatcher: it takes none.
func TestCmdModelsRejectsArguments(t *testing.T) {
	if err := cmdModels(context.Background(), &provider{}, nil, newDisplay(), []string{"x"}); err == nil {
		t.Fatal("cmdModels accepted an argument, want an error")
	}
}

// TestRunModelTurnSendsReasoning checks that the configured effort reaches the
// request as the Responses API reasoning object.
func TestRunModelTurnSendsReasoning(t *testing.T) {
	requests := make(chan map[string]any, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		var body map[string]any
		_ = json.Unmarshal(raw, &body)
		requests <- body
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = io.WriteString(w, "data: "+completedText("done")+"\n\n")
		_, _ = io.WriteString(w, "data: [DONE]\n\n")
	}))
	t.Cleanup(srv.Close)

	prov := &provider{
		client:    newTestClient(srv.URL),
		model:     "stub",
		reasoning: &openai.ResponseReasoning{Effort: "high"},
	}
	var err error
	captureStdout(t, func() {
		_, _, _, err = runModelTurn(context.Background(), prov, "", nil, nil, newDisplay())
	})
	if err != nil {
		t.Fatalf("runModelTurn: %v", err)
	}

	body := <-requests
	reasoning, ok := body["reasoning"].(map[string]any)
	if !ok || reasoning["effort"] != "high" {
		t.Fatalf("request reasoning = %v, want {\"effort\":\"high\"}", body["reasoning"])
	}
}

// TestRunModelTurnOmitsReasoningWhenUnset is the other half: with no effort
// configured the request carries no reasoning object at all, leaving the
// endpoint's default in place.
func TestRunModelTurnOmitsReasoningWhenUnset(t *testing.T) {
	requests := make(chan map[string]any, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		var body map[string]any
		_ = json.Unmarshal(raw, &body)
		requests <- body
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = io.WriteString(w, "data: "+completedText("done")+"\n\n")
		_, _ = io.WriteString(w, "data: [DONE]\n\n")
	}))
	t.Cleanup(srv.Close)

	prov := &provider{client: newTestClient(srv.URL), model: "stub"}
	var err error
	captureStdout(t, func() {
		_, _, _, err = runModelTurn(context.Background(), prov, "", nil, nil, newDisplay())
	})
	if err != nil {
		t.Fatalf("runModelTurn: %v", err)
	}

	if body := <-requests; body["reasoning"] != nil {
		t.Fatalf("request reasoning = %v, want none", body["reasoning"])
	}
}

// TestDecodeModelMetadata covers the ways a router may report a model's
// reasoning levels, and the id-less entry that is skipped rather than shown as
// a blank row.
func TestDecodeModelMetadata(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		want []string
	}{
		{"reasoning.supported_efforts", `{"id":"m","reasoning":{"supported_efforts":["high","low"]}}`, []string{"low", "high"}},
		{"reasoning.efforts", `{"id":"m","reasoning":{"efforts":["high","low"]}}`, []string{"low", "high"}},
		{"reasoning.supported_effort", `{"id":"m","reasoning":{"supported_effort":"HIGH"}}`, []string{"high"}},
		{"reasoning_efforts", `{"id":"m","reasoning_efforts":["high","low"]}`, []string{"low", "high"}},
		{"supported_reasoning_levels", `{"id":"m","supported_reasoning_levels":["high","low"]}`, []string{"low", "high"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m, ok := decodeModel(json.RawMessage(tc.raw))
			if !ok {
				t.Fatal("decodeModel skipped a model with an id")
			}
			if !m.Known || !reflect.DeepEqual(m.Efforts, tc.want) {
				t.Fatalf("decodeModel = %+v, want known %v", m, tc.want)
			}
		})
	}

	if _, ok := decodeModel(json.RawMessage(`{"reasoning":{"supported_efforts":["high"]}}`)); ok {
		t.Fatal("decodeModel accepted a model without an id")
	}
}
