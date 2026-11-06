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
GHOSTTY_KEY_DIGIT_9 :: 15
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

// --- effects, selection gestures, diagnostics, and keyboard extras --------

GhosttySelectionGesture :: distinct rawptr
GhosttySelectionGestureEvent :: distinct rawptr

GhosttySurfacePosition :: struct {
	x, y: f64,
}

GhosttyClipboardContent :: struct {
	mime: GhosttyString,
	data: GhosttyString,
}

GhosttyClipboardWrite :: struct {
	size:         uint,
	location:     i32,
	contents:     [^]GhosttyClipboardContent,
	contents_len: uint,
}

GhosttySizeReportSize :: struct {
	rows:        u16,
	columns:     u16,
	cell_width:  u32,
	cell_height: u32,
}

GhosttyDeviceAttributesPrimary :: struct {
	conformance_level: u16,
	features:          [64]u16,
	num_features:      uint,
}

GhosttyDeviceAttributesSecondary :: struct {
	device_type:      u16,
	firmware_version: u16,
	rom_cartridge:    u16,
}

GhosttyDeviceAttributesTertiary :: struct {
	unit_id: u32,
}

GhosttyDeviceAttributes :: struct {
	primary:   GhosttyDeviceAttributesPrimary,
	secondary: GhosttyDeviceAttributesSecondary,
	tertiary:  GhosttyDeviceAttributesTertiary,
}

GhosttySelectionGestureBehaviors :: struct {
	single_click: i32,
	double_click: i32,
	triple_click: i32,
}

GhosttySelectionGestureGeometry :: struct {
	columns:       u32,
	cell_width:    u32,
	padding_left:  u32,
	screen_height: u32,
}

GhosttyTerminalSelectWordOptions :: struct {
	size:                  uint,
	ref:                   GhosttyGridRef,
	boundary_codepoints:   [^]u32,
	boundary_codepoints_len: uint,
}

GhosttyTerminalSelectWordBetweenOptions :: struct {
	size:                  uint,
	start:                 GhosttyGridRef,
	end:                   GhosttyGridRef,
	boundary_codepoints:   [^]u32,
	boundary_codepoints_len: uint,
}

GhosttyTerminalSelectLineOptions :: struct {
	size:                      uint,
	ref:                       GhosttyGridRef,
	whitespace:                [^]u32,
	whitespace_len:            uint,
	semantic_prompt_boundary:  bool,
	_pad:                      [7]u8,
}

// C callback types. Userdata is a stable ^Terminal.
GhosttyTerminalWritePtyFn :: proc "c" (t: GhosttyTerminal, userdata: rawptr, data: [^]u8, len: uint)
GhosttyTerminalBellFn :: proc "c" (t: GhosttyTerminal, userdata: rawptr)
GhosttyTerminalEnquiryFn :: proc "c" (t: GhosttyTerminal, userdata: rawptr) -> GhosttyString
GhosttyTerminalXtversionFn :: proc "c" (t: GhosttyTerminal, userdata: rawptr) -> GhosttyString
GhosttyTerminalTitleChangedFn :: proc "c" (t: GhosttyTerminal, userdata: rawptr)
GhosttyTerminalPwdChangedFn :: proc "c" (t: GhosttyTerminal, userdata: rawptr)
GhosttyTerminalSizeFn :: proc "c" (t: GhosttyTerminal, userdata: rawptr, out: ^GhosttySizeReportSize) -> bool
GhosttyTerminalColorSchemeFn :: proc "c" (t: GhosttyTerminal, userdata: rawptr, out: ^i32) -> bool
GhosttyTerminalDeviceAttributesFn :: proc "c" (t: GhosttyTerminal, userdata: rawptr, out: ^GhosttyDeviceAttributes) -> bool
GhosttyTerminalClipboardWriteFn :: proc "c" (t: GhosttyTerminal, userdata: rawptr, write: ^GhosttyClipboardWrite) -> i32
GhosttySysLogFn :: proc "c" (userdata: rawptr, level: i32, scope: [^]u8, scope_len: uint, message: [^]u8, message_len: uint)

