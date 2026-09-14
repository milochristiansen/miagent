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
// the number dropped returned so the caller can report it on the header.
func TestToolcallInputLines(t *testing.T) {
	cases := []struct {
		name       string
		args       string
		limit      int
		want       []string
		wantElided int
	}{
		{"empty", "", 3, nil, 0},
		{"unlimited", "a\nb\nc\nd", 0, []string{"a", "b", "c", "d"}, 0},
		{"fits", "a\nb", 3, []string{"a", "b"}, 0},
		{"exact", "a\nb", 2, []string{"a", "b"}, 0},
		{"truncated", "a\nb\nc\nd\ne", 3, []string{"a", "b", "c"}, 2},
		{"single row", "a\nb\nc", 1, []string{"a"}, 2},
		{"trailing newline dropped", "a\n", 3, []string{"a"}, 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, elided := toolcallInputLines(tc.args, tc.limit)
			if !reflect.DeepEqual(got, tc.want) || elided != tc.wantElided {
				t.Fatalf("toolcallInputLines(%q, %d) = %q, %d, want %q, %d",
					tc.args, tc.limit, got, elided, tc.want, tc.wantElided)
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
