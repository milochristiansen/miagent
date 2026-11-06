// A terminal drawer: a PTY running the user's shell, a libghostty-vt terminal
// for state, and an ImGui draw-list renderer for the cell grid.
package main

import "core:fmt"
import "core:math"
import "core:mem"
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

	cell_w_px: u32,
	cell_h_px: u32,
	def_fg: GhosttyColorRgb,
	def_bg: GhosttyColorRgb,
	def_cursor: GhosttyColorRgb,
	def_palette: [256]GhosttyColorRgb,
	def_cursor_style: i32,
	def_cursor_blink: bool,
	compress_activity: u64,
	compress_seen: bool,
	compress_next_at: f32,

	// Effect callbacks run synchronously inside libghostty, so they only set
	// these flags / copy data. The frame loop applies them afterwards.
	meta_dirty:       bool,
	bell_pending:     u32,
	clip_pending:     string,
	clip_allocator:   mem.Allocator,
	clip_pending_set: bool,
	clip_pending_clear: bool,
	pending_paste:    string,
	paste_prompt:     bool,
	hover_cell:       Terminal_Cell,
	hover_cell_valid: bool,
	hover_link_uri:   string,
	hover_link_valid: bool,
	hover_link_epoch: int,
	hover_link_cell:  Terminal_Cell,
	link_epoch:       int,
	render_rows:      [dynamic]Terminal_Row_Cache,
	render_cols:      u16,
	render_nrows:     u16,
	render_valid:     bool,
	render_invalid:   bool,
	key_down:         [1024]bool,
	has_focus:        bool,
	focus_mode_was:   bool,
	focus_reported:   bool,
	scheme_report_sent: bool,
	color_scheme:     i32,
	vt_error:         bool,
	vt_error_logged:  bool,

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

	gesture:            GhosttySelectionGesture,
	gesture_press:      GhosttySelectionGestureEvent,
	gesture_release:    GhosttySelectionGestureEvent,
	gesture_drag:       GhosttySelectionGestureEvent,
	gesture_autoscroll: GhosttySelectionGestureEvent,
	sel_last_tick:      f32,

	// Mouse reporting state. `mouse_grab` means a press was delivered to the
	// application, so motion/release must keep going to it even when the
	// pointer leaves the terminal body. `mouse_cell` deduplicates motion to
	// one report per cell.
	mouse_grab:      bool,
	mouse_cell:      Terminal_Cell,
	mouse_have_cell: bool,
}

IMGUI_INPUT_EVENT_KEY :: 4
IMGUI_INPUT_EVENT_TEXT :: 5
IMGUI_INPUT_EVENT_FOCUS :: 6

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

terminal_state_init :: proc(t: ^Terminal, th: Theme, cols, rows: u16, cell_w, cell_h: f32) -> Terminal_Result {
	t.clip_allocator = context.allocator
	t.fd = -1
	t.pid = -1
	t.cols = cols > 0 ? cols : 80
	t.nrows = rows > 0 ? rows : 24
	t.cell_w_px = u32(max(cell_w, 1))
	t.cell_h_px = u32(max(cell_h, 1))

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
	t.def_fg = fg
	t.def_bg = bg
	t.def_cursor = cur
	t.def_palette = palette
	t.def_cursor_style = th.cursor_style
	t.def_cursor_blink = th.cursor_blink
	style := th.cursor_style
	ghostty_terminal_set(t.gt, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE, &style)
	blink := th.cursor_blink
	ghostty_terminal_set(t.gt, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, &blink)

	if ghostty_render_state_new(nil, &t.rs) != GHOSTTY_SUCCESS do return .Ghostty_Failed
	if ghostty_render_state_row_iterator_new(nil, &t.row_iter) != GHOSTTY_SUCCESS do return .Ghostty_Failed
	if ghostty_render_state_row_cells_new(nil, &t.row_cells) != GHOSTTY_SUCCESS do return .Ghostty_Failed

	if ghostty_key_encoder_new(nil, &t.enc) != GHOSTTY_SUCCESS do return .Ghostty_Failed
	if ghostty_key_event_new(nil, &t.ev) != GHOSTTY_SUCCESS do return .Ghostty_Failed
	if ghostty_mouse_encoder_new(nil, &t.mouse_enc) != GHOSTTY_SUCCESS do return .Ghostty_Failed
	if ghostty_mouse_event_new(nil, &t.mouse_ev) != GHOSTTY_SUCCESS do return .Ghostty_Failed
	if !terminal_selection_init(t) do return .Ghostty_Failed
	alt_prefix := true
	ghostty_key_encoder_setopt(t.enc, GHOSTTY_KEY_ENCODER_OPT_ALT_ESC_PREFIX, &alt_prefix)

	// Color scheme is static for the lifetime of a terminal; the callback
	// reports it for CSI ?996n and mode 2031.
	bg_rgb := GhosttyColorRgb{u8(th.term_bg[0] * 255), u8(th.term_bg[1] * 255), u8(th.term_bg[2] * 255)}
	t.color_scheme = ghostty_color_luminance(&bg_rgb) < 0.5 ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT

	if !terminal_install_effects(t) do return .Ghostty_Failed
	return .Ok
}

