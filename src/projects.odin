// Known projects and their archived sessions, shown in the right-hand session
// panel. Selecting the launch project returns to the live harness; selecting
// any other project (or an archive) loads a read-only conversation preview.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "harness"

PROJECTS_PANEL_W :: f32(300)
PROJECTS_HEADER_H :: f32(54)
PROJECT_ROW_H :: f32(54)
PROJECT_SESSION_ROW_H :: f32(42)
PROJECT_CURRENT_ROW_H :: f32(38)

Project :: struct {
	path:     string,
	name:     string,
	expanded: bool,
	loaded:   bool,
	sessions: []harness.Archived_Session,
	error:    string,

	// Runtime state, never persisted. Each project owns conversation tabs and a
	// shared set of terminal shells.
	tabs_initialized: bool,
	tabs:             [dynamic]^Conversation_Tab,
	active_tab:       int,
	session_name_editing:   bool,
	session_name_focus:     bool,
	session_name_was_active: bool,
	session_name_input:     [SESSION_NAME_MAX]u8,
	drawers:              [dynamic]Drawer,
	focus_drawer:         int,
	drawer_anim:          f32,
}

project_destroy :: proc(p: ^Project) {
	for t in p.tabs {
		conversation_tab_destroy(t)
		free(t)
	}
	delete(p.tabs)
	for &d in p.drawers {
		if d.spawned do terminal_destroy(&d.term)
		delete(d.name)
	}
	delete(p.drawers)
	delete(p.path)
	delete(p.name)
	delete(p.error)
	if p.sessions != nil do harness.archived_sessions_destroy(p.sessions)
	p^ = {}
}

project_state_dir :: proc(p: ^Project) -> string {
	return fmt.aprintf("%s/%s", p.path, harness.STATE_DIR)
}

project_default_session_path :: proc(p: ^Project) -> string {
	return fmt.aprintf("%s/%s/session.jsonl", p.path, harness.STATE_DIR)
}

project_name_for_path :: proc(path: string) -> string {
	name := os.base(path)
	if len(name) == 0 do return strings.clone(path)
	return strings.clone(name)
}

app_active_project :: proc(app: ^App) -> ^Project {
	if app.selected_project < 0 || app.selected_project >= len(app.projects) do return nil
	return app.projects[app.selected_project]
}

// app_projects_init turns the persisted paths into runtime rows. Missing paths
// are kept visible (and removable) rather than silently disappearing.
app_projects_init :: proc(app: ^App, gui: ^Gui_Config) {
	app.projects = make([dynamic]^Project, 0, max(len(gui.projects), 1))
	for gp in gui.projects {
		app_project_add(app, gp.path, true)
	}
	if len(app.projects) == 0 {
		app_project_add(app, app.cwd, true)
	}

	app.selected_project = -1
	for p, i in app.projects {
		if p.path == app.cwd {
			app.selected_project = i
			break
		}
	}
	if app.selected_project < 0 {
		if idx, _ := app_project_add(app, app.cwd, true); idx >= 0 {
			app.selected_project = idx
		} else if len(app.projects) > 0 {
			app.selected_project = 0
		}
	}
	app.selected_session = -1
}

app_projects_destroy :: proc(app: ^App) {
	for p in app.projects {
		project_destroy(p)
		free(p)
	}
	delete(app.projects)
}

