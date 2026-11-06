// Terminal effect callbacks and the frame-level work they defer.
//
// libghostty invokes these synchronously from ghostty_terminal_vt_write and
// ghostty_terminal_resize. Userdata is the stable ^Terminal allocation, so the
// callbacks stay valid while drawers move in their dynamic arrays.
package main

import "core:fmt"
import "core:os"
import "base:runtime"
import "core:strings"

CLIPBOARD_WRITE_LIMIT :: 1024 * 1024

g_enquiry_text: string = "miagent"
g_xtversion_text: string = "miagent desktop"
g_xtversion_fallback_text: string = "miagent desktop"
g_verbose_vt_logs: bool
g_libghostty_version: string

terminal_sys_log :: proc "c" (userdata: rawptr, level: i32, scope: [^]u8, scope_len: uint,
                              message: [^]u8, message_len: uint) {
	context = runtime.default_context()
	if level > GHOSTTY_SYS_LOG_LEVEL_ERROR && !g_verbose_vt_logs do return
	scope_s := scope_len > 0 ? string(scope[:scope_len]) : "ghostty"
	msg := message_len > 0 ? string(message[:message_len]) : ""
	fmt.eprintf("libghostty[%s]: %s\n", scope_s, msg)
}

// terminal_runtime_init configures process-global libghostty facilities. Call
// once before creating terminals.
terminal_runtime_init :: proc() {
	g_verbose_vt_logs = len(os.get_env("MIAGENT_PROFILE", context.temp_allocator)) > 0

	version: GhosttyString
	if ghostty_build_info(GHOSTTY_BUILD_INFO_VERSION_STRING, &version) == GHOSTTY_SUCCESS && version.len > 0 {
		g_libghostty_version = strings.clone(string(version.ptr[:version.len]))
		g_xtversion_text = fmt.aprintf("miagent desktop %s", g_libghostty_version)
	}

	log_cb: GhosttySysLogFn = terminal_sys_log
	_ = ghostty_sys_set(GHOSTTY_SYS_OPT_LOG, rawptr(log_cb))
}

terminal_install_effects :: proc(t: ^Terminal) -> bool {
	if t.gt == nil do return false
	if ghostty_terminal_set(t.gt, GHOSTTY_TERMINAL_OPT_USERDATA, t) != GHOSTTY_SUCCESS do return false

	write_pty: GhosttyTerminalWritePtyFn = terminal_effect_write_pty
	bell: GhosttyTerminalBellFn = terminal_effect_bell
	enquiry: GhosttyTerminalEnquiryFn = terminal_effect_enquiry
	xtversion: GhosttyTerminalXtversionFn = terminal_effect_xtversion
	title_changed: GhosttyTerminalTitleChangedFn = terminal_effect_title_changed
	pwd_changed: GhosttyTerminalPwdChangedFn = terminal_effect_pwd_changed
	size_cb: GhosttyTerminalSizeFn = terminal_effect_size
	color_scheme: GhosttyTerminalColorSchemeFn = terminal_effect_color_scheme
	device_attributes: GhosttyTerminalDeviceAttributesFn = terminal_effect_device_attributes
	clipboard_write: GhosttyTerminalClipboardWriteFn = terminal_effect_clipboard_write

	if ghostty_terminal_set(t.gt, GHOSTTY_TERMINAL_OPT_WRITE_PTY, rawptr(write_pty)) != GHOSTTY_SUCCESS do return false
	if ghostty_terminal_set(t.gt, GHOSTTY_TERMINAL_OPT_BELL, rawptr(bell)) != GHOSTTY_SUCCESS do return false
	if ghostty_terminal_set(t.gt, GHOSTTY_TERMINAL_OPT_ENQUIRY, rawptr(enquiry)) != GHOSTTY_SUCCESS do return false
	if ghostty_terminal_set(t.gt, GHOSTTY_TERMINAL_OPT_XTVERSION, rawptr(xtversion)) != GHOSTTY_SUCCESS do return false
	if ghostty_terminal_set(t.gt, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, rawptr(title_changed)) != GHOSTTY_SUCCESS do return false
	if ghostty_terminal_set(t.gt, GHOSTTY_TERMINAL_OPT_PWD_CHANGED, rawptr(pwd_changed)) != GHOSTTY_SUCCESS do return false
	if ghostty_terminal_set(t.gt, GHOSTTY_TERMINAL_OPT_SIZE, rawptr(size_cb)) != GHOSTTY_SUCCESS do return false
	if ghostty_terminal_set(t.gt, GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, rawptr(color_scheme)) != GHOSTTY_SUCCESS do return false
	if ghostty_terminal_set(t.gt, GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES, rawptr(device_attributes)) != GHOSTTY_SUCCESS do return false
	if ghostty_terminal_set(t.gt, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, rawptr(clipboard_write)) != GHOSTTY_SUCCESS do return false
	return true
}

