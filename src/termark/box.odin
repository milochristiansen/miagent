// Code-box helpers shared by code blocks and live tool boxes.
package termark

import "core:os"
import "core:strings"
import "core:sys/linux"

TAB_STOP :: 4

Winsize :: struct {
	ws_row:    u16,
	ws_col:    u16,
	ws_xpixel: u16,
	ws_ypixel: u16,
}

// terminal_size reports the width and height of a file descriptor, if it is a
// terminal. The CLI is Linux/Unix oriented (like the desktop app).
terminal_size_fd :: proc(fd: uintptr) -> (width, height: int, ok: bool) {
	ws: Winsize
	ret := linux.ioctl(linux.Fd(fd), linux.TIOCGWINSZ, uintptr(&ws))
	if ret == ~uintptr(0) || ws.ws_col == 0 || ws.ws_row == 0 do return 0, 0, false
	return int(ws.ws_col), int(ws.ws_row), true
}

stdout_is_tty :: proc() -> bool {
	return os.is_tty(os.stdout)
}

stdout_size :: proc() -> (width, height: int, ok: bool) {
	return terminal_size_fd(os.fd(os.stdout))
}

stderr_is_tty :: proc() -> bool {
	return os.is_tty(os.stderr)
}

// expand_tabs replaces every tab with spaces up to the next tab stop, counting
// visible columns from col, and returns the new column. ANSI escapes occupy no
// columns and are copied through.
expand_tabs :: proc(text: string, col: int) -> (string, int) {
	if strings.index_byte(text, '\t') < 0 {
		return strings.clone(text), col + visible_width(text)
	}
	b := strings.builder_make()
	c := col
	i := 0
	for i < len(text) {
		if text[i] == '\t' {
			n := TAB_STOP - c % TAB_STOP
			for _ in 0 ..< n do strings.write_byte(&b, ' ')
			c += n
			i += 1
			continue
		}
		if text[i] == 0x1b {
			j := csi_end(text, i)
			strings.write_string(&b, text[i:j])
			i = j
			continue
		}
		j := i
		for j < len(text) && text[j] != '\t' && text[j] != 0x1b do j += 1
		strings.write_string(&b, text[i:j])
		c += visible_width(text[i:j])
		i = j
	}
	return strings.to_string(b), c
}

// box_row writes one code-content row: background, foreground, text with tabs
// expanded, and an EL fill. Ends with a newline.
box_row :: proc(b: ^strings.Builder, style: Style, text, color: string) {
	expanded, _ := expand_tabs(text, 0)
	defer delete(expanded)
	if len(style.code_block_bg) > 0 do strings.write_string(b, bg_sgr(style.code_block_bg))
	c := color
	if len(c) == 0 do c = style.code_block_color
	if len(c) > 0 do strings.write_string(b, fg_sgr(c))
	if len(style.code_block_bg) > 0 {
		reopened, allocated := strings.replace_all(expanded, RESET_SGR,
			strings.concatenate({RESET_SGR, bg_sgr(style.code_block_bg)}, context.temp_allocator))
		strings.write_string(b, reopened)
		if allocated do delete(reopened)
		strings.write_string(b, EL)
	} else {
		strings.write_string(b, expanded)
	}
	strings.write_string(b, RESET_SGR)
	strings.write_string(b, "\n")
}

box_border :: proc(b: ^strings.Builder, style: Style, width: int, label, note: string) {
	if len(style.code_block_bg) > 0 do strings.write_string(b, bg_sgr(style.code_block_bg))
	if len(style.code_block_color) > 0 do strings.write_string(b, fg_sgr(style.code_block_color))
	strings.write_string(b, code_header_note(label, note, width))
	strings.write_string(b, RESET_SGR)
	strings.write_string(b, "\n")
}
