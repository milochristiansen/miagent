package termark

import (
	"bytes"
	"fmt"
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
// footer. A mutex serializes all writes so the two stream goroutines never
// interleave bytes mid-row.
//
// The box has two kinds of rows. Static rows — the border headers and the
// tool call's arguments, added with Header and Row — are written once, in
// order. Streamed rows, written through Out and Err, are the tool's output.
//
// When Limit is 0, streamed rows are committed with a newline as they complete
// and scroll the terminal like any other output; an unterminated row is
// rewritten in place on each update. When Limit is positive, the streamed
// output is instead a window over the last Limit rows: the box redraws that
// window (and only that window) in place as new output arrives, so the output
// scrolls within the box rather than scrolling the screen. Static rows are
// still written once, so a box whose static part is taller than the screen
// scrolls it once when the call starts; the output window never does. Limit is
// reduced to the terminal height when that is known, because a taller window
// cannot be redrawn in place without running off the top of the screen.
type LiveBox struct {
	w     io.Writer
	mu    sync.Mutex
	style Style
	W     int

	// Limit is the per-section cap on content rows: the arguments and the
	// streamed output are each limited to this many rows. 0 means unlimited.
	// It is reduced to the terminal height by NewLiveBox.
	Limit int

	// height is the terminal height (0 when unknown). The output window is
	// kept no taller than this many physical rows, which can be fewer logical
	// rows when long lines soft-wrap.
	height int

	open bool

	// tail is the current unterminated streamed row. In unlimited mode it is
	// drawn live as it grows; in windowed mode it is the newest row of the
	// output window. It is guarded by mu.
	tail []codeSeg

	// Windowed mode (Limit > 0). out holds the completed streamed rows, oldest
	// first, at most Limit of them; drawn is how many output rows are
	// currently on screen. Both are guarded by mu.
	out   [][]codeSeg
	drawn int

	// inputs counts the argument rows Row has committed, for the input cap.
	inputs int
}

// NewLiveBox creates a live code box writing to w (the dark style, width from
// the terminal). An optional limit caps each content section (see LiveBox);
// with no limit, or a limit of 0, every row is shown. A positive limit is
// reduced to the terminal height.
func NewLiveBox(w io.Writer, limit ...int) *LiveBox {
	n := 0
	if len(limit) > 0 {
		n = limit[0]
	}
	h := boxHeight(w)
	return &LiveBox{
		w:      w,
		style:  darkStyle(),
		W:      boxWidth(w),
		Limit:  limitRows(n, h),
		height: h,
		open:   true,
	}
}

// limitRows returns the effective per-section row cap: limit reduced to the
// terminal height when that is known and smaller. A limit of 0 or less is
// unlimited (0), and an unknown height (0) leaves the limit alone.
func limitRows(limit, height int) int {
	if limit <= 0 {
		return 0
	}
	if height > 0 && limit > height {
		return height
	}
	return limit
}

// Header draws a full-width border row embedding label. It is static: written
// once and never redrawn.
func (b *LiveBox) Header(label string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if !b.open {
		return
	}
	boxBorder(b.w, b.style, b.W, label)
}

// Row commits one content row in the code-block color (used for static
// content such as the tool call's arguments). It is written once, like Header.
// In windowed mode rows past Limit are dropped, so the arguments cannot grow
// the box without bound.
func (b *LiveBox) Row(text string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if !b.open {
		return
	}
	if b.Limit > 0 && b.inputs >= b.Limit {
		return
	}
	b.inputs++
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

	if b.Limit > 0 {
		// The window is already on screen with the cursor at the end of its
		// last row (or, with no output, just below the output border). Move
		// below it, then finish the box. The tail, if any, is already drawn as
		// the window's last row.
		if b.drawn > 0 {
			io.WriteString(b.w, "\r\n")
		}
		b.tail = nil
		if code != 0 {
			b.rowNote(code)
		}
		boxBorder(b.w, b.style, b.W, "")
		return
	}

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

// append routes a chunk to the mode-specific handler. A chunk is split into
// complete lines and a trailing partial run; lines from the two streams
// interleave in arrival order because append serializes on b.mu.
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
	if b.Limit > 0 {
		b.appendWindowed(color, p)
		return
	}
	b.appendUnlimited(color, p)
}

// appendUnlimited is the uncapped path. A line whose text arrived in earlier
// chunks is already displayed live, so committing it emits only a newline; a
// line completed entirely within this chunk is printed now.
func (b *LiveBox) appendUnlimited(color string, p []byte) {
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

// appendWindowed is the capped path. It folds the chunk into the completed
// rows and the partial tail, then redraws the output window in place. A window
// row is redrawn whether or not it started in an earlier chunk, because the
// whole window moves as new rows arrive.
func (b *LiveBox) appendWindowed(color string, p []byte) {
	segs := b.tail
	b.tail = nil

	data := p
	for len(data) > 0 {
		i := bytes.IndexByte(data, '\n')
		if i < 0 {
			break
		}
		segs = append(segs, codeSeg{color, string(data[:i])})
		b.addOut(segs)
		segs = nil
		data = data[i+1:]
	}
	if len(data) > 0 {
		b.tail = append(segs, codeSeg{color, string(data)})
	}
	b.redraw()
}

// addOut appends one completed output row, dropping the oldest once the window
// is full. Called with b.mu held.
func (b *LiveBox) addOut(segs []codeSeg) {
	b.out = append(b.out, segs)
	if len(b.out) > b.Limit {
		b.out = b.out[len(b.out)-b.Limit:]
	}
}

// window returns the rows the output window currently shows: the most recent
// completed rows, with the tail, when present, as the final row. At most
// b.Limit logical rows are returned, and, when the terminal height is known,
// no more physical rows than fit the screen: a long line that soft-wraps into
// several rows is trimmed from the top like any other. Called with b.mu held.
func (b *LiveBox) window() [][]codeSeg {
	var rows [][]codeSeg
	if len(b.tail) == 0 {
		rows = b.out
	} else {
		// Keep one slot for the partial row.
		maxCompleted := b.Limit - 1
		start := 0
		if len(b.out) > maxCompleted {
			start = len(b.out) - maxCompleted
		}
		rows = make([][]codeSeg, 0, len(b.out)-start+1)
		rows = append(rows, b.out[start:]...)
		rows = append(rows, b.tail)
	}

	// Wrapped rows count for more than one terminal row. Drop the oldest until
	// the window fits; always keep the newest row, even if it alone is taller
	// than the screen (there is nothing useful to show otherwise).
	if b.height > 0 {
		for len(rows) > 1 && b.physicalHeight(rows) > b.height {
			rows = rows[1:]
		}
	}
	return rows
}

// redraw repaints the output window in place. The cursor is assumed to be at
// the end of the window's last physical row (or at the window's top when
// nothing has been drawn), which is where the previous redraw left it. Called
// with b.mu held.
//
// Both the cursor movement and the erase work in physical rows: a logical row
// wider than the terminal soft-wraps into several, and a window taller than
// the screen cannot be redrawn in place. b.drawn records the physical height
// of the last paint, so the cursor can be returned to the window's first row.
func (b *LiveBox) redraw() {
	rows := b.window()

	// Back up to the window's first physical row and erase everything below
	// it, so a shorter repaint cannot leave stale cells on screen.
	if b.drawn > 0 {
		io.WriteString(b.w, "\r")
		if b.drawn > 1 {
			fmt.Fprintf(b.w, "\x1b[%dA", b.drawn-1)
		}
	}
	io.WriteString(b.w, "\x1b[J")

	for i, segs := range rows {
		if i > 0 {
			// \r cancels a pending autowrap, \n drops to the next row: the
			// pair always separates the previous logical row cleanly, wrapped
			// or not.
			io.WriteString(b.w, "\r\n")
		}
		b.writeSegs(b.w, segs)
	}
	b.drawn = b.physicalHeight(rows)
}

// physicalHeight returns the number of terminal rows the window occupies at
// the box's width: every logical row is at least one row, and a wider one
// wraps into as many as it fills.
func (b *LiveBox) physicalHeight(rows [][]codeSeg) int {
	W := b.W
	if W < 1 {
		W = 1
	}
	total := 0
	for _, segs := range rows {
		rows := (b.rowWidth(segs) + W - 1) / W
		if rows < 1 {
			rows = 1
		}
		total += rows
	}
	return total
}

// rowWidth returns the display width of one rendered row, with tabs expanded
// as writeSegs renders them.
func (b *LiveBox) rowWidth(segs []codeSeg) int {
	var sb strings.Builder
	b.writeSegs(&sb, segs)
	return visibleWidth(sb.String())
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

// drawSegs renders a row's colored runs at the cursor without a newline.
// Called with b.mu held.
func (b *LiveBox) drawSegs(segs []codeSeg) {
	b.writeSegs(b.w, segs)
}

// writeSegs renders a row's colored runs to w at the cursor without a newline.
// Tabs are expanded to tab stops, with the column carried across the runs so a
// tab in a later run still lands on the row's stops.
func (b *LiveBox) writeSegs(w io.Writer, segs []codeSeg) {
	bg := b.bgSeq()
	if bg != "" {
		io.WriteString(w, bg)
	}
	col := 0
	for _, s := range segs {
		if fg := b.fgSeq(s.color); fg != "" {
			io.WriteString(w, fg)
		}
		text, next := expandTabs(s.text, col)
		col = next
		if bg != "" {
			text = strings.ReplaceAll(text, resetSGR, resetSGR+bg)
		}
		io.WriteString(w, text)
	}
	if bg != "" {
		io.WriteString(w, "\x1b[K")
	}
	io.WriteString(w, resetSGR)
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
