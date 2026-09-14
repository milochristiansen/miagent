package termark

import (
	"io"
	"os"
	"strings"

	"golang.org/x/term"
)

// boxWidth returns the terminal width for box borders, falling back to 80
// cells when w is not a terminal (or its size is unknown).
func boxWidth(w io.Writer) int {
	if f, ok := w.(*os.File); ok {
		if term.IsTerminal(int(f.Fd())) {
			if W, _, err := term.GetSize(int(f.Fd())); err == nil && W > 0 {
				return W
			}
		}
	}
	return 80
}

// boxHeight returns the terminal height for box borders, or 0 when w is not a
// terminal (or its size is unknown). A 0 means the height is unknown, so no
// screen-height cap is applied.
func boxHeight(w io.Writer) int {
	if f, ok := w.(*os.File); ok {
		if term.IsTerminal(int(f.Fd())) {
			if _, H, err := term.GetSize(int(f.Fd())); err == nil && H > 0 {
				return H
			}
		}
	}
	return 0
}

// boxBorder writes a full-width border row in the code-block foreground and
// background, embedding the label ("─ label ───…"; an empty label is a bare
// rule). An optional note is inset at the right end of the rule, which is
// where the box reports how many rows it has elided.
func boxBorder(w io.Writer, style Style, W int, label string, note ...string) {
	n := ""
	if len(note) > 0 {
		n = note[0]
	}
	if bg := style.CodeBlockBG; bg != "" {
		io.WriteString(w, bgSGR(bg))
	}
	if fg := style.CodeBlockColor; fg != "" {
		io.WriteString(w, fgSGR(fg))
	}
	io.WriteString(w, codeHeaderNote(label, n, W))
	io.WriteString(w, resetSGR)
	io.WriteString(w, "\n")
}

// codeHeaderNote builds a header border with a label on the left and a note
// inset at the right end: "─ label ───── note ─". It falls back to the plain
// label border when there is not room for both, so a long label or a long note
// degrades instead of overflowing.
func codeHeaderNote(label, note string, width int) string {
	if note == "" {
		return codeHeader(label, width)
	}
	left := ""
	if label != "" {
		left = "─ " + label + " "
	}
	right := " " + note + " ─"
	lw, rw := displayWidth(left), displayWidth(right)
	if lw+rw > width {
		return codeHeader(label, width)
	}
	return left + strings.Repeat("─", width-lw-rw) + right
}

// tabStop is the interval between tab stops: a tab advances to the next
// multiple of this many columns.
const tabStop = 4

// expandTabs returns text with every tab replaced by the spaces up to the next
// tab stop, counting visible columns from col, plus the column the text ends
// at. A terminal only moves the cursor over the cells a tab crosses — it never
// paints them — so a tab left in a code-block row drops the block's background
// from wherever the row is indented with one. Rows are therefore expanded to
// spaces before they are styled. ANSI escapes occupy no columns and are copied
// through, keeping a styled row aligned. Text without a tab is returned as is.
func expandTabs(text string, col int) (string, int) {
	if strings.IndexByte(text, '\t') < 0 {
		return text, col + visibleWidth(text)
	}
	var b strings.Builder
	b.Grow(len(text) + tabStop)
	for i := 0; i < len(text); {
		if text[i] == '\t' {
			n := tabStop - col%tabStop
			for range n {
				b.WriteByte(' ')
			}
			col += n
			i++
			continue
		}
		if text[i] == 0x1b {
			j := csiEnd(text, i)
			b.WriteString(text[i:j])
			i = j
			continue
		}
		j := i
		for j < len(text) && text[j] != '\t' && text[j] != 0x1b {
			j++
		}
		b.WriteString(text[i:j])
		col += displayWidth(text[i:j])
		i = j
	}
	return b.String(), col
}

// visibleWidth returns the display width of text, ignoring ANSI escapes.
func visibleWidth(text string) int {
	if strings.IndexByte(text, 0x1b) < 0 {
		return displayWidth(text)
	}
	return displayWidth(scrub([]byte(text)))
}

// boxRow writes one code-content row: the row background (re-opened after
// any reset inside the text), the row foreground (color, or the code-block
// color when empty), the text, and an EL fill so the row spans the full
// width without literal trailing spaces. Ends with a newline.
func boxRow(w io.Writer, style Style, text, color string) {
	text, _ = expandTabs(text, 0)
	bg := style.CodeBlockBG
	if bg != "" {
		io.WriteString(w, bgSGR(bg))
	}
	c := color
	if c == "" {
		c = style.CodeBlockColor
	}
	if c != "" {
		io.WriteString(w, fgSGR(c))
	}
	if bg != "" {
		text = strings.ReplaceAll(text, resetSGR, resetSGR+bgSGR(bg))
	}
	io.WriteString(w, text)
	if bg != "" {
		io.WriteString(w, "\x1b[K")
	}
	io.WriteString(w, resetSGR)
	io.WriteString(w, "\n")
}
