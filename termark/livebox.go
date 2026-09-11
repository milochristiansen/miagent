package termark

import (
	"bytes"
	"io"
	"strings"
	"sync"
)

// codeSeg is one colored run of text in the box's current (unterminated)
// row. Runs from stdout and stderr interleave in arrival order.
type codeSeg struct {
	color string // 256-color foreground; "" = code-block color
	text  string
}

// LiveBox renders an open code box whose rows can be appended live while the
// box is open, interleaving stdout and stderr in arrival order. It is used
// for tool calls: the harness draws the header and output border, tees the
// tool's two pipes into Out/Err while it runs, then closes the box with a
// footer. Whole lines commit and scroll; an unterminated row is rewritten in
// place on each update. A mutex serializes all writes so the two stream
// goroutines never interleave bytes mid-row.
type LiveBox struct {
	w     io.Writer
	mu    sync.Mutex
	style Style
	W     int

	open bool
	tail []codeSeg // the current unterminated row (drawn live)
}

// NewLiveBox creates a live code box writing to w (the dark style, width
// from the terminal). The caller draws the box's headers and rows, tees
// output into Out/Err, and finishes with End.
func NewLiveBox(w io.Writer) *LiveBox {
	return &LiveBox{w: w, style: darkStyle(), W: boxWidth(w), open: true}
}

// Header draws a full-width border row embedding label.
func (b *LiveBox) Header(label string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if !b.open {
		return
	}
	boxBorder(b.w, b.style, b.W, label)
}

// Row commits one content row in the code-block color (used for static
// content such as the tool call's arguments).
func (b *LiveBox) Row(text string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if !b.open {
		return
	}
	boxRow(b.w, b.style, text, "")
}

// Out returns the writer for the tool's stdout stream (code-block color).
func (b *LiveBox) Out() io.Writer { return boxStream{b: b, stderr: false} }

// Err returns the writer for the tool's stderr stream (the style's error
// color — light red in the dark style).
func (b *LiveBox) Err() io.Writer { return boxStream{b: b, stderr: true} }

// End commits any unterminated row, draws an "(exit N)" note for non-zero
// exits, closes the box with a footer border, and makes further writes
// no-ops.
func (b *LiveBox) End(code int) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if !b.open {
		return
	}
	b.open = false
	if len(b.tail) > 0 {
		// The tail row is already on screen (drawn live): commit it.
		b.tail = nil
		io.WriteString(b.w, "\n")
	}
	if code != 0 {
		b.rowNote(code)
	}
	boxBorder(b.w, b.style, b.W, "")
}

// boxStream adapts one of the tool's pipes to LiveBox. Write returns len(p)
// unconditionally: the box has no failure mode beyond the write itself.
type boxStream struct {
	b      *LiveBox
	stderr bool
}

func (s boxStream) Write(p []byte) (int, error) {
	s.b.append(s.stderr, p)
	return len(p), nil
}

// append splits a chunk into complete lines and a trailing partial run.
// Lines from the two streams interleave in arrival order because append
// serializes on b.mu. A line whose text arrived in earlier chunks is already
// displayed live, so committing it emits only a newline; a line completed
// entirely within this chunk is printed now.
func (b *LiveBox) append(stderr bool, p []byte) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if !b.open {
		return
	}
	color := ""
	if stderr {
		color = b.style.CodeColor
	}

	// had reports whether the current row started in an earlier write (and
	// is therefore already on screen).
	had := len(b.tail) > 0
	segs := b.tail
	b.tail = nil

	data := p
	for len(data) > 0 {
		i := bytes.IndexByte(data, '\n')
		if i < 0 {
			break
		}
		segs = append(segs, codeSeg{color, string(data[:i])})
		if had {
			// The row is live on screen; rewrite it in place with the
			// completed content and commit it.
			b.commitLiveRow(segs)
		} else {
			b.commitSegs(segs)
		}
		had = false
		segs = nil
		data = data[i+1:]
	}
	if len(data) > 0 {
		b.tail = append(segs, codeSeg{color, string(data)})
		b.drawTail()
	}
}

// commitSegs emits one complete row (all its colored runs) followed by a
// newline. Called with b.mu held.
func (b *LiveBox) commitSegs(segs []codeSeg) {
	b.drawSegs(segs)
	io.WriteString(b.w, "\n")
}

// commitLiveRow rewrites the current live row in place with segs and commits
// it: carriage return to its start (the cursor is at the end of the tail
// text), the row's runs, then a newline. Called with b.mu held.
func (b *LiveBox) commitLiveRow(segs []codeSeg) {
	io.WriteString(b.w, "\r")
	b.drawSegs(segs)
	io.WriteString(b.w, "\n")
}

// drawTail rewrites the box's current (unterminated) row in place: carriage
// return, then the row's colored runs. The tail's row is live on screen, so
// committing it later emits only a newline. Called with b.mu held.
func (b *LiveBox) drawTail() {
	io.WriteString(b.w, "\r")
	b.drawSegs(b.tail)
}

// drawSegs renders a row's colored runs at the cursor without a newline. Tabs
// are expanded to tab stops, with the column carried across the runs so a tab
// in a later run still lands on the row's stops. Called with b.mu held.
func (b *LiveBox) drawSegs(segs []codeSeg) {
	bg := b.bgSeq()
	if bg != "" {
		io.WriteString(b.w, bg)
	}
	col := 0
	for _, s := range segs {
		if fg := b.fgSeq(s.color); fg != "" {
			io.WriteString(b.w, fg)
		}
		text, next := expandTabs(s.text, col)
		col = next
		if bg != "" {
			text = strings.ReplaceAll(text, resetSGR, resetSGR+bg)
		}
		io.WriteString(b.w, text)
	}
	if bg != "" {
		io.WriteString(b.w, "\x1b[K")
	}
	io.WriteString(b.w, resetSGR)
}

// rowNote draws the exit-code note row before the footer.
func (b *LiveBox) rowNote(code int) {
	boxRow(b.w, b.style, "(exit "+itoa(code)+")", "")
}

func (b *LiveBox) bgSeq() string {
	if b.style.CodeBlockBG == "" {
		return ""
	}
	return bgSGR(b.style.CodeBlockBG)
}

func (b *LiveBox) fgSeq(color string) string {
	c := color
	if c == "" {
		c = b.style.CodeBlockColor
	}
	if c == "" {
		return ""
	}
	return fgSGR(c)
}