// app_project_add returns the index of path, adding it when new. With
// allow_missing set, a path that does not exist is still recorded so a project
// on an unmounted drive can be shown and removed instead of vanishing. New
// projects start collapsed; expanding one is an explicit action.
app_project_add :: proc(app: ^App, path: string, allow_missing: bool) -> (int, string) {
	trimmed := strings.trim_space(path)
	if len(trimmed) == 0 do return -1, "project path is empty"
	resolved := trimmed
	if trimmed == "~" || strings.has_prefix(trimmed, "~/") {
		if home, herr := os.user_home_dir(context.temp_allocator); herr == nil {
			resolved = fmt.tprintf("%s%s", home, trimmed[1:])
		}
	}

	abs, aerr := filepath.abs(resolved, context.allocator)
	if aerr != nil do return -1, fmt.aprintf("resolving %s: %v", trimmed, aerr)

	for p, i in app.projects {
		if p.path == abs {
			delete(abs)
			return i, ""
		}
	}

	missing := false
	err_text := ""
	if st, serr := os.stat(abs, context.temp_allocator); serr != nil {
		if !allow_missing {
			msg := fmt.aprintf("%s: %v", abs, serr)
			delete(abs)
			return -1, msg
		}
		missing = true
		err_text = fmt.aprintf("%s: %v", abs, serr)
	} else if st.type != .Directory {
		msg := fmt.aprintf("%s is not a directory", abs)
		delete(abs)
		return -1, msg
	}

	p := new(Project)
	p^ = Project{
		path = abs,
		name = project_name_for_path(abs),
		loaded = missing,
		error = err_text,
		focus_drawer = -1,
		active_tab = -1,
		tabs = make([dynamic]^Conversation_Tab, 0, 4),
		drawers = make([dynamic]Drawer, 0, 4),
	}
	append(&app.projects, p)
	return len(app.projects) - 1, ""
}

// app_clear_no_projects leaves the GUI in an empty, ready-to-add state.
app_clear_no_projects :: proc(app: ^App) {
	app.selected_project = -1
	app.selected_session = -1
	app.preview_active = false
	delete(app.preview_title)
	app.preview_title = ""
	delete(app.preview_subtitle)
	app.preview_subtitle = ""
	view_clear_messages(&app.preview)
	delete(app.preview.session_path)
	app.preview.session_path = ""
	view_clear_messages(&app.blank_view)
	delete(app.blank_view.session_path)
	app.blank_view.session_path = ""
	view_add_note(&app.blank_view, "No projects open. Add one with + in the projects pane.")
	app.blank_view.scroll_pending = 2
	app.project_input[0] = 0
	app.project_input_open = false
	app.project_input_focus = false
	delete(app.project_input_error)
	app.project_input_error = ""
}

app_project_remove :: proc(app: ^App, index: int) -> string {
	if index < 0 || index >= len(app.projects) do return ""
	was_selected := index == app.selected_project
	p := app.projects[index]
	if p.session_name_editing do app_session_name_commit(p)
	project_destroy(p)
	free(p)
	ordered_remove(&app.projects, index)

	if was_selected {
		app.selected_project = -1
		app.selected_session = -1
		app.preview_active = false
		if len(app.projects) == 0 {
			app_clear_no_projects(app)
		} else {
			next := index < len(app.projects) ? index : len(app.projects) - 1
			app_select_project(app, next)
		}
	} else if app.selected_project > index {
		app.selected_project -= 1
	}
	return ""
}

project_refresh_sessions :: proc(app: ^App, index: int, force: bool) {
	if index < 0 || index >= len(app.projects) do return
	p := app.projects[index]
	if p.loaded && !force && len(p.error) == 0 do return

	// Reset the previous result before re-reading the directory.
	if p.sessions != nil {
		harness.archived_sessions_destroy(p.sessions)
		p.sessions = nil
	}
	delete(p.error)
	p.error = ""
	p.loaded = true

	if !os.exists(p.path) {
		p.error = fmt.aprintf("%s: directory not found", p.path)
		return
	}
	dir := project_state_dir(p)
	defer delete(dir)
	sessions, err := harness.list_archived_sessions(dir)
	if err != "" {
		p.error = err
		return
	}
	p.sessions = sessions
}

app_toggle_project :: proc(app: ^App, index: int) {
	if index < 0 || index >= len(app.projects) do return
	p := app.projects[index]
	p.expanded = !p.expanded
	if p.expanded do project_refresh_sessions(app, index, true)
}