GHOSTTY_TERMINAL_OPT_USERDATA :: 0
GHOSTTY_TERMINAL_OPT_WRITE_PTY :: 1
GHOSTTY_TERMINAL_OPT_BELL :: 2
GHOSTTY_TERMINAL_OPT_ENQUIRY :: 3
GHOSTTY_TERMINAL_OPT_XTVERSION :: 4
GHOSTTY_TERMINAL_OPT_TITLE_CHANGED :: 5
GHOSTTY_TERMINAL_OPT_SIZE :: 6
GHOSTTY_TERMINAL_OPT_COLOR_SCHEME :: 7
GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES :: 8
GHOSTTY_TERMINAL_OPT_TITLE :: 9
GHOSTTY_TERMINAL_OPT_PWD :: 10
GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE :: 22
GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK :: 23
GHOSTTY_TERMINAL_OPT_PWD_CHANGED :: 25
GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE :: 26

GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN :: 6
GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS :: 8
GHOSTTY_TERMINAL_DATA_CURSOR_STYLE :: 10
GHOSTTY_TERMINAL_DATA_TOTAL_ROWS :: 14
GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS :: 15
GHOSTTY_TERMINAL_DATA_VT_PROCESSING_ERROR :: 33

GHOSTTY_TERMINAL_SCREEN_PRIMARY :: 0
GHOSTTY_TERMINAL_SCREEN_ALTERNATE :: 1

GHOSTTY_MODE_DECCKM :: u16(1)
GHOSTTY_MODE_FOCUS_EVENT :: u16(1004)
GHOSTTY_MODE_ALT_SCROLL :: u16(1007)
GHOSTTY_MODE_ALT_SCREEN :: u16(1047)
GHOSTTY_MODE_COLOR_SCHEME_REPORT :: u16(2031)
GHOSTTY_MODE_IN_BAND_RESIZE :: u16(2048)

GHOSTTY_RENDER_STATE_DATA_DIRTY :: 3
GHOSTTY_RENDER_STATE_DATA_COLOR_CURSOR_HAS_VALUE :: 8
GHOSTTY_RENDER_STATE_DATA_COLOR_PALETTE :: 9
GHOSTTY_RENDER_STATE_DATA_CURSOR_PASSWORD_INPUT :: 13
GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_WIDE_TAIL :: 17
GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY :: 1
GHOSTTY_RENDER_STATE_ROW_DATA_RAW :: 2
GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY :: 0
GHOSTTY_RENDER_STATE_OPTION_DIRTY :: 0

GHOSTTY_RENDER_STATE_DIRTY_FALSE :: 0
GHOSTTY_RENDER_STATE_DIRTY_PARTIAL :: 1
GHOSTTY_RENDER_STATE_DIRTY_FULL :: 2

GHOSTTY_FOCUS_GAINED :: 0
GHOSTTY_FOCUS_LOST :: 1

GHOSTTY_COLOR_SCHEME_LIGHT :: 0
GHOSTTY_COLOR_SCHEME_DARK :: 1

GHOSTTY_SIZE_REPORT_MODE_2048 :: 0
GHOSTTY_SIZE_REPORT_CSI_14_T :: 1
GHOSTTY_SIZE_REPORT_CSI_16_T :: 2
GHOSTTY_SIZE_REPORT_CSI_18_T :: 3

GHOSTTY_CLIPBOARD_LOCATION_STANDARD :: 0
GHOSTTY_CLIPBOARD_LOCATION_SELECTION :: 1
GHOSTTY_CLIPBOARD_LOCATION_PRIMARY :: 2

GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS :: 0
GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED :: 1
GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED :: 2
GHOSTTY_CLIPBOARD_WRITE_RESULT_BUSY :: 3
GHOSTTY_CLIPBOARD_WRITE_RESULT_INVALID_DATA :: 4
GHOSTTY_CLIPBOARD_WRITE_RESULT_IO_ERROR :: 5

GHOSTTY_SYS_OPT_USERDATA :: 0
GHOSTTY_SYS_OPT_DECODE_PNG :: 1
GHOSTTY_SYS_OPT_LOG :: 2

GHOSTTY_SYS_LOG_LEVEL_ERROR :: 0
GHOSTTY_SYS_LOG_LEVEL_WARNING :: 1
GHOSTTY_SYS_LOG_LEVEL_INFO :: 2
GHOSTTY_SYS_LOG_LEVEL_DEBUG :: 3

GHOSTTY_BUILD_INFO_KITTY_GRAPHICS :: 2
GHOSTTY_BUILD_INFO_OPTIMIZE :: 4
GHOSTTY_BUILD_INFO_VERSION_STRING :: 5

