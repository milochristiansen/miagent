// A terminal drawer: a PTY running the user's shell, a libghostty-vt terminal
// for state, and an ImGui draw-list renderer for the cell grid.
package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

Terminal :: struct {
	gt:        GhosttyTerminal,
	rs:        GhosttyRenderState,
	row_iter:  GhosttyRenderStateRowIterator,
	row_cells: GhosttyRenderStateRowCells,
	enc:       GhosttyKeyEncoder,
	ev:        GhosttyKeyEvent,
	mouse_enc: GhosttyMouseEncoder,
	mouse_ev:  GhosttyMouseEvent,

	fd:        i32,
	pid:       i32,
	alive:     bool,
	exit_code: i32,

	cols:   u16,
	nrows:  u16,
	dirty:  bool,
	title:  string,
	cwd:    string,
	shell:  string,

	cursor_text: [64]u8,
	cursor_len:  int,
	scroll_grab: f32,

	// Drag selection state. The endpoints themselves live in libghostty once
	// installed, so they stay anchored to cells as output scrolls. The anchor
	// is kept in viewport coordinates for the duration of the drag.
	sel_dragging:   bool,
	sel_moved:      bool,
	sel_was_down:   bool,
	sel_anchor_col: u16,
	sel_anchor_row: u32,

	// Mouse reporting state. `mouse_grab` means a press was delivered to the
	// application, so motion/release must keep going to it even when the
	// pointer leaves the terminal body. `mouse_cell` deduplicates motion to
	// one report per cell.
	mouse_grab:      bool,
	mouse_cell:      Terminal_Cell,
	mouse_have_cell: bool,
}

TERM_PAD_X :: f32(9.0)
TERM_PAD_Y :: f32(4.0)

// libghostty treats max_scrollback == 0 as "no scrollback", which also means
// the terminal never reports a scrollable area and the drawer scrollbar stays
// hidden. Give every shell a bounded history so scrolling and the scrollbar
// work; the value is in lines.
TERM_SCROLLBACK :: 10_000

// terminal_grid_size is the exact cols/rows terminal_draw will use for an
// area. Starting the PTY with this size avoids the shell drawing a prompt at
// the default 80x24 and then redrawing it after a resize.
terminal_grid_size :: proc(area: Rect, f: Fonts) -> (cols, rows: u16) {
	inner_w := area.w - TERM_PAD_X * 2
	inner_h := area.h - TERM_PAD_Y * 2
	if inner_w < f.cell_w * 4 || inner_h < f.cell_h * 2 do return 0, 0
	return u16(clamp(int(inner_w / f.cell_w), 1, 1000)),
	       u16(clamp(int(inner_h / f.cell_h), 1, 1000))
}

Terminal_Result :: enum {
	Ok,
	Invalid_Dimensions,
	Ghostty_Failed,
	Pty_Failed,
}

terminal_init :: proc(t: ^Terminal, shell: string, cwd: string, th: Theme, cols, rows: u16) -> Terminal_Result {
	t.cols = cols > 0 ? cols : 80
	t.nrows = rows > 0 ? rows : 24
	t.shell = strings.clone(shell, context.allocator)

	opts := GhosttyTerminalOptions {
		cols = t.cols,
		rows = t.nrows,
		max_scrollback = TERM_SCROLLBACK,
	}
	if ghostty_terminal_new(nil, &t.gt, opts) != GHOSTTY_SUCCESS {
		return .Ghostty_Failed
	}

	// Tell libghostty about the palette so OSC queries and default colors
	// match the terminal theme exactly.
	fg := GhosttyColorRgb{u8(th.term_fg[0] * 255), u8(th.term_fg[1] * 255), u8(th.term_fg[2] * 255)}
	bg := GhosttyColorRgb{u8(th.term_bg[0] * 255), u8(th.term_bg[1] * 255), u8(th.term_bg[2] * 255)}
	cur := GhosttyColorRgb{u8(th.cursor[0] * 255), u8(th.cursor[1] * 255), u8(th.cursor[2] * 255)}
	ghostty_terminal_set(t.gt, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg)
	ghostty_terminal_set(t.gt, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg)
	ghostty_terminal_set(t.gt, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cur)
	palette: [256]GhosttyColorRgb
	ghostty_color_palette_default(&palette)
	for i in 0 ..< 16 {
		c := th.ansi[i]
		palette[i] = GhosttyColorRgb{u8(c[0] * 255), u8(c[1] * 255), u8(c[2] * 255)}
	}
	ghostty_terminal_set(t.gt, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, &palette)

	if ghostty_render_state_new(nil, &t.rs) != GHOSTTY_SUCCESS do return .Ghostty_Failed
	if ghostty_render_state_row_iterator_new(nil, &t.row_iter) != GHOSTTY_SUCCESS do return .Ghostty_Failed
	if ghostty_render_state_row_cells_new(nil, &t.row_cells) != GHOSTTY_SUCCESS do return .Ghostty_Failed

	if ghostty_key_encoder_new(nil, &t.enc) != GHOSTTY_SUCCESS do return .Ghostty_Failed
	if ghostty_key_event_new(nil, &t.ev) != GHOSTTY_SUCCESS do return .Ghostty_Failed
	if ghostty_mouse_encoder_new(nil, &t.mouse_enc) != GHOSTTY_SUCCESS do return .Ghostty_Failed
	if ghostty_mouse_event_new(nil, &t.mouse_ev) != GHOSTTY_SUCCESS do return .Ghostty_Failed
	alt_prefix := true
	ghostty_key_encoder_setopt(t.enc, GHOSTTY_KEY_ENCODER_OPT_ALT_ESC_PREFIX, &alt_prefix)

	errbuf: [256]u8
	rc := mi_pty_spawn(
		zstr(shell),
		zstr(cwd),
		t.cols,
		t.nrows,
		&t.fd,
		&t.pid,
		&errbuf[0],
		i32(len(errbuf)),
	)
	if rc != 0 {
		fmt.eprintf("pty spawn failed: %s\n", string(cstring(&errbuf[0])))
		return .Pty_Failed
	}
	t.alive = true
	t.dirty = true
	t.title = strings.clone("shell", context.allocator)
	t.cwd = strings.clone(cwd, context.allocator)
	return .Ok
}

