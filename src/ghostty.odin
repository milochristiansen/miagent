// Bindings for the slice of libghostty-vt (Ghostty's VT core) used by the
// terminal drawers: terminal state, render state, and key encoding.
package main

GhosttyTerminal :: distinct rawptr
GhosttyRenderState :: distinct rawptr
GhosttyRenderStateRowIterator :: distinct rawptr
GhosttyRenderStateRowCells :: distinct rawptr
GhosttyKeyEncoder :: distinct rawptr
GhosttyKeyEvent :: distinct rawptr
GhosttyMouseEncoder :: distinct rawptr
GhosttyMouseEvent :: distinct rawptr

GhosttyResult :: distinct i32
GHOSTTY_SUCCESS :: GhosttyResult(0)
GHOSTTY_OUT_OF_SPACE :: GhosttyResult(-3)
GHOSTTY_NO_VALUE :: GhosttyResult(-4)

GhosttyColorRgb :: struct {
	r, g, b: u8,
}

// Mouse position in surface-space pixels. libghostty converts this to a cell
// using the encoder's screen/cell/padding size context.
GhosttyMousePosition :: struct {
	x, y: f32,
}

// Renderer geometry used by the mouse encoder. Must be initialized with
// `size` before being passed with GHOSTTY_MOUSE_ENCODER_OPT_SIZE.
GhosttyMouseEncoderSize :: struct {
	size:          uint,
	screen_width:  u32,
	screen_height: u32,
	cell_width:    u32,
	cell_height:   u32,
	padding_top:   u32,
	padding_bottom: u32,
	padding_right: u32,
	padding_left:  u32,
}

// Ghostty 1.3.2-dev's terminal constructor takes this by value. The C struct
// is { uint16_t cols; uint16_t rows; size_t max_scrollback; }.
GhosttyTerminalOptions :: struct {
	cols:           u16,
	rows:           u16,
	max_scrollback: uint,
}

GhosttyTerminalScrollbar :: struct {
	total, offset, len: u64,
}

// A resolved cell position snapshot. Must be initialized with `size` before
// passing it to the grid-ref APIs.
GhosttyGridRef :: struct {
	size: uint,
	node: rawptr,
	x:    u16,
	y:    u16,
}

GhosttyPointCoordinate :: struct {
	x: u16,
	y: u32,
}

GhosttyPointValue :: struct #raw_union {
	coordinate: GhosttyPointCoordinate,
	_padding:    [2]u64,
}

GhosttyPointTag :: enum i32 {
	ACTIVE   = 0,
	VIEWPORT = 1,
	SCREEN   = 2,
	HISTORY  = 3,
}

GhosttyPoint :: struct {
	tag:   GhosttyPointTag,
	_pad:  i32,
	value: GhosttyPointValue,
}

// Selection snapshot. The terminal copies it (converting the endpoints to
// tracked references) when it is installed with GHOSTTY_TERMINAL_OPT_SELECTION.
GhosttySelection :: struct {
	size:      uint,
	start:     GhosttyGridRef,
	end:       GhosttyGridRef,
	rectangle: bool,
}

GhosttyRenderStateRowSelection :: struct {
	size:    uint,
	start_x: u16,
	end_x:   u16,
}

GhosttyTerminalSelectionFormatOptions :: struct {
	size:      uint,
	emit:      i32,
	unwrap:    bool,
	trim:      bool,
	_pad:      [2]u8,
	selection: ^GhosttySelection,
}

GhosttyBuffer :: struct {
	ptr: [^]u8,
	cap: uint,
	len: uint,
}

GhosttyString :: struct {
	ptr: [^]u8,
	len: uint,
}

GhosttyStyleColorTag :: enum i32 {
	NONE      = 0,
	PALETTE   = 1,
	RGB       = 2,
}

GhosttyStyleColorValue :: struct #raw_union {
	palette:  u8,
	rgb:      GhosttyColorRgb,
	_padding: u64,
}

