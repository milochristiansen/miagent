// Fixed regions of the shell: the projects pane on the left, the conversation,
// and the terminal rail and drawers on the right.
package main

import "core:fmt"

rail_bg :: proc(th: Theme) -> Color { return mix(th.bg, rgb(0, 0, 0), 0.30) }

// --- right rail ------------------------------------------------------------

draw_rail :: proc(app: ^App) {
	th := app.th
	p := app_active_project(app)
	r := rect(app.width - RAIL_W, 0, RAIL_W, app.height)
	if !mi_begin_panel("##rail", r.x, r.y, r.w, r.h, true) {
		igEnd()
		return
	}
	list := igGetWindowDrawList()
	panel(list, r, rail_bg(th), 0)
	vrule(list, r.x, 0, app.height, th.border_soft)

	y := r.y + 10
	if p != nil {
	for &d, i in p.drawers {
		// The whole rail row is clickable, including the accent bar at its
		// left edge; the rounded visual stays 32x32.
		row := rect(r.x, y, r.w, 32)
		tab := rect(r.x + 8, y, 32, 32)
		idbuf: [32]u8
		clicked := hit(id_cstr(idbuf[:], "drawertab%d", i), row)
		hovered := mi_hit_hovered()
		if d.open {
			panel(list, tab, th.bg_active, 8)
			panel(list, rect(tab.x - 8, tab.y + 8, 2.5, tab.h - 16), th.accent, 1.2)
		} else if hovered {
			panel(list, tab, th.bg_hover, 8)
		}
		label := fmt.tprintf("%d", i + 1)
		lw, lh := measure(app.f.mono, 13.0, label)
		text_font(list, app.f.mono, 13.0, tab.x + (tab.w - lw) * 0.5, tab.y + (tab.h - lh) * 0.5, d.open ? th.accent : th.fg_dim, label)
		if hovered do tooltip(d.name)
		if clicked do app_toggle_drawer(app, i)
		y += 38
	}
	}

	add_row := rect(r.x, y, r.w, 32)
	add_tab := rect(r.x + 8, y, 32, 32)
	clicked := hit(cstr("##newdrawer"), add_row)
	hovered := mi_hit_hovered()
	if hovered do panel(list, add_tab, th.bg_hover, 8)
	glyph_plus(list, add_tab.x + 16, add_tab.y + 16, 5.5, th.fg_dim, 1.4)
	if clicked do app_new_drawer(app)
	if hovered do tooltip("New shell")

	igEnd()
}

// --- drawers ---------------------------------------------------------------

// Slim scrollbar over the terminal's right padding. It only appears when the
// shell has scrollback; dragging it scrolls to an absolute row, and clicking
// the track centers the thumb there.
draw_terminal_scrollbar :: proc(app: ^App, list: ^ImDrawList, t: ^Terminal, index: int, area: Rect, th: Theme,
                                sb: GhosttyTerminalScrollbar, has_sb: bool) {
	if !has_sb do return

	max_off := f32(sb.total - sb.len)
	track := rect(area.x + area.w - 8, area.y + 6, 5, max(area.h - 18, 10))
	frac := f32(sb.len) / f32(sb.total)
	thumb_h := min(max(track.h * frac, 24.0), track.h)
	travel := track.h - thumb_h
	thumb_y := track.y
	if travel > 0 && max_off > 0 {
		thumb_y += travel * clamp(f32(sb.offset) / max_off, 0, 1)
	}
	thumb := rect(track.x, thumb_y, track.w, thumb_h)

	// Wider invisible strip for grabbing, submitted after the terminal body
	// hit so it takes priority on the right edge.
	strip := rect(area.x + area.w - 12, area.y + 4, 12, max(area.h - 8, 8))
	idbuf: [32]u8
	clicked := hit(id_cstr(idbuf[:], "termscroll%d", index), strip)
	hovered := mi_hit_hovered()
	active := mi_hit_active()

	if clicked {
		if app.mouse.y >= thumb.y && app.mouse.y <= thumb.y + thumb.h {
			t.scroll_grab = app.mouse.y - thumb.y
		} else {
			t.scroll_grab = thumb_h * 0.5
		}
	}
	if (clicked || active) && travel > 0 && max_off > 0 {
		ty := clamp(app.mouse.y - t.scroll_grab, track.y, track.y + travel)
		row := u64(clamp((ty - track.y) / travel * max_off, 0, max_off) + 0.5)
		if row != sb.offset do terminal_scroll_row(t, row)
		// Draw the thumb where the pointer put it this frame; the terminal's
		// scrollbar state catches up next frame.
		thumb.y = ty
	}
	if hovered || active do mi_io_set_mouse_cursor(i32(CURSOR_ARROW))

	// Track and thumb. Keep it subtle until the pointer is near it.
	if hovered || active {
		panel(list, track, alpha(th.fg, 0.07), 2.5)
	}
	panel(list, thumb, alpha(th.fg, active ? 0.45 : hovered ? 0.32 : 0.18), 2.5)
}

