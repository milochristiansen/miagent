// ANSI helpers: SGR sequences, visible-width measurement, ANSI stripping, and
// SGR-aware word wrapping. The behaviour follows the Go termark package.
package termark

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

ESC :: "\x1b"
RESET_SGR :: "\x1b[0m"
BOLD_SGR :: "\x1b[1m"
ITALIC_SGR :: "\x1b[3m"
UNDERLINE_SGR :: "\x1b[4m"
STRIKE_SGR :: "\x1b[9m"
EL :: "\x1b[K"

fg_sgr :: proc(color: string) -> string {
	if len(color) == 0 do return ""
	return fmt.tprintf("\x1b[38;5;%sm", color)
}

bg_sgr :: proc(color: string) -> string {
	if len(color) == 0 do return ""
	return fmt.tprintf("\x1b[48;5;%sm", color)
}

// csi_end returns the index just past the CSI sequence starting at s[i]
// (s[i] == ESC). Returns i+1 if malformed.
csi_end :: proc(s: string, i: int) -> int {
	j := i + 2
	for j < len(s) {
		c := s[j]
		if (c >= '0' && c <= '9') || c == ';' {
			j += 1
			continue
		}
		if c == 'm' do return j + 1
		return i + 1
	}
	return i + 1
}

// strip_ansi removes CSI, OSC, and single-character ESC sequences.
strip_ansi :: proc(s: string) -> string {
	has_esc := false
	for i := 0; i < len(s); i += 1 {
		if s[i] == 0x1b {
			has_esc = true
			break
		}
	}
	if !has_esc do return s

	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(s) {
		if s[i] != 0x1b {
			strings.write_byte(&b, s[i])
			i += 1
			continue
		}
		if i + 1 >= len(s) do break
		switch s[i + 1] {
		case '[':
			i += 2
			for i < len(s) && (s[i] < 0x40 || s[i] > 0x7e) do i += 1
			if i < len(s) do i += 1
		case ']':
			i += 2
			for i < len(s) {
				if s[i] == 0x07 {
					i += 1
					break
				}
				if s[i] == 0x1b && i + 1 < len(s) && s[i + 1] == '\\' {
					i += 2
					break
				}
				i += 1
			}
		case:
			i += 2
			for i < len(s) && s[i] < 0x40 do i += 1
			if i < len(s) do i += 1
		}
	}
	return strings.to_string(b)
}

// rune_width is a compact wcwidth approximation: combining marks and control
// characters occupy no cells, East Asian wide characters and emoji occupy two.
rune_width :: proc(r: rune) -> int {
	if r == 0 do return 0
	if r < 0x20 || (r >= 0x7f && r < 0xa0) do return 0
	// Combining marks, zero-width joiners, variation selectors.
	if (r >= 0x0300 && r <= 0x036f) ||
	   (r >= 0x0483 && r <= 0x0489) ||
	   (r >= 0x0591 && r <= 0x05bd) ||
	   r == 0x05bf || (r >= 0x05c1 && r <= 0x05c2) ||
	   (r >= 0x0610 && r <= 0x061a) ||
	   (r >= 0x064b && r <= 0x065f) || r == 0x0670 ||
	   (r >= 0x06d6 && r <= 0x06dc) ||
	   (r >= 0x06df && r <= 0x06e4) ||
	   (r >= 0x06e7 && r <= 0x06e8) ||
	   (r >= 0x06ea && r <= 0x06ed) ||
	   (r >= 0x0900 && r <= 0x0902) || r == 0x093c ||
	   (r >= 0x0941 && r <= 0x0948) || (r >= 0x094d && r <= 0x094d) ||
	   (r >= 0x0951 && r <= 0x0957) ||
	   (r >= 0x1ab0 && r <= 0x1aff) ||
	   (r >= 0x1dc0 && r <= 0x1dff) ||
	   (r >= 0x20d0 && r <= 0x20ff) ||
	   (r >= 0xfe00 && r <= 0xfe0f) ||
	   (r >= 0xfe20 && r <= 0xfe2f) ||
	   r == 0x200b || r == 0x200c || r == 0x200d || r == 0x2060 ||
	   (r >= 0xe0100 && r <= 0xe01ef) {
		return 0
	}
	// East Asian wide / fullwidth ranges.
	if r >= 0x1100 && (r <= 0x115f ||
	   r == 0x2329 || r == 0x232a ||
	   (r >= 0x2e80 && r <= 0x303e) ||
	   (r >= 0x3041 && r <= 0x33ff) ||
	   (r >= 0x3400 && r <= 0x4dbf) ||
	   (r >= 0x4e00 && r <= 0x9fff) ||
	   (r >= 0xa000 && r <= 0xa4cf) ||
	   (r >= 0xa960 && r <= 0xa97f) ||
	   (r >= 0xac00 && r <= 0xd7a3) ||
	   (r >= 0xf900 && r <= 0xfaff) ||
	   (r >= 0xfe10 && r <= 0xfe19) ||
	   (r >= 0xfe30 && r <= 0xfe6f) ||
	   (r >= 0xff00 && r <= 0xff60) ||
	   (r >= 0xffe0 && r <= 0xffe6) ||
	   (r >= 0x1f000 && r <= 0x1faff) ||
	   (r >= 0x20000 && r <= 0x2fffd) ||
	   (r >= 0x30000 && r <= 0x3fffd)) {
		return 2
	}
	return 1
}