// --- conversation previews -------------------------------------------------

app_preview_begin :: proc(app: ^App, title, subtitle: string) {
	view_clear_messages(&app.preview)
	delete(app.preview.session_path)
	app.preview.session_path = ""
	delete(app.preview_title)
	delete(app.preview_subtitle)
	app.preview_title = strings.clone(title)
	app.preview_subtitle = strings.clone(subtitle)
	app.preview_active = true
	app.preview.follow = true
	app.preview.scroll_pending = 6
	// Do not leave the hidden composer holding keyboard focus.
	igClearActiveID()
}

app_preview_archive :: proc(app: ^App, path, title, subtitle: string) {
	app_preview_begin(app, title, subtitle)
	app.preview.session_path = strings.clone(path)
	items, err := harness.harness_read_archive_items(path)
	if err != "" {
		view_add_error(&app.preview, err)
		delete(err)
		return
	}
	view_load_history(&app.preview, items, path)
	harness.harness_free_items(items)
}

// app_load_previewed_archive resumes the archive currently shown in the
// read-only preview. It queues the harness's direct archive-load action, which
// has the same semantics as /load: the project's current session is archived
// first, then the preview's archive is adopted. The preview is dismissed right
// away so the load notes and resulting transcript are visible in the live view.
app_load_previewed_archive :: proc(app: ^App) -> bool {
	if !app.preview_active do return false
	p := app_active_project(app)
	t := project_active_tab(p)
	if t == nil || !t.harness_ready do return false
	if len(app.preview.session_path) == 0 do return false
	if !harness.harness_load_archive(&t.harness, app.preview.session_path) do return false

	app.preview_active = false
	app.selected_session = -1
	t.details_open = false
	t.view.follow = true
	t.view.scroll_pending = 4
	t.composer_refocus = true
	return true
}

app_select_project :: proc(app: ^App, index: int) {
	if index < 0 || index >= len(app.projects) do return
	if old := app_active_project(app); old != nil && old.session_name_editing {
		app_session_name_commit(old)
	}
	p := app.projects[index]
	same_live_project := index == app.selected_project && !app.preview_active
	app.selected_project = index
	app.selected_session = -1
	app.preview_active = false
	p.session_name_editing = false
	app_project_ensure_runtime(app, p)
	if t := project_active_tab(p); !same_live_project && t != nil {
		t.view.follow = true
		t.view.scroll_pending = 4
		t.composer_refocus = true
	}
	app.mcp_status_refreshed = false
	app_refresh_mcp_status(app, true)
}

app_select_archive :: proc(app: ^App, project_index, session_index: int) {
	if project_index < 0 || project_index >= len(app.projects) do return
	p := app.projects[project_index]
	if session_index < 0 || session_index >= len(p.sessions) do return
	app_select_project(app, project_index)
	// An archive is a transcript preview, so make sure it is visible even if
	// the project's live session was showing the details page.
	if t := project_active_tab(p); t != nil do t.details_open = false
	p.session_name_editing = false
	app.selected_session = session_index
	a := p.sessions[session_index]
	desc := project_one_line(a.description)
	defer if len(desc) > 0 { delete(desc) }
	title := len(desc) > 0 ? desc : a.name
	stamp := archive_stamp_display(a.stamp)
	sub := fmt.tprintf("archived %s  ·  %s", stamp, a.name)
	app_preview_archive(app, a.path, title, sub)
}

app_add_project_from_input :: proc(app: ^App, text: string) -> string {
	idx, err := app_project_add(app, text, false)
	if err != "" do return err
	if idx < 0 do return "could not add project"
	app.selected_project = idx
	app.selected_session = -1
	app.project_input[0] = 0
	app.project_input_open = false
	app.project_input_focus = false
	delete(app.project_input_error)
	app.project_input_error = ""
	project_refresh_sessions(app, idx, true)
	app_select_project(app, idx)
	return ""
}

