package main

import (
	"reflect"
	"testing"
)

// TestReasoningFromEnv covers how OPENAI_REASONING_EFFORT becomes a request
// field: the off values send nothing, and any other value is trimmed,
// lower-cased, and passed through so a proxy can accept levels the OpenAI API
// does not name.
func TestReasoningFromEnv(t *testing.T) {
	cases := []struct {
		env  string
		want string // effort, or "" for no reasoning object
	}{
		{"", ""},
		{"none", ""},
		{"off", ""},
		{"OFF", ""},
		{"default", ""},
		{"low", "low"},
		{"medium", "medium"},
		{" HIGH ", "high"},
		{"xhigh", "xhigh"}, // endpoint-specific levels pass through
	}
	for _, tc := range cases {
		t.Run(tc.env, func(t *testing.T) {
			t.Setenv(reasoningEffortEnv, tc.env)
			got := reasoningFromEnv()
			if tc.want == "" {
				if got != nil {
					t.Fatalf("reasoningFromEnv() = %+v, want nil", got)
				}
				return
			}
			if got == nil {
				t.Fatalf("reasoningFromEnv() = nil, want effort %q", tc.want)
			}
			if got.Effort != tc.want {
				t.Fatalf("effort = %q, want %q", got.Effort, tc.want)
			}
		})
	}
}

// TestConfiguredReasoningEffort checks the raw value /models displays.
func TestConfiguredReasoningEffort(t *testing.T) {
	t.Setenv(reasoningEffortEnv, "  High ")
	if got := configuredReasoningEffort(); got != "high" {
		t.Fatalf("configuredReasoningEffort() = %q, want %q", got, "high")
	}
}

// TestInferReasoningEfforts covers the built-in model-family table, which is
// the only source of reasoning levels for the standard /models response.
func TestInferReasoningEfforts(t *testing.T) {
	cases := []struct {
		id    string
		want  []string
		known bool
	}{
		{"gpt-5", []string{"minimal", "low", "medium", "high"}, true},
		{"gpt-5-mini", []string{"minimal", "low", "medium", "high"}, true},
		{"gpt-5-chat", nil, true},
		{"o3-mini", []string{"low", "medium", "high"}, true},
		{"o3-pro", nil, true},
		{"openai/o1-preview", []string{"low", "medium", "high"}, true},
		{"gpt-4o", nil, true},
		{"gpt-4o-mini", nil, true},
		{"text-embedding-3-small", nil, true},
		{"llama-3.1-8b", nil, false},
		{"some-random-model", nil, false},
	}
	for _, tc := range cases {
		got, known := inferReasoningEfforts(tc.id)
		if known != tc.known {
			t.Fatalf("inferReasoningEfforts(%q) known = %v, want %v", tc.id, known, tc.known)
		}
		if known && !reflect.DeepEqual(got, tc.want) {
			t.Fatalf("inferReasoningEfforts(%q) = %v, want %v", tc.id, got, tc.want)
		}
	}
}

// TestNormalizeEfforts checks the cleanup applied to endpoint-reported levels:
// trimmed, lower-cased, de-duplicated, and ordered weakest first, with any
// endpoint-specific levels kept after the documented ones.
func TestNormalizeEfforts(t *testing.T) {
	cases := []struct {
		in, want []string
	}{
		{nil, nil},
		{[]string{"High", "low", "MEDIUM", "high", ""}, []string{"low", "medium", "high"}},
		{[]string{"xhigh", "low"}, []string{"low", "xhigh"}},
		{[]string{" medium "}, []string{"medium"}},
	}
	for _, tc := range cases {
		got := normalizeEfforts(tc.in)
		if !reflect.DeepEqual(got, tc.want) {
			t.Fatalf("normalizeEfforts(%v) = %v, want %v", tc.in, got, tc.want)
		}
	}
}
