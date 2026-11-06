package main

import "core:testing"

// Exercises the parts of the pinned libghostty-vt C API that this tree relies
// on: the GhosttyTerminalOptions constructor, separate cursor queries, and the
// in-order row iterator used to match the cursor to a viewport row.
@(test)
test_ghostty_terminal_render_state :: proc(t: ^testing.T) {
	term: GhosttyTerminal
	opts := GhosttyTerminalOptions {
		cols = 20,
		rows = 5,
	}
	if !testing.expect_value(t, ghostty_terminal_new(nil, &term, opts), GHOSTTY_SUCCESS) do return
	defer ghostty_terminal_free(term)

	state: GhosttyRenderState
	if !testing.expect_value(t, ghostty_render_state_new(nil, &state), GHOSTTY_SUCCESS) do return
	defer ghostty_render_state_free(state)

	row_iter: GhosttyRenderStateRowIterator
	if !testing.expect_value(t, ghostty_render_state_row_iterator_new(nil, &row_iter), GHOSTTY_SUCCESS) do return
	defer ghostty_render_state_row_iterator_free(row_iter)

	row_cells: GhosttyRenderStateRowCells
	if !testing.expect_value(t, ghostty_render_state_row_cells_new(nil, &row_cells), GHOSTTY_SUCCESS) do return
	defer ghostty_render_state_row_cells_free(row_cells)

	text := "hello"
	ghostty_terminal_vt_write(term, raw_data(text), len(text))
	if !testing.expect_value(t, ghostty_render_state_update(state, term), GHOSTTY_SUCCESS) do return

	cols: u16
	rows: u16
	testing.expect_value(t, ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLS, &cols), GHOSTTY_SUCCESS)
	testing.expect_value(t, ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows), GHOSTTY_SUCCESS)
	testing.expect_value(t, cols, u16(20))
	testing.expect_value(t, rows, u16(5))

	testing.expect(t, render_state_bool(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE))
	testing.expect(t, render_state_bool(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE))

	cursor_x: u16
	cursor_y: u16
	style: i32
	testing.expect_value(t, ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &cursor_x), GHOSTTY_SUCCESS)
	testing.expect_value(t, ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &cursor_y), GHOSTTY_SUCCESS)
	testing.expect_value(t, ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &style), GHOSTTY_SUCCESS)
	testing.expect_value(t, cursor_x, u16(5))
	testing.expect_value(t, cursor_y, u16(0))
	testing.expect(t, style == GHOSTTY_CURSOR_BAR || style == GHOSTTY_CURSOR_BLOCK ||
	                  style == GHOSTTY_CURSOR_UNDERLINE || style == GHOSTTY_CURSOR_BLOCK_HOLLOW)

	if !testing.expect_value(t, ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &row_iter), GHOSTTY_SUCCESS) do return

	// The iterator must visit every viewport row in order, which is what lets
	// terminal_draw use a simple counter for the cursor's viewport Y on the
	// pinned 1.3.2-dev API.
	found: [64]u8
	found_len := 0
	row_count := 0
	for ghostty_render_state_row_iterator_next(row_iter) {
		ghostty_render_state_row_get(row_iter, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &row_cells)
		for ghostty_render_state_row_cells_next(row_cells) {
			buf: [64]u8
			gb := GhosttyBuffer {
				ptr = &buf[0],
				cap = len(buf),
			}
			if ghostty_render_state_row_cells_get(row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &gb) == GHOSTTY_SUCCESS && gb.len > 0 {
				n := int(gb.len)
				if found_len + n <= len(found) {
					copy(found[found_len:], buf[:n])
					found_len += n
				}
			}
		}
		row_count += 1
	}

	testing.expect_value(t, row_count, int(rows))
	testing.expect_value(t, string(found[:found_len]), "hello")
}