GHOSTTY_TERMINAL_COMPRESSION_MODE_INCREMENTAL :: 0
GHOSTTY_TERMINAL_COMPRESSION_MODE_FULL :: 1
GHOSTTY_TERMINAL_COMPRESSION_RESULT_UNSUPPORTED :: 0
GHOSTTY_TERMINAL_COMPRESSION_RESULT_PENDING :: 1
GHOSTTY_TERMINAL_COMPRESSION_RESULT_COMPLETE :: 2

GHOSTTY_SELECTION_GESTURE_BEHAVIOR_CELL :: 0
GHOSTTY_SELECTION_GESTURE_BEHAVIOR_WORD :: 1
GHOSTTY_SELECTION_GESTURE_BEHAVIOR_LINE :: 2
GHOSTTY_SELECTION_GESTURE_BEHAVIOR_OUTPUT :: 3

GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS :: 0
GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE :: 1
GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG :: 2
GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_AUTOSCROLL_TICK :: 3
GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DEEP_PRESS :: 4

GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF :: 0
GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION :: 1
GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE :: 2
GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS :: 3
GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS :: 4
GHOSTTY_SELECTION_GESTURE_EVENT_OPT_WORD_BOUNDARY_CODEPOINTS :: 5
GHOSTTY_SELECTION_GESTURE_EVENT_OPT_BEHAVIORS :: 6
GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE :: 7
GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY :: 8
GHOSTTY_SELECTION_GESTURE_EVENT_OPT_VIEWPORT :: 9

GHOSTTY_SELECTION_GESTURE_DATA_CLICK_COUNT :: 0
GHOSTTY_SELECTION_GESTURE_DATA_DRAGGED :: 1
GHOSTTY_SELECTION_GESTURE_DATA_AUTOSCROLL :: 2
GHOSTTY_SELECTION_GESTURE_DATA_BEHAVIOR :: 3
GHOSTTY_SELECTION_GESTURE_DATA_ANCHOR :: 4

GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_NONE :: 0
GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_UP :: 1
GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_DOWN :: 2

GHOSTTY_SELECTION_ADJUST_LEFT :: 0
GHOSTTY_SELECTION_ADJUST_RIGHT :: 1
GHOSTTY_SELECTION_ADJUST_UP :: 2
GHOSTTY_SELECTION_ADJUST_DOWN :: 3
GHOSTTY_SELECTION_ADJUST_HOME :: 4
GHOSTTY_SELECTION_ADJUST_END :: 5
GHOSTTY_SELECTION_ADJUST_PAGE_UP :: 6
GHOSTTY_SELECTION_ADJUST_PAGE_DOWN :: 7
GHOSTTY_SELECTION_ADJUST_BEGINNING_OF_LINE :: 8
GHOSTTY_SELECTION_ADJUST_END_OF_LINE :: 9

GHOSTTY_SELECTION_ORDER_FORWARD :: 0
GHOSTTY_SELECTION_ORDER_REVERSE :: 1
GHOSTTY_SELECTION_ORDER_MIRRORED_FORWARD :: 2
GHOSTTY_SELECTION_ORDER_MIRRORED_REVERSE :: 3

GHOSTTY_SGR_UNDERLINE_NONE :: 0
GHOSTTY_SGR_UNDERLINE_SINGLE :: 1
GHOSTTY_SGR_UNDERLINE_DOUBLE :: 2
GHOSTTY_SGR_UNDERLINE_CURLY :: 3
GHOSTTY_SGR_UNDERLINE_DOTTED :: 4
GHOSTTY_SGR_UNDERLINE_DASHED :: 5

GHOSTTY_KEY_ENCODER_OPT_CURSOR_KEY_APPLICATION :: 0
GHOSTTY_KEY_ENCODER_OPT_KEYPAD_KEY_APPLICATION :: 1
GHOSTTY_KEY_ENCODER_OPT_IGNORE_KEYPAD_WITH_NUMLOCK :: 2
GHOSTTY_KEY_ENCODER_OPT_MODIFY_OTHER_KEYS_STATE_2 :: 4
GHOSTTY_KEY_ENCODER_OPT_KITTY_FLAGS :: 5
GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT :: 6
GHOSTTY_KEY_ENCODER_OPT_BACKARROW_KEY_MODE :: 7

