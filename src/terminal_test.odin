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

// --- selection gestures -----------------------------------------------------

terminal_test_selection_text :: proc(t: ^Terminal) -> (text: string, ok: bool) {
	sel: GhosttySelection
	if ghostty_terminal_get(t.gt, GHOSTTY_TERMINAL_DATA_SELECTION, &sel) != GHOSTTY_SUCCESS {
		return "", false
	}
	opts := GhosttyTerminalSelectionFormatOptions {
		size      = size_of(GhosttyTerminalSelectionFormatOptions),
		emit      = GHOSTTY_FORMATTER_FORMAT_PLAIN,
		unwrap    = true,
		trim      = true,
		selection = &sel,
	}
	needed: uint
	if ghostty_terminal_selection_format_buf(t.gt, opts, nil, 0, &needed) != GHOSTTY_OUT_OF_SPACE ||
	   needed == 0 {
		return "", false
	}
	out := make([]u8, int(needed), context.temp_allocator)
	if ghostty_terminal_selection_format_buf(t.gt, opts, raw_data(out), needed, &needed) != GHOSTTY_SUCCESS {
		return "", false
	}
	return string(out[:needed]), true
}

terminal_test_autoscroll :: proc(t: ^Terminal) -> i32 {
	v: i32 = -1
	_ = ghostty_selection_gesture_get(t.gesture, t.gt, GHOSTTY_SELECTION_GESTURE_DATA_AUTOSCROLL, &v)
	return v
}

terminal_test_selection_geometry :: proc() -> GhosttySelectionGestureGeometry {
	return {
		columns       = 20,
		cell_width    = 10,
		padding_left  = u32(TERM_PAD_X),
		screen_height = 100,
	}
}

// Surface position of a cell, with `frac` pixels into the cell (0..cell_width).
terminal_test_selection_pos :: proc(cell: Terminal_Cell, frac: f32) -> GhosttySurfacePosition {
	return {
		x = f64(TERM_PAD_X + f32(cell.col) * 10 + frac),
		y = f64(TERM_PAD_Y + f32(cell.row) * 20 + 10),
	}
}

@(test)
test_terminal_selection_click_does_not_select :: proc(t: ^testing.T) {
	tt, ok := test_terminal_new(t)
	if !ok do return
	defer test_terminal_destroy(tt)
	test_terminal_write(tt, "hello world")

	geometry := terminal_test_selection_geometry()
	cell := Terminal_Cell{col = 2, row = 0}
	// Right-hand side of the cell: with the drag position left unset the
	// gesture reads (0, 0) and treated this as a real drag, selecting the cell.
	pos := terminal_test_selection_pos(cell, 8)

	if !testing.expect(t, terminal_selection_press(tt.term, cell, pos, 1_000_000)) do return
	_ = terminal_selection_drag_to(tt.term, cell, pos, geometry, false)

	sel: GhosttySelection
	res := ghostty_terminal_get(tt.term.gt, GHOSTTY_TERMINAL_DATA_SELECTION, &sel)
	testing.expect_value(t, res, GHOSTTY_NO_VALUE)
}

@(test)
test_terminal_selection_drag_selects_cells :: proc(t: ^testing.T) {
	tt, ok := test_terminal_new(t)
	if !ok do return
	defer test_terminal_destroy(tt)
	test_terminal_write(tt, "hello world")

	geometry := terminal_test_selection_geometry()
	start := Terminal_Cell{col = 2, row = 0}
	end := Terminal_Cell{col = 7, row = 0}

	if !testing.expect(t, terminal_selection_press(tt.term, start,
		terminal_test_selection_pos(start, 5), 1_000_000)) {
		return
	}
	if !testing.expect(t, terminal_selection_drag_to(tt.term, end,
		terminal_test_selection_pos(end, 8), geometry, false)) {
		return
	}

	text, has := terminal_test_selection_text(tt.term)
	if !testing.expect(t, has, "drag should install a selection") do return
	testing.expect_value(t, text, "llo wo")
}