// Scrollback must be enabled at construction: with max_scrollback == 0
// libghostty keeps no history, so the terminal never reports a scrollable
// area and the drawer scrollbar is never drawn.
@(test)
test_ghostty_terminal_scrollback :: proc(t: ^testing.T) {
	term: GhosttyTerminal
	opts := GhosttyTerminalOptions {
		cols = 20,
		rows = 5,
		max_scrollback = TERM_SCROLLBACK,
	}
	if !testing.expect_value(t, ghostty_terminal_new(nil, &term, opts), GHOSTTY_SUCCESS) do return
	defer ghostty_terminal_free(term)

	for _ in 0 ..< 30 {
		text := "line\r\n"
		ghostty_terminal_vt_write(term, raw_data(text), len(text))
	}

	sb: GhosttyTerminalScrollbar
	if !testing.expect_value(t, ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &sb), GHOSTTY_SUCCESS) do return
	testing.expect(t, sb.len > 0, "viewport length should be non-zero")
	testing.expect(t, sb.total > sb.len, "terminal should have scrollback after 30 lines in a 5-row grid")
	testing.expect_value(t, sb.offset + sb.len, sb.total) // viewport follows output
}

// Selection snapshots must convert to tracked state on install, show up in the
// render state, and format back to the text the user dragged over.
@(test)
test_ghostty_terminal_selection :: proc(t: ^testing.T) {
	term: GhosttyTerminal
	opts := GhosttyTerminalOptions{cols = 20, rows = 5, max_scrollback = TERM_SCROLLBACK}
	if !testing.expect_value(t, ghostty_terminal_new(nil, &term, opts), GHOSTTY_SUCCESS) do return
	defer ghostty_terminal_free(term)

	text := "hello world\r\nsecond line\r\n"
	ghostty_terminal_vt_write(term, raw_data(text), len(text))
	state: GhosttyRenderState
	if !testing.expect_value(t, ghostty_render_state_new(nil, &state), GHOSTTY_SUCCESS) do return
	defer ghostty_render_state_free(state)
	if !testing.expect_value(t, ghostty_render_state_update(state, term), GHOSTTY_SUCCESS) do return

	a: GhosttyGridRef
	b: GhosttyGridRef
	pa: GhosttyPointValue
	pa.coordinate = GhosttyPointCoordinate{x = 0, y = 0}
	pb: GhosttyPointValue
	pb.coordinate = GhosttyPointCoordinate{x = 10, y = 0}
	if !testing.expect_value(t, ghostty_terminal_grid_ref(term, GhosttyPoint{tag = .VIEWPORT, value = pa}, &a), GHOSTTY_SUCCESS) do return
	if !testing.expect_value(t, ghostty_terminal_grid_ref(term, GhosttyPoint{tag = .VIEWPORT, value = pb}, &b), GHOSTTY_SUCCESS) do return

	sel := GhosttySelection{size = size_of(GhosttySelection), start = a, end = b}
	if !testing.expect_value(t, ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SELECTION, &sel), GHOSTTY_SUCCESS) do return
	if !testing.expect_value(t, ghostty_render_state_update(state, term), GHOSTTY_SUCCESS) do return

	// The row iterator reports the selected column range for the first row.
	row_iter: GhosttyRenderStateRowIterator
	if !testing.expect_value(t, ghostty_render_state_row_iterator_new(nil, &row_iter), GHOSTTY_SUCCESS) do return
	defer ghostty_render_state_row_iterator_free(row_iter)
	if !testing.expect_value(t, ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &row_iter), GHOSTTY_SUCCESS) do return
	if !testing.expect(t, ghostty_render_state_row_iterator_next(row_iter)) do return
	row_sel: GhosttyRenderStateRowSelection
	row_sel.size = size_of(GhosttyRenderStateRowSelection)
	if !testing.expect_value(t, ghostty_render_state_row_get(row_iter, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &row_sel), GHOSTTY_SUCCESS) do return
	testing.expect_value(t, row_sel.start_x, u16(0))
	testing.expect_value(t, row_sel.end_x, u16(10))

	fmt_opts := GhosttyTerminalSelectionFormatOptions {
		size   = size_of(GhosttyTerminalSelectionFormatOptions),
		emit   = GHOSTTY_FORMATTER_FORMAT_PLAIN,
		unwrap = true,
		trim   = true,
	}
	needed: uint
	if !testing.expect_value(t, ghostty_terminal_selection_format_buf(term, fmt_opts, nil, 0, &needed), GHOSTTY_OUT_OF_SPACE) do return
	buf := make([]u8, int(needed) + 1, context.temp_allocator)
	defer delete(buf, context.temp_allocator)
	if !testing.expect_value(t, ghostty_terminal_selection_format_buf(term, fmt_opts, raw_data(buf), needed, &needed), GHOSTTY_SUCCESS) do return
	testing.expect_value(t, string(buf[:needed]), "hello world")

	// Installing a selection converts it to tracked references, so it must
	// stay on the selected cells when later output scrolls them up.
	more := "one\r\ntwo\r\nthree\r\nfour\r\nfive\r\n"
	ghostty_terminal_vt_write(term, raw_data(more), len(more))
	if !testing.expect_value(t, ghostty_terminal_selection_format_buf(term, fmt_opts, raw_data(buf), uint(len(buf)), &needed), GHOSTTY_SUCCESS) do return
	testing.expect_value(t, string(buf[:needed]), "hello world")
}

