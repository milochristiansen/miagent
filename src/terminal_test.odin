package main

import "core:os"
import "core:strings"
import "core:time"
import "core:testing"

Test_Terminal :: struct {
	term: ^Terminal,
	rd:   ^os.File,
	wr:   ^os.File,
}

test_terminal_new :: proc(t: ^testing.T) -> (Test_Terminal, bool) {
	term := new(Terminal)
	th := Theme {
		term_bg = rgb(0x1d, 0x1f, 0x21),
		term_fg = rgb(0xc5, 0xc8, 0xc6),
		cursor  = rgb(0xc5, 0xc8, 0xc6),
		ansi    = {},
		cursor_style = GHOSTTY_CURSOR_BLOCK,
	}
	if terminal_state_init(term, th, 20, 5, 10, 20) != .Ok {
		free(term)
		return {}, false
	}
	rd, wr, err := os.pipe()
	if err != nil {
		terminal_destroy(term)
		free(term)
		return {}, false
	}
	term.fd = i32(os.fd(wr))
	term.pid = -1
	term.alive = true
	return Test_Terminal{term = term, rd = rd, wr = wr}, true
}

test_terminal_destroy :: proc(tt: Test_Terminal) {
	tt.term.fd = -1
	tt.term.pid = -1
	tt.term.alive = false
	terminal_destroy(tt.term)
	free(tt.term)
	os.close(tt.rd)
	os.close(tt.wr)
}

test_terminal_write :: proc(tt: Test_Terminal, s: string) {
	if len(s) == 0 do return
	ghostty_terminal_vt_write(tt.term.gt, raw_data(s), uint(len(s)))
}

test_terminal_read :: proc(tt: Test_Terminal) -> string {
	if ok, _ := os.pipe_has_data(tt.rd); !ok do return ""
	buf: [256]u8
	n, err := os.read(tt.rd, buf[:])
	if err != nil || n <= 0 do return ""
	return strings.clone(string(buf[:n]), context.temp_allocator)
}

test_terminal_drain :: proc(tt: Test_Terminal) {
	buf: [256]u8
	for {
		if ok, _ := os.pipe_has_data(tt.rd); !ok do break
		n, _ := os.read(tt.rd, buf[:])
		if n <= 0 do break
	}
}

@(test)
test_terminal_effects_focus :: proc(t: ^testing.T) {
	tt, ok := test_terminal_new(t)
	if !ok do return
	defer test_terminal_destroy(tt)

	test_terminal_write(tt, "\x1b[?1004h")
	terminal_update_focus(tt.term, true)
	if !testing.expect_value(t, test_terminal_read(tt), "\x1b[I") do return
	terminal_update_focus(tt.term, true)
	if !testing.expect_value(t, test_terminal_read(tt), "") do return
	terminal_update_focus(tt.term, false)
	testing.expect_value(t, test_terminal_read(tt), "\x1b[O")
}

@(test)
test_terminal_effects_queries :: proc(t: ^testing.T) {
	tt, ok := test_terminal_new(t)
	if !ok do return
	defer test_terminal_destroy(tt)

	test_terminal_write(tt, "\x1b[c")
	testing.expect_value(t, test_terminal_read(tt), "\x1b[?62;22;52c")

	test_terminal_write(tt, "\x1b[18t")
	testing.expect_value(t, test_terminal_read(tt), "\x1b[8;5;20t")

	test_terminal_write(tt, "\x1b[>q")
	got := test_terminal_read(tt)
	testing.expect(t, len(got) > 0 && got[:2] == "\x1bP")
}

