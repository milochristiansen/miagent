package termark

import (
	"fmt"
	"strings"
	"testing"
)

// terminal is a minimal screen emulator for the cursor protocol LiveBox uses:
// carriage return, newline (with the tty driver's CR translation), cursor-up,
// erase-to-end-of-line, erase-to-end-of-screen, and ignored SGR. It lets a
// test assert the box's final on-screen shape rather than the raw byte stream.
type terminal struct {
	rows  [][]rune
	row   int
	col   int
	width int // 0 disables autowrap
}

func (t *terminal) ensure(row int) {
	for len(t.rows) <= row {
		t.rows = append(t.rows, nil)
	}
}

func (t *terminal) put(r rune) {
	// Deferred autowrap: a glyph at the right margin stays on its row and the
	// next glyph wraps.
	if t.width > 0 && t.col >= t.width {
		t.row++
		t.col = 0
	}
	t.ensure(t.row)
	line := t.rows[t.row]
	for len(line) <= t.col {
		line = append(line, ' ')
	}
	line[t.col] = r
	t.rows[t.row] = line
	t.col++
}

func (t *terminal) clearLine() {
	if t.row >= len(t.rows) {
		return
	}
	if t.col < len(t.rows[t.row]) {
		t.rows[t.row] = t.rows[t.row][:t.col]
	}
}

func (t *terminal) clearScreen() {
	t.clearLine()
	for i := t.row + 1; i < len(t.rows); i++ {
		t.rows[i] = nil
	}
}

func (t *terminal) feed(s string) {
	rs := []rune(s)
	for i := 0; i < len(rs); {
		if rs[i] != 0x1b {
			switch rs[i] {
			case '\r':
				t.col = 0
			case '\n':
				t.row++
				t.col = 0
			default:
				t.put(rs[i])
			}
			i++
			continue
		}
		// An escape sequence: only CSI matters here.
		if i+1 >= len(rs) || rs[i+1] != '[' {
			i += 2
			continue
		}
		j := i + 2
		for j < len(rs) && (rs[j] < 0x40 || rs[j] > 0x7e) {
			j++
		}
		if j >= len(rs) {
			break
		}
		params, final := string(rs[i+2:j]), rs[j]
		switch final {
		case 'A':
			n := 1
			if params != "" {
				fmt.Sscanf(params, "%d", &n)
			}
			t.row -= n
			if t.row < 0 {
				t.row = 0
			}
		case 'K':
			t.clearLine()
		case 'J':
			t.clearScreen()
		case 'm': // styling: not visible
		}
		i = j + 1
	}
}

// lines returns the screen's rows, trailing spaces trimmed.
func (t *terminal) lines() []string {
	out := make([]string, len(t.rows))
	for i, r := range t.rows {
		out[i] = strings.TrimRight(string(r), " ")
	}
	return out
}

// screenRows feeds a box's byte stream through the emulator and returns the
// non-empty rows, borders included, so a test can check both the content and
// the box's overall height.
func screenRows(stream string) []string {
	return screenRowsWidth(stream, 0)
}

// screenRowsWidth is screenRows on a terminal of the given width, so wrapped
// rows can be checked.
func screenRowsWidth(stream string, width int) []string {
	t := &terminal{width: width}
	t.feed(stream)
	var out []string
	for _, l := range t.lines() {
		if l != "" {
			out = append(out, l)
		}
	}
	return out
}

// contentRowsOf returns the screen rows that are not borders.
func contentRowsOf(rows []string) []string {
	var out []string
	for _, l := range rows {
		if !strings.ContainsRune(l, '─') {
			out = append(out, l)
		}
	}
	return out
}

func TestLimitRows(t *testing.T) {
	cases := []struct {
		limit, height, want int
	}{
		{0, 24, 0},   // unlimited stays unlimited
		{-1, 24, 0},  // negative is treated as unlimited
		{10, 24, 10}, // fits
		{10, 0, 10},  // height unknown: no cap
		{30, 24, 24}, // capped at the screen height
		{24, 24, 24}, // exactly the height
	}
	for _, tc := range cases {
		if got := limitRows(tc.limit, tc.height); got != tc.want {
			t.Errorf("limitRows(%d, %d) = %d, want %d", tc.limit, tc.height, got, tc.want)
		}
	}
}

// TestLiveBoxWindowedShowsLastRows covers the capped output: the box keeps its
// height and shows a window over the most recent rows, so a long stream scrolls
// within the box instead of growing it.
func TestLiveBoxWindowedShowsLastRows(t *testing.T) {
	var out strings.Builder
	b := NewLiveBox(&out, 3)
	b.Header("tool")
	b.Header("output")
	for _, l := range []string{"one\n", "two\n", "three\n", "four\n", "five\n"} {
		if _, err := b.Out().Write([]byte(l)); err != nil {
			t.Fatal(err)
		}
	}
	b.End(0)

	rows := screenRows(out.String())
	if got, want := len(rows), 6; got != want { // 2 headers + 3 window rows + footer
		t.Fatalf("box has %d rows, want %d:\n%s", got, want, strings.Join(rows, "\n"))
	}
	want := []string{"three", "four", "five"}
	if got := contentRowsOf(rows); !equalStrings(got, want) {
		t.Fatalf("window = %q, want %q", got, want)
	}
}