@(test)
test_terminal_selection_autoscroll_follows_pointer :: proc(t: ^testing.T) {
	tt, ok := test_terminal_new(t)
	if !ok do return
	defer test_terminal_destroy(tt)
	test_terminal_write(tt, "hello world")

	geometry := terminal_test_selection_geometry()
	cell := Terminal_Cell{col = 2, row = 0}
	inside := terminal_test_selection_pos(cell, 5)

	if !testing.expect(t, terminal_selection_press(tt.term, cell, inside, 1_000_000)) do return

	// A drag inside the body must not autoscroll. This regressed to UP when the
	// drag event omitted its position because (0, 0) is above the top edge.
	_ = terminal_selection_drag_to(tt.term, cell, inside, geometry, false)
	testing.expect_value(t, terminal_test_autoscroll(tt.term), i32(GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_NONE))

	above := GhosttySurfacePosition{x = inside.x, y = -4}
	_ = terminal_selection_drag_to(tt.term, cell, above, geometry, false)
	testing.expect_value(t, terminal_test_autoscroll(tt.term), i32(GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_UP))

	below := GhosttySurfacePosition{x = inside.x, y = f64(geometry.screen_height) + 4}
	_ = terminal_selection_drag_to(tt.term, cell, below, geometry, false)
	testing.expect_value(t, terminal_test_autoscroll(tt.term), i32(GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_DOWN))

	_ = terminal_selection_drag_to(tt.term, cell, inside, geometry, false)
	testing.expect_value(t, terminal_test_autoscroll(tt.term), i32(GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_NONE))
}

@(test)
test_terminal_key_repeat_encoding :: proc(t: ^testing.T) {
	// Plain printable repeats arrive through ImGui's text queue, so encoding
	// them again would duplicate the character.
	testing.expect(t, !terminal_encode_key_repeat(GHOSTTY_KEY_A, true, false, false, false, false))
	testing.expect(t, !terminal_encode_key_repeat(GHOSTTY_KEY_A, true, false, true, false, false), "shift+letter")
	testing.expect(t, !terminal_encode_key_repeat(GHOSTTY_KEY_SPACE, false, false, false, false, false))
	testing.expect(t, !terminal_encode_key_repeat(GHOSTTY_KEY_NUMPAD_1, false, false, false, false, false))

	// Keys with no text and modified keys need an explicit repeat event.
	testing.expect(t, terminal_encode_key_repeat(GHOSTTY_KEY_A, true, true, false, false, false), "ctrl+letter")
	testing.expect(t, terminal_encode_key_repeat(GHOSTTY_KEY_A, true, false, false, true, false), "alt+letter")
	testing.expect(t, terminal_encode_key_repeat(GHOSTTY_KEY_ARROW_LEFT, false, false, true, false, false), "shift+arrow")
	testing.expect(t, terminal_encode_key_repeat(GHOSTTY_KEY_ARROW_LEFT, false, false, false, false, false))
	testing.expect(t, terminal_encode_key_repeat(GHOSTTY_KEY_BACKSPACE, false, false, false, false, false))
	testing.expect(t, terminal_encode_key_repeat(GHOSTTY_KEY_ENTER, false, false, false, false, false))
	testing.expect(t, terminal_encode_key_repeat(GHOSTTY_KEY_TAB, false, false, false, false, false))
	testing.expect(t, terminal_encode_key_repeat(GHOSTTY_KEY_F1, false, false, false, false, false))

	// Modifiers, super shortcuts, and the local Ctrl+Shift actions must not
	// repeat into the shell.
	testing.expect(t, !terminal_encode_key_repeat(GHOSTTY_KEY_SHIFT_LEFT, false, false, true, false, false))
	testing.expect(t, !terminal_encode_key_repeat(GHOSTTY_KEY_ARROW_UP, false, false, false, false, true))
	testing.expect(t, !terminal_encode_key_repeat(GHOSTTY_KEY_A, true, true, true, false, false), "ctrl+shift+a")
	testing.expect(t, !terminal_encode_key_repeat(GHOSTTY_KEY_A + 2, true, true, true, false, false), "ctrl+shift+c")
	testing.expect(t, !terminal_encode_key_repeat(GHOSTTY_KEY_A + 21, true, true, true, false, false), "ctrl+shift+v")
	testing.expect(t, !terminal_encode_key_repeat(GHOSTTY_KEY_A + 14, true, true, true, false, false), "ctrl+shift+o")
	testing.expect(t, terminal_encode_key_repeat(GHOSTTY_KEY_A + 15, true, true, true, false, false), "ctrl+shift+p")
	testing.expect(t, !terminal_encode_key_repeat(GHOSTTY_KEY_UNIDENTIFIED, false, false, false, false, false))
}
