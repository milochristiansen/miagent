package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	openai "github.com/sashabaranov/go-openai"
)

// TestEstimateAndContextTokens covers how the context size is derived: a
// usage record sizes everything up to the items it covers, everything after
// the newest one of those is estimated from text length, and a record that
// says nothing about what it covered only bounds the total from below.
func TestEstimateAndContextTokens(t *testing.T) {
	// Four items of 400 chars each: 100 estimated tokens apiece.
	filler := strings.Repeat("x", 400)
	items := []StoredItem{
		{Role: "user", Content: filler},
		{Role: "assistant", Content: filler},
		{Role: "user", Content: filler},
		{Role: "assistant", Content: filler},
	}

	t.Run("no usage", func(t *testing.T) {
		s := &Session{Items: items}
		got, measured := s.contextTokens()
		if measured {
			t.Fatal("measured = true with no usage record")
		}
		if want := 400; got != want {
			t.Fatalf("tokens = %d, want %d", got, want)
		}
	})

	t.Run("anchored measurement", func(t *testing.T) {
		// The provider measured 1000 in + 50 out for the first two items;
		// the two after them are estimated on top.
		s := &Session{
			Items:  items,
			Usages: []Usage{{InputTokens: 1000, OutputTokens: 50, AtItems: 2}},
		}
		got, measured := s.contextTokens()
		if !measured {
			t.Fatal("measured = false with a usage record")
		}
		if want := 1050 + 200; got != want {
			t.Fatalf("tokens = %d, want %d", got, want)
		}
	})

	t.Run("measurement of the whole conversation", func(t *testing.T) {
		// A record covering every item needs no correction: its count is
		// the size, whatever the text would suggest.
		s := &Session{
			Items:  items,
			Usages: []Usage{{InputTokens: 1000, OutputTokens: 50, AtItems: 4}},
		}
		got, measured := s.contextTokens()
		if !measured {
			t.Fatal("measured = false with a usage record")
		}
		if want := 1050; got != want {
			t.Fatalf("tokens = %d, want %d", got, want)
		}
	})

	t.Run("span between two records", func(t *testing.T) {
		// Two records: 1000 tokens up to the second item and 3000 up to the
		// fourth. The tokens between them are the difference between the
		// counts, not the 200 the text suggests.
		s := &Session{
			Items: items,
			Usages: []Usage{
				{InputTokens: 950, OutputTokens: 50, AtItems: 2},
				{InputTokens: 2900, OutputTokens: 100, AtItems: 4},
			},
		}
		got, measured := s.contextTokens()
		if !measured {
			t.Fatal("measured = false with usage records")
		}
		if want := 3000; got != want {
			t.Fatalf("tokens = %d, want %d", got, want)
		}
		if got, want := newTokenIndex(s.Items, s.Usages).suffix(2), 2000; got != want {
			t.Fatalf("tokens from item 2 on = %d, want the measured %d", got, want)
		}
	})

	t.Run("a count that does not grow", func(t *testing.T) {
		// A second count no larger than the first cannot be placed after it,
		// since a context only grows: the first record stays the anchor and
		// the rest of the conversation is estimated on top of it.
		s := &Session{
			Items: items,
			Usages: []Usage{
				{InputTokens: 500, AtItems: 2},
				{InputTokens: 200, AtItems: 3},
			},
		}
		got, measured := s.contextTokens()
		if !measured {
			t.Fatal("measured = false with usage records")
		}
		if want := 500 + 200; got != want {
			t.Fatalf("tokens = %d, want %d", got, want)
		}
	})

	t.Run("unanchored record", func(t *testing.T) {
		// A record with no AtItems cannot be placed in the conversation: it
		// measures a prefix of it, which is all the size that record bounds
		// from below.
		s := &Session{
			Items:  items,
			Usages: []Usage{{InputTokens: 1000, OutputTokens: 50}},
		}
		got, measured := s.contextTokens()
		if !measured {
			t.Fatal("measured = false with a usage record")
		}
		if want := 1050; got != want {
			t.Fatalf("tokens = %d, want %d", got, want)
		}
	})
}

