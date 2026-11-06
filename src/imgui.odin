// Minimal Odin bindings for the slice of Dear ImGui (via cimgui) this app
// uses, plus the small C bridge in bridge.c for the parts that are awkward to
// bind (the ImGuiIO layout, style setup, fonts, and varargs helpers).
//
// Everything lives in a single merged static archive built by `make deps`
// (see Makefile) so link order never matters.
package main

ImVec2 :: struct {
	x, y: f32,
}

ImVec4 :: struct {
	x, y, z, w: f32,
}

ImDrawList :: struct {}
ImFont :: struct {}
ImFontAtlas :: struct {}
ImGuiContext :: struct {}
ImDrawData :: struct {}
GLFWwindow :: struct {}

ImU32 :: distinct u32
ImGuiKey :: distinct i32
ImGuiCol :: distinct i32
ImGuiWindowFlags :: distinct u32
ImGuiChildFlags :: distinct u32
ImGuiMouseCursor :: distinct i32
ImGuiInputTextFlags :: distinct u32

foreign import cimgui "../build/libmiagent.a"

@(default_calling_convention = "c")
foreign cimgui {
	// --- context / frame ---------------------------------------------------
	igCreateContext :: proc(shared_font_atlas: ^ImFontAtlas) -> ^ImGuiContext ---
	igDestroyContext :: proc(ctx: ^ImGuiContext) ---
	igNewFrame :: proc() ---
	igRender :: proc() ---
	igEndFrame :: proc() ---
	igGetDrawData :: proc() -> ^ImDrawData ---
	igGetWindowDrawList :: proc() -> ^ImDrawList ---

	// --- windows -----------------------------------------------------------
	igBegin :: proc(name: cstring, p_open: ^bool, flags: ImGuiWindowFlags) -> bool ---
	igEnd :: proc() ---
	igBeginChild_Str :: proc(str_id: cstring, size: ImVec2, child_flags: ImGuiChildFlags, window_flags: ImGuiWindowFlags) -> bool ---
	igEndChild :: proc() ---
	igSetNextWindowBgAlpha :: proc(alpha: f32) ---
	igSetNextItemWidth :: proc(width: f32) ---
	igClearActiveID :: proc() ---
	igSetKeyboardFocusHere :: proc(offset: i32) ---
	igPushStyleColor_Vec4 :: proc(index: ImGuiCol, col: ImVec4) ---
	igPopStyleColor :: proc(count: i32) ---
	igGetScrollY :: proc() -> f32 ---
	igSetScrollY_Float :: proc(scroll_y: f32) ---
	igGetScrollMaxY :: proc() -> f32 ---
	igSetScrollHereY :: proc(center_y_ratio: f32) ---

	// --- widgets / input ---------------------------------------------------
	igInputTextMultiline :: proc(label: cstring, buf: [^]u8, buf_size: uint, size: ImVec2, flags: ImGuiInputTextFlags, callback: rawptr, user_data: rawptr) -> bool ---
	igInputText :: proc(label: cstring, buf: [^]u8, buf_size: uint, flags: ImGuiInputTextFlags, callback: rawptr, user_data: rawptr) -> bool ---
	igDummy :: proc(size: ImVec2) ---
	igIsItemActive :: proc() -> bool ---
	igIsKeyDown_Nil :: proc(key: ImGuiKey) -> bool ---
	igIsKeyPressed_Bool :: proc(key: ImGuiKey, repeat: bool) -> bool ---
	igIsMouseDown_Nil :: proc(button: i32) -> bool ---
	igIsMouseClicked_Bool :: proc(button: i32, repeat: bool) -> bool ---
	igIsMouseReleased_Nil :: proc(button: i32) -> bool ---
	igGetMousePos :: proc() -> ImVec2 ---
	igSetMouseCursor :: proc(cursor: ImGuiMouseCursor) ---
	igGetFrameHeight :: proc() -> f32 ---
	igGetTextLineHeight :: proc() -> f32 ---

	// --- draw list ---------------------------------------------------------
	ImDrawList_AddText_FontPtr :: proc(list: ^ImDrawList, font: ^ImFont, font_size: f32, pos: ImVec2, col: ImU32, text_begin: cstring, text_end: cstring, wrap_width: f32, cpu_fine_clip_rect: ^ImVec4) ---

	// --- backends ----------------------------------------------------------
	ImGui_ImplGlfw_InitForOpenGL :: proc(window: ^GLFWwindow, install_callbacks: bool) -> bool ---
	ImGui_ImplGlfw_Shutdown :: proc() ---
	ImGui_ImplGlfw_NewFrame :: proc() ---
	ImGui_ImplOpenGL3_Init :: proc(glsl_version: cstring) -> bool ---
	ImGui_ImplOpenGL3_Shutdown :: proc() ---
	ImGui_ImplOpenGL3_NewFrame :: proc() ---
	ImGui_ImplOpenGL3_RenderDrawData :: proc(draw_data: ^ImDrawData) ---

	// --- bridge.c ----------------------------------------------------------
	mi_io_setup :: proc(ini_path: cstring) ---
	mi_io_display_size :: proc(w, h: ^f32) ---
	mi_io_dt :: proc() -> f32 ---
	mi_io_time :: proc() -> f32 ---
	mi_io_want_text_input :: proc() -> i32 ---
	mi_io_want_capture_mouse :: proc() -> i32 ---
	mi_io_key_ctrl :: proc() -> i32 ---
	mi_io_key_shift :: proc() -> i32 ---
	mi_io_key_alt :: proc() -> i32 ---
	mi_io_key_super :: proc() -> i32 ---
	mi_io_wheel :: proc() -> f32 ---
	mi_io_set_mouse_cursor :: proc(cursor: i32) ---
	mi_io_input_chars :: proc(out: [^]u32, cap: i32) -> i32 ---

	mi_font_add :: proc(path: cstring, px: f32) -> ^ImFont ---
	mi_font_merge :: proc(dst: ^ImFont, path: cstring, px: f32) -> ^ImFont ---
	mi_font_set_default :: proc(font: ^ImFont) ---
	mi_font_px :: proc(font: ^ImFont) -> f32 ---
	mi_font_push :: proc(font: ^ImFont) ---
	mi_font_push_size :: proc(font: ^ImFont, size: f32) ---
	mi_font_pop :: proc() ---

	mi_text_size_n :: proc(text: cstring, len: uint, wrap_width: f32, w: ^f32, h: ^f32) ---
	mi_draw_text_n :: proc(list: ^ImDrawList, x, y: f32, col: ImU32, text: cstring, len: uint) ---
	mi_draw_text_wrapped_n :: proc(list: ^ImDrawList, x, y, wrap: f32, col: ImU32, text: cstring, len: uint) -> f32 ---
	mi_draw_text_font_n :: proc(list: ^ImDrawList, font: ^ImFont, size, x, y: f32, col: ImU32, text: cstring, len: uint) ---

	mi_style_apply :: proc(scale: f32) ---
	mi_style_color :: proc(index: i32, r, g, b, a: f32) ---

	mi_set_next_window_rect :: proc(x, y, w, h: f32) ---
	mi_begin_panel :: proc(name: cstring, x, y, w, h: f32, interactive: bool) -> bool ---

	mi_draw_rect :: proc(list: ^ImDrawList, x0, y0, x1, y1: f32, col: ImU32, rounding: f32) ---
	mi_draw_rect_stroke :: proc(list: ^ImDrawList, x0, y0, x1, y1: f32, col: ImU32, rounding: f32, thickness: f32) ---
	mi_draw_rect_round_bottom :: proc(list: ^ImDrawList, x0, y0, x1, y1: f32, col: ImU32, rounding: f32) ---
	mi_draw_line :: proc(list: ^ImDrawList, x0, y0, x1, y1: f32, col: ImU32, thickness: f32) ---
	mi_draw_circle :: proc(list: ^ImDrawList, x, y, r: f32, col: ImU32) ---
	mi_draw_triangle :: proc(list: ^ImDrawList, ax, ay, bx, by, cx, cy: f32, col: ImU32) ---
	mi_clip_push :: proc(list: ^ImDrawList, x0, y0, x1, y1: f32) ---
	mi_clip_pop :: proc(list: ^ImDrawList) ---

	mi_hit :: proc(id: cstring, x, y, w, h: f32) -> bool ---
	mi_hit_hovered :: proc() -> bool ---
	mi_hit_clicked :: proc() -> bool ---
	mi_hit_active :: proc() -> bool ---

	mi_cursor_screen :: proc() -> ImVec2 ---
	mi_set_cursor_screen :: proc(x, y: f32) ---
	mi_get_window_pos :: proc(x, y: ^f32) ---
	mi_get_window_size :: proc(w, h: ^f32) ---
	mi_get_content_avail :: proc(w, h: ^f32) ---
	mi_style_scrollbar :: proc() -> f32 ---
	mi_style_frame_padding_x :: proc() -> f32 ---
	mi_style_frame_padding_y :: proc() -> f32 ---
	mi_tooltip_n :: proc(text: cstring, len: uint) ---
	mi_set_clipboard :: proc(text: cstring) ---
	mi_get_clipboard :: proc() -> cstring ---
	igBeginTooltip :: proc() -> bool ---
	igEndTooltip :: proc() ---
	igTextUnformatted :: proc(text: cstring, text_end: cstring) ---
}