// --- active view helpers ---------------------------------------------------

app_active_view :: proc(app: ^App) -> ^Conversation_View {
	if app.preview_active do return &app.preview
	if t := app_active_tab(app); t != nil do return &t.view
	return &app.blank_view
}

app_active_harness :: proc(app: ^App) -> ^harness.Harness {
	if t := app_active_tab(app); t != nil && t.harness_ready do return &t.harness
	return nil
}

app_active_title :: proc(app: ^App) -> string {
	if app.preview_active && len(app.preview_title) > 0 do return app.preview_title
	if t := app_active_tab(app); t != nil && len(t.name) > 0 do return t.name
	if p := app_active_project(app); p != nil do return p.name
	return "No project open"
}

app_sync_gui_config :: proc(app: ^App, gui: ^Gui_Config) {
	for &p in gui.projects do delete(p.path)
	delete(gui.projects)
	gui.projects = make([]Gui_Project, len(app.projects))
	for p, i in app.projects {
		gui.projects[i] = Gui_Project{path = strings.clone(p.path)}
	}
	gui.version = GUI_CONFIG_VERSION
	gui.drawer_width = app.drawer_width > 0 ? int(app.drawer_width + 0.5) : 0
}

// --- formatting ------------------------------------------------------------

project_one_line :: proc(s: string) -> string {
	fields := strings.fields(s, context.temp_allocator)
	if len(fields) == 0 do return ""
	return strings.join(fields, " ", context.allocator)
}

archive_stamp_display :: proc(stamp: string) -> string {
	if len(stamp) != 16 do return stamp
	return fmt.tprintf("%s-%s-%s %s:%s", stamp[0:4], stamp[4:6], stamp[6:8], stamp[9:11], stamp[11:13])
}

// --- drawing ---------------------------------------------------------------

draw_project_row :: proc(app: ^App, list: ^ImDrawList, pi: int, p: ^Project, r: Rect) -> f32 {
	th := app.th
	selected := pi == app.selected_project
	hovered := rect_contains(r, app.mouse.x, app.mouse.y)
	if selected {
		panel(list, r, th.bg_active, 8)
	} else if hovered {
		panel(list, r, th.bg_hover, 8)
	}

	// Running / idle state lives on the card's left edge. Yellow means a turn
	// is running; green means the project has been opened and is idle; faint
	// means its harness has not been started yet.
	ready := project_any_tab_ready(p)
	running := project_any_tab_running(p)
	status_col := !ready ? th.fg_faint : running ? th.yellow : th.green
	panel(list, rect(r.x, r.y + 8, 3.0, r.h - 16), status_col, 1.5)

	chev := rect(r.x + 6, r.y + 8, 22, 22)
	chev_hover := rect_contains(chev, app.mouse.x, app.mouse.y)
	if chev_hover do panel(list, chev, th.bg_hover, 6)
	if p.expanded {
		glyph_chevron_down(list, chev.x + 11, chev.y + 11, 4.2, th.fg_faint)
	} else {
		glyph_chevron_right(list, chev.x + 11, chev.y + 11, 4.2, th.fg_faint)
	}

	name_col := selected ? th.fg : mix(th.fg, th.bg, 0.08)
	text_elided(list, app.f.ui, 14.5, r.x + 32, r.y + 10, r.w - 58, name_col, p.name)
	count := ""
	count_w: f32 = 0
	if p.loaded && len(p.error) == 0 && len(p.sessions) > 0 {
		count = fmt.tprintf("%d archived", len(p.sessions))
		count_w, _ = measure(app.f.ui, 10.5, count)
	}
	path := pwd_display(p.path, app.home)
	path_w := r.w - 44 - (count_w > 0 ? count_w + 8 : 0)
	text_elided(list, app.f.ui, 11.5, r.x + 32, r.y + 30, path_w, th.fg_faint, path)
	if len(count) > 0 {
		text_font(list, app.f.ui, 10.5, r.x + r.w - count_w - 12, r.y + 31, th.fg_faint, count)
	}

	idbuf: [32]u8
	chev_clicked := hit(id_cstr(idbuf[:], "projchev%d", pi), chev)
	body := rect(r.x + 30, r.y, r.w - 30 - 26, r.h)
	body_clicked := hit(id_cstr(idbuf[:], "projrow%d", pi), body)
	if chev_clicked {
		app_toggle_project(app, pi)
	} else if body_clicked {
		app_select_project(app, pi)
	}

	if hovered {
		close_r := rect(r.x + r.w - 24, r.y + 15, 22, 22)
		if icon_button(list, id_cstr(idbuf[:], "projrm%d", pi), close_r, "", app.f.ui, 11.0, th.fg_faint, th.bg_hover, 6) {
			app.project_remove_pending = pi
		}
		glyph_close(list, close_r.x + 11, close_r.y + 11, 3.3, th.fg_faint)
		if rect_contains(close_r, app.mouse.x, app.mouse.y) do tooltip("Remove from known projects")
	}
	return r.h
}