// TestFindCutPoint covers where a compaction splits: never at an item that
// must stay with what precedes it, always reporting the turn being split so
// its prefix can be summarized separately, and sizing the conversation from
// the provider's measurements where a session has them.
func TestFindCutPoint(t *testing.T) {
	// One turn's worth of items, ~100 estimated tokens each.
	big := strings.Repeat("x", 400)
	turn := func() []StoredItem {
		return []StoredItem{
			{Role: "user", Content: big}, // 0
			{Role: "reasoning", Reasoning: &reasoning{Content: []ReasoningPart{{Text: big}}}}, // 1
			{Role: "function_call", Name: "bash", Arguments: big},                             // 2
			{Role: "function_call_output", Output: big},                                       // 3
			{Role: "assistant", Content: big},                                                 // 4
		}
	}
	items := append(append(turn(), turn()...), turn()...) // 15 items

	t.Run("keeps the tail", func(t *testing.T) {
		cut := newTokenIndex(items, nil).findCutPoint(300)
		if cut.firstKept <= 0 {
			t.Fatalf("firstKept = %d, want a cut inside the conversation", cut.firstKept)
		}
		// The kept range must never open with an item that needs what came
		// before it: a tool result belongs with its call. Reasoning is the
		// one exception, and then only because the cut stepped back to keep
		// it with the reply that follows.
		switch got := items[cut.firstKept].Role; got {
		case "function_call_output":
			t.Fatalf("cut at %s: kept range would open with an orphaned tool result", got)
		case "reasoning":
			if next := items[cut.firstKept+1].Role; next != "assistant" && next != "function_call" {
				t.Fatalf("reasoning kept at %d without its reply (next is %s)", cut.firstKept, next)
			}
		}
		if !cut.split {
			t.Fatal("split = false, want the mid-turn cut reported")
		}
		if got := items[cut.turnStart].Role; got != "user" {
			t.Fatalf("turnStart role = %s, want the turn's user message", got)
		}
		if cut.turnStart >= cut.firstKept {
			t.Fatalf("turnStart = %d, firstKept = %d: the prefix must precede what is kept", cut.turnStart, cut.firstKept)
		}
	})

	t.Run("everything fits", func(t *testing.T) {
		cut := newTokenIndex(items, nil).findCutPoint(1_000_000)
		if cut.firstKept != 0 {
			t.Fatalf("firstKept = %d, want 0 when the budget covers everything", cut.firstKept)
		}
	})

	t.Run("tail-heavy fallback", func(t *testing.T) {
		// The budget is consumed by a trailing tool result that cannot start
		// the kept range: the cut falls back to the last valid cut point
		// rather than refusing to compact.
		items := []StoredItem{
			{Role: "user", Content: big},
			{Role: "assistant", Content: big},
			{Role: "function_call", Name: "bash", Arguments: big},
			{Role: "function_call_output", Output: strings.Repeat("x", 40000)},
		}
		cut := newTokenIndex(items, nil).findCutPoint(10)
		if cut.firstKept == 3 {
			t.Fatal("cut at the tool result: kept range would open with an orphaned output")
		}
		if cut.firstKept != 2 {
			t.Fatalf("firstKept = %d, want 2 (the last valid cut point)", cut.firstKept)
		}
	})

	t.Run("reasoning stays with its reply", func(t *testing.T) {
		// The budget lands exactly on the assistant message, with reasoning
		// before it: the cut steps back so the two stay together.
		items := []StoredItem{
			{Role: "user", Content: big},
			{Role: "reasoning", Reasoning: &reasoning{Content: []ReasoningPart{{Text: big}}}},
			{Role: "assistant", Content: big},
		}
		cut := newTokenIndex(items, nil).findCutPoint(100)
		if cut.firstKept != 1 {
			t.Fatalf("firstKept = %d, want 1 (reasoning kept with its reply)", cut.firstKept)
		}
	})

	t.Run("measured size, not guessed", func(t *testing.T) {
		// Three turns of ~200 tokens of text each, two of whose openings the
		// provider measured: the first turn at 1000 tokens and the second —
		// a tool-heavy one, say — at 2000 in the span from the first
		// measurement to the second, where the text suggests 200.
		items := []StoredItem{
			{Role: "user", Content: big},      // 0, turn 1
			{Role: "assistant", Content: big}, // 1
			{Role: "user", Content: big},      // 2, turn 2
			{Role: "assistant", Content: big}, // 3
			{Role: "user", Content: big},      // 4, turn 3
			{Role: "assistant", Content: big}, // 5
		}
		usages := []Usage{
			{InputTokens: 900, OutputTokens: 100, AtItems: 2},
			{InputTokens: 2900, OutputTokens: 100, AtItems: 4},
		}

		// What the provider measured decides the cut: a 400-token budget
		// reaches back into the second turn, and one of 2000, under which the
		// whole text-sized conversation would sit, back to its opening.
		// The same conversation without the measurements is the 600 tokens of
		// text it looks like, so the two budgets land elsewhere.
		for _, tc := range []struct {
			name      string
			usages    []Usage
			keep      int
			firstKept int
		}{
			{"measured, 400-token budget", usages, 400, 3},
			{"measured, 2000-token budget", usages, 2000, 2},
			{"estimated, 400-token budget", nil, 400, 2},
			{"estimated, 2000-token budget", nil, 2000, 0},
		} {
			cut := newTokenIndex(items, tc.usages).findCutPoint(tc.keep)
			if cut.firstKept != tc.firstKept {
				t.Fatalf("%s: firstKept = %d, want %d", tc.name, cut.firstKept, tc.firstKept)
			}
		}
	})
}