GhosttyStyleColor :: struct {
	tag:   GhosttyStyleColorTag,
	value: GhosttyStyleColorValue,
}

// Sized struct: `size` must be set to size_of(GhosttyStyle).
GhosttyStyle :: struct {
	size:            uint,
	fg_color:        GhosttyStyleColor,
	bg_color:        GhosttyStyleColor,
	underline_color: GhosttyStyleColor,
	bold:            bool,
	italic:          bool,
	faint:           bool,
	blink:           bool,
	inverse:         bool,
	invisible:       bool,
	strikethrough:   bool,
	overline:        bool,
	underline:       i32,
}

GhosttyScrollViewportTag :: enum i32 {
	TOP          = 0,
	BOTTOM       = 1,
	DELTA        = 2,
	ROW          = 3,
	DELTA_PROMPT = 4,
}

// The C union is padded to 16 bytes (`uint64_t _padding[2]`) for ABI
// compatibility, so the whole tagged union is 24 bytes, not 16.
GhosttyScrollViewportValue :: struct #raw_union {
	delta:        int,
	row:          u64,
	delta_prompt: int,
	_padding:     [2]u64,
}

GhosttyScrollViewport :: struct {
	tag:   GhosttyScrollViewportTag,
	_pad:  i32,
	value: GhosttyScrollViewportValue,
}

// --- enums -----------------------------------------------------------------

GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND :: 11
GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND :: 12
GHOSTTY_TERMINAL_OPT_COLOR_CURSOR :: 13
GHOSTTY_TERMINAL_OPT_COLOR_PALETTE :: 14
GHOSTTY_TERMINAL_DATA_SCROLLBAR :: 9
GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING :: 11
GHOSTTY_TERMINAL_DATA_TITLE :: 12
GHOSTTY_TERMINAL_DATA_PWD :: 13
GHOSTTY_TERMINAL_DATA_SELECTION :: 31
GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE :: 32
GHOSTTY_TERMINAL_OPT_SELECTION :: 21

GHOSTTY_FORMATTER_FORMAT_PLAIN :: 0

GHOSTTY_RENDER_STATE_DATA_COLS :: 1
GHOSTTY_RENDER_STATE_DATA_ROWS :: 2
GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR :: 4
GHOSTTY_RENDER_STATE_DATA_COLOR_BACKGROUND :: 5
GHOSTTY_RENDER_STATE_DATA_COLOR_FOREGROUND :: 6
GHOSTTY_RENDER_STATE_DATA_COLOR_CURSOR :: 7
GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE :: 10
GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE :: 11
GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING :: 12
GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE :: 14
GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X :: 15
GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y :: 16

GHOSTTY_RENDER_STATE_ROW_DATA_CELLS :: 3
GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION :: 4

GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE :: 2
GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN :: 3
GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF :: 4
GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR :: 5
GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR :: 6
GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING :: 8
GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8 :: 9

GHOSTTY_CURSOR_BAR :: 0
GHOSTTY_CURSOR_BLOCK :: 1
GHOSTTY_CURSOR_UNDERLINE :: 2
GHOSTTY_CURSOR_BLOCK_HOLLOW :: 3

GHOSTTY_KEY_ACTION_RELEASE :: 0
GHOSTTY_KEY_ACTION_PRESS :: 1
GHOSTTY_KEY_ACTION_REPEAT :: 2

GHOSTTY_MODS_SHIFT :: u16(1 << 0)
GHOSTTY_MODS_CTRL :: u16(1 << 1)
GHOSTTY_MODS_ALT :: u16(1 << 2)
GHOSTTY_MODS_SUPER :: u16(1 << 3)

// Packed DEC mode 2004. Bits 0-14 are the mode number and bit 15 is the
// ANSI-mode flag, which is zero for DEC private modes.
GHOSTTY_MODE_BRACKETED_PASTE :: u16(2004)