draw_project_sessions :: proc(app: ^App, list: ^ImDrawList, pi: int, p: ^Project, x, y, w: f32) -> f32 {
	th := app.th
	start := y
	yy := y

	// Current session row.
	cur := rect(x + 20, yy, w - 26, PROJECT_CURRENT_ROW_H)
	cur_selected := pi == app.selected_project && app.selected_session < 0 && !app.preview_active
	cur_hover := rect_contains(cur, app.mouse.x, app.mouse.y)
	if cur_selected {
		panel(list, cur, th.bg_active, 7)
	} else if cur_hover {
		panel(list, cur, th.bg_hover, 7)
	}
	if pi == app.selected_project {
		dot(list, cur.x + 11, cur.y + 14, 3.0, th.green)
	} else {
		dot(list, cur.x + 11, cur.y + 14, 3.0, th.fg_faint)
	}
	text_font(list, app.f.ui, 12.5, cur.x + 22, cur.y + 6, th.fg_dim, "Current session")
	has_session := false
	if t := project_active_tab(p); t != nil {
		has_session = os.exists(t.session_path)
	} else {
		path := project_default_session_path(p)
		has_session = os.exists(path)
		delete(path)
	}
	detail := has_session ? "on disk" : "not started"
	text_font(list, app.f.ui, 10.5, cur.x + 22, cur.y + 22, th.fg_faint, detail)
	idbuf: [32]u8
	if hit(id_cstr(idbuf[:], "projcur%d", pi), cur) do app_select_project(app, pi)
	yy += PROJECT_CURRENT_ROW_H

	if p.error != "" {
		eh := plain_wrapped_height(app.f.ui, 10.5, w - 52, p.error)
		text_wrapped(list, app.f.ui, 10.5, x + 34, yy + 4, w - 52, alpha(th.red, 0.85), p.error)
		yy += eh + 10
	} else if p.loaded && len(p.sessions) == 0 {
		text_font(list, app.f.ui, 11.0, x + 34, yy + 4, th.fg_faint, "No archived sessions")
		yy += 26
	} else {
		for a, si in p.sessions {
			row := rect(x + 20, yy, w - 26, PROJECT_SESSION_ROW_H)
			selected := pi == app.selected_project && si == app.selected_session
			hover := rect_contains(row, app.mouse.x, app.mouse.y)
			if selected {
				panel(list, row, th.bg_active, 7)
				panel(list, rect(row.x, row.y + 8, 2.0, row.h - 16), th.accent, 1.0)
			} else if hover {
				panel(list, row, th.bg_hover, 7)
			}
			desc := project_one_line(a.description)
			label := len(desc) > 0 ? desc : a.name
			text_elided(list, app.f.ui, 12.0, row.x + 12, row.y + 6, row.w - 24, selected ? th.fg : th.fg_dim, label)
			stamp := archive_stamp_display(a.stamp)
			text_font(list, app.f.ui, 10.5, row.x + 12, row.y + 23, th.fg_faint, stamp)
			if len(desc) > 0 do delete(desc)
			if hit(id_cstr(idbuf[:], "projarc%d-%d", pi, si), row) {
				app_select_archive(app, pi, si)
			}
			yy += PROJECT_SESSION_ROW_H
		}
	}
	return yy - start
}