// --- Constants used by the app ---------------------------------------------

COL_TEXT :: ImGuiCol(0)
COL_TEXT_DISABLED :: ImGuiCol(1)
COL_WINDOW_BG :: ImGuiCol(2)
COL_CHILD_BG :: ImGuiCol(3)
COL_POPUP_BG :: ImGuiCol(4)
COL_BORDER :: ImGuiCol(5)
COL_FRAME_BG :: ImGuiCol(7)
COL_FRAME_BG_HOVERED :: ImGuiCol(8)
COL_FRAME_BG_ACTIVE :: ImGuiCol(9)
COL_SCROLLBAR_BG :: ImGuiCol(14)
COL_SCROLLBAR_GRAB :: ImGuiCol(15)
COL_SCROLLBAR_GRAB_HOVERED :: ImGuiCol(16)
COL_SCROLLBAR_GRAB_ACTIVE :: ImGuiCol(17)
COL_CHECK_MARK :: ImGuiCol(18)
COL_BUTTON :: ImGuiCol(22)
COL_BUTTON_HOVERED :: ImGuiCol(23)
COL_BUTTON_ACTIVE :: ImGuiCol(24)
COL_HEADER :: ImGuiCol(25)
COL_HEADER_HOVERED :: ImGuiCol(26)
COL_HEADER_ACTIVE :: ImGuiCol(27)
COL_SEPARATOR :: ImGuiCol(28)
COL_TEXT_SELECTED_BG :: ImGuiCol(52)
COL_NAV_CURSOR :: ImGuiCol(57)

