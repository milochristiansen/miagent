// Tests for the pre-turn context guard: the environment setting it reads, and
// the decision it makes from a session's measured or estimated size.
package main

import (
	"strings"
	"testing"
)

func TestContextHeadroomFromEnv(t *testing.T) {
	cases := []struct {
		name string
		env  string
		want int
		bad  bool
	}{
		{name: "unset is the default"},
		{name: "blank is the default", env: "  "},
		{name: "zero disables", env: "0", want: 0},
		{name: "a percentage", env: "25", want: 25},
		{name: "full window", env: "100", want: 100},
		{name: "not a number", env: "ten", bad: true},
		{name: "negative", env: "-1", bad: true},
		{name: "over a hundred", env: "101", bad: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv(contextHeadroomEnv, tc.env)
			got, err := contextHeadroomFromEnv()
			if tc.bad {
				if err == nil {
					t.Fatalf("contextHeadroomFromEnv = %d, want an error", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("contextHeadroomFromEnv: %v", err)
			}
			want := tc.want
			if tc.name == "unset is the default" || tc.name == "blank is the default" {
				want = defaultContextHeadroom
			}
			if got != want {
				t.Fatalf("contextHeadroomFromEnv = %d, want %d", got, want)
			}
		})
	}
}

// sessionAtTokens returns a session whose measured size is exactly tokens: one
// item covered by one usage record.
func sessionAtTokens(tokens int) *Session {
	return &Session{
		Items:  []StoredItem{{Role: "user", Content: "hello"}},
		Usages: []Usage{{InputTokens: tokens, AtItems: 1}},
	}
}

func TestContextRefusal(t *testing.T) {
	cases := []struct {
		name     string
		limit    string
		headroom int
		used     int
		refuse   bool
	}{
		{name: "no limit configured", limit: "", headroom: 10, used: 99999},
		{name: "headroom disabled", limit: "100000", headroom: 0, used: 99999},
		{name: "plenty left", limit: "100000", headroom: 10, used: 50000},
		{name: "boundary is allowed", limit: "100000", headroom: 10, used: 90000},
		{name: "just inside", limit: "100000", headroom: 10, used: 90001, refuse: true},
		{name: "nearly full", limit: "100000", headroom: 10, used: 95000, refuse: true},
		{name: "over the limit", limit: "100000", headroom: 10, used: 100500, refuse: true},
		{name: "custom headroom", limit: "100000", headroom: 25, used: 80000, refuse: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv(contextLimitEnv, tc.limit)
			note, refuse, err := contextRefusal(sessionAtTokens(tc.used), tc.headroom)
			if err != nil {
				t.Fatalf("contextRefusal: %v", err)
			}
			if refuse != tc.refuse {
				t.Fatalf("refuse = %v, want %v (note %q)", refuse, tc.refuse, note)
			}
			if tc.refuse && !strings.Contains(note, "/compact") {
				t.Fatalf("note = %q, want it to point at /compact", note)
			}
		})
	}
}

// TestContextRefusalEstimates covers a session with no usage to measure: the
// guard still uses the estimate /context reports, labels it as estimated, and
// refuses when it leaves too little room.
func TestContextRefusalEstimates(t *testing.T) {
	t.Setenv(contextLimitEnv, "10")
	s := &Session{Items: []StoredItem{{Role: "user", Content: strings.Repeat("x", 400)}}}
	note, refuse, err := contextRefusal(s, 10)
	if err != nil {
		t.Fatalf("contextRefusal: %v", err)
	}
	if !refuse {
		t.Fatalf("refuse = false, want the estimated size to refuse (note %q)", note)
	}
	if !strings.Contains(note, "estimated") {
		t.Fatalf("note = %q, want it labelled estimated", note)
	}
}

func TestContextRefusalMalformedLimit(t *testing.T) {
	t.Setenv(contextLimitEnv, "lots")
	if _, _, err := contextRefusal(sessionAtTokens(1), 10); err == nil {
		t.Fatal("contextRefusal = nil error, want a malformed limit reported")
	}
}