MCP_CARD_H :: f32(58)

draw_mcp_status_card :: proc(app: ^App, list: ^ImDrawList, x, y, w: f32) {
	th := app.th
	status := app.mcp_status
	r := rect(x, y, w, MCP_CARD_H)
	panel(list, r, th.bg_raised, 8, th.border_soft, 1)

	failed := 0
	for s in status.servers {
		if s.state == "failed" || s.state == "closed" do failed += 1
	}
	dot_col := th.red
	state_text := "offline"
	if status.running {
		if failed > 0 {
			dot_col = th.yellow
			state_text = "degraded"
		} else {
			dot_col = th.green
			state_text = "ready"
		}
	}

	text_font(list, app.f.ui, 10.5, r.x + 12, r.y + 9, th.fg_faint, "MCP BRIDGE")
	state_w, _ := measure(app.f.ui, 10.5, state_text)
	dot(list, r.x + r.w - 12 - state_w - 12, r.y + 15, 3.2, dot_col)
	text_font(list, app.f.ui, 10.5, r.x + r.w - 12 - state_w, r.y + 9, mix(th.fg, dot_col, 0.35), state_text)

	line := ""
	if status.running {
		line = fmt.tprintf("%d server%s · %d tool%s", len(status.servers), len(status.servers) == 1 ? "" : "s", status.tool_count, status.tool_count == 1 ? "" : "s")
	} else {
		line = "background host not running"
	}
	text_elided(list, app.f.ui, 11.5, r.x + 12, r.y + 25, r.w - 24, th.fg_dim, line)
	sub := status.running ? fmt.tprintf("pid %d · survives agent restarts", status.pid) : "tools will start it on demand"
	text_elided(list, app.f.ui, 10.0, r.x + 12, r.y + 42, r.w - 24, th.fg_faint, sub)

	if rect_contains(r, app.mouse.x, app.mouse.y) {
		detail := strings.builder_make()
		defer delete(detail.buf)
		if len(status.error) > 0 {
			strings.write_string(&detail, status.error)
			strings.write_byte(&detail, '\n')
		}
		for s in status.servers {
			fmt.sbprintf(&detail, "%s [%s] %s · %d tools%s", s.name, s.transport, s.state, s.tool_count, s.resources ? " + resources" : "")
			if len(s.error) > 0 do fmt.sbprintf(&detail, "\n  %s", s.error)
			if len(s.log_tail) > 0 do fmt.sbprintf(&detail, "\n  log: %s", s.log_tail)
			strings.write_byte(&detail, '\n')
		}
		if strings.builder_len(detail) > 0 do tooltip(strings.to_string(detail))
	}
}