// Paste encoding depends on bracketed-paste mode: plain pastes must not inject
// newlines, while bracketed pastes keep them inside the paste markers.
@(test)
test_ghostty_paste_encode :: proc(t: ^testing.T) {
	src := []u8{'a', '\n', 'b'}
	buf: [64]u8

	plain := make([]u8, len(src), context.temp_allocator)
	defer delete(plain, context.temp_allocator)
	copy(plain, src)
	n: uint
	if !testing.expect_value(t, ghostty_paste_encode(raw_data(plain), uint(len(plain)), false, &buf[0], len(buf), &n), GHOSTTY_SUCCESS) do return
	testing.expect_value(t, string(buf[:n]), "a\rb")

	bracketed := make([]u8, len(src), context.temp_allocator)
	defer delete(bracketed, context.temp_allocator)
	copy(bracketed, src)
	if !testing.expect_value(t, ghostty_paste_encode(raw_data(bracketed), uint(len(bracketed)), true, &buf[0], len(buf), &n), GHOSTTY_SUCCESS) do return
	testing.expect_value(t, string(buf[:n]), "\x1b[200~a\nb\x1b[201~")
}

// The paste shortcut consults libghostty's bracketed-paste mode before
// encoding clipboard data.
@(test)
test_ghostty_bracketed_paste_mode :: proc(t: ^testing.T) {
	term: GhosttyTerminal
	opts := GhosttyTerminalOptions{cols = 20, rows = 5, max_scrollback = TERM_SCROLLBACK}
	if !testing.expect_value(t, ghostty_terminal_new(nil, &term, opts), GHOSTTY_SUCCESS) do return
	defer ghostty_terminal_free(term)

	enable := "\x1b[?2004h"
	ghostty_terminal_vt_write(term, raw_data(enable), len(enable))
	bracketed := false
	if !testing.expect_value(t, ghostty_terminal_mode_get(term, GHOSTTY_MODE_BRACKETED_PASTE, &bracketed), GHOSTTY_SUCCESS) do return
	testing.expect(t, bracketed)

	disable := "\x1b[?2004l"
	ghostty_terminal_vt_write(term, raw_data(disable), len(disable))
	if !testing.expect_value(t, ghostty_terminal_mode_get(term, GHOSTTY_MODE_BRACKETED_PASTE, &bracketed), GHOSTTY_SUCCESS) do return
	testing.expect(t, !bracketed)
}

// The mouse encoder turns surface pixels into the X10/SGR sequences that
// terminal applications such as micro consume. Exercise the C bindings,
// terminal-derived tracking/format options, drag motion, release, and wheel.
mouse_encode_test :: proc(
	t: ^testing.T,
	enc: GhosttyMouseEncoder,
	ev: GhosttyMouseEvent,
	action, button: i32,
	pos: GhosttyMousePosition,
	buf: []u8,
) -> string {
	ghostty_mouse_event_set_action(ev, action)
	if button == GHOSTTY_MOUSE_BUTTON_UNKNOWN {
		ghostty_mouse_event_clear_button(ev)
	} else {
		ghostty_mouse_event_set_button(ev, button)
	}
	ghostty_mouse_event_set_mods(ev, 0)
	ghostty_mouse_event_set_position(ev, pos)
	n: uint
	if !testing.expect_value(t,
		ghostty_mouse_encoder_encode(enc, ev, raw_data(buf), uint(len(buf)), &n),
		GHOSTTY_SUCCESS,
	) {
		return ""
	}
	return string(buf[:n])
}

