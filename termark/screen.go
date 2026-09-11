package termark

import (
	"bytes"
	"fmt"
	"io"
)

// Screen is the screen manager: it owns the line model (committed lines, tail
// lines, terminal size) and emits tail updates via the cursor protocol.
//
// Model (§3.5.1):
//
//	W, H        terminal size
//	cachedLines number of lines in the committed part (emitted once)
//	tailLines   the previous tick's tail rendering
//	D           = cachedLines + len(tailLines)  // total document lines
//	tailTopRow  = max(1, D - len(tailLines) + 1)  // absolute row of tail's first line
//
// No DECSTBM scrolling region is used. Emission is plain append-with-normal
// scroll (LF at the bottom scrolls the whole screen), so the scrollback buffer
// stays in document order.
type Screen struct {
	W int
	w io.Writer

	cachedLines int
	tailLines   []Line
}

// NewScreen creates a screen manager for a W-column terminal, emitting to w.
func NewScreen(W int, w io.Writer) *Screen {
	return &Screen{W: W, w: w}
}

// Commit appends committed lines (the stable part) to the cache and emits them
// via the normal scroll (they are frozen; never re-emitted).
func (s *Screen) Commit(lines []Line) {
	if len(lines) == 0 {
		return
	}
	s.cachedLines += len(lines)
	for _, l := range lines {
		s.emit(l.Bytes)
		s.emitLF()
	}
}

// CommitAndUpdate commits newCommitted (which replaces the current tail) and
// sets the tail to newTail, re-emitting the region from the previous tail's
// top row. A block that just finalized was the tail on the previous tick; its
// committed rendering replaces that partial tail, and the new tail follows.
func (s *Screen) CommitAndUpdate(newCommitted, newTail []Line) {
	combined := make([]Line, 0, len(newCommitted)+len(newTail))
	combined = append(combined, newCommitted...)
	combined = append(combined, newTail...)
	s.UpdateTail(combined)
	s.cachedLines += len(newCommitted)
	s.tailLines = newTail
}

// UpdateTail updates the tail (the last block) and re-emits it via the cursor
// protocol (§3.5.2). Lines wider than the terminal soft-wrap into several
// physical rows, so all backtracking and erasure count physical rows, never
// logical lines.
func (s *Screen) UpdateTail(tail []Line) {
	oldTail := s.tailLines
	newTail := tail
	s.tailLines = newTail

	// Find the first logical line where newTail and oldTail differ. i = len(old)
	// if pure extension (newTail starts with oldTail). Equal bytes mean equal
	// width, hence equal physical rows, so the common prefix needs no work.
	i := 0
	for i < len(oldTail) && i < len(newTail) {
		if !bytes.Equal(oldTail[i].Bytes, newTail[i].Bytes) {
			break
		}
		i++
	}
	// Identical: nothing to emit.
	if i == len(oldTail) && i == len(newTail) {
		return
	}

	// Pure extension (append) with a non-empty previous tail: the cursor is at
	// the end of the old tail's last physical row; append the new lines, LF per
	// logical line, scrolling at the bottom so a growing tail pushes its top
	// into scrollback. (LF between logical lines is correct even when lines
	// wrap: the terminal's autowrap already advanced past the extra rows.)
	if len(oldTail) > 0 && i == len(oldTail) {
		for j := i; j < len(newTail); j++ {
			s.emitLF()
			s.emit(newTail[j].Bytes)
			s.emit([]byte("\x1b[K"))
		}
		return
	}

	// A change in the tail: erase the whole region the old tail occupies from
	// line i onward (measured in physical rows) and rewrite the new tail. The
	// cursor is at the old tail's last physical row, so move up to the first
	// physical row of line i, erase max(old,new) rows, and write from there.
	oldRows := physicalRows(oldTail[i:], s.W)
	newRows := physicalRows(newTail[i:], s.W)
	region := oldRows
	if newRows > region {
		region = newRows
	}

	if oldRows > 0 {
		s.emit([]byte("\x1b[1G"))
		if up := oldRows - 1; up > 0 {
			s.emit([]byte(fmt.Sprintf("\x1b[%dA", up)))
		}
		for r := 0; r < region; r++ {
			s.emit([]byte("\x1b[1G"))
			s.emit([]byte("\x1b[K"))
			if r < region-1 {
				s.emitLF()
			}
		}
		// Back to the top of the region to write the new lines.
		s.emit([]byte("\x1b[1G"))
		if up := region - 1; up > 0 {
			s.emit([]byte(fmt.Sprintf("\x1b[%dA", up)))
		}
	}

	// Write the new tail from line i. Each logical line is preceded by column 1
	// (its first physical row starts at the current row: LF between lines, with
	// autowrap having consumed any continuation rows) and cleared to end of
	// line so no stale cells survive a shorter line.
	for j := i; j < len(newTail); j++ {
		s.emit([]byte("\x1b[1G"))
		s.emit(newTail[j].Bytes)
		s.emit([]byte("\x1b[K"))
		if j < len(newTail)-1 {
			s.emitLF()
		}
	}
}

// physicalRows returns the number of terminal rows the lines occupy when
// rendered at width W: lines wider than W soft-wrap into multiple rows.
func physicalRows(lines []Line, W int) int {
	if W < 1 {
		W = 1
	}
	total := 0
	for _, l := range lines {
		rows := (l.Width + W - 1) / W // ceil(width/W)
		if rows < 1 {
			rows = 1 // an empty line still occupies one row
		}
		total += rows
	}
	return total
}

// Close moves the cursor to a fresh line so the shell prompt isn't left on a
// partial line (which shells mark with a reverse-video "%").
func (s *Screen) Close() {
	s.emitLF()
}

// Resize updates the terminal width.
func (s *Screen) Resize(W int) {
	s.W = W
}

// emit writes bytes to the terminal.
func (s *Screen) emit(b []byte) {
	s.w.Write(b)
}

// emitLF writes a carriage return + line feed. The explicit CR resets the
// column even when the terminal's ONLCR output post-processing is disabled
// (raw mode, which the watch tool enables on stdin, applies to the whole
// terminal device including stdout), where a bare LF would preserve the column
// and staircase the output.
func (s *Screen) emitLF() {
	s.w.Write([]byte("\r\n"))
}