@(test)
test_terminal_effects_bell_clipboard_meta :: proc(t: ^testing.T) {
	tt, ok := test_terminal_new(t)
	if !ok do return
	defer test_terminal_destroy(tt)

	test_terminal_write(tt, "\x07")
	testing.expect_value(t, terminal_take_bell(tt.term), u32(1))

	test_terminal_write(tt, "\x1b]52;c;aGVsbG8=\x07")
	testing.expect(t, tt.term.clip_pending_set)
	testing.expect_value(t, tt.term.clip_pending, "hello")

	test_terminal_write(tt, "\x1b]2;new title\x07")
	testing.expect(t, tt.term.meta_dirty)
	terminal_refresh_meta(tt.term)
	testing.expect_value(t, tt.term.title, "new title")

	test_terminal_write(tt, "\x1b]7;file:///tmp\x07")
	terminal_refresh_meta(tt.term)
	testing.expect_value(t, tt.term.cwd, "file:///tmp")
}

@(test)
test_terminal_paste_safety :: proc(t: ^testing.T) {
	safe := "hello"
	unsafe := "hello\nworld"
	terminator := "x\x1b[201~y"
	testing.expect(t, ghostty_paste_is_safe(raw_data(safe), uint(len(safe))))
	testing.expect(t, !ghostty_paste_is_safe(raw_data(unsafe), uint(len(unsafe))))
	testing.expect(t, !ghostty_paste_is_safe(raw_data(terminator), uint(len(terminator))))
}

@(test)
test_terminal_reset :: proc(t: ^testing.T) {
	tt, ok := test_terminal_new(t)
	if !ok do return
	defer test_terminal_destroy(tt)

	test_terminal_write(tt, "\x1b[?1004h")
	terminal_update_focus(tt.term, true)
	_ = test_terminal_read(tt)
	terminal_reset(tt.term)
	test_terminal_drain(tt)
	test_terminal_write(tt, "\x1b[?1004h")
	terminal_update_focus(tt.term, true)
	testing.expect_value(t, test_terminal_read(tt), "\x1b[I")
}

@(test)
test_terminal_write_pipe :: proc(t: ^testing.T) {
	tt, ok := test_terminal_new(t)
	if !ok do return
	defer test_terminal_destroy(tt)
	data := []u8{'a', 'b', 'c'}
	terminal_write(tt.term, data)
	testing.expect_value(t, test_terminal_read(tt), "abc")
}


@(test)
test_terminal_pty_smoke :: proc(t: ^testing.T) {
	term := new(Terminal)
	defer {
		terminal_destroy(term)
		free(term)
	}
	th := Theme {
		term_bg = rgb(0x1d, 0x1f, 0x21),
		term_fg = rgb(0xc5, 0xc8, 0xc6),
		cursor  = rgb(0xc5, 0xc8, 0xc6),
		cursor_style = GHOSTTY_CURSOR_BLOCK,
	}
	res := terminal_init(term, "/bin/sh", "/tmp", th, 40, 10, 9, 18)
	if !testing.expect_value(t, res, Terminal_Result.Ok) do return
	if !testing.expect(t, term.alive) do return

	cmd := "printf 'miagent-pty-ok\\n'\n"
	terminal_write(term, transmute([]u8)cmd)
	for _ in 0 ..< 50 {
		terminal_pump(term)
		if !term.alive do break
		time.sleep(10 * time.Millisecond)
	}

	found := false

	// Format the whole screen through the selection formatter instead of
	// rebuilding row text in the test.
	sel: GhosttySelection
	if ghostty_terminal_select_all(term.gt, &sel) == GHOSTTY_SUCCESS {
		opts := GhosttyTerminalSelectionFormatOptions {
			size = size_of(GhosttyTerminalSelectionFormatOptions),
			emit = GHOSTTY_FORMATTER_FORMAT_PLAIN,
			unwrap = true,
			trim = true,
			selection = &sel,
		}
		needed: uint
		if ghostty_terminal_selection_format_buf(term.gt, opts, nil, 0, &needed) == GHOSTTY_OUT_OF_SPACE && needed > 0 {
			out := make([]u8, int(needed), context.temp_allocator)
			if ghostty_terminal_selection_format_buf(term.gt, opts, raw_data(out), needed, &needed) == GHOSTTY_SUCCESS {
				found = strings.contains(string(out[:needed]), "miagent-pty-ok")
			}
		}
	}
	testing.expect(t, found, "shell output should be visible in terminal state")
}