draw_projects :: proc(app: ^App) {
	th := app.th
	r := rect(0, 0, PROJECTS_PANEL_W, app.height)
	if !mi_begin_panel("##projects", r.x, r.y, r.w, r.h, true) {
		igEnd()
		return
	}
	list := igGetWindowDrawList()
	panel(list, r, rail_bg(th), 0)
	vrule(list, r.x + r.w - 1, 0, app.height, th.border_soft)

	x := r.x + 14
	w := r.w - 28
	y := r.y + 16

	text_font(list, app.f.ui, 11.5, x, y, th.fg_faint, "PROJECTS")
	count := fmt.tprintf("%d", len(app.projects))
	text_font(list, app.f.ui, 10.5, x + 74, y + 1, th.fg_faint, count)

	add_r := rect(r.x + r.w - 14 - 24, y - 5, 24, 24)
	if icon_button(list, cstr("##addproject"), add_r, "", app.f.ui, 12.0, th.fg_dim, th.bg_hover, 6) {
		app_open_project_picker(app)
	}
	if app.folder_picker.running {
		dot(list, add_r.x + 12, add_r.y + 12, 3.2, th.yellow)
	} else {
		glyph_plus(list, add_r.x + 12, add_r.y + 12, 4.5, th.fg_dim, 1.4)
	}
	if rect_contains(add_r, app.mouse.x, app.mouse.y) {
		tooltip(app.folder_picker.running ? "Choose a project folder..." : "Add a known project")
	}

	header_h := PROJECTS_HEADER_H
	if app.project_input_open {
		field := rect(x, y + 22, w, 34)
		panel(list, field, th.bg_raised, 7, th.border_soft, 1)
		igPushStyleColor_Vec4(COL_FRAME_BG, ImVec4{0, 0, 0, 0})
		mi_set_cursor_screen(field.x + 7, field.y + 6)
		if app.project_input_focus {
			igSetKeyboardFocusHere(0)
			app.project_input_focus = false
		}
		igSetNextItemWidth(field.w - 14)
		igInputText("##projectpath", &app.project_input[0], uint(len(app.project_input)), 0, nil, nil)
		active := igIsItemActive()
		igPopStyleColor(1)
		if app.project_input[0] == 0 {
			text_font(list, app.f.ui, 13.0, field.x + 8, field.y + 8, th.fg_faint, "project path...")
		}
		if active && igIsKeyPressed_Bool(KEY_ENTER, false) {
			text := string(cstring(&app.project_input[0]))
			if err := app_add_project_from_input(app, text); err != "" {
				delete(app.project_input_error)
				app.project_input_error = strings.clone(err)
			}
		}
		if igIsKeyPressed_Bool(KEY_ESCAPE, false) {
			app.project_input_open = false
			app.project_input[0] = 0
			app.project_input_focus = false
			delete(app.project_input_error)
			app.project_input_error = ""
		}
		header_h = PROJECTS_HEADER_H + 42
	}

	list_y := r.y + header_h
	card_space: f32 = app.mcp_configured ? MCP_CARD_H + 12 : 0
	list_h := max(r.y + r.h - list_y - card_space, 20)
	mi_set_cursor_screen(r.x, list_y)
	if igBeginChild_Str("##projectlist", ivec2(r.w, list_h), CHILD_NONE, ImGuiWindowFlags(0)) {
		child_list := igGetWindowDrawList()
		origin := mi_cursor_screen()
		y2 := origin.y
		content_w := r.w - 20
		for p, pi in app.projects {
			row := rect(origin.x + 6, y2, content_w, PROJECT_ROW_H)
			y2 += draw_project_row(app, child_list, pi, p, row)
			if p.expanded {
				y2 += draw_project_sessions(app, child_list, pi, p, origin.x + 6, y2, content_w)
				y2 += 6
			}
		}
		if len(app.projects) == 0 {
			text_font(child_list, app.f.ui, 12.0, origin.x + 16, y2 + 8, th.fg_faint, "No known projects")
			y2 += 32
		}
		if app.project_input_error != "" {
			y2 += 6
			eh := plain_wrapped_height(app.f.ui, 10.5, content_w - 24, app.project_input_error)
			text_wrapped(child_list, app.f.ui, 10.5, origin.x + 14, y2, content_w - 24, alpha(th.red, 0.9), app.project_input_error)
			y2 += eh + 10
		}
		mi_set_cursor_screen(origin.x, y2)
		igDummy(ivec2(1, y2 - origin.y))
	}
	igEndChild()

	if app.mcp_configured {
		draw_mcp_status_card(app, list, r.x + 14, r.y + r.h - MCP_CARD_H - 12, r.w - 28)
	}

	igEnd()
}