GHOSTTY_KITTY_KEY_DISAMBIGUATE :: u8(1 << 0)
GHOSTTY_KITTY_KEY_REPORT_EVENTS :: u8(1 << 1)
GHOSTTY_KITTY_KEY_REPORT_ALTERNATES :: u8(1 << 2)
GHOSTTY_KITTY_KEY_REPORT_ALL :: u8(1 << 3)
GHOSTTY_KITTY_KEY_REPORT_ASSOCIATED :: u8(1 << 4)

GHOSTTY_KEY_F13 :: 133
GHOSTTY_KEY_F24 :: 144
GHOSTTY_KEY_PRINT_SCREEN :: 149
GHOSTTY_KEY_SCROLL_LOCK :: 150
GHOSTTY_KEY_PAUSE :: 151

#assert(size_of(GhosttySurfacePosition) == 16)
#assert(size_of(GhosttyClipboardContent) == 32)
#assert(size_of(GhosttyClipboardWrite) == 32)
#assert(size_of(GhosttySizeReportSize) == 12)
#assert(size_of(GhosttyDeviceAttributesPrimary) == 144)
#assert(size_of(GhosttyDeviceAttributesSecondary) == 6)
#assert(size_of(GhosttyDeviceAttributesTertiary) == 4)
#assert(size_of(GhosttyDeviceAttributes) == 160)
#assert(size_of(GhosttySelectionGestureBehaviors) == 12)
#assert(size_of(GhosttySelectionGestureGeometry) == 16)
#assert(size_of(GhosttyTerminalSelectWordOptions) == 48)
#assert(size_of(GhosttyTerminalSelectWordBetweenOptions) == 72)
#assert(size_of(GhosttyTerminalSelectLineOptions) == 56)

@(default_calling_convention = "c")
foreign ghostty {
	ghostty_terminal_reset :: proc(t: GhosttyTerminal) ---
	ghostty_terminal_compression_activity :: proc(t: GhosttyTerminal, out: ^u64) -> GhosttyResult ---
	ghostty_terminal_compress :: proc(t: GhosttyTerminal, mode: i32, out: ^i32) -> GhosttyResult ---

	ghostty_render_state_set :: proc(rs: GhosttyRenderState, option: i32, value: rawptr) -> GhosttyResult ---
	ghostty_render_state_row_set :: proc(it: GhosttyRenderStateRowIterator, option: i32, value: rawptr) -> GhosttyResult ---
	ghostty_render_state_row_cells_select :: proc(cells: GhosttyRenderStateRowCells, x: u16) -> GhosttyResult ---

	ghostty_focus_encode :: proc(event: i32, buf: [^]u8, buf_len: uint, out_len: ^uint) -> GhosttyResult ---
	ghostty_color_scheme_report_encode :: proc(scheme: i32, buf: [^]u8, buf_len: uint, out_len: ^uint) -> GhosttyResult ---
	ghostty_size_report_encode :: proc(style: i32, size: GhosttySizeReportSize, buf: [^]u8, buf_len: uint, out_len: ^uint) -> GhosttyResult ---

	ghostty_grid_ref_hyperlink_uri :: proc(ref: ^GhosttyGridRef, buf: [^]u8, buf_len: uint, out_len: ^uint) -> GhosttyResult ---

	ghostty_key_event_set_consumed_mods :: proc(ev: GhosttyKeyEvent, mods: u16) ---
	ghostty_key_event_set_unshifted_codepoint :: proc(ev: GhosttyKeyEvent, codepoint: u32) ---
	ghostty_key_event_set_composing :: proc(ev: GhosttyKeyEvent, composing: bool) ---

	ghostty_selection_gesture_new :: proc(allocator: rawptr, out: ^GhosttySelectionGesture) -> GhosttyResult ---
	ghostty_selection_gesture_free :: proc(g: GhosttySelectionGesture, t: GhosttyTerminal) ---
	ghostty_selection_gesture_reset :: proc(g: GhosttySelectionGesture, t: GhosttyTerminal) ---
	ghostty_selection_gesture_event_new :: proc(allocator: rawptr, out: ^GhosttySelectionGestureEvent, event_type: i32) -> GhosttyResult ---
	ghostty_selection_gesture_event_free :: proc(ev: GhosttySelectionGestureEvent) ---
	ghostty_selection_gesture_event_set :: proc(ev: GhosttySelectionGestureEvent, option: i32, value: rawptr) -> GhosttyResult ---
	ghostty_selection_gesture_event :: proc(g: GhosttySelectionGesture, t: GhosttyTerminal, ev: GhosttySelectionGestureEvent, out: ^GhosttySelection) -> GhosttyResult ---
	ghostty_selection_gesture_get :: proc(g: GhosttySelectionGesture, t: GhosttyTerminal, data: i32, value: rawptr) -> GhosttyResult ---
	ghostty_terminal_select_word :: proc(t: GhosttyTerminal, options: ^GhosttyTerminalSelectWordOptions, out: ^GhosttySelection) -> GhosttyResult ---
	ghostty_terminal_select_word_between :: proc(t: GhosttyTerminal, options: ^GhosttyTerminalSelectWordBetweenOptions, out: ^GhosttySelection) -> GhosttyResult ---
	ghostty_terminal_select_line :: proc(t: GhosttyTerminal, options: ^GhosttyTerminalSelectLineOptions, out: ^GhosttySelection) -> GhosttyResult ---
	ghostty_terminal_select_all :: proc(t: GhosttyTerminal, out: ^GhosttySelection) -> GhosttyResult ---
	ghostty_terminal_select_output :: proc(t: GhosttyTerminal, ref: GhosttyGridRef, out: ^GhosttySelection) -> GhosttyResult ---
	ghostty_terminal_selection_adjust :: proc(t: GhosttyTerminal, sel: ^GhosttySelection, adjustment: i32) -> GhosttyResult ---

	ghostty_build_info :: proc(data: i32, out: rawptr) -> GhosttyResult ---
	ghostty_sys_set :: proc(option: i32, value: rawptr) -> GhosttyResult ---
	ghostty_color_luminance :: proc(color: ^GhosttyColorRgb) -> f64 ---
}

