package main

import "core:strings"
import "core:unicode/utf8"

Rect :: struct {
	x, y, w, h: f32,
}

rect :: proc(x, y, w, h: f32) -> Rect { return Rect{x, y, w, h} }
rect_x1 :: proc(r: Rect) -> f32 { return r.x + r.w }
rect_y1 :: proc(r: Rect) -> f32 { return r.y + r.h }
rect_contains :: proc(r: Rect, px, py: f32) -> bool {
	return px >= r.x && px <= r.x + r.w && py >= r.y && py <= r.y + r.h
}
rect_inset :: proc(r: Rect, d: f32) -> Rect {
	return Rect{r.x + d, r.y + d, max(r.w - d * 2, 0), max(r.h - d * 2, 0)}
}
ease_out_cubic :: proc(t: f32) -> f32 {
	u := clamp(t, 0, 1)
	return 1 - (1 - u) * (1 - u) * (1 - u)
}

// ImGui's packed color is ABGR in little-endian memory.
pack_color :: proc(r, g, b, a: f32) -> ImU32 {
	ri := u32(clamp(r, 0, 1) * 255.0 + 0.5)
	gi := u32(clamp(g, 0, 1) * 255.0 + 0.5)
	bi := u32(clamp(b, 0, 1) * 255.0 + 0.5)
	ai := u32(clamp(a, 0, 1) * 255.0 + 0.5)
	return ImU32(ri | (gi << 8) | (bi << 16) | (ai << 24))
}

color_eq :: proc(a, b: Color) -> bool {
	return a[0] == b[0] && a[1] == b[1] && a[2] == b[2] && a[3] == b[3]
}

color_from_ghostty :: proc(c: GhosttyColorRgb) -> Color {
	return rgb(c.r, c.g, c.b)
}

cstr :: proc(s: string) -> cstring {
	return cstring(raw_data(s))
}

// NUL-terminated copy for C APIs that require a real C string. Odin strings
// are not guaranteed to be terminated.
zstr :: proc(s: string, allocator := context.temp_allocator) -> cstring {
	b := make([]u8, len(s) + 1, allocator)
	copy(b, s)
	b[len(s)] = 0
	return cstring(raw_data(b))
}

utf8_encode :: proc(cp: rune, buf: []u8) -> int {
	encoded, n := utf8.encode_rune(cp)
	copy(buf, encoded[:n])
	return n
}

// OSC 7 hands us file://host/path URIs; strip the URI down to a path before
// shortening it for display.
pwd_display :: proc(pwd: string, home: string, allocator := context.temp_allocator) -> string {
	p := pwd
	if strings.has_prefix(p, "file://") {
		rest := p[7:]
		if i := strings.index(rest, "/"); i >= 0 {
			p = rest[i:]
		}
	}
	if strings.contains(p, "%") {
		b := strings.builder_make(allocator)
		i := 0
		for i < len(p) {
			if p[i] == '%' && i + 2 < len(p) {
				hi, ok_hi := hex_digit(p[i + 1])
				lo, ok_lo := hex_digit(p[i + 2])
				if ok_hi && ok_lo {
					strings.write_byte(&b, u8(hi * 16 + lo))
					i += 3
					continue
				}
			}
			strings.write_byte(&b, p[i])
			i += 1
		}
		p = strings.to_string(b)
	}
	return shorten_home(p, home, allocator)
}

hex_digit :: proc(c: u8) -> (int, bool) {
	switch {
	case c >= '0' && c <= '9': return int(c - '0'), true
	case c >= 'a' && c <= 'f': return int(c - 'a') + 10, true
	case c >= 'A' && c <= 'F': return int(c - 'A') + 10, true
	}
	return 0, false
}

// "~/Projects/MiAgent" from "/home/milo/Projects/MiAgent"
shorten_home :: proc(path: string, home: string, allocator := context.temp_allocator) -> string {
	if len(home) > 0 && len(path) >= len(home) && path[:len(home)] == home {
		return strings.concatenate({"~", path[len(home):]}, allocator)
	}
	return path
}