// TestSerializeConversation covers the text a summarization request carries:
// every kind of item, tool results capped, and a previous summary withheld
// from the text so it can drive the update prompt instead.
func TestSerializeConversation(t *testing.T) {
	long := strings.Repeat("y", toolResultSummaryChars+25)
	items := []StoredItem{
		{Role: "compaction", Content: "previous summary"},
		{Role: "user", Content: "do a thing"},
		{Role: "reasoning", Reasoning: &reasoning{Content: []ReasoningPart{{Text: "thinking hard"}}}},
		{Role: "assistant", Content: "on it"},
		{Role: "function_call", Name: "bash", Arguments: `{"command":"ls -la","n":2}`},
		{Role: "function_call_output", Output: long},
	}
	text, previous := serializeConversation(items)

	if previous != "previous summary" {
		t.Fatalf("previous summary = %q, want it extracted", previous)
	}
	if strings.Contains(text, "previous summary") {
		t.Fatal("the previous summary leaked into the conversation text")
	}
	for _, want := range []string{
		"[User]: do a thing",
		"[Assistant thinking]: thinking hard",
		"[Assistant]: on it",
		`[Assistant tool calls]: bash(command="ls -la", n=2)`,
		"[Tool result]: ",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("text is missing %q:\n%s", want, text)
		}
	}
	if !strings.Contains(text, "[... 25 more characters truncated]") {
		t.Fatalf("long tool result was not truncated:\n%s", text)
	}
}

// TestTruncateForSummaryKeepsRunes covers the cap landing inside a character:
// the text the model is shown has to be valid UTF-8, and the count of what was
// dropped is in characters, not bytes.
func TestTruncateForSummaryKeepsRunes(t *testing.T) {
	text := strings.Repeat("é", 10) // 20 bytes, 10 characters
	got := truncateForSummary(text, 5)
	if !utf8.ValidString(got) {
		t.Fatalf("truncated text is not valid UTF-8: %q", got)
	}
	if !strings.HasPrefix(got, "éé") {
		t.Fatalf("truncated text = %q, want the characters that fit", got)
	}
	if !strings.Contains(got, "[... 8 more characters truncated]") {
		t.Fatalf("truncated text = %q, want the dropped characters counted", got)
	}
	// Text within the cap is returned whole, multibyte or not.
	if got := truncateForSummary(text, len(text)); got != text {
		t.Fatalf("truncateForSummary(whole) = %q, want it unchanged", got)
	}
}

