package termark

import (
	"strings"
	"testing"
)

// A terminal moves the cursor over the cells a tab crosses without painting
// them, so a tab left in a code-block row leaves the default background showing
// under the row's leading whitespace. Rows must therefore reach the terminal as
// spaces, with the tab stops counted in visible columns.

// contentRows returns the visible text of the rendered lines, dropping borders
// and blank rows, and applying in-place rewrites (an \r returns the cursor to
// column 0, so what follows rewrites that row).
func contentRows(lines []Line) []string {
	var rows []string
	for _, l := range lines {
		text := scrub(l.Bytes)
		if i := strings.LastIndexByte(text, '\r'); i >= 0 {
			text = text[i+1:]
		}
		if strings.TrimSpace(text) == "" || strings.ContainsRune(text, '─') {
			continue // blank row, or a header/footer border
		}
		rows = append(rows, text)
	}
	return rows
}

func checkRows(t *testing.T, got, want []string) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("rendered rows %q, want %q", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("row %d renders %q, want %q", i, got[i], want[i])
		}
	}
}

func TestBoxRowExpandsTabs(t *testing.T) {
	style := darkStyle()
	tests := []struct {
		name string
		text string
		want string
	}{
		{"leading", "\talpha", "    alpha"},
		{"two", "\t\talpha", "        alpha"},
		{"mid-line", "ab\tcd", "ab  cd"},
		{"on-stop", "abcdefgh\tcd", "abcdefgh    cd"},
		{"after-escape", fgSGR("203") + "ab" + resetSGR + "\tcd", "ab  cd"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var b strings.Builder
			boxRow(&b, style, tc.text, "")
			checkRows(t, contentRows(splitLines([]byte(b.String()))), []string{tc.want})
			if !strings.HasPrefix(b.String(), bgSGR(style.CodeBlockBG)) {
				t.Errorf("boxRow(%q) does not open with the code-block background", tc.text)
			}
		})
	}
}

func TestLiveBoxExpandsTabs(t *testing.T) {
	// The tab and the rest of the row arrive in separate writes: the column a
	// later chunk appends at must account for the text already on the row.
	var out strings.Builder
	b := NewLiveBox(&out)
	b.Header("t")
	b.Out().Write([]byte("ab"))
	b.Out().Write([]byte("\tcd\n"))
	b.Err().Write([]byte("\terr\n"))
	b.End(0)

	checkRows(t, contentRows(splitLines([]byte(out.String()))), []string{"ab  cd", "    err"})
}

func TestCodeBlockExpandsTabs(t *testing.T) {
	fr := newFragmentRenderer(darkStyle(), 40)
	tests := []struct {
		name string
		md   string
		want []string
	}{
		{name: "fence", md: "```\n\talpha\n```\n", want: []string{"    alpha"}},
		{name: "fence with language", md: "```go\n\talpha := 1\n```\n", want: []string{"    alpha := 1"}},
		{name: "fence with unknown language", md: "```notalang\n\talpha\n```\n", want: []string{"    alpha"}},
		// An indented code block is a CodeBlock, not a FencedCodeBlock: it
		// carries no info string, so it must render through the same body
		// path without asking a fence for its language.
		{name: "indented", md: "para\n\n    \talpha\n", want: []string{"para", "    alpha"}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			lines := fr.render([]byte(tc.md))
			checkRows(t, contentRows(lines), tc.want)
			for _, l := range lines {
				if got := scrub(l.Bytes); strings.TrimSpace(got) != "" && l.Width != displayWidth(got) {
					t.Errorf("code block %q renders %q with width %d, want %d", tc.md, got, l.Width, displayWidth(got))
				}
			}
		})
	}
}

// TestLineBreaksInABlock covers the newlines goldmark keeps out of a text
// segment: ignoring them runs the words on either side together, which is what
// model prose (wrapped at some column width) arrives with. A soft break — the
// newline that only wraps a line of one paragraph — is a space; a hard break
// keeps its own line; and a break with nothing after it adds no empty line,
// which the line count catches because contentRows filters blank rows out.
func TestLineBreaksInABlock(t *testing.T) {
	fr := newFragmentRenderer(darkStyle(), 40)
	cases := []struct {
		name string
		md   string
		want []string
	}{
		{"soft break", "hello\nworld\n", []string{"hello world"}},
		{"soft breaks in a list item", "- item one\n  continued\n", []string{"  • item one continued"}},
		{"hard break", "first  \nsecond\n", []string{"first", "second"}},
		{"backslash hard break", "first\\\nsecond\n", []string{"first", "second"}},
		{"nothing after the break", "only line\n", []string{"only line"}},
		{"break before emphasis", "one\n*two*\n", []string{"one two"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			lines := fr.render([]byte(tc.md))
			if len(lines) != len(tc.want) {
				t.Fatalf("rendered %d lines (%q), want %d", len(lines), lineStrings(lines), len(tc.want))
			}
			checkRows(t, contentRows(lines), tc.want)
		})
	}
}

// TestImageKeepsDestination covers the one part of an image a terminal can act
// on: the destination, rendered beside the alt text the way a link's is.
func TestImageKeepsDestination(t *testing.T) {
	fr := newFragmentRenderer(darkStyle(), 80)
	checkRows(t, contentRows(fr.render([]byte("![chart](https://example.com/c.png)\n"))),
		[]string{"[chart] (https://example.com/c.png)"})
}

// TestRenderingDoesNotWriteOutsideItsInput covers the aliasing goldmark brings
// with it: a segment's Value appends into the byte slice it is handed (a code
// block's last line carries ForceNewline, implemented as append(value, '\n')),
// so a parse given the renderer's buffer — which always has spare capacity, and
// is handed over trimmed of a trailing incomplete rune — would write past the
// part it was given and into bytes that are still arriving.
func TestRenderingDoesNotWriteOutsideItsInput(t *testing.T) {
	const doc = "```\ncode" // an unterminated fence: its last line carries ForceNewline
	raw := make([]byte, len(doc)+32)
	copy(raw, doc)
	sentinel := byte(0xAA) // buffered input the renderer has not handed over yet
	for i := len(doc); i < len(raw); i++ {
		raw[i] = sentinel
	}
	view := raw[:len(doc)]

	fr := newFragmentRenderer(darkStyle(), 40)
	fr.render(view)
	fr.topLevelBlocks(view)

	for i := len(doc); i < len(raw); i++ {
		if raw[i] != sentinel {
			t.Fatalf("byte %d past the input is now %#x: the parse wrote into the caller's buffer", i, raw[i])
		}
	}
}

// lineStrings renders lines as visible text, for failure messages.
func lineStrings(lines []Line) []string {
	out := make([]string, 0, len(lines))
	for _, l := range lines {
		out = append(out, scrub(l.Bytes))
	}
	return out
}