drawer_header_h :: f32(34)

draw_one_drawer :: proc(app: ^App, list: ^ImDrawList, p: ^Project, d: ^Drawer, index: int, r: Rect) {
	th := app.th
	focused := p.focus_drawer == index
	border := focused ? alpha(th.accent, 0.75) : th.border
	// Fill only for now; the border is stroked last so the terminal body can
	// never paint over it at the rounded corners.
	panel(list, r, th.bg, 10)

	// Header.
	hy := r.y + drawer_header_h * 0.5
	status := th.green
	if d.failed do status = th.red
	if d.spawned && !d.term.alive do status = th.red
	dot(list, r.x + 14, hy, 3.0, status)

	name_w := min(f32(190), r.w * 0.42)
	text_elided(list, app.f.mono, 12.5, r.x + 24, r.y + 9, name_w, th.fg_dim, d.name)

	cwd := d.spawned ? pwd_display(d.term.cwd, app.home) : pwd_display(p.path, app.home)
	cx := r.x + 24 + name_w + 6
	text_font(list, app.f.ui, 11.5, cx, r.y + 10, th.fg_faint, "·")
	cx += 10
	close_r := rect(r.x + r.w - 8 - 28, r.y + (drawer_header_h - 24) * 0.5, 28, 24)
	text_elided(list, app.f.ui, 11.5, cx, r.y + 10, close_r.x - cx - 8, th.fg_faint, cwd)

	idbuf: [32]u8
	if icon_button(list, id_cstr(idbuf[:], "drawerclose%d", index), close_r, "", app.f.ui, 13.0, th.fg_faint, th.bg_hover, 7) {
		app_close_drawer(app, index)
	}
	glyph_close(list, close_r.x + 14, close_r.y + 12, 3.8, th.fg_dim)

	// Body: round the bottom so it sits inside the panel's rounded border, and
	// keep only a few pixels between the header rule and the first row.
	body := rect(r.x + 1, r.y + drawer_header_h, r.w - 2, r.h - drawer_header_h - 1)
	mi_draw_rect_round_bottom(list, body.x, body.y, body.x + body.w, body.y + body.h, color_u32(th.term_bg), 9)
	rule(list, r.x + 1, r.x + r.w - 1, r.y + drawer_header_h, th.border_soft)

	term_area := body
	// Read the scrollbar state before creating the terminal's hit box, so the
	// terminal does not claim presses on the scrollbar strip.
	has_sb := false
	sb: GhosttyTerminalScrollbar
	if d.spawned {
		if ghostty_terminal_get(d.term.gt, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &sb) == GHOSTTY_SUCCESS &&
			sb.total > sb.len && sb.len > 0 {
			has_sb = true
		}
	}
	term_hit := term_area
	if has_sb do term_hit.w = max(term_hit.w - 12, 0)

	hovered := rect_contains(term_area, app.mouse.x, app.mouse.y)
	termid: [32]u8
	clicked := hit(id_cstr(termid[:], "drawerterm%d", index), term_hit)
	// Focus on the press edge too: an application that captures the mouse
	// needs the drawer selected before its press sequence is delivered, and
	// hit() only reports on release.
	if rect_contains(term_hit, app.mouse.x, app.mouse.y) && igIsMouseClicked_Bool(0, false) {
		p.focus_drawer = index
		focused = true
		border = alpha(th.accent, 0.75)
	}
	if clicked {
		p.focus_drawer = index
		focused = true
		border = alpha(th.accent, 0.75)
	}
	if mi_hit_hovered() do mi_io_set_mouse_cursor(i32(CURSOR_TEXT))

	if !d.spawned && !d.failed && d.anim >= 0.99 {
		cols, rows := terminal_grid_size(term_area, app.f)
		if cols > 0 && rows > 0 {
			res := terminal_init(&d.term, app.shell, p.path, app.th, cols, rows)
			if res == .Ok {
				d.spawned = true
			} else {
				d.failed = true
			}
		}
	}
	if !d.spawned {
		msg := d.failed ? "failed to start shell" : "starting shell..."
		mw, mh := measure(app.f.ui, 12.5, msg)
		text_font(list, app.f.ui, 12.5, term_area.x + (term_area.w - mw) * 0.5, term_area.y + (term_area.h - mh) * 0.5, th.fg_faint, msg)
	} else {
		over_body := rect_contains(term_hit, app.mouse.x, app.mouse.y)
		shift := mi_io_key_shift() != 0
		tracking := terminal_mouse_tracking(&d.term)
		if !tracking {
			d.term.mouse_grab = false
			d.term.mouse_have_cell = false
		}
		// While the application is tracking the mouse, a plain press/drag is
		// delivered to it (including motion outside the body once a press has
		// grabbed the pointer). Shift keeps the usual local text selection.
		report_mouse := tracking && ((over_body && !shift) || d.term.mouse_grab)
		wheel := hovered ? mi_io_wheel() : 0
		app_wheel := tracking && over_body && !shift
		if report_mouse {
			terminal_mouse_input(&d.term, term_area, app.f, app.mouse, over_body, shift,
				app_wheel ? wheel : 0)
		}
		// Suppress local selection while an application owns the gesture.
		selecting := !tracking || (shift && !d.term.mouse_grab)
		terminal_selection_update(&d.term, term_area, app.f, app.mouse, over_body,
			igIsMouseDown_Nil(0) && selecting)
		terminal_draw(&d.term, list, term_area, th, app.f, focused, app.now)
		draw_terminal_scrollbar(app, list, &d.term, index, term_area, th, sb, has_sb)

		if wheel != 0 && !app_wheel {
			terminal_scroll(&d.term, -i32(wheel * 3.0))
		}
		if focused && !app.shortcut_fired && mi_io_want_text_input() == 0 {
			terminal_handle_input(&d.term)
		}
	}

	// Border last.
	mi_draw_rect_stroke(list, r.x + 0.5, r.y + 0.5, r.x + r.w - 0.5, r.y + r.h - 0.5, color_u32(border), 10, 1)
}