// TestCompactWithoutSessionFile covers the first-time case: there is nothing to
// summarize, so /compact reports that rather than failing on a stat, and it
// does not need the prompts or the provider to say so.
func TestCompactWithoutSessionFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "session.jsonl")
	s := newSession(path)

	var out string
	out = captureStdout(t, func() {
		// A provider with no client at all: reaching one would panic, which is
		// the point — a missing session is not a model call.
		if err := (&provider{}).compact(context.Background(), s, newDisplay()); err != nil {
			t.Fatalf("compact: %v", err)
		}
	})
	if !strings.Contains(out, "nothing to compact: no session file at "+path) {
		t.Fatalf("output = %q, want the missing session reported", out)
	}
	if entries, err := os.ReadDir(dir); err != nil {
		t.Fatal(err)
	} else if len(entries) != 0 {
		t.Fatalf("compact wrote %d entries into an empty session directory", len(entries))
	}
}

// TestSessionRoundTripsCompaction covers the format: a compacted session
// writes a record plus the summary item, reloads with its carried usage and
// compacted state, and replays the summary as a user message wrapped the way
// earlier sessions were.
func TestSessionRoundTripsCompaction(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	kept := []StoredItem{
		{Role: "compaction", Content: "## Goal\nsummarized"},
		{Role: "user", Content: "next thing"},
		{Role: "assistant", Content: "done"},
	}
	rec := compactionRecord{
		Type:         "compaction",
		Archived:     ".prepak-20260101T000000Z-session.jsonl",
		Created:      "2026-01-01T00:00:00Z",
		TokensBefore: 5000,
		TokensAfter:  100,
		Usage:        Usage{InputTokens: 700, OutputTokens: 90},
	}
	content, err := compactedSessionBytes(rec, kept)
	if err != nil {
		t.Fatal(err)
	}
	if err := writeSessionFile(path, content); err != nil {
		t.Fatal(err)
	}

	s := newSession(path)
	if err := s.load(); err != nil {
		t.Fatalf("load: %v", err)
	}
	if !s.Compacted {
		t.Fatal("Compacted = false after loading a compaction record")
	}
	if got := (Usage{InputTokens: 700, OutputTokens: 90}); s.Carried != got {
		t.Fatalf("Carried = %+v, want %+v", s.Carried, got)
	}
	if len(s.Items) != 3 || s.Items[0].Role != "compaction" {
		t.Fatalf("items = %+v, want the summary first", s.Items)
	}
	if _, measured := s.contextTokens(); measured {
		t.Fatal("a freshly compacted session should have no measurement yet")
	}

	in := itemsToInput(s.Items)
	if len(in) != 3 {
		t.Fatalf("input items = %d, want 3", len(in))
	}
	msg, ok := in[0].(openai.ResponseInputMessage)
	if !ok {
		t.Fatalf("first input item is %T, want a message", in[0])
	}
	if msg.Role != "user" {
		t.Fatalf("summary message role = %q, want user", msg.Role)
	}
	parts, ok := msg.Content.([]openai.ResponseInputText)
	if !ok || len(parts) != 1 {
		t.Fatalf("summary content = %#v, want one text part", msg.Content)
	}
	want := compactionPrefix + "## Goal\nsummarized" + compactionSuffix
	if parts[0].Text != want {
		t.Fatalf("summary text = %q, want %q", parts[0].Text, want)
	}
}

