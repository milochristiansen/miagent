// Exported entry points for the CLI. The implementation is intentionally
// package-private; these thin wrappers are the stable surface.
package termark

import "core:io"

New_Renderer :: proc(w: io.Writer, style_name: string, width: int) -> (^Renderer, string) {
	return new_renderer(w, style_name, width)
}

Renderer_Write :: proc(r: ^Renderer, s: string) {
	renderer_write(r, s)
}

Renderer_Flush :: proc(r: ^Renderer) {
	renderer_flush(r)
}

Renderer_Close :: proc(r: ^Renderer) {
	renderer_close(r)
}

Renderer_Destroy :: proc(r: ^Renderer) {
	renderer_destroy(r)
}

New_Live_Box :: proc(w: io.Writer, width, height, limit: int) -> Live_Box {
	return new_live_box(w, width, height, limit)
}

Live_Box_Header :: proc(b: ^Live_Box, label: string, elided: int = 0) {
	live_box_header(b, label, elided)
}

Live_Box_Output_Header :: proc(b: ^Live_Box, label: string) {
	live_box_output_header(b, label)
}

Live_Box_Row :: proc(b: ^Live_Box, text: string) {
	live_box_row(b, text)
}

Live_Box_Out :: proc(b: ^Live_Box, text: string) {
	live_box_out(b, text)
}

Live_Box_Err :: proc(b: ^Live_Box, text: string) {
	live_box_err(b, text)
}

Live_Box_End :: proc(b: ^Live_Box, code: int) {
	live_box_end(b, code)
}

Live_Box_Destroy :: proc(b: ^Live_Box) {
	live_box_destroy(b)
}

Stdout_Is_Tty :: proc() -> bool {
	return stdout_is_tty()
}

Stderr_Is_Tty :: proc() -> bool {
	return stderr_is_tty()
}

Terminal_Size :: proc() -> (width, height: int, ok: bool) {
	return stdout_size()
}

Visible_Width :: proc(s: string) -> int {
	return visible_width(s)
}

Strip_ANSI :: proc(s: string) -> string {
	return strip_ansi(s)
}
