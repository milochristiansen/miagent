// Small immediate-mode drawing helpers on top of the ImGui draw list.
package main

import "core:fmt"
import "core:math"
import "core:unicode/utf8"

// One place to scale all non-terminal UI typography. The terminal grid uses
// the raw mono size and cell metrics directly, so shells keep their configured
// font size.
UI_TEXT_SCALE :: f32(1.15)

// Pages can temporarily raise this to make their own text larger without
// changing the rest of the app (currently used by the details page only).
ui_text_extra_scale: f32 = 1.0

// Snap to whole pixels. ImGui rounds the size it bakes glyphs at but scales
// the resulting quads by the original requested size, so a fractional size
// (17.25px baked at 17px, for example) resamples the glyph bitmap and makes
// text look fuzzy. Keeping requested sizes integral also keeps measurement and
// drawing consistent.
ui_text_px :: proc(px: f32) -> f32 {
	return math.round(px * UI_TEXT_SCALE * ui_text_extra_scale)
}

ui_text_set_extra_scale :: proc(scale: f32) -> f32 {
	old := ui_text_extra_scale
	ui_text_extra_scale = scale
	return old
}

// Odin strings carry their length, so every C call passes it explicitly.
text :: proc(list: ^ImDrawList, x, y: f32, col: Color, s: string) {
	mi_draw_text_n(list, x, y, color_u32(col), cstr(s), uint(len(s)))
}

text_font :: proc(list: ^ImDrawList, font: ^ImFont, size, x, y: f32, col: Color, s: string) {
	if font == nil {
		text(list, x, y, col, s)
		return
	}
	mi_draw_text_font_n(list, font, ui_text_px(size), x, y, color_u32(col), cstr(s), uint(len(s)))
}

measure :: proc(font: ^ImFont, size: f32, s: string, wrap: f32 = 0) -> (w, h: f32) {
	if font != nil do mi_font_push_size(font, ui_text_px(size))
	mi_text_size_n(cstr(s), uint(len(s)), wrap, &w, &h)
	if font != nil do mi_font_pop()
	return
}

// measure_raw is for things that must stay independent of UI text scaling,
// chiefly terminal cell metrics.
measure_raw :: proc(font: ^ImFont, size: f32, s: string, wrap: f32 = 0) -> (w, h: f32) {
	if font != nil do mi_font_push_size(font, size)
	mi_text_size_n(cstr(s), uint(len(s)), wrap, &w, &h)
	if font != nil do mi_font_pop()
	return
}

text_wrapped :: proc(list: ^ImDrawList, font: ^ImFont, size, x, y, wrap: f32, col: Color, s: string) -> f32 {
	if font != nil do mi_font_push_size(font, ui_text_px(size))
	h := mi_draw_text_wrapped_n(list, x, y, wrap, color_u32(col), cstr(s), uint(len(s)))
	if font != nil do mi_font_pop()
	return h
}

// Format an ImGui id into caller storage and NUL-terminate it. ImGui's string
// ids are C strings, and fmt.tprintf results are not.
id_cstr :: proc(buf: []u8, format: string, args: ..any) -> cstring {
	s := fmt.bprintf(buf[:len(buf) - 1], format, ..args)
	buf[len(s)] = 0
	return cstring(raw_data(buf))
}

tooltip :: proc(s: string) {
	mi_tooltip_n(cstr(s), uint(len(s)))
}

dot :: proc(list: ^ImDrawList, x, y, r: f32, col: Color) {
	mi_draw_circle(list, x, y, r, color_u32(col))
}

// A rounded, optionally bordered panel.
panel :: proc(list: ^ImDrawList, r: Rect, fill: Color, radius: f32, border: Color = {0, 0, 0, 0}, border_w: f32 = 0) {
	if r.w <= 0 || r.h <= 0 do return
	mi_draw_rect(list, r.x, r.y, r.x + r.w, r.y + r.h, color_u32(fill), radius)
	if border_w > 0 && border[3] > 0 {
		mi_draw_rect_stroke(list, r.x + 0.5, r.y + 0.5, r.x + r.w - 0.5, r.y + r.h - 0.5, color_u32(border), radius, border_w)
	}
}

// Inclusive hover + click for an arbitrary rect.
hit :: proc(id: cstring, r: Rect) -> bool {
	return mi_hit(id, r.x, r.y, r.w, r.h)
}

button :: proc(
	list: ^ImDrawList,
	id: cstring,
	r: Rect,
	label: string,
	font: ^ImFont,
	size: f32,
	fg: Color,
	bg: Color,
	bg_hover: Color,
	bg_active: Color,
	radius: f32 = 7,
	border: Color = {0, 0, 0, 0},
) -> bool {
	clicked := hit(id, r)
	hovered := mi_hit_hovered()
	fill := bg
	if hovered do fill = bg_hover
	if mi_hit_active() do fill = bg_active
	if fill[3] > 0 do panel(list, r, fill, radius, border)
	if len(label) > 0 {
		tw, th := measure(font, size, label)
		text_font(list, font, size, r.x + (r.w - tw) * 0.5, r.y + (r.h - th) * 0.5, fg, label)
	}
	return clicked
}