WINDOW_NO_DECORATION :: ImGuiWindowFlags(1 | 2 | 8 | 32)
WINDOW_NO_SCROLLBAR :: ImGuiWindowFlags(8)
WINDOW_NO_SCROLL_WITH_MOUSE :: ImGuiWindowFlags(16)
WINDOW_NO_SAVED_SETTINGS :: ImGuiWindowFlags(256)
WINDOW_NO_BACKGROUND :: ImGuiWindowFlags(128)
WINDOW_NO_BRING_TO_FRONT :: ImGuiWindowFlags(8192)
WINDOW_NO_NAV_FOCUS :: ImGuiWindowFlags(131072)
WINDOW_NO_NAV_INPUTS :: ImGuiWindowFlags(65536)

CHILD_NONE :: ImGuiChildFlags(0)
CHILD_BORDERS :: ImGuiChildFlags(1)

INPUT_TEXT_WORD_WRAP :: ImGuiInputTextFlags(1 << 24)
INPUT_TEXT_ENTER_RETURNS_TRUE :: ImGuiInputTextFlags(1 << 6)
INPUT_TEXT_CTRL_ENTER_FOR_NEWLINE :: ImGuiInputTextFlags(1 << 8)

CURSOR_ARROW :: ImGuiMouseCursor(0)
CURSOR_TEXT :: ImGuiMouseCursor(1)
CURSOR_RESIZE_NS :: ImGuiMouseCursor(3)
CURSOR_RESIZE_EW :: ImGuiMouseCursor(4)
CURSOR_HAND :: ImGuiMouseCursor(7)

// ImGuiKey values (stable numeric subset from imgui.h).
KEY_TAB :: ImGuiKey(512)
KEY_LEFT :: ImGuiKey(513)
KEY_RIGHT :: ImGuiKey(514)
KEY_UP :: ImGuiKey(515)
KEY_DOWN :: ImGuiKey(516)
KEY_PAGE_UP :: ImGuiKey(517)
KEY_PAGE_DOWN :: ImGuiKey(518)
KEY_HOME :: ImGuiKey(519)
KEY_END :: ImGuiKey(520)
KEY_INSERT :: ImGuiKey(521)
KEY_DELETE :: ImGuiKey(522)
KEY_BACKSPACE :: ImGuiKey(523)
KEY_SPACE :: ImGuiKey(524)
KEY_ENTER :: ImGuiKey(525)
KEY_ESCAPE :: ImGuiKey(526)
KEY_0 :: ImGuiKey(536)
KEY_9 :: ImGuiKey(545)
KEY_A :: ImGuiKey(546)
KEY_C :: ImGuiKey(548)
KEY_V :: ImGuiKey(567)
KEY_Z :: ImGuiKey(571)

// Convenience
ivec2 :: proc(x, y: f32) -> ImVec2 { return ImVec2{x, y} }