terminal_effect_write_pty :: proc "c" (gt: GhosttyTerminal, userdata: rawptr, data: [^]u8, len: uint) {
	t := cast(^Terminal)userdata
	if t == nil || data == nil || len == 0 do return
	if t.alive && t.fd >= 0 {
		mi_pty_write(t.fd, data, i32(len))
	}
}

terminal_effect_bell :: proc "c" (gt: GhosttyTerminal, userdata: rawptr) {
	t := cast(^Terminal)userdata
	if t == nil do return
	if t.bell_pending < 8 do t.bell_pending += 1
}

terminal_effect_enquiry :: proc "c" (gt: GhosttyTerminal, userdata: rawptr) -> GhosttyString {
	return GhosttyString{ptr = raw_data(g_enquiry_text), len = uint(len(g_enquiry_text))}
}

terminal_effect_xtversion :: proc "c" (gt: GhosttyTerminal, userdata: rawptr) -> GhosttyString {
	if len(g_xtversion_text) == 0 {
		return GhosttyString{ptr = raw_data(g_xtversion_fallback_text), len = uint(len(g_xtversion_fallback_text))}
	}
	return GhosttyString{ptr = raw_data(g_xtversion_text), len = uint(len(g_xtversion_text))}
}

terminal_effect_title_changed :: proc "c" (gt: GhosttyTerminal, userdata: rawptr) {
	t := cast(^Terminal)userdata
	if t != nil do t.meta_dirty = true
}

terminal_effect_pwd_changed :: proc "c" (gt: GhosttyTerminal, userdata: rawptr) {
	t := cast(^Terminal)userdata
	if t != nil do t.meta_dirty = true
}

terminal_effect_size :: proc "c" (gt: GhosttyTerminal, userdata: rawptr, out: ^GhosttySizeReportSize) -> bool {
	t := cast(^Terminal)userdata
	if t == nil || out == nil do return false
	out^ = GhosttySizeReportSize {
		rows        = t.nrows,
		columns     = t.cols,
		cell_width  = t.cell_w_px,
		cell_height = t.cell_h_px,
	}
	return true
}

terminal_effect_color_scheme :: proc "c" (gt: GhosttyTerminal, userdata: rawptr, out: ^i32) -> bool {
	t := cast(^Terminal)userdata
	if t == nil || out == nil do return false
	out^ = t.color_scheme
	return true
}

terminal_effect_device_attributes :: proc "c" (gt: GhosttyTerminal, userdata: rawptr, out: ^GhosttyDeviceAttributes) -> bool {
	if out == nil do return false
	out^ = {}
	out.primary.conformance_level = 62 // VT220
	out.primary.features[0] = 22       // ANSI color
	out.primary.features[1] = 52       // clipboard
	out.primary.num_features = 2
	out.secondary.device_type = 1
	out.secondary.firmware_version = 1
	out.tertiary.unit_id = 0
	return true
}

clipboard_mime_rank :: proc(mime: string) -> int {
	switch {
	case strings.equal_fold(mime, "text/plain;charset=utf-8"): return 0
	case strings.equal_fold(mime, "text/plain"): return 1
	case strings.equal_fold(mime, "utf8_string"): return 2
	case strings.equal_fold(mime, "string"): return 3
	case strings.has_prefix(mime, "text/"): return 4
	}
	return -1
}

terminal_effect_clipboard_write :: proc "c" (gt: GhosttyTerminal, userdata: rawptr,
                                             write: ^GhosttyClipboardWrite) -> i32 {
	context = runtime.default_context()
	t := cast(^Terminal)userdata
	if t == nil || write == nil do return GHOSTTY_CLIPBOARD_WRITE_RESULT_INVALID_DATA
	if write.location != GHOSTTY_CLIPBOARD_LOCATION_STANDARD {
		return GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED
	}

	if write.contents_len == 0 {
		delete(t.clip_pending, t.clip_allocator)
		t.clip_pending = ""
		t.clip_pending_set = true
		t.clip_pending_clear = true
		return GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS
	}

	best := -1
	best_rank := 99
	for i in 0 ..< int(write.contents_len) {
		content := write.contents[i]
		mime := string(content.mime.ptr[:content.mime.len])
		rank := clipboard_mime_rank(mime)
		if rank >= 0 && rank < best_rank {
			best = i
			best_rank = rank
		}
	}
	if best < 0 do return GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED

	content := write.contents[best]
	if content.data.len > CLIPBOARD_WRITE_LIMIT do return GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED
	bytes := content.data.ptr[:content.data.len]
	for b in bytes {
		if b == 0 do return GHOSTTY_CLIPBOARD_WRITE_RESULT_INVALID_DATA
	}
	delete(t.clip_pending, t.clip_allocator)
	t.clip_pending = strings.clone(string(bytes), t.clip_allocator)
	t.clip_pending_set = true
	t.clip_pending_clear = false
	return GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS
}