// visible_width measures a string, ignoring ANSI escapes.
visible_width :: proc(s: string) -> int {
	plain := strip_ansi(s)
	w := 0
	i := 0
	for i < len(plain) {
		r, size := utf8.decode_rune_in_string(plain[i:])
		if size <= 0 do break
		w += rune_width(r)
		i += size
	}
	return w
}

// display_width is the visible cell width of an ANSI string.
display_width :: proc(s: string) -> int {
	return visible_width(s)
}

// apply_sgr updates an active SGR parameter list given one SGR sequence.
apply_sgr :: proc(active, seq: string) -> string {
	if len(seq) < 3 do return active
	params := seq[2:len(seq) - 1]
	for p in strings.split(params, ";", context.temp_allocator) {
		if p == "0" do return ""
	}
	if len(active) == 0 do return strings.clone(params, context.temp_allocator)
	return fmt.tprintf("%s;%s", active, params)
}

// wrap_ansi wraps styled text into visible lines of at most width cells,
// breaking at word boundaries and preserving SGR state across breaks. Explicit
// newlines are hard breaks. The returned strings are allocated with the
// default allocator.
wrap_ansi :: proc(s: string, width: int) -> []string {
	w := max(width, 1)
	lines := make([dynamic]string, 0, 8)
	line := strings.builder_make()
	col := 0
	active := ""

	emit :: proc(lines: ^[dynamic]string, line: ^strings.Builder, active: ^string, col: ^int) {
		if len(active^) > 0 do strings.write_string(line, RESET_SGR)
		append(lines, strings.clone(strings.to_string(line^)))
		strings.builder_reset(line)
		if len(active^) > 0 do strings.write_string(line, fmt.tprintf("\x1b[%sm", active^))
		col^ = 0
	}

	i := 0
	need_space := false
	for i < len(s) {
		c := s[i]
		if c == 0x1b {
			if need_space && col > 0 {
				strings.write_byte(&line, ' ')
				col += 1
				need_space = false
			}
			j := csi_end(s, i)
			strings.write_string(&line, s[i:j])
			active = apply_sgr(active, s[i:j])
			i = j
			continue
		}
		if c == ' ' {
			need_space = true
			for i < len(s) && s[i] == ' ' do i += 1
			continue
		}
		if c == '\n' {
			if col > 0 || strings.builder_len(line) > 0 do emit(&lines, &line, &active, &col)
			need_space = false
			i += 1
			continue
		}
		j := i
		for j < len(s) && s[j] != ' ' && s[j] != '\n' && s[j] != 0x1b do j += 1
		word := s[i:j]
		ww := visible_width(word)
		add := ww
		if need_space do add += 1
		if col + add > w && col > 0 {
			emit(&lines, &line, &active, &col)
			strings.write_string(&line, word)
			col = ww
		} else {
			if need_space && col > 0 do strings.write_byte(&line, ' ')
			strings.write_string(&line, word)
			col += add
		}
		need_space = false
		i = j
	}

	if col > 0 || strings.builder_len(line) > 0 || len(lines) == 0 {
		if len(active) > 0 do strings.write_string(&line, RESET_SGR)
		append(&lines, strings.clone(strings.to_string(line)))
	}
	delete(line.buf)
	return lines[:]
}

// split_cells splits a space-free run into display-cell pieces of at most
// width cells, never splitting a wide (double-cell) rune.
split_cells :: proc(s: string, width: int) -> []string {
	w := max(width, 1)
	pieces := make([dynamic]string, 0, 4)
	b := strings.builder_make()
	cw := 0
	i := 0
	for i < len(s) {
		r, size := utf8.decode_rune_in_string(s[i:])
		if size <= 0 do break
		rw := rune_width(r)
		if cw > 0 && cw + rw > w {
			append(&pieces, strings.clone(strings.to_string(b)))
			strings.builder_reset(&b)
			cw = 0
		}
		strings.write_string(&b, s[i:i + size])
		cw += rw
		i += size
	}
	if cw > 0 do append(&pieces, strings.clone(strings.to_string(b)))
	if len(pieces) == 0 do append(&pieces, "")
	delete(b.buf)
	return pieces[:]
}

// itoa renders a non-negative integer without allocating a formatted string.
itoa :: proc(n: int) -> string {
	if n == 0 do return "0"
	buf: [24]u8
	i := len(buf)
	v := n
	for v > 0 {
		i -= 1
		buf[i] = u8('0' + v % 10)
		v /= 10
	}
	return strings.clone(string(buf[i:]), context.temp_allocator)
}