@(default_calling_convention = "c")
foreign ghostty {
	ghostty_paste_is_safe :: proc(data: [^]u8, len: uint) -> bool ---
}

// Additional key codes used by the full input map.
GHOSTTY_KEY_INTL_BACKSLASH :: 17
GHOSTTY_KEY_ALT_RIGHT :: 52
GHOSTTY_KEY_CAPS_LOCK :: 54
GHOSTTY_KEY_CONTEXT_MENU :: 55
GHOSTTY_KEY_META_LEFT :: 59
GHOSTTY_KEY_META_RIGHT :: 60
GHOSTTY_KEY_SHIFT_RIGHT :: 62
GHOSTTY_KEY_F2 :: 122
GHOSTTY_KEY_F14 :: 134
GHOSTTY_KEY_F15 :: 135
GHOSTTY_KEY_F16 :: 136
GHOSTTY_KEY_F17 :: 137
GHOSTTY_KEY_F18 :: 138
GHOSTTY_KEY_F19 :: 139
GHOSTTY_KEY_F20 :: 140
GHOSTTY_KEY_F21 :: 141
GHOSTTY_KEY_F22 :: 142
GHOSTTY_KEY_F23 :: 143
GHOSTTY_KEY_NUM_LOCK :: 79
GHOSTTY_KEY_NUMPAD_0 :: 80
GHOSTTY_KEY_NUMPAD_1 :: 81
GHOSTTY_KEY_NUMPAD_2 :: 82
GHOSTTY_KEY_NUMPAD_3 :: 83
GHOSTTY_KEY_NUMPAD_4 :: 84
GHOSTTY_KEY_NUMPAD_5 :: 85
GHOSTTY_KEY_NUMPAD_6 :: 86
GHOSTTY_KEY_NUMPAD_7 :: 87
GHOSTTY_KEY_NUMPAD_8 :: 88
GHOSTTY_KEY_NUMPAD_9 :: 89
GHOSTTY_KEY_NUMPAD_ADD :: 90
GHOSTTY_KEY_NUMPAD_DECIMAL :: 95
GHOSTTY_KEY_NUMPAD_DIVIDE :: 96
GHOSTTY_KEY_NUMPAD_ENTER :: 97
GHOSTTY_KEY_NUMPAD_EQUAL :: 98
GHOSTTY_KEY_NUMPAD_SUBTRACT :: 111
GHOSTTY_KEY_NUMPAD_MULTIPLY :: 112
GHOSTTY_KEY_BROWSER_BACK :: 156
GHOSTTY_KEY_BROWSER_FORWARD :: 158