GHOSTTY_KEY_ENCODER_OPT_ALT_ESC_PREFIX :: 3

// Mouse encoder options and event values (ghostty/vt/mouse/encoder.h and
// ghostty/vt/mouse/event.h).
GHOSTTY_MOUSE_ENCODER_OPT_EVENT :: 0
GHOSTTY_MOUSE_ENCODER_OPT_FORMAT :: 1
GHOSTTY_MOUSE_ENCODER_OPT_SIZE :: 2
GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED :: 3
GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL :: 4

GHOSTTY_MOUSE_ACTION_PRESS :: 0
GHOSTTY_MOUSE_ACTION_RELEASE :: 1
GHOSTTY_MOUSE_ACTION_MOTION :: 2

GHOSTTY_MOUSE_BUTTON_UNKNOWN :: 0
GHOSTTY_MOUSE_BUTTON_LEFT :: 1
GHOSTTY_MOUSE_BUTTON_RIGHT :: 2
GHOSTTY_MOUSE_BUTTON_MIDDLE :: 3
GHOSTTY_MOUSE_BUTTON_FOUR :: 4
GHOSTTY_MOUSE_BUTTON_FIVE :: 5

// Ghostty key codes we generate (values from ghostty/vt/key/event.h).
GHOSTTY_KEY_UNIDENTIFIED :: 0
GHOSTTY_KEY_DIGIT_0 :: 6
GHOSTTY_KEY_BACKQUOTE :: 1
GHOSTTY_KEY_BACKSLASH :: 2
GHOSTTY_KEY_BRACKET_LEFT :: 3
GHOSTTY_KEY_BRACKET_RIGHT :: 4
GHOSTTY_KEY_COMMA :: 5
GHOSTTY_KEY_EQUAL :: 16
GHOSTTY_KEY_A :: 20
GHOSTTY_KEY_Z :: 45
GHOSTTY_KEY_MINUS :: 46
GHOSTTY_KEY_PERIOD :: 47
GHOSTTY_KEY_QUOTE :: 48
GHOSTTY_KEY_SEMICOLON :: 49
GHOSTTY_KEY_SLASH :: 50
GHOSTTY_KEY_ALT_LEFT :: 51
GHOSTTY_KEY_BACKSPACE :: 53
GHOSTTY_KEY_CONTROL_LEFT :: 56
GHOSTTY_KEY_CONTROL_RIGHT :: 57
GHOSTTY_KEY_ENTER :: 58
GHOSTTY_KEY_SHIFT_LEFT :: 61
GHOSTTY_KEY_SPACE :: 63
GHOSTTY_KEY_TAB :: 64
GHOSTTY_KEY_DELETE :: 68
GHOSTTY_KEY_END :: 69
GHOSTTY_KEY_HOME :: 71
GHOSTTY_KEY_INSERT :: 72
GHOSTTY_KEY_PAGE_DOWN :: 73
GHOSTTY_KEY_PAGE_UP :: 74
GHOSTTY_KEY_ARROW_DOWN :: 75
GHOSTTY_KEY_ARROW_LEFT :: 76
GHOSTTY_KEY_ARROW_RIGHT :: 77
GHOSTTY_KEY_ARROW_UP :: 78
GHOSTTY_KEY_ESCAPE :: 120
GHOSTTY_KEY_F1 :: 121
GHOSTTY_KEY_F12 :: 132

