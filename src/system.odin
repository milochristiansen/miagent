// Small bindings for host integration shims implemented in portal.c.
package main

foreign import system "../build/libmiagent.a"

@(default_calling_convention = "c")
foreign system {
	mi_open_uri :: proc(uri: cstring) -> i32 ---
	mi_open_path :: proc(path: cstring) -> i32 ---
	mi_image_decode :: proc(data: rawptr, len: i32, w, h: ^i32) -> rawptr ---
	mi_image_free :: proc(pixels: rawptr) ---
	mi_image_http_get :: proc(url: cstring, max: uint, out_len: ^uint) -> rawptr ---
	mi_image_buf_free :: proc(p: rawptr) ---
}