// TestLiveBoxWindowedTail covers a partially arrived row: the current line is
// the last row of the window and is redrawn as its characters arrive.
func TestLiveBoxWindowedTail(t *testing.T) {
	var out strings.Builder
	b := NewLiveBox(&out, 2)
	b.Header("tool")
	b.Header("output")
	for _, p := range []string{"a\n", "b\n", "c", "d"} {
		if _, err := b.Out().Write([]byte(p)); err != nil {
			t.Fatal(err)
		}
	}
	b.End(0)

	rows := screenRows(out.String())
	if got := contentRowsOf(rows); !equalStrings(got, []string{"b", "cd"}) {
		t.Fatalf("window = %q, want [b cd]", got)
	}
}

// TestLiveBoxWindowedStderrInterleaves covers both pipes sharing the window in
// arrival order.
func TestLiveBoxWindowedStderrInterleaves(t *testing.T) {
	var out strings.Builder
	b := NewLiveBox(&out, 3)
	b.Header("tool")
	b.Header("output")
	b.Out().Write([]byte("out one\n"))
	b.Err().Write([]byte("err one\n"))
	b.Out().Write([]byte("out two\n"))
	b.End(1)

	rows := screenRows(out.String())
	content := contentRowsOf(rows)
	want := []string{"out one", "err one", "out two", "(exit 1)"}
	if !equalStrings(content, want) {
		t.Fatalf("window = %q, want %q", content, want)
	}
}

// TestLiveBoxInputCap covers the argument section: rows past the cap are
// dropped, so the static part cannot grow the box without bound.
func TestLiveBoxInputCap(t *testing.T) {
	var out strings.Builder
	b := NewLiveBox(&out, 2)
	b.Header("tool")
	b.Row("a")
	b.Row("b")
	b.Row("c") // over the cap
	b.Header("output")
	b.End(0)

	rows := screenRows(out.String())
	if got := contentRowsOf(rows); !equalStrings(got, []string{"a", "b"}) {
		t.Fatalf("arguments = %q, want [a b]", got)
	}
}

// TestLiveBoxUnlimitedShowsAll covers the 0 (unlimited) mode: every streamed
// row is committed, as the box always did.
func TestLiveBoxUnlimitedShowsAll(t *testing.T) {
	var out strings.Builder
	b := NewLiveBox(&out)
	b.Header("tool")
	b.Header("output")
	for _, l := range []string{"one\n", "two\n", "three\n", "four\n", "five\n"} {
		b.Out().Write([]byte(l))
	}
	b.End(0)

	rows := screenRows(out.String())
	want := []string{"one", "two", "three", "four", "five"}
	if got := contentRowsOf(rows); !equalStrings(got, want) {
		t.Fatalf("unlimited window = %q, want %q", got, want)
	}
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// TestLiveBoxWindowedConcurrentWrites covers the two tool pipes writing at
// once: the mutex must serialize whole redraws, and the window must stay at
// its cap no matter how the chunks interleave. Run with -race.
func TestLiveBoxWindowedConcurrentWrites(t *testing.T) {
	var out strings.Builder
	b := NewLiveBox(&out, 4)
	b.Header("tool")
	b.Header("output")

	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; i < 50; i++ {
			fmt.Fprintf(b.Out(), "out %d\n", i)
		}
	}()
	for i := 0; i < 50; i++ {
		fmt.Fprintf(b.Err(), "err %d\n", i)
	}
	<-done
	b.End(0)

	rows := screenRows(out.String())
	if got := contentRowsOf(rows); len(got) != 4 {
		t.Fatalf("Window = %d rows, want 4:\n%q", len(got), got)
	}
}

// TestLiveBoxWindowedWraps covers a logical row wider than the terminal at a
// window height below the screen: the redraw has to count physical rows, or
// backing up to repaint lands mid-row and scrambles the box.
func TestLiveBoxWindowedWraps(t *testing.T) {
	var out strings.Builder
	b := NewLiveBox(&out, 5)
	b.W = 10
	b.Header("tool")
	b.Header("output")
	b.Out().Write([]byte("0123456789abcdef\nshort\n"))
	b.End(0)

	rows := screenRowsWidth(out.String(), 10)
	want := []string{"0123456789", "abcdef", "short"}
	if got := contentRowsOf(rows); !equalStrings(got, want) {
		t.Fatalf("wrapped window = %q, want %q\n%s", got, want, strings.Join(rows, "\n"))
	}
}

// TestLiveBoxWindowedFitsWrappedScreen covers wrapped output on a short
// screen: logical rows are capped, but their physical rows are capped too, or
// the in-place redraw would run off the top of the terminal.
func TestLiveBoxWindowedFitsWrappedScreen(t *testing.T) {
	var out strings.Builder
	b := NewLiveBox(&out, 10)
	b.W = 10
	b.height = 3

	b.Header("tool")
	b.Header("output")
	for i := 0; i < 6; i++ {
		fmt.Fprintf(b.Out(), "line-%02d-abcdefghij\n", i)
	}
	b.End(0)

	if b.drawn > 3 {
		t.Fatalf("window is %d physical rows, want at most 3", b.drawn)
	}
	rows := screenRowsWidth(out.String(), 10)
	if content := contentRowsOf(rows); len(content) > 3 {
		t.Fatalf("screen shows %d content rows, want at most 3:\n%s", len(content), strings.Join(rows, "\n"))
	}
}