icon_button :: proc(
	list: ^ImDrawList,
	id: cstring,
	r: Rect,
	glyph: string,
	font: ^ImFont,
	size: f32,
	fg: Color,
	hover_bg: Color,
	radius: f32 = 6,
) -> bool {
	clicked := hit(id, r)
	hovered := mi_hit_hovered()
	if hovered do panel(list, r, hover_bg, radius)
	if len(glyph) > 0 {
		tw, th := measure(font, size, glyph)
		text_font(list, font, size, r.x + (r.w - tw) * 0.5, r.y + (r.h - th) * 0.5, fg, glyph)
	}
	return clicked
}

// --- little vector glyphs --------------------------------------------------

glyph_plus :: proc(list: ^ImDrawList, cx, cy, s: f32, col: Color, thickness: f32 = 1.5) {
	mi_draw_line(list, cx - s, cy, cx + s, cy, color_u32(col), thickness)
	mi_draw_line(list, cx, cy - s, cx, cy + s, color_u32(col), thickness)
}

glyph_close :: proc(list: ^ImDrawList, cx, cy, s: f32, col: Color, thickness: f32 = 1.5) {
	mi_draw_line(list, cx - s, cy - s, cx + s, cy + s, color_u32(col), thickness)
	mi_draw_line(list, cx - s, cy + s, cx + s, cy - s, color_u32(col), thickness)
}

glyph_chevron_down :: proc(list: ^ImDrawList, cx, cy, s: f32, col: Color, thickness: f32 = 1.5) {
	mi_draw_line(list, cx - s, cy - s * 0.35, cx, cy + s * 0.45, color_u32(col), thickness)
	mi_draw_line(list, cx, cy + s * 0.45, cx + s, cy - s * 0.35, color_u32(col), thickness)
}

glyph_chevron_right :: proc(list: ^ImDrawList, cx, cy, s: f32, col: Color, thickness: f32 = 1.5) {
	mi_draw_line(list, cx - s * 0.35, cy - s, cx + s * 0.45, cy, color_u32(col), thickness)
	mi_draw_line(list, cx + s * 0.45, cy, cx - s * 0.35, cy + s, color_u32(col), thickness)
}


glyph_terminal :: proc(list: ^ImDrawList, cx, cy, s: f32, col: Color) {
	mi_draw_line(list, cx - s * 0.8, cy - s * 0.55, cx - s * 0.15, cy, color_u32(col), 1.4)
	mi_draw_line(list, cx - s * 0.15, cy, cx - s * 0.8, cy + s * 0.55, color_u32(col), 1.4)
	mi_draw_line(list, cx + s * 0.15, cy + s * 0.55, cx + s * 0.85, cy + s * 0.55, color_u32(col), 1.4)
}

glyph_search :: proc(list: ^ImDrawList, cx, cy, s: f32, col: Color) {
	mi_draw_rect_stroke(list, cx - s, cy - s, cx + s * 0.2, cy + s * 0.2, color_u32(col), s, 1.2)
	mi_draw_line(list, cx + s * 0.15, cy + s * 0.15, cx + s, cy + s, color_u32(col), 1.4)
}

glyph_paperclip :: proc(list: ^ImDrawList, cx, cy, s: f32, col: Color) {
	// A slim diagonal clip: an outer loop and a shorter inner return.
	mi_draw_line(list, cx - s * 0.45, cy + s * 0.75, cx + s * 0.55, cy - s * 0.35, color_u32(col), 1.25)
	mi_draw_line(list, cx + s * 0.55, cy - s * 0.35, cx + s * 0.55, cy - s * 0.75, color_u32(col), 1.25)
	mi_draw_line(list, cx + s * 0.55, cy - s * 0.75, cx + s * 0.15, cy - s * 1.0, color_u32(col), 1.25)
	mi_draw_line(list, cx + s * 0.15, cy - s * 1.0, cx - s * 0.75, cy - 0.1 * s, color_u32(col), 1.25)
	mi_draw_line(list, cx - s * 0.75, cy - 0.1 * s, cx - s * 0.75, cy + s * 0.55, color_u32(col), 1.25)
	mi_draw_line(list, cx - s * 0.75, cy + s * 0.55, cx - s * 0.35, cy + s * 0.95, color_u32(col), 1.25)
	mi_draw_line(list, cx - s * 0.35, cy + s * 0.95, cx + s * 0.2, cy + s * 0.4, color_u32(col), 1.25)
}

