package main

import (
	"reflect"
	"testing"
)

// TestToolcallSizeFromEnv covers MIAGENT_TOOLCALL_SIZE: unset is the default,
// 0 means unlimited, a positive integer is itself, and a malformed value is an
// error rather than a silent fallback.
func TestToolcallSizeFromEnv(t *testing.T) {
	cases := []struct {
		env   string
		want  int
		isErr bool
	}{
		{"", defaultToolcallSize, false},
		{"   ", defaultToolcallSize, false},
		{"0", 0, false},
		{"5", 5, false},
		{" 7 ", 7, false},
		{"-1", 0, true},
		{"abc", 0, true},
		{"1.5", 0, true},
	}
	for _, tc := range cases {
		t.Run(tc.env, func(t *testing.T) {
			t.Setenv(toolcallSizeEnv, tc.env)
			got, err := toolcallSizeFromEnv()
			if tc.isErr {
				if err == nil {
					t.Fatalf("toolcallSizeFromEnv() = %d, want an error", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("toolcallSizeFromEnv() error = %v", err)
			}
			if got != tc.want {
				t.Fatalf("toolcallSizeFromEnv() = %d, want %d", got, tc.want)
			}
		})
	}
}

// TestToolcallInputLines covers the argument window: at most limit rows, with
// a note replacing the last row when rows are dropped so the reader can tell
// the call was truncated.
func TestToolcallInputLines(t *testing.T) {
	cases := []struct {
		name  string
		args  string
		limit int
		want  []string
	}{
		{"empty", "", 3, nil},
		{"unlimited", "a\nb\nc\nd", 0, []string{"a", "b", "c", "d"}},
		{"fits", "a\nb", 3, []string{"a", "b"}},
		{"exact", "a\nb", 2, []string{"a", "b"}},
		{"truncated", "a\nb\nc\nd\ne", 3, []string{"a", "b", "… (3 more lines)"}},
		{"single row", "a\nb\nc", 1, []string{"a"}},
		{"trailing newline dropped", "a\n", 3, []string{"a"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := toolcallInputLines(tc.args, tc.limit)
			if !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("toolcallInputLines(%q, %d) = %q, want %q", tc.args, tc.limit, got, tc.want)
			}
		})
	}
}

// TestNewDisplayReadsToolcallSize covers the display wiring: the size is read
// once when the display is built, and a malformed value is kept for main to
// report rather than crashing the display.
func TestNewDisplayReadsToolcallSize(t *testing.T) {
	t.Setenv(toolcallSizeEnv, "4")
	d := newDisplay()
	if d.toolSize != 4 {
		t.Fatalf("toolSize = %d, want 4", d.toolSize)
	}
	if d.toolSizeErr != nil {
		t.Fatalf("toolSizeErr = %v, want nil", d.toolSizeErr)
	}

	t.Setenv(toolcallSizeEnv, "nope")
	d = newDisplay()
	if d.toolSizeErr == nil {
		t.Fatal("toolSizeErr = nil, want the malformed value reported")
	}
}