// TestArchiveName covers the archive naming rule, including the dot move and
// collisions.
func TestArchiveName(t *testing.T) {
	ts := time.Date(2026, 9, 10, 2, 45, 12, 0, time.UTC)
	cases := map[string]string{
		".session.jsonl": ".prepak-20260910T024512Z-session.jsonl",
		"session.jsonl":  "prepak-20260910T024512Z-session.jsonl",
		"chat.jsonl":     "prepak-20260910T024512Z-chat.jsonl",
		".":              "prepak-20260910T024512Z-.",
		".jsonl":         ".prepak-20260910T024512Z-jsonl",
	}
	for base, want := range cases {
		if got := archiveName(base, ts); got != want {
			t.Errorf("archiveName(%q) = %q, want %q", base, got, want)
		}
	}

	dir := t.TempDir()
	name := ".prepak-20260910T024512Z-session.jsonl"
	taken := filepath.Join(dir, name)
	if err := os.WriteFile(taken, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	ext := filepath.Ext(name)
	got, err := uniquePath(dir, strings.TrimSuffix(name, ext), ext)
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(dir, ".prepak-20260910T024512Z-session-1.jsonl"); got != want {
		t.Fatalf("collision path = %q, want %q", got, want)
	}
}

// TestLoadCompactPrompts covers the prompt files: all four are read, and a
// missing one fails the load rather than a run.
func TestLoadCompactPrompts(t *testing.T) {
	dir := promptsFixture(t)

	system := "system prompt text"
	initial := "initial prompt text"
	update := "update prompt text"
	prefix := "prefix prompt text"
	for name, text := range map[string]string{
		"COMPACT-SYSTEM.md":  system,
		"COMPACT-INITIAL.md": initial,
		"COMPACT-UPDATE.md":  update,
		"COMPACT-PREFIX.md":  prefix,
	} {
		// Written with a trailing newline: loadPrompt trims it.
		if err := os.WriteFile(filepath.Join(dir, name), []byte(text+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	got, err := loadCompactPrompts()
	if err != nil {
		t.Fatalf("loadCompactPrompts: %v", err)
	}
	if got.System != system || got.Initial != initial || got.Update != update || got.TurnPrefix != prefix {
		t.Fatalf("prompts = %+v, want the four files trimmed of their newline", got)
	}

	if err := os.Remove(filepath.Join(dir, "COMPACT-UPDATE.md")); err != nil {
		t.Fatal(err)
	}
	if _, err := loadCompactPrompts(); err == nil {
		t.Fatal("loadCompactPrompts accepted a missing prompt file")
	}
}

// TestCompactEndToEnd covers the whole command against a stub provider: the
// archive holds the pre-compaction session, the session file is replaced by
// the record, summary, and kept items, cost carries forward, and a second run
// finds nothing to do.
func TestCompactEndToEnd(t *testing.T) {
	dir := t.TempDir()
	promptDir := promptsFixture(t)
	for name, text := range map[string]string{
		"COMPACT-SYSTEM.md":  "summarize",
		"COMPACT-INITIAL.md": "initial format",
		"COMPACT-UPDATE.md":  "update rules",
		"COMPACT-PREFIX.md":  "prefix format",
	} {
		if err := os.WriteFile(filepath.Join(promptDir, name), []byte(text+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// A session of two turns whose ~400 tokens of text the provider measured
	// at 1040: a request carries the instructions and the tool schemas too,
	// and it is that measurement, not the text, that sizes the conversation.
	big := strings.Repeat("x", 400)
	path := filepath.Join(dir, ".session.jsonl")
	s := newSession(path)
	s.Items = []StoredItem{
		{Role: "user", Content: big},
		{Role: "assistant", Content: big},
		{Role: "user", Content: big},
		{Role: "assistant", Content: big},
	}
	s.Usages = []Usage{{InputTokens: 1000, OutputTokens: 40, AtItems: 4}}
	if err := s.commit(); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}

	var summarized string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req map[string]any
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Errorf("stub provider: %v", err)
		}
		if in, ok := req["input"].([]any); ok && len(in) > 0 {
			if msg, ok := in[0].(map[string]any); ok {
				if content, ok := msg["content"].([]any); ok && len(content) > 0 {
					if part, ok := content[0].(map[string]any); ok {
						summarized, _ = part["text"].(string)
					}
				}
			}
		}
		_, _ = w.Write([]byte(`{"status":"completed","output":[{"type":"message","role":"assistant",
			"content":[{"type":"output_text","text":"## Goal\nstub summary"}]}],
			"usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}`))
	}))
	defer srv.Close()

	prov := &provider{client: newTestClient(srv.URL), model: "stub"}
	t.Setenv("MIAGENT_KEEP_RECENT_TOKENS", "150")

	out := captureStdout(t, func() {
		if err := prov.compact(context.Background(), s, newDisplay()); err != nil {
			t.Fatalf("compact: %v", err)
		}
	})
	if !strings.Contains(out, "compacted") || !strings.Contains(out, "archived as ") || !strings.Contains(out, "prepak-") {
		t.Fatalf("output = %q", out)
	}
	// The sizes are the measured ones, not what the text suggests: 1040
	// tokens, of which the 150-token retention budget reaches back to the
	// second turn, leaving its two items where the text alone would have
	// counted the whole conversation as 400.
	if !strings.Contains(out, "compacting: replacing 2 items with a summary (1,040 tokens)") {
		t.Fatalf("output = %q, want the measured size", out)
	}
	if !strings.Contains(out, "compacted 1,040 -> 205 tokens (kept tail measured, summary estimated); replaced 2 items, kept 2 as they were") {
		t.Fatalf("output = %q, want the measured sizes", out)
	}
	// The line names the archive's location, not just its file name: with the
	// session inside a state directory, a bare name would not be findable.
	if !strings.Contains(out, filepath.Join(dir, ".prepak-")) {
		t.Fatalf("output = %q, want the archive path", out)
	}
	if strings.Contains(out, "$") {
		t.Fatalf("output = %q, want no cost figure", out)
	}
	if !strings.Contains(summarized, "<conversation>") {
		t.Fatalf("the summarization request did not carry the conversation: %q", summarized)
	}

	// The archive holds the pre-compaction session, byte for byte.
	archives, err := filepath.Glob(filepath.Join(dir, ".prepak-*.jsonl"))
	if err != nil || len(archives) != 1 {
		t.Fatalf("archives = %v (err %v), want exactly one", archives, err)
	}
	archived, err := os.ReadFile(archives[0])
	if err != nil {
		t.Fatal(err)
	}
	if string(archived) != string(before) {
		t.Fatal("the archive does not match the pre-compaction session")
	}

	// The new session: header, record, summary, and the kept items.
	reloaded := newSession(path)
	if err := reloaded.load(); err != nil {
		t.Fatalf("reloading the compacted session: %v", err)
	}
	if !reloaded.Compacted {
		t.Fatal("reloaded session is not marked compacted")
	}
	if len(reloaded.Items) == 0 || reloaded.Items[0].Role != "compaction" {
		t.Fatalf("items = %+v, want the summary first", reloaded.Items)
	}
	// The cut lands on the second turn's opening request, so its summary
	// stands alone.
	wantSummary := "## Goal\nstub summary"
	if reloaded.Items[0].Content != wantSummary {
		t.Fatalf("summary = %q, want %q", reloaded.Items[0].Content, wantSummary)
	}
	// Kept items are the tail the retention budget spared; the rest became
	// the summary, and the archive holds all four originals (checked below).
	if kept := len(reloaded.Items) - 1; kept != 2 {
		t.Fatalf("kept %d items, want 2", kept)
	}
	// Cost carries forward: the archived turns' usage plus the summary call's.
	want := Usage{InputTokens: 1000 + 100, OutputTokens: 40 + 20}
	if got := reloaded.total(); got.InputTokens != want.InputTokens || got.OutputTokens != want.OutputTokens {
		t.Fatalf("carried usage = %+v, want %+v", got, want)
	}
	// The file on disk already holds everything, so nothing is pending.
	if reloaded.committed != len(reloaded.Items) {
		t.Fatalf("committed = %d, items = %d: a later turn would duplicate records", reloaded.committed, len(reloaded.Items))
	}
	// A second run has nothing to summarize.
	out = captureStdout(t, func() {
		if err := prov.compact(context.Background(), reloaded, newDisplay()); err != nil {
			t.Fatalf("second compact: %v", err)
		}
	})
	if !strings.Contains(out, "nothing to compact") {
		t.Fatalf("second run output = %q, want nothing to compact", out)
	}
	if after, err := os.ReadFile(path); err != nil || string(after) == "" {
		t.Fatalf("session file after the no-op run: %v %v", after, err)
	}

	// The archive is itself loadable: the full conversation survives.
	restored := newSession(archives[0])
	if err := restored.load(); err != nil {
		t.Fatalf("loading the archive: %v", err)
	}
	if len(restored.Items) != 4 {
		t.Fatalf("archive items = %d, want the 4 original items", len(restored.Items))
	}
}

// TestCompactLeavesSessionAloneOnProviderFailure covers the promise that a
// failed summarization costs nothing: no rewrite, no archive, no temp file.
func TestCompactLeavesSessionAloneOnProviderFailure(t *testing.T) {
	dir := t.TempDir()
	promptDir := promptsFixture(t)
	for _, name := range []string{"COMPACT-SYSTEM.md", "COMPACT-INITIAL.md", "COMPACT-UPDATE.md", "COMPACT-PREFIX.md"} {
		if err := os.WriteFile(filepath.Join(promptDir, name), []byte("prompt"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	big := strings.Repeat("x", 400)
	path := filepath.Join(dir, "session.jsonl")
	s := newSession(path)
	s.Items = []StoredItem{
		{Role: "user", Content: big},
		{Role: "assistant", Content: big},
		{Role: "user", Content: big},
		{Role: "assistant", Content: big},
	}
	s.Usages = []Usage{{InputTokens: 1000, OutputTokens: 40, AtItems: 4}}
	if err := s.commit(); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	itemsBefore := len(s.Items)

	// A provider that fails, and one that "succeeds" with nothing to say:
	// an empty summary would silently delete the conversation it replaced.
	bodies := map[string]string{
		"provider error": "",
		"empty summary": `{"status":"completed","output":[{"type":"message","role":"assistant",
			"content":[{"type":"output_text","text":"   "}]}],
			"usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}`,
	}
	for name, body := range bodies {
		t.Run(name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if body == "" {
					http.Error(w, "boom", http.StatusInternalServerError)
					return
				}
				_, _ = w.Write([]byte(body))
			}))
			defer srv.Close()

			prov := &provider{client: newTestClient(srv.URL), model: "stub"}
			t.Setenv("MIAGENT_KEEP_RECENT_TOKENS", "150")
			if err := prov.compact(context.Background(), s, newDisplay()); err == nil {
				t.Fatal("compact succeeded, want a failure")
			}

			after, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if string(after) != string(before) {
				t.Fatal("the session file changed after a failed compaction")
			}
			if len(s.Items) != itemsBefore {
				t.Fatalf("in-memory items changed: %d, want %d", len(s.Items), itemsBefore)
			}
			if s.Compacted || s.Carried != (Usage{}) {
				t.Fatalf("session state changed: compacted=%v carried=%+v", s.Compacted, s.Carried)
			}
			entries, err := os.ReadDir(dir)
			if err != nil {
				t.Fatal(err)
			}
			for _, e := range entries {
				if strings.Contains(e.Name(), "prepak") || strings.Contains(e.Name(), ".tmp") {
					t.Fatalf("a failed compaction left %s behind", e.Name())
				}
			}
		})
	}
}

// newTestClient returns a client talking to a stub server.
func newTestClient(baseURL string) *openai.Client {
	cfg := openai.DefaultConfig("test-key")
	cfg.BaseURL = baseURL
	return openai.NewClientWithConfig(cfg)
}

// promptsFixture creates the configuration directory's prompts subdirectory
// and returns it, so a test can write prompt files into it.
func promptsFixture(t *testing.T) string {
	t.Helper()
	dir := filepath.Join(configFixture(t), promptsDir)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	return dir
}

// configFixture points XDG_CONFIG_HOME at a fresh directory holding this
// package's config directory, and returns that directory so a test can write
// files into it.
func configFixture(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", root)
	// An ambient MIAGENT_CONFIG_DIR would shadow the fixture; clear it so the
	// directory under test is the one resolved from XDG_CONFIG_HOME.
	t.Setenv(configDirEnv, "")
	dir := filepath.Join(root, configName)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	return dir
}