glyph_pencil :: proc(list: ^ImDrawList, cx, cy, s: f32, col: Color) {
	// Two parallel body edges, a pointed tip, and a short eraser cap.
	mi_draw_line(list, cx - s * 0.8, cy + s * 0.45, cx + s * 0.45, cy - s * 0.8, color_u32(col), 1.3)
	mi_draw_line(list, cx - s * 0.45, cy + s * 0.8, cx + s * 0.8, cy - s * 0.45, color_u32(col), 1.3)
	mi_draw_line(list, cx - s * 0.8, cy + s * 0.45, cx - s * 1.05, cy + s * 1.05, color_u32(col), 1.3)
	mi_draw_line(list, cx - s * 0.45, cy + s * 0.8, cx - s * 1.05, cy + s * 1.05, color_u32(col), 1.3)
	mi_draw_line(list, cx + s * 0.45, cy - s * 0.8, cx + s * 0.8, cy - s * 0.45, color_u32(col), 1.3)
}

glyph_gear :: proc(list: ^ImDrawList, cx, cy, s: f32, col: Color) {
	mi_draw_rect_stroke(list, cx - s * 0.45, cy - s * 0.45, cx + s * 0.45, cy + s * 0.45, color_u32(col), s * 0.45, 1.3)
	for i in 0 ..< 8 {
		a := f32(i) * math.PI * 0.25
		mi_draw_line(list,
			cx + math.cos(a) * s * 0.75, cy + math.sin(a) * s * 0.75,
			cx + math.cos(a) * s * 1.0, cy + math.sin(a) * s * 1.0,
			color_u32(col), 1.2)
	}
}

// Rounded status pill. Returns its width.
pill :: proc(list: ^ImDrawList, x, y, h: f32, label: string, font: ^ImFont, size: f32, fg: Color, bg: Color, border: Color = {0, 0, 0, 0}, pad: f32 = 9) -> f32 {
	tw, _ := measure(font, size, label)
	w := tw + pad * 2
	r := Rect{x, y, w, h}
	panel(list, r, bg, h * 0.5, border, border[3] > 0 ? 1 : 0)
	ts := ui_text_px(size)
	text_font(list, font, size, x + pad, y + (h - ts) * 0.5 - ts * 0.06, fg, label)
	return w
}

pill_dot :: proc(list: ^ImDrawList, x, y, h: f32, label: string, font: ^ImFont, size: f32, fg: Color, bg: Color, dot_col: Color) -> f32 {
	tw, _ := measure(font, size, label)
	w := tw + 30
	r := Rect{x, y, w, h}
	panel(list, r, bg, h * 0.5)
	dot(list, x + 11, y + h * 0.5, 3.2, dot_col)
	ts := ui_text_px(size)
	text_font(list, font, size, x + 20, y + (h - ts) * 0.5 - ts * 0.06, fg, label)
	return w
}

// Horizontal 1px rule.
rule :: proc(list: ^ImDrawList, x0, x1, y: f32, col: Color) {
	mi_draw_rect(list, x0, y, x1, y + 1, color_u32(col), 0)
}

// Vertical 1px rule.
vrule :: proc(list: ^ImDrawList, x, y0, y1: f32, col: Color) {
	mi_draw_rect(list, x, y0, x + 1, y1, color_u32(col), 0)
}

// Single line clipped to max_w, with a trailing ellipsis.
text_elided :: proc(list: ^ImDrawList, font: ^ImFont, size, x, y, max_w: f32, col: Color, s: string) -> f32 {
	tw, _ := measure(font, size, s)
	if tw <= max_w {
		text_font(list, font, size, x, y, col, s)
		return tw
	}
	ell := "..."
	ew, _ := measure(font, size, ell)
	budget := max_w - ew
	acc: f32 = 0
	i := 0
	for i < len(s) {
		_, sz := utf8.decode_rune_in_string(s[i:])
		if sz <= 0 do break
		cw, _ := measure(font, size, s[i:i + sz])
		if acc + cw > budget do break
		acc += cw
		i += sz
	}
	text_font(list, font, size, x, y, col, fmt.tprintf("%s%s", s[:i], ell))
	return max_w
}


// glyph_lock draws a tiny padlock for password-input cursors.
glyph_lock :: proc(list: ^ImDrawList, cx, cy, s: f32, col: Color) {
	w := s * 0.85
	h := s * 0.7
	body := rect(cx - w * 0.5, cy - h * 0.1, w, h)
	mi_draw_rect_stroke(list, body.x, body.y, body.x + body.w, body.y + body.h, color_u32(col), 1.5, 1.1)
	mi_draw_line(list, cx - w * 0.3, cy - h * 0.1, cx - w * 0.3, cy - h * 0.5, color_u32(col), 1.1)
	mi_draw_line(list, cx + w * 0.3, cy - h * 0.1, cx + w * 0.3, cy - h * 0.5, color_u32(col), 1.1)
	mi_draw_line(list, cx - w * 0.3, cy - h * 0.5, cx + w * 0.3, cy - h * 0.5, color_u32(col), 1.1)
}