terminal_spawn_shell :: proc(t: ^Terminal, shell, cwd: string) -> Terminal_Result {
	t.shell = strings.clone(shell, context.allocator)
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

terminal_init :: proc(t: ^Terminal, shell: string, cwd: string, th: Theme, cols, rows: u16,
                      cell_w, cell_h: f32) -> Terminal_Result {
	if res := terminal_state_init(t, th, cols, rows, cell_w, cell_h); res != .Ok {
		return res
	}
	return terminal_spawn_shell(t, shell, cwd)
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
	terminal_selection_destroy(t)
	if t.mouse_enc != nil do ghostty_mouse_encoder_free(t.mouse_enc)
	if t.mouse_ev != nil do ghostty_mouse_event_free(t.mouse_ev)
	if t.gt != nil do ghostty_terminal_free(t.gt)
	delete(t.title)
	delete(t.cwd)
	delete(t.shell)
	delete(t.clip_pending, t.clip_allocator)
	delete(t.pending_paste)
	delete(t.hover_link_uri)
	for &row in t.render_rows do delete(row.cells)
	delete(t.render_rows)
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
	if t.dirty || t.meta_dirty {
		terminal_refresh_meta(t)
	}
	terminal_apply_pending_effects(t)
	terminal_maybe_report_color_scheme(t)
	terminal_poll_diagnostics(t)
}

// render_state_bool reads a boolean render-state field, treating a failed
// query the same as a false value.
render_state_bool :: proc(state: GhosttyRenderState, data: i32) -> bool {
	value := false
	return ghostty_render_state_get(state, data, &value) == GHOSTTY_SUCCESS && value
}

terminal_refresh_meta :: proc(t: ^Terminal) {
	s: GhosttyString
	if ghostty_terminal_get(t.gt, GHOSTTY_TERMINAL_DATA_TITLE, &s) == GHOSTTY_SUCCESS {
		val := s.len > 0 ? string(s.ptr[:s.len]) : ""
		delete(t.title)
		t.title = strings.clone(val, context.allocator)
	}
	if ghostty_terminal_get(t.gt, GHOSTTY_TERMINAL_DATA_PWD, &s) == GHOSTTY_SUCCESS {
		val := s.len > 0 ? string(s.ptr[:s.len]) : ""
		delete(t.cwd)
		t.cwd = strings.clone(val, context.allocator)
	}
	t.meta_dirty = false
}

terminal_resize :: proc(t: ^Terminal, cols, rows: u16, cell_w, cell_h: f32) {
	if cols == 0 || rows == 0 do return
	cw := u32(max(cell_w, 1))
	ch := u32(max(cell_h, 1))
	if cols == t.cols && rows == t.nrows && cw == t.cell_w_px && ch == t.cell_h_px do return
	ghostty_terminal_resize(t.gt, cols, rows, cw, ch)
	if t.fd >= 0 do mi_pty_resize(t.fd, cols, rows)
	t.cols = cols
	t.nrows = rows
	t.cell_w_px = cw
	t.cell_h_px = ch
	t.dirty = true
	t.link_epoch += 1
	t.render_invalid = true
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
	{ImGuiKey(512), GHOSTTY_KEY_TAB},
	{ImGuiKey(513), GHOSTTY_KEY_ARROW_LEFT},
	{ImGuiKey(514), GHOSTTY_KEY_ARROW_RIGHT},
	{ImGuiKey(515), GHOSTTY_KEY_ARROW_UP},
	{ImGuiKey(516), GHOSTTY_KEY_ARROW_DOWN},
	{ImGuiKey(517), GHOSTTY_KEY_PAGE_UP},
	{ImGuiKey(518), GHOSTTY_KEY_PAGE_DOWN},
	{ImGuiKey(519), GHOSTTY_KEY_HOME},
	{ImGuiKey(520), GHOSTTY_KEY_END},
	{ImGuiKey(521), GHOSTTY_KEY_INSERT},
	{ImGuiKey(522), GHOSTTY_KEY_DELETE},
	{ImGuiKey(523), GHOSTTY_KEY_BACKSPACE},
	{ImGuiKey(524), GHOSTTY_KEY_SPACE},
	{ImGuiKey(525), GHOSTTY_KEY_ENTER},
	{ImGuiKey(526), GHOSTTY_KEY_ESCAPE},
	{ImGuiKey(527), GHOSTTY_KEY_CONTROL_LEFT},
	{ImGuiKey(528), GHOSTTY_KEY_SHIFT_LEFT},
	{ImGuiKey(529), GHOSTTY_KEY_ALT_LEFT},
	{ImGuiKey(530), GHOSTTY_KEY_META_LEFT},
	{ImGuiKey(531), GHOSTTY_KEY_CONTROL_RIGHT},
	{ImGuiKey(532), GHOSTTY_KEY_SHIFT_RIGHT},
	{ImGuiKey(533), GHOSTTY_KEY_ALT_RIGHT},
	{ImGuiKey(534), GHOSTTY_KEY_META_RIGHT},
	{ImGuiKey(535), GHOSTTY_KEY_CONTEXT_MENU},
	{ImGuiKey(596), GHOSTTY_KEY_QUOTE},
	{ImGuiKey(597), GHOSTTY_KEY_COMMA},
	{ImGuiKey(598), GHOSTTY_KEY_MINUS},
	{ImGuiKey(599), GHOSTTY_KEY_PERIOD},
	{ImGuiKey(600), GHOSTTY_KEY_SLASH},
	{ImGuiKey(601), GHOSTTY_KEY_SEMICOLON},
	{ImGuiKey(602), GHOSTTY_KEY_EQUAL},
	{ImGuiKey(603), GHOSTTY_KEY_BRACKET_LEFT},
	{ImGuiKey(604), GHOSTTY_KEY_BACKSLASH},
	{ImGuiKey(605), GHOSTTY_KEY_BRACKET_RIGHT},
	{ImGuiKey(606), GHOSTTY_KEY_BACKQUOTE},
	{ImGuiKey(607), GHOSTTY_KEY_CAPS_LOCK},
	{ImGuiKey(608), GHOSTTY_KEY_SCROLL_LOCK},
	{ImGuiKey(609), GHOSTTY_KEY_NUM_LOCK},
	{ImGuiKey(610), GHOSTTY_KEY_PRINT_SCREEN},
	{ImGuiKey(611), GHOSTTY_KEY_PAUSE},
	{ImGuiKey(612), GHOSTTY_KEY_NUMPAD_0},
	{ImGuiKey(613), GHOSTTY_KEY_NUMPAD_1},
	{ImGuiKey(614), GHOSTTY_KEY_NUMPAD_2},
	{ImGuiKey(615), GHOSTTY_KEY_NUMPAD_3},
	{ImGuiKey(616), GHOSTTY_KEY_NUMPAD_4},
	{ImGuiKey(617), GHOSTTY_KEY_NUMPAD_5},
	{ImGuiKey(618), GHOSTTY_KEY_NUMPAD_6},
	{ImGuiKey(619), GHOSTTY_KEY_NUMPAD_7},
	{ImGuiKey(620), GHOSTTY_KEY_NUMPAD_8},
	{ImGuiKey(621), GHOSTTY_KEY_NUMPAD_9},
	{ImGuiKey(622), GHOSTTY_KEY_NUMPAD_DECIMAL},
	{ImGuiKey(623), GHOSTTY_KEY_NUMPAD_DIVIDE},
	{ImGuiKey(624), GHOSTTY_KEY_NUMPAD_MULTIPLY},
	{ImGuiKey(625), GHOSTTY_KEY_NUMPAD_SUBTRACT},
	{ImGuiKey(626), GHOSTTY_KEY_NUMPAD_ADD},
	{ImGuiKey(627), GHOSTTY_KEY_NUMPAD_ENTER},
	{ImGuiKey(628), GHOSTTY_KEY_NUMPAD_EQUAL},
	{ImGuiKey(629), GHOSTTY_KEY_BROWSER_BACK},
	{ImGuiKey(630), GHOSTTY_KEY_BROWSER_FORWARD},
	{ImGuiKey(631), GHOSTTY_KEY_INTL_BACKSLASH},
}

// Punctuation keys, for Ctrl+<key> combinations.
PUNCT_BINDINGS := [?]Key_Binding {
	{ImGuiKey(596), GHOSTTY_KEY_QUOTE},
	{ImGuiKey(597), GHOSTTY_KEY_COMMA},
	{ImGuiKey(598), GHOSTTY_KEY_MINUS},
	{ImGuiKey(599), GHOSTTY_KEY_PERIOD},
	{ImGuiKey(600), GHOSTTY_KEY_SLASH},
	{ImGuiKey(601), GHOSTTY_KEY_SEMICOLON},
	{ImGuiKey(602), GHOSTTY_KEY_EQUAL},
	{ImGuiKey(603), GHOSTTY_KEY_BRACKET_LEFT},
	{ImGuiKey(604), GHOSTTY_KEY_BACKSLASH},
	{ImGuiKey(605), GHOSTTY_KEY_BRACKET_RIGHT},
	{ImGuiKey(606), GHOSTTY_KEY_BACKQUOTE},
}

// Returns (ghostty_key, is_text_key).
imgui_key_to_ghostty :: proc(key: ImGuiKey) -> (i32, bool) {
	v := i32(key)
	if v >= 546 && v <= 571 do return GHOSTTY_KEY_A + (v - 546), true
	if v >= 536 && v <= 545 do return GHOSTTY_KEY_DIGIT_0 + (v - 536), true
	if v >= 572 && v <= 595 do return GHOSTTY_KEY_F1 + (v - 572), false
	for b in PUNCT_BINDINGS {
		if b.imgui == key do return b.ghostty, true
	}
	for b in KEY_BINDINGS {
		if b.imgui == key do return b.ghostty, false
	}
	return GHOSTTY_KEY_UNIDENTIFIED, false
}

terminal_unshifted_codepoint :: proc(gkey: i32) -> u32 {
	switch {
	case gkey >= GHOSTTY_KEY_A && gkey <= GHOSTTY_KEY_Z:
		return u32('a' + (gkey - GHOSTTY_KEY_A))
	case gkey >= GHOSTTY_KEY_DIGIT_0 && gkey <= GHOSTTY_KEY_DIGIT_9:
		return u32('0' + (gkey - GHOSTTY_KEY_DIGIT_0))
	case gkey == GHOSTTY_KEY_SPACE: return u32(' ')
	case gkey == GHOSTTY_KEY_MINUS: return u32('-')
	case gkey == GHOSTTY_KEY_EQUAL: return u32('=')
	case gkey == GHOSTTY_KEY_BRACKET_LEFT: return u32('[')
	case gkey == GHOSTTY_KEY_BRACKET_RIGHT: return u32(']')
	case gkey == GHOSTTY_KEY_BACKSLASH: return u32('\\')
	case gkey == GHOSTTY_KEY_SEMICOLON: return u32(';')
	case gkey == GHOSTTY_KEY_QUOTE: return u32('\'')
	case gkey == GHOSTTY_KEY_COMMA: return u32(',')
	case gkey == GHOSTTY_KEY_PERIOD: return u32('.')
	case gkey == GHOSTTY_KEY_SLASH: return u32('/')
	case gkey == GHOSTTY_KEY_BACKQUOTE: return u32('`')
	}
	return 0
}

// --- selection and clipboard
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

	if !bracketed && !ghostty_paste_is_safe(raw_data(s), uint(len(s))) {
		delete(t.pending_paste)
		t.pending_paste = strings.clone(s)
		t.paste_prompt = true
		return
	}
	terminal_paste_text(t, s, bracketed)
}