terminal_destroy :: proc(t: ^Terminal) {
	if t.fd >= 0 || t.pid > 0 {
		mi_pty_terminate(t.fd, t.pid)
		// Reap if the child is gone; WNOHANG makes this a no-op otherwise.
		if t.pid > 0 do mi_pty_reap(t.pid)
		t.fd = -1
		t.pid = -1
	}
	if t.row_cells != nil do ghostty_render_state_row_cells_free(t.row_cells)
	if t.row_iter != nil do ghostty_render_state_row_iterator_free(t.row_iter)
	if t.rs != nil do ghostty_render_state_free(t.rs)
	if t.enc != nil do ghostty_key_encoder_free(t.enc)
	if t.ev != nil do ghostty_key_event_free(t.ev)
	if t.mouse_enc != nil do ghostty_mouse_encoder_free(t.mouse_enc)
	if t.mouse_ev != nil do ghostty_mouse_event_free(t.mouse_ev)
	if t.gt != nil do ghostty_terminal_free(t.gt)
	delete(t.title)
	delete(t.cwd)
	delete(t.shell)
}

// Drain whatever the shell has produced since the last frame.
terminal_pump :: proc(t: ^Terminal) {
	if !t.alive do return
	buf: [65536]u8
	for {
		n := mi_pty_read(t.fd, &buf[0], i32(len(buf)))
		if n > 0 {
			ghostty_terminal_vt_write(t.gt, &buf[0], uint(n))
			t.dirty = true

		} else if n == 0 {
			break
		} else {
			t.alive = false
			break
		}
	}
	if t.alive {
		code := mi_pty_reap(t.pid)
		if code > 0 {
			t.alive = false
			t.exit_code = code - 1
			t.pid = -1
		}
	}
	if !t.alive && t.fd >= 0 {
		// Keep the last frame on screen; release the fd.
		t.fd = -1
	}

	// Pick up title / cwd updates advertised through OSC sequences.
	if t.dirty {
		terminal_refresh_meta(t)
	}
}

// render_state_bool reads a boolean render-state field, treating a failed
// query the same as a false value.
render_state_bool :: proc(state: GhosttyRenderState, data: i32) -> bool {
	value := false
	return ghostty_render_state_get(state, data, &value) == GHOSTTY_SUCCESS && value
}

terminal_refresh_meta :: proc(t: ^Terminal) {
	s: GhosttyString
	if ghostty_terminal_get(t.gt, GHOSTTY_TERMINAL_DATA_TITLE, &s) == GHOSTTY_SUCCESS && s.len > 0 {
		val := string(s.ptr[:s.len])
		if len(val) > 0 {
			delete(t.title)
			t.title = strings.clone(val, context.allocator)
		}
	}
	if ghostty_terminal_get(t.gt, GHOSTTY_TERMINAL_DATA_PWD, &s) == GHOSTTY_SUCCESS && s.len > 0 {
		val := string(s.ptr[:s.len])
		if len(val) > 0 {
			delete(t.cwd)
			t.cwd = strings.clone(val, context.allocator)
		}
	}
}

terminal_resize :: proc(t: ^Terminal, cols, rows: u16, cell_w, cell_h: f32) {
	if cols == 0 || rows == 0 do return
	if cols == t.cols && rows == t.nrows do return
	ghostty_terminal_resize(t.gt, cols, rows, u32(max(cell_w, 1)), u32(max(cell_h, 1)))
	if t.fd >= 0 do mi_pty_resize(t.fd, cols, rows)
	t.cols = cols
	t.nrows = rows
	t.dirty = true
}

terminal_write :: proc(t: ^Terminal, data: []u8) {
	if !t.alive || t.fd < 0 || len(data) == 0 do return
	mi_pty_write(t.fd, raw_data(data), i32(len(data)))
}

