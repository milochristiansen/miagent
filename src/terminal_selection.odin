// Selection gestures, word/line/block selection, and keyboard selection.
package main

import "core:math"
import "core:strings"

SELECTION_REPEAT_INTERVAL_NS :: u64(500 * 1000 * 1000)
SELECTION_REPEAT_DISTANCE :: f64(5.0)
SELECTION_TICK_SECONDS :: f32(0.05)

terminal_selection_init :: proc(t: ^Terminal) -> bool {
	if ghostty_selection_gesture_new(nil, &t.gesture) != GHOSTTY_SUCCESS do return false
	if ghostty_selection_gesture_event_new(nil, &t.gesture_press, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS) != GHOSTTY_SUCCESS do return false
	if ghostty_selection_gesture_event_new(nil, &t.gesture_release, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE) != GHOSTTY_SUCCESS do return false
	if ghostty_selection_gesture_event_new(nil, &t.gesture_drag, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG) != GHOSTTY_SUCCESS do return false
	if ghostty_selection_gesture_event_new(nil, &t.gesture_autoscroll, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_AUTOSCROLL_TICK) != GHOSTTY_SUCCESS do return false
	return true
}

terminal_selection_destroy :: proc(t: ^Terminal) {
	if t.gesture_autoscroll != nil do ghostty_selection_gesture_event_free(t.gesture_autoscroll)
	if t.gesture_drag != nil do ghostty_selection_gesture_event_free(t.gesture_drag)
	if t.gesture_release != nil do ghostty_selection_gesture_event_free(t.gesture_release)
	if t.gesture_press != nil do ghostty_selection_gesture_event_free(t.gesture_press)
	if t.gesture != nil do ghostty_selection_gesture_free(t.gesture, t.gt)
	t.gesture = nil
	t.gesture_press = nil
	t.gesture_release = nil
	t.gesture_drag = nil
	t.gesture_autoscroll = nil
}

terminal_selection_reset :: proc(t: ^Terminal) {
	if t.gesture != nil do ghostty_selection_gesture_reset(t.gesture, t.gt)
	t.sel_dragging = false
	t.sel_moved = false
}

terminal_ref_at_cell :: proc(t: ^Terminal, cell: Terminal_Cell) -> (GhosttyGridRef, bool) {
	ref: GhosttyGridRef
	p: GhosttyPointValue
	p.coordinate = GhosttyPointCoordinate{x = cell.col, y = cell.row}
	if ghostty_terminal_grid_ref(t.gt, GhosttyPoint{tag = .VIEWPORT, value = p}, &ref) != GHOSTTY_SUCCESS {
		return {}, false
	}
	return ref, true
}

terminal_install_selection :: proc(t: ^Terminal, sel: ^GhosttySelection) -> bool {
	if sel == nil do return false
	if ghostty_terminal_set(t.gt, GHOSTTY_TERMINAL_OPT_SELECTION, sel) != GHOSTTY_SUCCESS do return false
	t.dirty = true
	return true
}

terminal_geometry :: proc(area: Rect, f: Fonts, cols: u16) -> GhosttySelectionGestureGeometry {
	return {
		columns = u32(cols),
		cell_width = u32(max(f.cell_w, 1)),
		padding_left = u32(TERM_PAD_X),
		screen_height = u32(max(area.h, 1)),
	}
}