// terminal_apply_pending_effects runs on the GUI thread after the PTY has
// been pumped. Clipboard writes are applied here rather than inside the
// parser callback so tests and policy stay in one place.
terminal_apply_pending_effects :: proc(t: ^Terminal) {
	if t.clip_pending_set {
		if t.clip_pending_clear {
			mi_set_clipboard(cstr(""))
		} else {
			mi_set_clipboard(cstr(t.clip_pending))
		}
		delete(t.clip_pending)
		t.clip_pending = ""
		t.clip_pending_set = false
		t.clip_pending_clear = false
	}
}

terminal_take_bell :: proc(t: ^Terminal) -> u32 {
	n := t.bell_pending
	t.bell_pending = 0
	return n
}

terminal_maybe_report_color_scheme :: proc(t: ^Terminal) {
	enabled := false
	if ghostty_terminal_mode_get(t.gt, GHOSTTY_MODE_COLOR_SCHEME_REPORT, &enabled) != GHOSTTY_SUCCESS {
		return
	}
	if !enabled {
		t.scheme_report_sent = false
		return
	}
	if t.scheme_report_sent do return

	buf: [32]u8
	n: uint
	if ghostty_color_scheme_report_encode(t.color_scheme, &buf[0], len(buf), &n) == GHOSTTY_SUCCESS && n > 0 {
		terminal_write(t, buf[:n])
	}
	t.scheme_report_sent = true
}

terminal_poll_diagnostics :: proc(t: ^Terminal) {
	had_error := false
	if ghostty_terminal_get(t.gt, GHOSTTY_TERMINAL_DATA_VT_PROCESSING_ERROR, &had_error) != GHOSTTY_SUCCESS {
		return
	}
	if had_error && !t.vt_error {
		t.vt_error = true
		if !t.vt_error_logged {
			t.vt_error_logged = true
			fmt.eprintln("terminal: libghostty reported a VT processing error")
		}
	}
}


terminal_reset :: proc(t: ^Terminal) {
	if t == nil || t.gt == nil do return
	terminal_selection_reset(t)
	terminal_cancel_paste(t)
	t.focus_reported = false
	t.focus_mode_was = false
	t.scheme_report_sent = false
	t.mouse_grab = false
	t.mouse_have_cell = false
	for i in 0 ..< len(t.key_down) do t.key_down[i] = false
	ghostty_terminal_reset(t.gt)
	ghostty_terminal_set(t.gt, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &t.def_fg)
	ghostty_terminal_set(t.gt, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &t.def_bg)
	ghostty_terminal_set(t.gt, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &t.def_cursor)
	ghostty_terminal_set(t.gt, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, &t.def_palette)
	ghostty_terminal_set(t.gt, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE, &t.def_cursor_style)
	ghostty_terminal_set(t.gt, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, &t.def_cursor_blink)
	delete(t.hover_link_uri)
	t.hover_link_uri = ""
	t.hover_link_valid = false
	t.link_epoch += 1
	t.render_invalid = true
	t.dirty = true
	t.meta_dirty = true
}

terminal_compression_tick :: proc(t: ^Terminal, now: f32) {
	if t == nil || !t.alive || t.gt == nil do return
	if t.compress_seen && now < t.compress_next_at do return

	activity: u64
	if ghostty_terminal_compression_activity(t.gt, &activity) != GHOSTTY_SUCCESS {
		t.compress_next_at = now + 10.0
		return
	}
	if !t.compress_seen || activity != t.compress_activity {
		t.compress_seen = true
		t.compress_activity = activity
		t.compress_next_at = now + 2.0
		return
	}

	rows: uint
	if ghostty_terminal_get(t.gt, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &rows) != GHOSTTY_SUCCESS || rows < 500 {
		t.compress_next_at = now + 5.0
		return
	}

	result: i32 = GHOSTTY_TERMINAL_COMPRESSION_RESULT_UNSUPPORTED
	if ghostty_terminal_compress(t.gt, GHOSTTY_TERMINAL_COMPRESSION_MODE_INCREMENTAL, &result) != GHOSTTY_SUCCESS {
		t.compress_next_at = now + 10.0
		return
	}
	switch result {
	case GHOSTTY_TERMINAL_COMPRESSION_RESULT_PENDING:
		t.compress_next_at = now + 0.01
	case GHOSTTY_TERMINAL_COMPRESSION_RESULT_COMPLETE:
		t.compress_next_at = now + 5.0
	case:
		t.compress_next_at = now + 10.0
	}
}