terminal_send :: proc(t: ^Terminal, s: string) {
	if !t.alive || t.fd < 0 || len(s) == 0 do return
	mi_pty_write(t.fd, raw_data(s), i32(len(s)))
}

// --- input -----------------------------------------------------------------

Key_Binding :: struct {
	imgui:  ImGuiKey,
	ghostty: i32,
}

KEY_BINDINGS := [?]Key_Binding {
	{KEY_ENTER, GHOSTTY_KEY_ENTER},
	{KEY_TAB, GHOSTTY_KEY_TAB},
	{KEY_BACKSPACE, GHOSTTY_KEY_BACKSPACE},
	{KEY_ESCAPE, GHOSTTY_KEY_ESCAPE},
	{KEY_DELETE, GHOSTTY_KEY_DELETE},
	{KEY_INSERT, GHOSTTY_KEY_INSERT},
	{KEY_HOME, GHOSTTY_KEY_HOME},
	{KEY_END, GHOSTTY_KEY_END},
	{KEY_PAGE_UP, GHOSTTY_KEY_PAGE_UP},
	{KEY_PAGE_DOWN, GHOSTTY_KEY_PAGE_DOWN},
	{KEY_UP, GHOSTTY_KEY_ARROW_UP},
	{KEY_DOWN, GHOSTTY_KEY_ARROW_DOWN},
	{KEY_LEFT, GHOSTTY_KEY_ARROW_LEFT},
	{KEY_RIGHT, GHOSTTY_KEY_ARROW_RIGHT},
	{ImGuiKey(572), GHOSTTY_KEY_F1},
	{ImGuiKey(573), 122},
	{ImGuiKey(574), 123},
	{ImGuiKey(575), 124},
	{ImGuiKey(576), 125},
	{ImGuiKey(577), 126},
	{ImGuiKey(578), 127},
	{ImGuiKey(579), 128},
	{ImGuiKey(580), 129},
	{ImGuiKey(581), 130},
	{ImGuiKey(582), 131},
	{ImGuiKey(583), GHOSTTY_KEY_F12},
}

// Punctuation keys, for Ctrl+<key> combinations.
PUNCT_BINDINGS := [?]Key_Binding {
	{ImGuiKey(586), GHOSTTY_KEY_QUOTE},
	{ImGuiKey(587), GHOSTTY_KEY_COMMA},
	{ImGuiKey(588), GHOSTTY_KEY_MINUS},
	{ImGuiKey(589), GHOSTTY_KEY_PERIOD},
	{ImGuiKey(590), GHOSTTY_KEY_SLASH},
	{ImGuiKey(591), GHOSTTY_KEY_SEMICOLON},
	{ImGuiKey(592), GHOSTTY_KEY_EQUAL},
	{ImGuiKey(593), GHOSTTY_KEY_BRACKET_LEFT},
	{ImGuiKey(594), GHOSTTY_KEY_BACKSLASH},
	{ImGuiKey(595), GHOSTTY_KEY_BRACKET_RIGHT},
	{ImGuiKey(596), GHOSTTY_KEY_BACKQUOTE},
}

// Returns (ghostty_key, is_text_key).
imgui_key_to_ghostty :: proc(key: ImGuiKey) -> (i32, bool) {
	v := i32(key)
	// A-Z
	if v >= 546 && v <= 571 do return GHOSTTY_KEY_A + (v - 546), true
	// 0-9
	if v >= 536 && v <= 545 do return GHOSTTY_KEY_DIGIT_0 + (v - 536), true
	if key == KEY_SPACE do return GHOSTTY_KEY_SPACE, true
	for b in PUNCT_BINDINGS {
		if b.imgui == key do return b.ghostty, true
	}
	for b in KEY_BINDINGS {
		if b.imgui == key do return b.ghostty, false
	}
	return GHOSTTY_KEY_UNIDENTIFIED, false
}

// --- selection and clipboard ----------------------------------------------

Terminal_Cell :: struct {
	col: u16,
	row: u32,
}

terminal_cell_at :: proc(inner: Rect, f: Fonts, mouse: ImVec2, cols, rows: u16) -> Terminal_Cell {
	col := u16(clamp(int((mouse.x - inner.x) / f.cell_w), 0, int(cols) - 1))
	row := u32(clamp(int((mouse.y - inner.y) / f.cell_h), 0, int(rows) - 1))
	return {col, row}
}