// Guard the C layouts we rely on. The scroll-viewport union in particular is
// padded to 16 bytes by the C API, which makes the tagged union 24 bytes.
#assert(size_of(GhosttyTerminalOptions) == 16)
#assert(size_of(GhosttyScrollViewport) == 24)
#assert(size_of(GhosttyStyle) == 72)
#assert(size_of(GhosttyStyleColor) == 16)
#assert(size_of(GhosttyBuffer) == 24)
#assert(size_of(GhosttyString) == 16)
#assert(size_of(GhosttyTerminalScrollbar) == 24)
#assert(size_of(GhosttyGridRef) == 24)
#assert(size_of(GhosttyPointCoordinate) == 8)
#assert(size_of(GhosttyPoint) == 24)
#assert(size_of(GhosttySelection) == 64)
#assert(size_of(GhosttyRenderStateRowSelection) == 16)
#assert(size_of(GhosttyTerminalSelectionFormatOptions) == 24)
#assert(size_of(GhosttyMousePosition) == 8)
#assert(size_of(GhosttyMouseEncoderSize) == 40)

// --- functions -------------------------------------------------------------

foreign import ghostty "../build/libmiagent.a"

@(default_calling_convention = "c")
foreign ghostty {
	ghostty_terminal_new :: proc(allocator: rawptr, out: ^GhosttyTerminal, options: GhosttyTerminalOptions) -> GhosttyResult ---
	ghostty_terminal_free :: proc(t: GhosttyTerminal) ---
	ghostty_terminal_resize :: proc(t: GhosttyTerminal, cols, rows: u16, cell_w_px, cell_h_px: u32) -> GhosttyResult ---
	ghostty_terminal_set :: proc(t: GhosttyTerminal, option: i32, value: rawptr) -> GhosttyResult ---
	ghostty_terminal_vt_write :: proc(t: GhosttyTerminal, data: [^]u8, len: uint) ---
	ghostty_terminal_scroll_viewport :: proc(t: GhosttyTerminal, behavior: GhosttyScrollViewport) ---
	ghostty_terminal_get :: proc(t: GhosttyTerminal, data: i32, out: rawptr) -> GhosttyResult ---
	ghostty_terminal_mode_get :: proc(t: GhosttyTerminal, mode: u16, out_value: ^bool) -> GhosttyResult ---
	ghostty_terminal_grid_ref :: proc(t: GhosttyTerminal, point: GhosttyPoint, out_ref: ^GhosttyGridRef) -> GhosttyResult ---
	ghostty_terminal_selection_format_buf :: proc(t: GhosttyTerminal, options: GhosttyTerminalSelectionFormatOptions, buf: [^]u8, buf_len: uint, out_written: ^uint) -> GhosttyResult ---
	ghostty_paste_encode :: proc(data: [^]u8, data_len: uint, bracketed: bool, buf: [^]u8, buf_len: uint, out_written: ^uint) -> GhosttyResult ---

	ghostty_render_state_new :: proc(allocator: rawptr, out: ^GhosttyRenderState) -> GhosttyResult ---
	ghostty_render_state_free :: proc(s: GhosttyRenderState) ---
	ghostty_render_state_update :: proc(s: GhosttyRenderState, t: GhosttyTerminal) -> GhosttyResult ---
	ghostty_render_state_get :: proc(s: GhosttyRenderState, data: i32, out: rawptr) -> GhosttyResult ---

	ghostty_render_state_row_iterator_new :: proc(allocator: rawptr, out: ^GhosttyRenderStateRowIterator) -> GhosttyResult ---
	ghostty_render_state_row_iterator_free :: proc(it: GhosttyRenderStateRowIterator) ---
	ghostty_render_state_row_iterator_next :: proc(it: GhosttyRenderStateRowIterator) -> bool ---
	ghostty_render_state_row_get :: proc(it: GhosttyRenderStateRowIterator, data: i32, out: rawptr) -> GhosttyResult ---

	ghostty_render_state_row_cells_new :: proc(allocator: rawptr, out: ^GhosttyRenderStateRowCells) -> GhosttyResult ---
	ghostty_render_state_row_cells_free :: proc(c: GhosttyRenderStateRowCells) ---
	ghostty_render_state_row_cells_next :: proc(c: GhosttyRenderStateRowCells) -> bool ---
	ghostty_render_state_row_cells_get :: proc(c: GhosttyRenderStateRowCells, data: i32, out: rawptr) -> GhosttyResult ---

	ghostty_key_encoder_new :: proc(allocator: rawptr, out: ^GhosttyKeyEncoder) -> GhosttyResult ---
	ghostty_key_encoder_free :: proc(e: GhosttyKeyEncoder) ---
	ghostty_key_encoder_setopt :: proc(e: GhosttyKeyEncoder, option: i32, value: rawptr) ---
	ghostty_key_encoder_setopt_from_terminal :: proc(e: GhosttyKeyEncoder, t: GhosttyTerminal) ---
	ghostty_key_encoder_encode :: proc(e: GhosttyKeyEncoder, ev: GhosttyKeyEvent, buf: [^]u8, cap: uint, out_len: ^uint) -> GhosttyResult ---

	ghostty_key_event_new :: proc(allocator: rawptr, out: ^GhosttyKeyEvent) -> GhosttyResult ---
	ghostty_key_event_free :: proc(ev: GhosttyKeyEvent) ---
	ghostty_key_event_set_action :: proc(ev: GhosttyKeyEvent, action: i32) ---
	ghostty_key_event_set_key :: proc(ev: GhosttyKeyEvent, key: i32) ---
	ghostty_key_event_set_mods :: proc(ev: GhosttyKeyEvent, mods: u16) ---
	ghostty_key_event_set_utf8 :: proc(ev: GhosttyKeyEvent, utf8: cstring, len: uint) ---

	ghostty_mouse_encoder_new :: proc(allocator: rawptr, out: ^GhosttyMouseEncoder) -> GhosttyResult ---
	ghostty_mouse_encoder_free :: proc(e: GhosttyMouseEncoder) ---
	ghostty_mouse_encoder_setopt :: proc(e: GhosttyMouseEncoder, option: i32, value: rawptr) ---
	ghostty_mouse_encoder_setopt_from_terminal :: proc(e: GhosttyMouseEncoder, t: GhosttyTerminal) ---
	ghostty_mouse_encoder_reset :: proc(e: GhosttyMouseEncoder) ---
	ghostty_mouse_encoder_encode :: proc(e: GhosttyMouseEncoder, ev: GhosttyMouseEvent, buf: [^]u8, cap: uint, out_len: ^uint) -> GhosttyResult ---

	ghostty_mouse_event_new :: proc(allocator: rawptr, out: ^GhosttyMouseEvent) -> GhosttyResult ---
	ghostty_mouse_event_free :: proc(ev: GhosttyMouseEvent) ---
	ghostty_mouse_event_set_action :: proc(ev: GhosttyMouseEvent, action: i32) ---
	ghostty_mouse_event_set_button :: proc(ev: GhosttyMouseEvent, button: i32) ---
	ghostty_mouse_event_clear_button :: proc(ev: GhosttyMouseEvent) ---
	ghostty_mouse_event_set_mods :: proc(ev: GhosttyMouseEvent, mods: u16) ---
	ghostty_mouse_event_set_position :: proc(ev: GhosttyMouseEvent, position: GhosttyMousePosition) ---

	ghostty_color_palette_default :: proc(out: ^[256]GhosttyColorRgb) ---

	// PTY shim (pty.c)
	mi_pty_spawn :: proc(shell, cwd: cstring, cols, rows: u16, out_fd, out_pid: ^i32, err: [^]u8, err_len: i32) -> i32 ---
	mi_pty_resize :: proc(fd: i32, cols, rows: u16) -> i32 ---
	mi_pty_read :: proc(fd: i32, buf: rawptr, cap: i32) -> i32 ---
	mi_pty_write :: proc(fd: i32, buf: rawptr, len: i32) -> i32 ---
	mi_pty_terminate :: proc(fd, pid: i32) ---
	mi_pty_reap :: proc(pid: i32) -> i32 ---
}