@(test)
test_terminal_destroy_uninitialized :: proc(t: ^testing.T) {
	term := new(Terminal)
	terminal_destroy(term)
	free(term)
	testing.expect(t, true)
}

@(test)
test_terminal_in_band_resize :: proc(t: ^testing.T) {
	tt, ok := test_terminal_new(t)
	if !ok do return
	defer test_terminal_destroy(tt)

	test_terminal_write(tt, "\x1b[?2048h")
	terminal_resize(tt.term, 30, 6, 10, 20)
	testing.expect_value(t, test_terminal_read(tt), "\x1b[48;6;30;120;300t")
}

@(test)
test_terminal_micro_alt_screen :: proc(t: ^testing.T) {
	if !os.exists("/usr/bin/micro") do return
	term := new(Terminal)
	defer {
		terminal_destroy(term)
		free(term)
	}
	th := Theme {
		term_bg = rgb(0x1d, 0x1f, 0x21),
		term_fg = rgb(0xc5, 0xc8, 0xc6),
		cursor  = rgb(0xc5, 0xc8, 0xc6),
		cursor_style = GHOSTTY_CURSOR_BLOCK,
	}
	if terminal_init(term, "/bin/sh", "/tmp", th, 60, 20, 9, 18) != .Ok do return
	for _ in 0 ..< 10 { terminal_pump(term); time.sleep(10 * time.Millisecond) }
	cmd := "micro /tmp/miagent_micro_terminal_test.txt\n"
	terminal_write(term, transmute([]u8)cmd)
	for _ in 0 ..< 100 {
		terminal_pump(term)
		time.sleep(10 * time.Millisecond)
	}

	state: GhosttyRenderState
	if ghostty_render_state_new(nil, &state) != GHOSTTY_SUCCESS do return
	defer ghostty_render_state_free(state)
	_ = ghostty_render_state_update(state, term.gt)
	ri: GhosttyRenderStateRowIterator
	_ = ghostty_render_state_row_iterator_new(nil, &ri)
	defer ghostty_render_state_row_iterator_free(ri)
	rc: GhosttyRenderStateRowCells
	_ = ghostty_render_state_row_cells_new(nil, &rc)
	defer ghostty_render_state_row_cells_free(rc)
	_ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &ri)
	render_text := 0
	for ghostty_render_state_row_iterator_next(ri) {
		_ = ghostty_render_state_row_get(ri, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &rc)
		for ghostty_render_state_row_cells_next(rc) {
			buf: [64]u8
			gb := GhosttyBuffer{ptr = &buf[0], cap = len(buf)}
			if ghostty_render_state_row_cells_get(rc, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &gb) == GHOSTTY_SUCCESS {
				render_text += int(gb.len)
			}
		}
	}
	testing.expect(t, render_text > 0, "render state should have text")

	sel: GhosttySelection
	if ghostty_terminal_select_all(term.gt, &sel) != GHOSTTY_SUCCESS do return
	opts := GhosttyTerminalSelectionFormatOptions {
		size = size_of(GhosttyTerminalSelectionFormatOptions),
		emit = GHOSTTY_FORMATTER_FORMAT_PLAIN,
		unwrap = true,
		trim = true,
		selection = &sel,
	}
	needed: uint
	if ghostty_terminal_selection_format_buf(term.gt, opts, nil, 0, &needed) == GHOSTTY_OUT_OF_SPACE && needed > 0 {
		out := make([]u8, int(needed), context.temp_allocator)
		if ghostty_terminal_selection_format_buf(term.gt, opts, raw_data(out), needed, &needed) == GHOSTTY_SUCCESS {
			testing.expect(t, strings.contains(string(out[:needed]), "miagent_micro_terminal_test.txt"))
			return
		}
	}
	testing.expect(t, false, "micro screen should contain its filename")
}