terminal_confirm_paste :: proc(t: ^Terminal) {
	if len(t.pending_paste) == 0 {
		t.paste_prompt = false
		return
	}
	terminal_paste_text(t, t.pending_paste, false)
	delete(t.pending_paste)
	t.pending_paste = ""
	t.paste_prompt = false
}

terminal_cancel_paste :: proc(t: ^Terminal) {
	delete(t.pending_paste)
	t.pending_paste = ""
	t.paste_prompt = false
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

	// Terminal clipboard/selection shortcuts. These must run before the
	// generic encoder path so Ctrl+Shift+C never reaches the shell as Ctrl+C.
	if ctrl && shift {
		if igIsKeyPressed_Bool(KEY_C, false) {
			terminal_copy(t)
			return
		}
		if igIsKeyPressed_Bool(KEY_V, false) {
			terminal_paste(t)
			return
		}
		if igIsKeyPressed_Bool(KEY_A, false) {
			terminal_select_all(t)
			return
		}
		if igIsKeyPressed_Bool(ImGuiKey(546 + 14), false) { // O
			if t.hover_cell_valid do terminal_select_output(t, t.hover_cell)
			return
		}
		if igIsKeyPressed_Bool(KEY_LEFT, false) { terminal_selection_adjust(t, GHOSTTY_SELECTION_ADJUST_LEFT); return }
		if igIsKeyPressed_Bool(KEY_RIGHT, false) { terminal_selection_adjust(t, GHOSTTY_SELECTION_ADJUST_RIGHT); return }
		if igIsKeyPressed_Bool(KEY_UP, false) { terminal_selection_adjust(t, GHOSTTY_SELECTION_ADJUST_UP); return }
		if igIsKeyPressed_Bool(KEY_DOWN, false) { terminal_selection_adjust(t, GHOSTTY_SELECTION_ADJUST_DOWN); return }
		if igIsKeyPressed_Bool(KEY_HOME, false) { terminal_selection_adjust(t, GHOSTTY_SELECTION_ADJUST_BEGINNING_OF_LINE); return }
		if igIsKeyPressed_Bool(KEY_END, false) { terminal_selection_adjust(t, GHOSTTY_SELECTION_ADJUST_END_OF_LINE); return }
		if igIsKeyPressed_Bool(KEY_PAGE_UP, false) { terminal_selection_adjust(t, GHOSTTY_SELECTION_ADJUST_PAGE_UP); return }
		if igIsKeyPressed_Bool(KEY_PAGE_DOWN, false) { terminal_selection_adjust(t, GHOSTTY_SELECTION_ADJUST_PAGE_DOWN); return }
	}

	mods: u16
	if ctrl do mods |= GHOSTTY_MODS_CTRL
	if shift do mods |= GHOSTTY_MODS_SHIFT
	if alt do mods |= GHOSTTY_MODS_ALT
	if super do mods |= GHOSTTY_MODS_SUPER

	count := mi_io_input_event_count()
	if count <= 0 do return

	i: i32 = 0
	for i < count {
		e: Mi_Input_Event
		if !mi_io_input_event_get(i, &e) do break

		if e.type == IMGUI_INPUT_EVENT_KEY {
			key := ImGuiKey(e.key)
			// Gather text events immediately following this key.
			text_buf: [128]u8
			text_len := 0
			j := i + 1
			for j < count {
				tx: Mi_Input_Event
				if !mi_io_input_event_get(j, &tx) do break
				if tx.type != IMGUI_INPUT_EVENT_TEXT do break
				cp := rune(tx.ch)
				if cp != 0 && text_len + 4 <= len(text_buf) {
					text_len += utf8_encode(cp, text_buf[text_len:])
				}
				j += 1
			}

			action: i32 = GHOSTTY_KEY_ACTION_RELEASE
			if e.down != 0 {
				action = int(key) < len(t.key_down) && t.key_down[int(key)] ? GHOSTTY_KEY_ACTION_REPEAT : GHOSTTY_KEY_ACTION_PRESS
				if int(key) < len(t.key_down) do t.key_down[int(key)] = true
			} else {
				if int(key) < len(t.key_down) do t.key_down[int(key)] = false
			}

			gkey, _ := imgui_key_to_ghostty(key)
			if gkey != GHOSTTY_KEY_UNIDENTIFIED && !super {
				text := action == GHOSTTY_KEY_ACTION_RELEASE ? "" : string(text_buf[:text_len])
				unshifted := terminal_unshifted_codepoint(gkey)
				consumed: u16
				if len(text) > 0 && shift do consumed |= GHOSTTY_MODS_SHIFT
				terminal_emit_key(t, action, gkey, mods, text, unshifted, consumed)
			}
			i = j
			continue
		}

		if e.type == IMGUI_INPUT_EVENT_TEXT {
			// IME or other text not attached to a key event.
			cp := rune(e.ch)
			if cp != 0 && !super {
				out: [8]u8
				n := utf8_encode(cp, out[:])
				if n > 0 do terminal_write(t, out[:n])
			}
		}

		i += 1
	}
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

// terminal_encode_key writes one key event through libghostty's encoder. It
// also keeps the encoder's terminal-derived options current.
terminal_emit_key :: proc(t: ^Terminal, action, gkey: i32, mods: u16,
                         text: string, unshifted: u32, consumed: u16) {
	if t.enc == nil || t.ev == nil do return
	ghostty_key_encoder_setopt_from_terminal(t.enc, t.gt)
	ghostty_key_event_set_action(t.ev, action)
	ghostty_key_event_set_key(t.ev, gkey)
	ghostty_key_event_set_mods(t.ev, mods)
	ghostty_key_event_set_consumed_mods(t.ev, consumed)
	ghostty_key_event_set_unshifted_codepoint(t.ev, unshifted)
	ghostty_key_event_set_composing(t.ev, false)
	if len(text) > 0 {
		ghostty_key_event_set_utf8(t.ev, cstring(raw_data(text)), uint(len(text)))
	} else {
		ghostty_key_event_set_utf8(t.ev, nil, 0)
	}
	buf: [256]u8
	n: uint
	if ghostty_key_encoder_encode(t.enc, t.ev, &buf[0], len(buf), &n) == GHOSTTY_SUCCESS && n > 0 {
		terminal_write(t, buf[:n])
	}
}

terminal_encode_key :: proc(t: ^Terminal, action, gkey: i32, mods: u16) {
	if t.enc == nil || t.ev == nil do return
	ghostty_key_encoder_setopt_from_terminal(t.enc, t.gt)
	ghostty_key_event_set_action(t.ev, action)
	ghostty_key_event_set_key(t.ev, gkey)
	ghostty_key_event_set_mods(t.ev, mods)
	ghostty_key_event_set_consumed_mods(t.ev, 0)
	ghostty_key_event_set_unshifted_codepoint(t.ev, 0)
	ghostty_key_event_set_composing(t.ev, false)
	ghostty_key_event_set_utf8(t.ev, nil, 0)
	buf: [128]u8
	n: uint
	if ghostty_key_encoder_encode(t.enc, t.ev, &buf[0], len(buf), &n) == GHOSTTY_SUCCESS && n > 0 {
		terminal_write(t, buf[:n])
	}
}

terminal_update_focus :: proc(t: ^Terminal, focused: bool) {
	if t == nil || t.gt == nil do return
	if !focused {
		for i in 0 ..< len(t.key_down) do t.key_down[i] = false
	}
	t.has_focus = focused
	enabled := false
	if ghostty_terminal_mode_get(t.gt, GHOSTTY_MODE_FOCUS_EVENT, &enabled) != GHOSTTY_SUCCESS do return
	if !enabled {
		t.focus_mode_was = false
		t.focus_reported = false
		return
	}
	if !t.focus_mode_was {
		t.focus_mode_was = true
		t.focus_reported = false
	}
	if focused == t.focus_reported do return
	buf: [8]u8
	n: uint
	event: i32 = focused ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST
	if ghostty_focus_encode(event, &buf[0], len(buf), &n) == GHOSTTY_SUCCESS && n > 0 {
		terminal_write(t, buf[:n])
	}
	t.focus_reported = focused
}

// Alternate-screen applications without mouse reporting expect the wheel to
// become cursor keys when mode 1007 is enabled.
terminal_wheel :: proc(t: ^Terminal, lines: i32) {
	if lines == 0 do return
	screen: i32 = GHOSTTY_TERMINAL_SCREEN_PRIMARY
	_ = ghostty_terminal_get(t.gt, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
	alt_scroll := false
	_ = ghostty_terminal_mode_get(t.gt, GHOSTTY_MODE_ALT_SCROLL, &alt_scroll)
	if screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE && alt_scroll {
		key: i32 = lines < 0 ? GHOSTTY_KEY_ARROW_UP : GHOSTTY_KEY_ARROW_DOWN
		steps := min(abs(lines), 20)
		for _ in 0 ..< steps do terminal_encode_key(t, GHOSTTY_KEY_ACTION_PRESS, key, 0)
		return
	}
	terminal_scroll(t, lines)
}

terminal_paste_text :: proc(t: ^Terminal, s: string, bracketed: bool) {
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

terminal_scroll_row :: proc(t: ^Terminal, row: u64) {
	v: GhosttyScrollViewportValue
	v.row = row
	b := GhosttyScrollViewport {
		tag   = .ROW,
		value = v,
	}
	ghostty_terminal_scroll_viewport(t.gt, b)
	t.dirty = true
	t.link_epoch += 1
	t.render_invalid = true
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
	t.link_epoch += 1
	t.render_invalid = true
}


// --- rendering -------------------------------------------------------------

// A resolved cell snapshot. Selection is applied at draw time from the live
// row selection range so moving a selection does not force a cache rebuild.
Terminal_Cell_Visual :: struct {
	text:               [64]u8,
	text_len:           int,
	fg, bg:             Color,
	underline_color:    Color,
	underline_color_set: bool,
	bold:               bool,
	italic:             bool,
	faint:              bool,
	blink:              bool,
	inverse:            bool,
	invisible:          bool,
	strikethrough:      bool,
	overline:           bool,
	underline:          i32,
}

Terminal_Row_Cache :: struct {
	cells: [dynamic]Terminal_Cell_Visual,
	valid: bool,
}

Fonts :: struct {
	ui:               ^ImFont,
	mono:             ^ImFont,
	mono_bold:        ^ImFont,
	mono_italic:      ^ImFont,
	mono_bold_italic: ^ImFont,
	ui_size:          f32,
	mono_size:        f32,
	cell_w:           f32,
	cell_h:           f32,
}

style_color :: proc(c: GhosttyStyleColor, palette: ^[256]GhosttyColorRgb, fallback: Color) -> Color {
	switch c.tag {
	case .NONE:
		return fallback
	case .PALETTE:
		return color_from_ghostty(palette[c.value.palette])
	case .RGB:
		return color_from_ghostty(c.value.rgb)
	}
	return fallback
}

terminal_draw :: proc(t: ^Terminal, list: ^ImDrawList, area: Rect, th: Theme, f: Fonts, focused: bool, now: f32) {
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
	palette: [256]GhosttyColorRgb
	ghostty_color_palette_default(&palette)
	_ = ghostty_render_state_get(t.rs, GHOSTTY_RENDER_STATE_DATA_COLOR_PALETTE, &palette)

	have_cursor := render_state_bool(t.rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE) &&
	               render_state_bool(t.rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE)
	cursor_x: u16 = 0
	cursor_y: u16 = 0
	cursor_style: i32 = GHOSTTY_CURSOR_BLOCK
	cursor_blinking := render_state_bool(t.rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING)
	cursor_wide_tail := false
	cursor_password := false
	if have_cursor {
		_ = ghostty_render_state_get(t.rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &cursor_x)
		_ = ghostty_render_state_get(t.rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &cursor_y)
		_ = ghostty_render_state_get(t.rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &cursor_style)
		cursor_wide_tail = render_state_bool(t.rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_WIDE_TAIL)
		cursor_password = render_state_bool(t.rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_PASSWORD_INPUT)
	}
	cursor_head := u16(cursor_wide_tail && cursor_x > 0 ? cursor_x - 1 : cursor_x)
	t.cursor_len = 0

	// Ensure the row cache has the current viewport shape.
	if len(t.render_rows) != int(rows) {
		for &row in t.render_rows do delete(row.cells)
		delete(t.render_rows)
		t.render_rows = make([dynamic]Terminal_Row_Cache, int(rows))
		t.render_valid = false
	}
	for &row in t.render_rows {
		if len(row.cells) != int(cols) {
			old := len(row.cells)
			resize(&row.cells, int(cols))
			if int(cols) > old {
				for i in old ..< int(cols) do row.cells[i] = {}
			}
			row.valid = false
		}
	}

	dirty: i32 = GHOSTTY_RENDER_STATE_DIRTY_FULL
	_ = ghostty_render_state_get(t.rs, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)
	full := !t.render_valid || t.render_invalid || t.render_cols != cols || t.render_nrows != rows ||
	        dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL

	mi_clip_push(list, inner.x, inner.y, inner.x + inner.w, inner.y + inner.h)

	if ghostty_render_state_get(t.rs, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &t.row_iter) == GHOSTTY_SUCCESS {
		y := inner.y
		row_y := 0
		for ghostty_render_state_row_iterator_next(t.row_iter) {
			if row_y >= int(rows) do break
			row_cache := &t.render_rows[row_y]
			row_dirty := true
			if !full {
				d := false
				if ghostty_render_state_row_get(t.row_iter, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &d) == GHOSTTY_SUCCESS {
					row_dirty = d
				}
			}

			if full || row_dirty || !row_cache.valid {
				if ghostty_render_state_row_get(t.row_iter, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &t.row_cells) == GHOSTTY_SUCCESS {
					col := 0
					for ghostty_render_state_row_cells_next(t.row_cells) {
						if col >= int(cols) do break
						vis := Terminal_Cell_Visual{}
						gb := GhosttyBuffer {
							ptr = &vis.text[0],
							cap = len(vis.text),
						}
						if ghostty_render_state_row_cells_get(t.row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &gb) == GHOSTTY_SUCCESS {
							vis.text_len = int(gb.len)
						}

						vis.fg = def_fg
						if ghostty_render_state_row_cells_get(t.row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &rgb_buf) == GHOSTTY_SUCCESS {
							vis.fg = color_from_ghostty(rgb_buf)
						}
						vis.bg = def_bg
						if ghostty_render_state_row_cells_get(t.row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &rgb_buf) == GHOSTTY_SUCCESS {
							vis.bg = color_from_ghostty(rgb_buf)
						}

						style := GhosttyStyle {
							size = size_of(GhosttyStyle),
						}
						_ = ghostty_render_state_row_cells_get(t.row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)
						vis.bold = style.bold
						vis.italic = style.italic
						vis.faint = style.faint
						vis.blink = style.blink
						vis.inverse = style.inverse
						vis.invisible = style.invisible
						vis.strikethrough = style.strikethrough
						vis.overline = style.overline
						vis.underline = style.underline
						if style.underline_color.tag != .NONE {
							vis.underline_color = style_color(style.underline_color, &palette, vis.fg)
							vis.underline_color_set = true
						}

						row_cache.cells[col] = vis
						col += 1
					}
					for ; col < int(cols); col += 1 do row_cache.cells[col] = {}
					row_cache.valid = true
				}
			}

			row_sel: GhosttyRenderStateRowSelection
			row_sel.size = size_of(GhosttyRenderStateRowSelection)
			has_row_sel := ghostty_render_state_row_get(t.row_iter, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &row_sel) == GHOSTTY_SUCCESS

			if row_cache.valid {
				x := inner.x
				col: u16 = 0
				for &vis in row_cache.cells {
					fgc := vis.fg
					bgc := vis.bg
					if vis.inverse do fgc, bgc = bgc, fgc
					if vis.faint do fgc = mix(fgc, bgc, 0.45)
					if has_row_sel && col >= row_sel.start_x && col <= row_sel.end_x {
						fgc = th.sel_fg
						bgc = th.sel_bg
					}

					if !color_eq(bgc, def_bg) {
						mi_draw_rect(list, x, y, x + f.cell_w, y + f.cell_h, color_u32(bgc), 0)
					}

					blink_on := !vis.blink || int(now * 2.0) % 2 == 0
					if vis.text_len > 0 && !vis.invisible && blink_on {
						font := f.mono
						if vis.bold && vis.italic && f.mono_bold_italic != nil {
							font = f.mono_bold_italic
						} else if vis.bold && f.mono_bold != nil {
							font = f.mono_bold
						} else if vis.italic && f.mono_italic != nil {
							font = f.mono_italic
						}
						mi_draw_text_font_n(list, font, f.mono_size, x, y, color_u32(fgc), cstring(&vis.text[0]), uint(vis.text_len))
					}

					if blink_on {
						ucol := vis.underline_color_set ? vis.underline_color : fgc
						switch vis.underline {
						case GHOSTTY_SGR_UNDERLINE_DOUBLE:
							mi_draw_line(list, x, y + f.cell_h - 1.5, x + f.cell_w, y + f.cell_h - 1.5, color_u32(ucol), 1)
							mi_draw_line(list, x, y + f.cell_h - 3.5, x + f.cell_w, y + f.cell_h - 3.5, color_u32(ucol), 1)
						case GHOSTTY_SGR_UNDERLINE_CURLY:
							y0 := y + f.cell_h - 2.0
							step := f.cell_w / 4.0
							for i in 0 ..< 4 {
								ax := x + step * f32(i)
								bx := ax + step
								ay := y0 + (i % 2 == 0 ? -1.0 : 1.0)
								by := y0 + (i % 2 == 0 ? 1.0 : -1.0)
								mi_draw_line(list, ax, ay, bx, by, color_u32(ucol), 1)
							}
						case GHOSTTY_SGR_UNDERLINE_DOTTED:
							yy := y + f.cell_h - 2.0
							xx := x
							for xx < x + f.cell_w {
								mi_draw_rect(list, xx, yy, min(xx + 1.5, x + f.cell_w), yy + 1.5, color_u32(ucol), 0)
								xx += 3.0
							}
						case GHOSTTY_SGR_UNDERLINE_DASHED:
							yy := y + f.cell_h - 2.0
							xx := x
							for xx < x + f.cell_w {
								mi_draw_line(list, xx, yy, min(xx + 3.0, x + f.cell_w), yy, color_u32(ucol), 1)
								xx += 5.0
							}
						case GHOSTTY_SGR_UNDERLINE_SINGLE:
							mi_draw_line(list, x, y + f.cell_h - 1.5, x + f.cell_w, y + f.cell_h - 1.5, color_u32(ucol), 1)
						}
						if vis.strikethrough {
							mi_draw_line(list, x, y + f.cell_h * 0.55, x + f.cell_w, y + f.cell_h * 0.55, color_u32(fgc), 1)
						}
						if vis.overline {
							mi_draw_line(list, x, y + 0.5, x + f.cell_w, y + 0.5, color_u32(fgc), 1)
						}
					}

					if have_cursor && row_y == int(cursor_y) && col == cursor_head {
						if vis.text_len > 0 && vis.text_len <= len(t.cursor_text) {
							copy(t.cursor_text[:], vis.text[:vis.text_len])
							t.cursor_len = vis.text_len
						}
					}

					x += f.cell_w
					col += 1
				}
			}

			row_dirty_false := false
			_ = ghostty_render_state_row_set(t.row_iter, GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &row_dirty_false)
			y += f.cell_h
			row_y += 1
		}

		dirty_false: i32 = GHOSTTY_RENDER_STATE_DIRTY_FALSE
		_ = ghostty_render_state_set(t.rs, GHOSTTY_RENDER_STATE_OPTION_DIRTY, &dirty_false)
		t.render_valid = true
		t.render_invalid = false
		t.render_cols = cols
		t.render_nrows = rows
	}

	mi_clip_pop(list)

	// Cursor is independent of cell dirty state.
	if have_cursor {
		blink_on := !cursor_blinking || int(now * 1.8) % 2 == 0
		if blink_on {
			cw := cursor_wide_tail ? f.cell_w * 2.0 : f.cell_w
			cx := inner.x + f32(cursor_head) * f.cell_w
			cy := inner.y + f32(cursor_y) * f.cell_h
			if cursor_password {
				mi_draw_rect_stroke(list, cx + 0.5, cy + 0.5, cx + cw - 0.5, cy + f.cell_h - 0.5, color_u32(cursor_col), 1, 1.5)
				glyph_lock(list, cx + cw * 0.5, cy + f.cell_h * 0.5, f.cell_h * 0.28, cursor_col)
			} else {
				switch cursor_style {
				case GHOSTTY_CURSOR_BAR:
					mi_draw_rect(list, cx, cy, cx + 2, cy + f.cell_h, color_u32(cursor_col), 0)
				case GHOSTTY_CURSOR_UNDERLINE:
					mi_draw_rect(list, cx, cy + f.cell_h - 2, cx + cw, cy + f.cell_h, color_u32(cursor_col), 0)
				case GHOSTTY_CURSOR_BLOCK_HOLLOW:
					mi_draw_rect_stroke(list, cx + 0.5, cy + 0.5, cx + cw - 0.5, cy + f.cell_h - 0.5, color_u32(cursor_col), 1, 1.5)
				case:
					if !focused {
						mi_draw_rect_stroke(list, cx + 0.5, cy + 0.5, cx + cw - 0.5, cy + f.cell_h - 0.5, color_u32(cursor_col), 1, 1.5)
					} else {
						mi_draw_rect(list, cx, cy, cx + cw, cy + f.cell_h, color_u32(cursor_col), 0)
						if t.cursor_len > 0 {
							mi_draw_text_font_n(list, f.mono, f.mono_size, cx, cy, color_u32(th.term_bg), cstring(&t.cursor_text[0]), uint(t.cursor_len))
						}
					}
				}
			}
		}
	}

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