// terminal_select_cells installs a linear selection from two viewport cells.
// libghostty converts the endpoints to tracked references immediately, so the
// selection survives scrolling and later output.
terminal_select_cells :: proc(t: ^Terminal, a, b: Terminal_Cell) -> bool {
	start: GhosttyGridRef
	end: GhosttyGridRef
	pa: GhosttyPointValue
	pa.coordinate = GhosttyPointCoordinate{x = a.col, y = a.row}
	pb: GhosttyPointValue
	pb.coordinate = GhosttyPointCoordinate{x = b.col, y = b.row}
	if ghostty_terminal_grid_ref(t.gt, GhosttyPoint{tag = .VIEWPORT, value = pa}, &start) != GHOSTTY_SUCCESS do return false
	if ghostty_terminal_grid_ref(t.gt, GhosttyPoint{tag = .VIEWPORT, value = pb}, &end) != GHOSTTY_SUCCESS do return false
	sel := GhosttySelection {
		size  = size_of(GhosttySelection),
		start = start,
		end   = end,
	}
	return ghostty_terminal_set(t.gt, GHOSTTY_TERMINAL_OPT_SELECTION, &sel) == GHOSTTY_SUCCESS
}

terminal_clear_selection :: proc(t: ^Terminal) {
	if t.gt == nil do return
	ghostty_terminal_set(t.gt, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
	t.dirty = true
}

// terminal_selection_update drives click-and-drag selection from raw pointer
// input. It must run before terminal_draw so the render state reflects the new
// selection in the same frame it was dragged. `over_body` must exclude the
// scrollbar strip so dragging the scrollbar never starts a text selection.
terminal_selection_update :: proc(t: ^Terminal, area: Rect, f: Fonts, mouse: ImVec2, over_body, down: bool) {
	if !t.alive || f.cell_w <= 0 || f.cell_h <= 0 do return
	cols, rows := terminal_grid_size(area, f)
	if cols == 0 || rows == 0 do return
	terminal_resize(t, cols, rows, f.cell_w, f.cell_h)

	inner := rect(area.x + TERM_PAD_X, area.y + TERM_PAD_Y,
		max(area.w - TERM_PAD_X * 2, 0), max(area.h - TERM_PAD_Y * 2, 0))
	// InvisibleButton reports a click on release, so selection needs the raw
	// press edge to begin a drag.
	pressed := down && !t.sel_was_down && over_body
	t.sel_was_down = down
	if pressed {
		t.sel_dragging = true
		t.sel_moved = false
		cell := terminal_cell_at(inner, f, mouse, cols, rows)
		t.sel_anchor_col = cell.col
		t.sel_anchor_row = cell.row
		terminal_clear_selection(t)
	}
	if !t.sel_dragging do return
	if !down {
		t.sel_dragging = false
		return
	}

	cell := terminal_cell_at(inner, f, mouse, cols, rows)
	if cell.col != t.sel_anchor_col || cell.row != t.sel_anchor_row do t.sel_moved = true
	if t.sel_moved {
		a := Terminal_Cell{t.sel_anchor_col, t.sel_anchor_row}
		if terminal_select_cells(t, a, cell) do t.dirty = true
	}
}

terminal_copy :: proc(t: ^Terminal) {
	if t.gt == nil do return
	opts := GhosttyTerminalSelectionFormatOptions {
		size   = size_of(GhosttyTerminalSelectionFormatOptions),
		emit   = GHOSTTY_FORMATTER_FORMAT_PLAIN,
		unwrap = true,
		trim   = true,
	}
	needed: uint
	res := ghostty_terminal_selection_format_buf(t.gt, opts, nil, 0, &needed)
	if res != GHOSTTY_OUT_OF_SPACE || needed == 0 do return
	buf := make([]u8, int(needed) + 1, context.temp_allocator)
	res = ghostty_terminal_selection_format_buf(t.gt, opts, raw_data(buf), needed, &needed)
	if res != GHOSTTY_SUCCESS || needed == 0 do return
	buf[needed] = 0
	mi_set_clipboard(cstring(raw_data(buf)))
}

terminal_paste :: proc(t: ^Terminal) {
	if !t.alive || t.gt == nil do return
	clip := mi_get_clipboard()
	if clip == nil do return
	s := string(clip)
	if len(s) == 0 do return

	bracketed := false
	_ = ghostty_terminal_mode_get(t.gt, GHOSTTY_MODE_BRACKETED_PASTE, &bracketed)

	// paste_encode modifies its input in place, so give each attempt a fresh
	// copy. Query the output size first.
	src := make([]u8, len(s), context.temp_allocator)
	copy(src, s)
	needed: uint
	res := ghostty_paste_encode(raw_data(src), uint(len(src)), bracketed, nil, 0, &needed)
	if res != GHOSTTY_OUT_OF_SPACE || needed == 0 do return
	copy(src, s)
	out := make([]u8, int(needed), context.temp_allocator)
	res = ghostty_paste_encode(raw_data(src), uint(len(src)), bracketed, raw_data(out), needed, &needed)
	if res == GHOSTTY_SUCCESS && needed > 0 do terminal_write(t, out[:needed])
}

// Feed one frame of keyboard input to the shell. Text arrives through ImGui's
// character queue; key events are only encoded for keys that don't produce
// text (plus Ctrl combinations), which keeps libghostty's encoder authoritative
// for escapes and modifiers without double-sending printable characters.
terminal_handle_input :: proc(t: ^Terminal) {
	if !t.alive do return

	ctrl := mi_io_key_ctrl() != 0
	shift := mi_io_key_shift() != 0
	alt := mi_io_key_alt() != 0
	super := mi_io_key_super() != 0

	// Terminal clipboard shortcuts. Handle them before the generic Ctrl-key
	// encoding below so Ctrl+Shift+C never reaches the shell as Ctrl+C.
	if ctrl && shift {
		if igIsKeyPressed_Bool(KEY_C, false) {
			terminal_copy(t)
			return
		}
		if igIsKeyPressed_Bool(KEY_V, false) {
			terminal_paste(t)
			return
		}
	}

	mods: u16
	if ctrl do mods |= GHOSTTY_MODS_CTRL
	if shift do mods |= GHOSTTY_MODS_SHIFT
	if alt do mods |= GHOSTTY_MODS_ALT
	if super do mods |= GHOSTTY_MODS_SUPER

	ghostty_key_encoder_setopt_from_terminal(t.enc, t.gt)

	encode_buf: [128]u8
	// Control combinations and non-text keys.
	handle_key :: proc(t: ^Terminal, gkey: i32, mods: u16, buf: ^[128]u8) {
		ghostty_key_event_set_action(t.ev, GHOSTTY_KEY_ACTION_PRESS)
		ghostty_key_event_set_key(t.ev, gkey)
		ghostty_key_event_set_mods(t.ev, mods)
		ghostty_key_event_set_utf8(t.ev, nil, 0)
		n: uint
		if ghostty_key_encoder_encode(t.enc, t.ev, &buf[0], len(buf), &n) == GHOSTTY_SUCCESS && n > 0 {
			terminal_write(t, buf[:n])
		}
	}

	for b in KEY_BINDINGS {
		if igIsKeyPressed_Bool(b.imgui, true) {
			handle_key(t, b.ghostty, mods, &encode_buf)
		}
	}
	if ctrl {
		if igIsKeyPressed_Bool(KEY_SPACE, true) do handle_key(t, GHOSTTY_KEY_SPACE, mods, &encode_buf)
		for i in 0 ..< 26 {
			if igIsKeyPressed_Bool(ImGuiKey(546 + i), true) {
				handle_key(t, GHOSTTY_KEY_A + i32(i), mods, &encode_buf)
			}
		}
		for i in 0 ..< 10 {
			if igIsKeyPressed_Bool(ImGuiKey(536 + i), true) {
				handle_key(t, GHOSTTY_KEY_DIGIT_0 + i32(i), mods, &encode_buf)
			}
		}
		for b in PUNCT_BINDINGS {
			if igIsKeyPressed_Bool(b.imgui, true) {
				handle_key(t, b.ghostty, mods, &encode_buf)
			}
		}
	}

	// Text.
	if super do return
	chars: [64]u32
	n := mi_io_input_chars(&chars[0], i32(len(chars)))
	out: [256]u8
	off := 0
	for i in 0 ..< int(n) {
		cp := rune(chars[i])
		if cp == 0 do continue
		if ctrl do continue
		if alt && off + 1 < len(out) {
			out[off] = 0x1b
			off += 1
		}
		off += utf8_encode(cp, out[off:])
	}
	if off > 0 do terminal_write(t, out[:off])
}

// --- mouse reporting -------------------------------------------------------

Mouse_Button_Binding :: struct {
	imgui:  i32,
	ghostty: i32,
}

// ImGui button order is left/right/middle. libghostty has its own button
// identities, and the encoder turns these into the X10/SGR button codes.
MOUSE_BUTTON_BINDINGS := [?]Mouse_Button_Binding {
	{0, GHOSTTY_MOUSE_BUTTON_LEFT},
	{1, GHOSTTY_MOUSE_BUTTON_RIGHT},
	{2, GHOSTTY_MOUSE_BUTTON_MIDDLE},
}

// terminal_mouse_tracking reports whether the running program has enabled a
// mouse tracking mode (?9, ?1000, ?1002, or ?1003). Painting and selection
// must consult this: while it is on, clicks belong to the application unless
// the user holds Shift to override it.
terminal_mouse_tracking :: proc(t: ^Terminal) -> bool {
	if t == nil || t.gt == nil do return false
	tracking := false
	if ghostty_terminal_get(t.gt, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking) != GHOSTTY_SUCCESS {
		return false
	}
	return tracking
}

// terminal_mouse_report encodes one normalized event with the encoder options
// taken from the terminal (tracking mode and wire format). At most one small
// escape sequence is produced.
terminal_mouse_report :: proc(t: ^Terminal, action, button: i32,
                               pos: GhosttyMousePosition, mods: u16, any_pressed: bool) {
	if t.mouse_enc == nil || t.mouse_ev == nil do return

	ghostty_mouse_event_set_action(t.mouse_ev, action)
	if button == GHOSTTY_MOUSE_BUTTON_UNKNOWN {
		ghostty_mouse_event_clear_button(t.mouse_ev)
	} else {
		ghostty_mouse_event_set_button(t.mouse_ev, button)
	}
	ghostty_mouse_event_set_mods(t.mouse_ev, mods)
	ghostty_mouse_event_set_position(t.mouse_ev, pos)

	any := any_pressed
	ghostty_mouse_encoder_setopt(t.mouse_enc, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &any)

	buf: [32]u8
	n: uint
	if ghostty_mouse_encoder_encode(t.mouse_enc, t.mouse_ev, &buf[0], len(buf), &n) == GHOSTTY_SUCCESS && n > 0 {
		terminal_write(t, buf[:n])
	}
}

// terminal_mouse_input forwards pointer input to the program when it has
// requested mouse tracking. Positions are passed relative to the drawer body;
// the encoder's size context removes the terminal padding and converts to
// cells. Shift-click/drag is reserved for local text selection, matching the
// usual terminal convention. Wheel events become buttons 4/5.
terminal_mouse_input :: proc(t: ^Terminal, area: Rect, f: Fonts, mouse: ImVec2,
                             over_body, shift: bool, wheel: f32) {
	if !t.alive || t.mouse_enc == nil || t.mouse_ev == nil do return
	if !terminal_mouse_tracking(t) {
		t.mouse_grab = false
		t.mouse_have_cell = false
		return
	}
	// A press that started in the terminal keeps the grab until release, even
	// if the pointer leaves the body. Shift starts a local selection instead.
	if !over_body && !t.mouse_grab do return
	if shift && !t.mouse_grab do return

	cols, rows := terminal_grid_size(area, f)
	if cols == 0 || rows == 0 do return
	terminal_resize(t, cols, rows, f.cell_w, f.cell_h)

	inner := rect(area.x + TERM_PAD_X, area.y + TERM_PAD_Y,
		max(area.w - TERM_PAD_X * 2, 0), max(area.h - TERM_PAD_Y * 2, 0))
	pos := GhosttyMousePosition{x = mouse.x - area.x, y = mouse.y - area.y}

	// Refresh tracking mode/format from the terminal, then give the encoder
	// the same geometry terminal_draw used. The size option must be set after
	// the terminal options; setopt_from_terminal only touches mode/format.
	ghostty_mouse_encoder_setopt_from_terminal(t.mouse_enc, t.gt)
	size := GhosttyMouseEncoderSize {
		size           = size_of(GhosttyMouseEncoderSize),
		screen_width   = u32(max(area.w, 1)),
		screen_height  = u32(max(area.h, 1)),
		cell_width     = u32(max(f.cell_w, 1)),
		cell_height    = u32(max(f.cell_h, 1)),
		padding_top    = u32(TERM_PAD_Y),
		padding_bottom = u32(TERM_PAD_Y),
		padding_right  = u32(TERM_PAD_X),
		padding_left   = u32(TERM_PAD_X),
	}
	ghostty_mouse_encoder_setopt(t.mouse_enc, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size)

	mods: u16
	if mi_io_key_ctrl() != 0 do mods |= GHOSTTY_MODS_CTRL
	if shift do mods |= GHOSTTY_MODS_SHIFT
	if mi_io_key_alt() != 0 do mods |= GHOSTTY_MODS_ALT
	if mi_io_key_super() != 0 do mods |= GHOSTTY_MODS_SUPER

	any_down := false
	for b in MOUSE_BUTTON_BINDINGS {
		if igIsMouseDown_Nil(b.imgui) do any_down = true
	}
	sent_button := false

	if over_body {
		for b in MOUSE_BUTTON_BINDINGS {
			if igIsMouseClicked_Bool(b.imgui, false) {
				t.mouse_grab = true
				t.mouse_have_cell = false
				// The application owns this gesture; a stale local selection
				// would otherwise remain highlighted underneath it.
				terminal_clear_selection(t)
				terminal_mouse_report(t, GHOSTTY_MOUSE_ACTION_PRESS, b.ghostty, pos, mods, true)
				sent_button = true
			}
		}
	}
	if t.mouse_grab {
		for b in MOUSE_BUTTON_BINDINGS {
			if igIsMouseReleased_Nil(b.imgui) {
				terminal_mouse_report(t, GHOSTTY_MOUSE_ACTION_RELEASE, b.ghostty, pos, mods, any_down)
				sent_button = true
			}
		}
	}
	if !any_down do t.mouse_grab = false

	// Motion is deduplicated by cell. The encoder itself drops motion in
	// modes that do not request it, so this also covers ?1003 (any-event)
	// without needing to inspect the tracking mode here.
	if !sent_button {
		cell := terminal_cell_at(inner, f, mouse, cols, rows)
		if !t.mouse_have_cell || cell.col != t.mouse_cell.col || cell.row != t.mouse_cell.row {
			t.mouse_cell = cell
			t.mouse_have_cell = true
			button: i32 = GHOSTTY_MOUSE_BUTTON_UNKNOWN
			for b in MOUSE_BUTTON_BINDINGS {
				if igIsMouseDown_Nil(b.imgui) {
					button = b.ghostty
					break
				}
			}
			terminal_mouse_report(t, GHOSTTY_MOUSE_ACTION_MOTION, button, pos, mods, any_down)
		}
	}

	// Wheel: X10-style buttons 4 (up) and 5 (down), press only. Applications
	// in mouse mode expect these instead of viewport scrolling.
	if wheel != 0 && over_body && !shift {
		steps := int(math.ceil(f64(math.abs(wheel))))
		if steps > 8 do steps = 8
		button: i32 = wheel > 0 ? GHOSTTY_MOUSE_BUTTON_FOUR : GHOSTTY_MOUSE_BUTTON_FIVE
		for _ in 0 ..< steps {
			terminal_mouse_report(t, GHOSTTY_MOUSE_ACTION_PRESS, button, pos, mods, true)
		}
	}
}

terminal_scroll_row :: proc(t: ^Terminal, row: u64) {
	v: GhosttyScrollViewportValue
	v.row = row
	b := GhosttyScrollViewport {
		tag   = .ROW,
		value = v,
	}
	ghostty_terminal_scroll_viewport(t.gt, b)
	t.dirty = true
}

terminal_scroll :: proc(t: ^Terminal, lines: i32) {
	if lines == 0 do return
	v: GhosttyScrollViewportValue
	v.delta = int(lines)
	b := GhosttyScrollViewport {
		tag = .DELTA,
		value = v,
	}
	ghostty_terminal_scroll_viewport(t.gt, b)
	t.dirty = true
}


// --- rendering -------------------------------------------------------------



Fonts :: struct {
	ui:        ^ImFont,
	mono:      ^ImFont,
	mono_bold: ^ImFont,
	ui_size:   f32,
	mono_size: f32,
	cell_w:    f32,
	cell_h:    f32,
}

terminal_draw :: proc(t: ^Terminal, list: ^ImDrawList, area: Rect, th: Theme, f: Fonts, focused: bool, now: f32) {
	// Small top/bottom padding: the header already provides the separation.
	inner := rect(area.x + TERM_PAD_X, area.y + TERM_PAD_Y,
		max(area.w - TERM_PAD_X * 2, 0), max(area.h - TERM_PAD_Y * 2, 0))
	cols, rows := terminal_grid_size(area, f)
	if cols == 0 || rows == 0 do return
	terminal_resize(t, cols, rows, f.cell_w, f.cell_h)

	ghostty_render_state_update(t.rs, t.gt)
	t.dirty = false

	def_bg := th.term_bg
	def_fg := th.term_fg
	cursor_col := th.cursor
	rgb_buf: GhosttyColorRgb
	if ghostty_render_state_get(t.rs, GHOSTTY_RENDER_STATE_DATA_COLOR_BACKGROUND, &rgb_buf) == GHOSTTY_SUCCESS {
		def_bg = color_from_ghostty(rgb_buf)
	}
	if ghostty_render_state_get(t.rs, GHOSTTY_RENDER_STATE_DATA_COLOR_FOREGROUND, &rgb_buf) == GHOSTTY_SUCCESS {
		def_fg = color_from_ghostty(rgb_buf)
	}
	if ghostty_render_state_get(t.rs, GHOSTTY_RENDER_STATE_DATA_COLOR_CURSOR, &rgb_buf) == GHOSTTY_SUCCESS {
		cursor_col = color_from_ghostty(rgb_buf)
	}

	have_cursor := render_state_bool(t.rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE) &&
	               render_state_bool(t.rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE)
	cursor_x: u16 = 0
	cursor_y: u16 = 0
	cursor_style: i32 = GHOSTTY_CURSOR_BLOCK
	cursor_blinking := render_state_bool(t.rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING)
	if have_cursor {
		_ = ghostty_render_state_get(t.rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &cursor_x)
		_ = ghostty_render_state_get(t.rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &cursor_y)
		_ = ghostty_render_state_get(t.rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &cursor_style)
	}
	t.cursor_len = 0

	mi_clip_push(list, inner.x, inner.y, inner.x + inner.w, inner.y + inner.h)

	// Pass 1: background + glyphs.
	if ghostty_render_state_get(t.rs, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &t.row_iter) == GHOSTTY_SUCCESS {
		y := inner.y
		row_y: i32 = 0
		for ghostty_render_state_row_iterator_next(t.row_iter) {
			ghostty_render_state_row_get(t.row_iter, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &t.row_cells)
			// A row-local selection range avoids a C call per cell; it is
			// absent when the current selection does not touch this row.
			row_sel: GhosttyRenderStateRowSelection
			row_sel.size = size_of(GhosttyRenderStateRowSelection)
			has_row_sel := ghostty_render_state_row_get(t.row_iter, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &row_sel) == GHOSTTY_SUCCESS
			// The row iterator walks viewport rows in order, so this counter is
			// the row's viewport Y. (The pinned 1.3.2-dev API does not expose a
			// separate ROW_DATA_VIEWPORT_Y query.)
			x := inner.x
			col: u16 = 0
			for ghostty_render_state_row_cells_next(t.row_cells) {
				charbuf: [64]u8
				gb := GhosttyBuffer {
					ptr = &charbuf[0],
					cap = len(charbuf),
				}
				text_len := 0
				if ghostty_render_state_row_cells_get(t.row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &gb) == GHOSTTY_SUCCESS {
					text_len = int(gb.len)
				}

				fgc := def_fg
				fg_ok := ghostty_render_state_row_cells_get(t.row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &rgb_buf) == GHOSTTY_SUCCESS
				if fg_ok do fgc = color_from_ghostty(rgb_buf)

				bgc := def_bg
				bg_ok := ghostty_render_state_row_cells_get(t.row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &rgb_buf) == GHOSTTY_SUCCESS
				if bg_ok do bgc = color_from_ghostty(rgb_buf)

				style := GhosttyStyle {
					size = size_of(GhosttyStyle),
				}
				ghostty_render_state_row_cells_get(t.row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)

				if style.inverse {
					fgc, bgc = bgc, fgc
				}
				if style.invisible do fgc = bgc
				if style.faint do fgc = mix(fgc, bgc, 0.45)
				if has_row_sel && col >= row_sel.start_x && col <= row_sel.end_x {
					fgc = th.sel_fg
					bgc = th.sel_bg
				}

				if !color_eq(bgc, def_bg) {
					mi_draw_rect(list, x, y, x + f.cell_w, y + f.cell_h, color_u32(bgc), 0)
				}

				if text_len > 0 {
					font := style.bold && f.mono_bold != nil ? f.mono_bold : f.mono
					mi_draw_text_font_n(list, font, f.mono_size, x, y, color_u32(fgc), cstring(&charbuf[0]), uint(text_len))
				}

				if style.underline != 0 {
					mi_draw_line(list, x, y + f.cell_h - 1.5, x + f.cell_w, y + f.cell_h - 1.5, color_u32(fgc), 1)
				}
				if style.strikethrough {
					mi_draw_line(list, x, y + f.cell_h * 0.55, x + f.cell_w, y + f.cell_h * 0.55, color_u32(fgc), 1)
				}
				if style.overline {
					mi_draw_line(list, x, y + 0.5, x + f.cell_w, y + 0.5, color_u32(fgc), 1)
				}

				// Remember the glyph under the cursor so a block cursor can
				// redraw it in the inverted color.
				if have_cursor && row_y == i32(cursor_y) && col == cursor_x {
					if text_len > 0 && text_len <= len(t.cursor_text) {
						copy(t.cursor_text[:], charbuf[:text_len])
						t.cursor_len = text_len
					}
				}

				x += f.cell_w
				col += 1
			}
			y += f.cell_h
			row_y += 1
		}
	}

	// Pass 2: cursor.
	if have_cursor {
		blink_on := !cursor_blinking || int(now * 1.8) % 2 == 0
		if blink_on {
			cx := inner.x + f32(cursor_x) * f.cell_w
			cy := inner.y + f32(cursor_y) * f.cell_h
			switch cursor_style {
			case GHOSTTY_CURSOR_BAR:
				mi_draw_rect(list, cx, cy, cx + 2, cy + f.cell_h, color_u32(cursor_col), 0)
			case GHOSTTY_CURSOR_UNDERLINE:
				mi_draw_rect(list, cx, cy + f.cell_h - 2, cx + f.cell_w, cy + f.cell_h, color_u32(cursor_col), 0)
			case GHOSTTY_CURSOR_BLOCK_HOLLOW:
				mi_draw_rect_stroke(list, cx + 0.5, cy + 0.5, cx + f.cell_w - 0.5, cy + f.cell_h - 0.5, color_u32(cursor_col), 1, 1.5)
			case:
				if !focused {
					mi_draw_rect_stroke(list, cx + 0.5, cy + 0.5, cx + f.cell_w - 0.5, cy + f.cell_h - 0.5, color_u32(cursor_col), 1, 1.5)
				} else {
					mi_draw_rect(list, cx, cy, cx + f.cell_w, cy + f.cell_h, color_u32(cursor_col), 0)
					if t.cursor_len > 0 {
						mi_draw_text_font_n(list, f.mono, f.mono_size, cx, cy, color_u32(th.term_bg), cstring(&t.cursor_text[0]), uint(t.cursor_len))
					}
				}
			}
		}
	}

	mi_clip_pop(list)

	// Empty-ish screens get a faint prompt so the panel never looks broken
	// before the shell has printed anything.
	if !t.alive {
		msg := fmt.tprintf("process exited (%d)", t.exit_code)
		mi_draw_text_font_n(list, f.mono, f.mono_size, inner.x, inner.y, color_u32(th.fg_faint), cstr(msg), uint(len(msg)))
	}
}

// Resolve $SHELL, falling back to /bin/sh.
default_shell :: proc(allocator := context.temp_allocator) -> string {
	if sh := os.get_env("SHELL", allocator); len(sh) > 0 do return sh
	return "/bin/sh"
}


