// Small bindings for host integration shims implemented in portal.c.
package main

foreign import system "../build/libmiagent.a"

@(default_calling_convention = "c")
foreign system {
	mi_open_uri :: proc(uri: cstring) -> i32 ---
}