@(test)
test_ghostty_mouse_encode :: proc(t: ^testing.T) {
	term: GhosttyTerminal
	opts := GhosttyTerminalOptions{cols = 20, rows = 5, max_scrollback = TERM_SCROLLBACK}
	if !testing.expect_value(t, ghostty_terminal_new(nil, &term, opts), GHOSTTY_SUCCESS) do return
	defer ghostty_terminal_free(term)

	tracking := false
	if !testing.expect_value(t,
		ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking),
		GHOSTTY_SUCCESS,
	) {
		return
	}
	testing.expect(t, !tracking, "mouse tracking should start disabled")

	// Micro enables button-event tracking and the SGR format.
	enable := "\x1b[?1002h\x1b[?1006h"
	ghostty_terminal_vt_write(term, raw_data(enable), len(enable))
	if !testing.expect_value(t,
		ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking),
		GHOSTTY_SUCCESS,
	) {
		return
	}
	testing.expect(t, tracking, "?1002 should enable mouse tracking")

	enc: GhosttyMouseEncoder
	if !testing.expect_value(t, ghostty_mouse_encoder_new(nil, &enc), GHOSTTY_SUCCESS) do return
	defer ghostty_mouse_encoder_free(enc)
	ev: GhosttyMouseEvent
	if !testing.expect_value(t, ghostty_mouse_event_new(nil, &ev), GHOSTTY_SUCCESS) do return
	defer ghostty_mouse_event_free(ev)

	size := GhosttyMouseEncoderSize {
		size          = size_of(GhosttyMouseEncoderSize),
		screen_width  = 100,
		screen_height = 100,
		cell_width    = 10,
		cell_height   = 10,
		padding_top   = 4,
		padding_left  = 9,
	}
	ghostty_mouse_encoder_setopt(enc, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size)
	ghostty_mouse_encoder_setopt_from_terminal(enc, term)

	// (34, 19) is column 2, row 1 after padding and cell division.
	pos := GhosttyMousePosition{x = 34, y = 19}
	buf: [64]u8
	testing.expect_value(t,
		mouse_encode_test(t, enc, ev, GHOSTTY_MOUSE_ACTION_PRESS, GHOSTTY_MOUSE_BUTTON_LEFT, pos, buf[:]),
		"\x1b[<0;3;2M",
	)
	testing.expect_value(t,
		mouse_encode_test(t, enc, ev, GHOSTTY_MOUSE_ACTION_MOTION, GHOSTTY_MOUSE_BUTTON_LEFT, pos, buf[:]),
		"\x1b[<32;3;2M",
	)
	testing.expect_value(t,
		mouse_encode_test(t, enc, ev, GHOSTTY_MOUSE_ACTION_RELEASE, GHOSTTY_MOUSE_BUTTON_LEFT, pos, buf[:]),
		"\x1b[<0;3;2m",
	)
	testing.expect_value(t,
		mouse_encode_test(t, enc, ev, GHOSTTY_MOUSE_ACTION_PRESS, GHOSTTY_MOUSE_BUTTON_FOUR, pos, buf[:]),
		"\x1b[<64;3;2M",
	)

	// Disabling tracking makes subsequent events silent.
	disable := "\x1b[?1002l"
	ghostty_terminal_vt_write(term, raw_data(disable), len(disable))
	ghostty_mouse_encoder_setopt_from_terminal(enc, term)
	testing.expect_value(t,
		mouse_encode_test(t, enc, ev, GHOSTTY_MOUSE_ACTION_PRESS, GHOSTTY_MOUSE_BUTTON_LEFT, pos, buf[:]),
		"",
	)
}
