// The screen manager owns the committed/tail line model and emits tail updates
// with the cursor protocol. It is a direct port of the Go CLI's termark Screen.
package termark

import "core:io"
import "core:strings"

Screen :: struct {
	W: int,
	w: io.Writer,

	cached_lines: int,
	tail_lines:   []Line,
}

new_screen :: proc(W: int, w: io.Writer) -> Screen {
	return Screen{W = max(W, 1), w = w}
}

// commit appends committed lines to the cache and emits them via normal scroll.
screen_commit :: proc(s: ^Screen, lines: []Line) {
	if len(lines) == 0 do return
	s.cached_lines += len(lines)
	for line in lines {
		io.write_string(s.w, line.text)
		io.write_string(s.w, "\r\n")
	}
}

screen_commit_and_update :: proc(s: ^Screen, new_committed, new_tail: []Line) {
	combined := make([dynamic]Line, 0, len(new_committed) + len(new_tail))
	append(&combined, ..new_committed)
	append(&combined, ..new_tail)
	screen_update_tail(s, combined[:])
	delete(combined)
	s.cached_lines += len(new_committed)
	s.tail_lines = new_tail
}

// screen_update_tail updates the tail and re-emits it via the cursor protocol.
// Lines wider than the terminal soft-wrap, so all backtracking counts physical
// rows rather than logical lines.
//
// The EL clears after each line paint erased cells with the current SGR
// background, so a line that wants its background to span the row (a code-block
// row) must leave that background active at its end.
screen_update_tail :: proc(s: ^Screen, tail: []Line) {
	old_tail := s.tail_lines
	new_tail := tail
	s.tail_lines = new_tail

	i := 0
	for i < len(old_tail) && i < len(new_tail) {
		if old_tail[i].text != new_tail[i].text do break
		i += 1
	}
	if i == len(old_tail) && i == len(new_tail) do return

	if len(old_tail) > 0 && i == len(old_tail) {
		for j := i; j < len(new_tail); j += 1 {
			io.write_string(s.w, "\r\n")
			io.write_string(s.w, new_tail[j].text)
			io.write_string(s.w, EL)
		}
		return
	}

	old_rows := physical_rows(old_tail[i:], s.W)
	new_rows := physical_rows(new_tail[i:], s.W)
	region := max(old_rows, new_rows)

	if old_rows > 0 {
		io.write_string(s.w, "\x1b[1G")
		if up := old_rows - 1; up > 0 {
			io.write_string(s.w, strings.concatenate({"\x1b[", itoa(up), "A"}, context.temp_allocator))
		}
		for r := 0; r < region; r += 1 {
			io.write_string(s.w, "\x1b[1G")
			io.write_string(s.w, EL)
			if r < region - 1 do io.write_string(s.w, "\r\n")
		}
		io.write_string(s.w, "\x1b[1G")
		if up := region - 1; up > 0 {
			io.write_string(s.w, strings.concatenate({"\x1b[", itoa(up), "A"}, context.temp_allocator))
		}
	}

	for j := i; j < len(new_tail); j += 1 {
		io.write_string(s.w, "\x1b[1G")
		io.write_string(s.w, new_tail[j].text)
		io.write_string(s.w, EL)
		if j < len(new_tail) - 1 do io.write_string(s.w, "\r\n")
	}
}

physical_rows :: proc(lines: []Line, W: int) -> int {
	w := max(W, 1)
	total := 0
	for line in lines {
		rows := (line.width + w - 1) / w
		if rows < 1 do rows = 1
		total += rows
	}
	return total
}

screen_close :: proc(s: ^Screen) {
	io.write_string(s.w, "\r\n")
}

screen_resize :: proc(s: ^Screen, W: int) {
	s.W = max(W, 1)
}
