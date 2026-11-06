// Drag selection over the conversation draw list. The transcript is drawn
// manually, so this records each drawn character with its screen rectangle and
// maps mouse positions back to those cells.
package main

import "core:math"
import "core:strings"

Sel_Item :: struct {
	msg_index: int,
	text:      string, // one rune (or a virtual space/newline) view; valid this frame
	rect:      Rect,
}

Sel_State :: struct {
	items:          [dynamic]Sel_Item,
	anchor:         int,
	cursor:         int,
	dragging:       bool,
	moved:          bool,
	mouse_was_down: bool,
}

Sel_Recorder :: struct {
	items:     ^[dynamic]Sel_Item,
	msg_index: int,
}

sel_init :: proc(s: ^Sel_State) {
	s.items = make([dynamic]Sel_Item, 0, 512)
	s.anchor = -1
	s.cursor = -1
}

sel_destroy :: proc(s: ^Sel_State) {
	delete(s.items)
}

sel_clear :: proc(s: ^Sel_State) {
	clear(&s.items)
	s.anchor = -1
	s.cursor = -1
	s.dragging = false
	s.moved = false
}

sel_begin_frame :: proc(s: ^Sel_State) {
	clear(&s.items)
}

sel_record_char :: proc(rec: ^Sel_Recorder, text: string, box: Rect) {
	if rec == nil || rec.items == nil || len(text) == 0 do return
	if len(rec.items) > 0 && rec.items[len(rec.items) - 1].msg_index != rec.msg_index {
		append(rec.items, Sel_Item{
			msg_index = rec.msg_index,
			text = "\n",
			rect = rect(box.x, box.y, 1, box.h),
		})
	}
	append(rec.items, Sel_Item{msg_index = rec.msg_index, text = text, rect = box})
}

sel_record_space :: proc(rec: ^Sel_Recorder, x, y, w, h: f32) {
	sel_record_char(rec, " ", rect(x, y, w, h))
}

sel_record_newline :: proc(rec: ^Sel_Recorder, x, y, h: f32) {
	sel_record_char(rec, "\n", rect(x, y, 1, h))
}

// sel_hovered reports whether the pointer is over a recorded selectable-text
// cell. Empty transcript space, headers, and gutters should keep the normal
// arrow cursor.
sel_hovered :: proc(s: ^Sel_State, px, py: f32) -> bool {
	for item in s.items {
		if rect_contains(item.rect, px, py) do return true
	}
	return false
}

sel_has_selection :: proc(s: ^Sel_State) -> bool {
	return s.anchor >= 0 && s.cursor >= 0 && s.anchor != s.cursor
}

sel_range :: proc(s: ^Sel_State) -> (lo, hi: int) {
	if s.anchor <= s.cursor do return s.anchor, s.cursor
	return s.cursor, s.anchor
}

sel_copy :: proc(s: ^Sel_State, whole_if_empty := false) -> string {
	if len(s.items) == 0 do return ""
	lo, hi := sel_range(s)
	if !sel_has_selection(s) {
		if !whole_if_empty do return ""
		lo, hi = 0, len(s.items) - 1
	}
	if lo < 0 || hi < lo do return ""
	b := strings.builder_make()
	for i := lo; i <= hi && i < len(s.items); i += 1 {
		strings.write_string(&b, s.items[i].text)
	}
	return strings.to_string(b)
}

// sel_nearest finds the text item closest to a point. Distance is measured to
// the item rectangle, so dragging below the transcript selects to the end and
// dragging between lines picks the closer line.
sel_nearest :: proc(s: ^Sel_State, px, py: f32) -> int {
	best := -1
	best_d: f32 = math.INF_F32
	for item, i in s.items {
		dx: f32 = 0
		dy: f32 = 0
		if px < item.rect.x do dx = item.rect.x - px
		else if px > item.rect.x + item.rect.w do dx = px - (item.rect.x + item.rect.w)
		if py < item.rect.y do dy = item.rect.y - py
		else if py > item.rect.y + item.rect.h do dy = py - (item.rect.y + item.rect.h)
		d := dx * dx + dy * dy
		// Prefer a real character over a virtual newline when both are at the
		// same position; otherwise clicking the first character of a line can
		// select the newline before it.
		if d < best_d || (d == best_d && best >= 0 && s.items[best].text == "\n" && item.text != "\n") {
			best_d = d
			best = i
		}
	}
	return best
}

sel_process_mouse :: proc(s: ^Sel_State, transcript: Rect, mouse: ImVec2) {
	if len(s.items) == 0 {
		s.mouse_was_down = igIsMouseDown_Nil(0)
		return
	}
	down := igIsMouseDown_Nil(0)
	inside := rect_contains(transcript, mouse.x, mouse.y) &&
		mouse.x < transcript.x + transcript.w - 14 // leave the scrollbar alone
	shift := mi_io_key_shift() != 0

	if down && !s.mouse_was_down {
		if inside {
			idx := sel_nearest(s, mouse.x, mouse.y)
			if idx >= 0 {
				if shift && s.anchor >= 0 {
					s.cursor = idx
				} else {
					s.anchor = idx
					s.cursor = idx
					s.moved = false
				}
				s.dragging = true
			}
		} else {
			s.anchor = -1
			s.cursor = -1
			s.dragging = false
		}
	} else if down && s.dragging && inside {
		idx := sel_nearest(s, mouse.x, mouse.y)
		if idx >= 0 {
			s.cursor = idx
			if s.anchor != s.cursor do s.moved = true
		}
	} else if !down && s.mouse_was_down {
		s.dragging = false
	}
	s.mouse_was_down = down
}

sel_draw_highlights :: proc(list: ^ImDrawList, s: ^Sel_State, th: Theme) {
	if !sel_has_selection(s) do return
	lo, hi := sel_range(s)
	i := lo
	for i <= hi && i < len(s.items) {
		item := s.items[i]
		y := item.rect.y
		msg := item.msg_index
		min_x := item.rect.x
		max_x := item.rect.x + item.rect.w
		h := item.rect.h
		j := i + 1
		for j <= hi && j < len(s.items) && s.items[j].msg_index == msg &&
		     math.abs(s.items[j].rect.y - y) < 0.6 {
			r := s.items[j].rect
			if r.x < min_x do min_x = r.x
			if r.x + r.w > max_x do max_x = r.x + r.w
			if r.h > h do h = r.h
			j += 1
		}
		panel(list, rect(min_x - 1, y, max(max_x - min_x + 2, 2), max(h, 1)),
			alpha(th.accent, 0.30), 2)
		i = j
	}
}