draw_drawers :: proc(app: ^App) {
	p := app_active_project(app)
	if p == nil do return
	region_w := drawer_region_width(app)
	if region_w < 3 do return
	th := app.th
	x1 := app.width - RAIL_W
	x0 := x1 - region_w
	r := rect(x0, 0, region_w, app.height)
	if !mi_begin_panel("##drawers", r.x, r.y, r.w, r.h, true) {
		igEnd()
		return
	}
	list := igGetWindowDrawList()
	panel(list, r, rail_bg(th), 0)
	vrule(list, r.x, 0, app.height, th.border)
	if app.splitter_hovered || app.splitter_dragging {
		col := alpha(th.accent, app.splitter_dragging ? 0.95 : 0.55)
		mi_draw_rect(list, r.x, 0, r.x + 2, app.height, color_u32(col), 0)
	}

	// Collect open drawers and their animated weights.
	total: f32 = 0
	count := 0
	for &d in p.drawers {
		w := d.open ? d.anim : 0
		if w > 0.01 {
			total += w
			count += 1
		}
	}
	if total <= 0 || count == 0 {
		igEnd()
		return
	}

	gap: f32 = 8
	top := f32(8)
	bottom := app.height - 8
	avail := bottom - top - gap * f32(count - 1)
	cursor := top
	for &d, i in p.drawers {
		w := d.open ? d.anim : 0
		if w <= 0.01 do continue
		h := avail * (w / total)
		dr := rect(x0 + 8, cursor, region_w - 16, h)
		if dr.w > 40 && dr.h > 40 {
			draw_one_drawer(app, list, p, &d, i, dr)
		}
		cursor += h + gap
	}

	igEnd()
}