// terminal_selection_press starts a gesture at a cell. The gesture returns a
// selection only for repeat clicks (word/line); a single click starts a drag
// without selecting anything yet. Any previous selection is cleared, and the
// return value reports whether the press was applied to the gesture state.
terminal_selection_press :: proc(t: ^Terminal, cell: Terminal_Cell, pos: GhosttySurfacePosition, time_ns: u64) -> bool {
	ref, ok := terminal_ref_at_cell(t, cell)
	if !ok do return false

	t.sel_anchor_col = cell.col
	t.sel_anchor_row = cell.row
	t.sel_moved = false
	terminal_clear_selection(t)

	repeat_ns := SELECTION_REPEAT_INTERVAL_NS
	repeat_dist := SELECTION_REPEAT_DISTANCE
	press_pos := pos
	press_time := time_ns
	behaviors := GhosttySelectionGestureBehaviors {
		single_click = GHOSTTY_SELECTION_GESTURE_BEHAVIOR_CELL,
		double_click = GHOSTTY_SELECTION_GESTURE_BEHAVIOR_WORD,
		triple_click = GHOSTTY_SELECTION_GESTURE_BEHAVIOR_LINE,
	}
	ghostty_selection_gesture_event_set(t.gesture_press, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
	ghostty_selection_gesture_event_set(t.gesture_press, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &press_pos)
	ghostty_selection_gesture_event_set(t.gesture_press, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS, &press_time)
	ghostty_selection_gesture_event_set(t.gesture_press, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS, &repeat_ns)
	ghostty_selection_gesture_event_set(t.gesture_press, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE, &repeat_dist)
	ghostty_selection_gesture_event_set(t.gesture_press, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_BEHAVIORS, &behaviors)

	sel: GhosttySelection
	res := ghostty_selection_gesture_event(t.gesture, t.gt, t.gesture_press, &sel)
	if res == GHOSTTY_SUCCESS {
		_ = terminal_install_selection(t, &sel)
		return true
	}
	return res == GHOSTTY_NO_VALUE
}

// terminal_selection_drag_to updates the active drag. The surface position is
// required: libghostty uses it for the within-cell selection threshold and to
// decide the autoscroll direction. Leaving it unset reads as (0, 0) -- the
// top-left edge -- which makes every drag look like it is above the surface
// (autoscrolling up forever) and can turn a same-cell click into a selection.
terminal_selection_drag_to :: proc(t: ^Terminal, cell: Terminal_Cell,
                                   pos: GhosttySurfacePosition,
                                   geometry: GhosttySelectionGestureGeometry,
                                   rectangle: bool) -> bool {
	ref, ok := terminal_ref_at_cell(t, cell)
	if !ok do return false
	drag_pos := pos
	drag_geometry := geometry
	drag_rectangle := rectangle
	ghostty_selection_gesture_event_set(t.gesture_drag, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
	ghostty_selection_gesture_event_set(t.gesture_drag, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &drag_pos)
	ghostty_selection_gesture_event_set(t.gesture_drag, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &drag_geometry)
	ghostty_selection_gesture_event_set(t.gesture_drag, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &drag_rectangle)

	sel: GhosttySelection
	res := ghostty_selection_gesture_event(t.gesture, t.gt, t.gesture_drag, &sel)
	if res == GHOSTTY_SUCCESS do return terminal_install_selection(t, &sel)
	// This drag position does not select a cell. Clear so dragging back to the
	// anchor does not leave a stale selection behind.
	if res == GHOSTTY_NO_VALUE do terminal_clear_selection(t)
	return false
}

// terminal_selection_autoscroll_to advances an edge-scroll drag. Position is
// passed again because libghostty re-evaluates autoscroll while continuing the
// drag; without it the tick would immediately think the pointer was at the top
// edge and keep scrolling up.
terminal_selection_autoscroll_to :: proc(t: ^Terminal, cell: Terminal_Cell,
                                         pos: GhosttySurfacePosition,
                                         geometry: GhosttySelectionGestureGeometry,
                                         rectangle: bool) -> bool {
	vp := GhosttyPointCoordinate{x = cell.col, y = cell.row}
	tick_pos := pos
	tick_geometry := geometry
	tick_rectangle := rectangle
	ghostty_selection_gesture_event_set(t.gesture_autoscroll, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_VIEWPORT, &vp)
	ghostty_selection_gesture_event_set(t.gesture_autoscroll, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &tick_pos)
	ghostty_selection_gesture_event_set(t.gesture_autoscroll, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &tick_geometry)
	ghostty_selection_gesture_event_set(t.gesture_autoscroll, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &tick_rectangle)

	sel: GhosttySelection
	res := ghostty_selection_gesture_event(t.gesture, t.gt, t.gesture_autoscroll, &sel)
	if res == GHOSTTY_SUCCESS {
		return terminal_install_selection(t, &sel)
	}
	if res == GHOSTTY_NO_VALUE do terminal_clear_selection(t)
	return false
}

terminal_selection_update :: proc(t: ^Terminal, area: Rect, f: Fonts, mouse: ImVec2, over_body, down: bool) {
	if !t.alive || t.gesture == nil || f.cell_w <= 0 || f.cell_h <= 0 do return
	cols, rows := terminal_grid_size(area, f)
	if cols == 0 || rows == 0 do return
	terminal_resize(t, cols, rows, f.cell_w, f.cell_h)

	inner := rect(area.x + TERM_PAD_X, area.y + TERM_PAD_Y,
		max(area.w - TERM_PAD_X * 2, 0), max(area.h - TERM_PAD_Y * 2, 0))
	cell := terminal_cell_at(inner, f, mouse, cols, rows)
	pos := GhosttySurfacePosition{x = f64(mouse.x - area.x), y = f64(mouse.y - area.y)}
	geometry := terminal_geometry(area, f, cols)

	pressed := down && !t.sel_was_down && over_body
	released := !down && t.sel_was_down
	t.sel_was_down = down

	if pressed {
		time_ns := u64(max(mi_io_time(), 0) * 1_000_000_000.0)
		if terminal_selection_press(t, cell, pos, time_ns) {
			t.sel_dragging = true
			t.sel_last_tick = mi_io_time()
		}
		return
	}

	if t.sel_dragging && down {
		if cell.col != t.sel_anchor_col || cell.row != t.sel_anchor_row do t.sel_moved = true
		rect_select := mi_io_key_alt() != 0
		_ = terminal_selection_drag_to(t, cell, pos, geometry, rect_select)

		// Edge autoscroll: ask the gesture for its preferred direction, scroll
		// one row, and feed it a tick with the clamped viewport coordinate.
		now := mi_io_time()
		if now - t.sel_last_tick >= SELECTION_TICK_SECONDS {
			autoscroll: i32 = GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_NONE
			_ = ghostty_selection_gesture_get(t.gesture, t.gt, GHOSTTY_SELECTION_GESTURE_DATA_AUTOSCROLL, &autoscroll)
			if autoscroll != GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_NONE {
				terminal_scroll(t, autoscroll == GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_UP ? -1 : 1)
				_ = terminal_selection_autoscroll_to(t, cell, pos, geometry, rect_select)
				t.sel_last_tick = now
			}
		}
		return
	}

	if released {
		if t.sel_dragging {
			ref, ok := terminal_ref_at_cell(t, cell)
			if ok do ghostty_selection_gesture_event_set(t.gesture_release, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
			_ = ghostty_selection_gesture_event(t.gesture, t.gt, t.gesture_release, nil)
		}
		t.sel_dragging = false
	}
}

terminal_select_all :: proc(t: ^Terminal) {
	if t.gt == nil do return
	sel: GhosttySelection
	if ghostty_terminal_select_all(t.gt, &sel) == GHOSTTY_SUCCESS {
		_ = terminal_install_selection(t, &sel)
	}
}

terminal_select_output :: proc(t: ^Terminal, cell: Terminal_Cell) {
	if t.gt == nil do return
	ref, ok := terminal_ref_at_cell(t, cell)
	if !ok do return
	sel: GhosttySelection
	if ghostty_terminal_select_output(t.gt, ref, &sel) == GHOSTTY_SUCCESS {
		_ = terminal_install_selection(t, &sel)
	}
}

terminal_selection_adjust :: proc(t: ^Terminal, adjustment: i32) {
	if t.gt == nil do return
	sel: GhosttySelection
	if ghostty_terminal_get(t.gt, GHOSTTY_TERMINAL_DATA_SELECTION, &sel) != GHOSTTY_SUCCESS do return
	if ghostty_terminal_selection_adjust(t.gt, &sel, adjustment) != GHOSTTY_SUCCESS do return
	_ = terminal_install_selection(t, &sel)
}


terminal_update_hover_cell :: proc(t: ^Terminal, area: Rect, f: Fonts, mouse: ImVec2, over_body: bool) {
	if !over_body || f.cell_w <= 0 || f.cell_h <= 0 {
		t.hover_cell_valid = false
		return
	}
	cols, rows := terminal_grid_size(area, f)
	if cols == 0 || rows == 0 {
		t.hover_cell_valid = false
		return
	}
	inner := rect(area.x + TERM_PAD_X, area.y + TERM_PAD_Y,
		max(area.w - TERM_PAD_X * 2, 0), max(area.h - TERM_PAD_Y * 2, 0))
	t.hover_cell = terminal_cell_at(inner, f, mouse, cols, rows)
	t.hover_cell_valid = true
}

terminal_update_hover_link :: proc(t: ^Terminal, over_body, allow: bool) -> bool {
	if !over_body || !allow || !t.hover_cell_valid {
		t.hover_link_valid = false
		return false
	}
	if t.hover_link_valid && t.hover_link_epoch == t.link_epoch &&
	   t.hover_cell.col == t.hover_link_cell.col && t.hover_cell.row == t.hover_link_cell.row {
		return len(t.hover_link_uri) > 0
	}

	delete(t.hover_link_uri)
	t.hover_link_uri = ""
	t.hover_link_valid = true
	t.hover_link_epoch = t.link_epoch
	t.hover_link_cell = t.hover_cell

	ref, ok := terminal_ref_at_cell(t, t.hover_cell)
	if !ok do return false
	needed: uint
	res := ghostty_grid_ref_hyperlink_uri(&ref, nil, 0, &needed)
	if res == GHOSTTY_SUCCESS {
		return false
	}
	if res != GHOSTTY_OUT_OF_SPACE || needed == 0 do return false
	buf := make([]u8, int(needed), context.temp_allocator)
	if ghostty_grid_ref_hyperlink_uri(&ref, raw_data(buf), needed, &needed) != GHOSTTY_SUCCESS {
		return false
	}
	if needed > 0 {
		t.hover_link_uri = strings.clone(string(buf[:needed]))
	}
	return needed > 0
}

terminal_link_allowed :: proc(uri: string) -> bool {
	return strings.has_prefix(uri, "http://") ||
	       strings.has_prefix(uri, "https://") ||
	       strings.has_prefix(uri, "mailto:")
}

terminal_open_link :: proc(t: ^Terminal) -> bool {
	if len(t.hover_link_uri) == 0 || !terminal_link_allowed(t.hover_link_uri) do return false
	return mi_open_uri(zstr(t.hover_link_uri)) >= 0
}
