// Application state and frame orchestration.
package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "harness"
import "mcp"

RAIL_W   :: f32(48)
// Width of the invisible grab zone centred on the drawer/conversation splitter.
SPLITTER_GRAB_W :: f32(9)
// The shell drawer may be dragged narrower than its default, but not so narrow
// that a terminal becomes unusable.
DRAWER_MIN_W :: f32(260)
MCP_STATUS_INTERVAL :: f32(2.0)

UI_PX      :: f32(15.0)
UI_SMALL   :: f32(11.5)
UI_TINY    :: f32(10.0)
MONO_PX    :: f32(15.0)
MONO_SMALL :: f32(11.5)

Drawer :: struct {
	term:    ^Terminal,
	name:    string,
	open:    bool,
	anim:    f32,
	spawned: bool,
	failed:  bool,
}

Mcp_Status_Poller :: struct {
	running: bool,
	done:    bool,
	project: string,
	status:  mcp.Host_Status,
	mutex:   sync.Mutex,
	thread:  ^thread.Thread,
}

App :: struct {
	th: Theme,
	f:  Fonts,

	width, height: f32,
	window_focused: bool,
	mouse:         ImVec2,
	now, dt:       f32,

	// Projects is the runtime view of the persisted known-project list; it is
	// copied back into gui_config before the app exits. Each Project owns its
	// harness and terminal shells.
	projects:               [dynamic]^Project,
	selected_project:       int,
	selected_session:       int,
	project_input:          [512]u8,
	project_input_open:     bool,
	project_input_focus:    bool,
	project_input_error:    string,
	project_remove_pending: int,

	// Archive previews are read-only transcripts laid over the active
	// project's conversation. Live project state lives in Project.
	preview:          Conversation_View,
	preview_active:   bool,
	preview_title:    string,
	preview_subtitle: string,

	// Markdown image textures and the optional expanded image overlay.
	image_cache:  Image_Cache,
	image_viewer: Image_Viewer,
	blank_view:       Conversation_View,

	folder_picker:     Folder_Picker,
	attachment_picker: Attachment_Picker,

	// The MCP status card is only shown when the active project has MCP
	// configuration. It is refreshed at a low frequency so a dead host never
	// stalls a frame for long.
	mcp_configured:      bool,
	mcp_status:          mcp.Host_Status,
	mcp_status_project:  string,
	mcp_status_at:       f32,
	mcp_status_refreshed: bool,
	mcp_poller:           Mcp_Status_Poller,

	shell: string,
	home:  string,
	cwd:   string,

	// Agent turn ends play a short tone; gui.json can mute it without
	// rebuilding. Slash commands and other non-turn actions stay silent.
	mute_audio: bool,

	// Draggable shell-drawer width. Zero means the automatic default; a
	// non-zero value is a user override, persisted in gui.json.
	drawer_width: f32,
	// Splitter interaction state. The drag is driven from raw mouse input so
	// the conversation can use the new width in the same frame it is updated.
	splitter_dragging:  bool,
	splitter_hovered:   bool,
	splitter_was_down:  bool,

	shortcut_fired: bool,
}

app_init :: proc(app: ^App, f: Fonts, th: Theme, gui: ^Gui_Config, extra_note: string = "") {
	app.th = th
	app.f = f
	app.selected_project = -1
	app.selected_session = -1
	app.project_remove_pending = -1
	app.shell = strings.clone(default_shell(), context.allocator)
	app.mute_audio = gui.mute_audio
	if gui.drawer_width > 0 do app.drawer_width = f32(gui.drawer_width)
	audio_alert_init()
	terminal_runtime_init()
	home, _ := os.user_home_dir(context.allocator)
	app.home = home
	cwd, cwd_err := os.get_working_directory(context.allocator)
	if cwd_err != nil || len(cwd) == 0 {
		cwd = strings.clone(app.home)
		if len(cwd) == 0 do cwd = strings.clone(".")
	}
	app.cwd = cwd

	view_init(&app.preview)
	view_init(&app.blank_view)
	image_cache_init(&app.image_cache)
	app_projects_init(app, gui)
	if app.selected_project >= 0 do app_select_project(app, app.selected_project)

	// Dev aid: open one shell drawer on launch for screenshots/smoke tests.
	if len(os.get_env("MIAGENT_DRAWER", context.temp_allocator)) > 0 {
		app_new_drawer(app)
	}

	if len(extra_note) > 0 {
		view_add_error(app_active_view(app), extra_note)
	}

	// Dev aid: submit one prompt on launch, for screenshots and smoke runs.
	if prompt := os.get_env("MIAGENT_PROMPT", context.temp_allocator); len(prompt) > 0 {
		if t := app_active_tab(app); t != nil && t.harness_ready {
			harness.harness_submit(&t.harness, prompt)
		}
	}
	// Dev aid: open the internal details page on launch, for screenshots.
	if len(os.get_env("MIAGENT_DETAILS", context.temp_allocator)) > 0 {
		if t := app_active_tab(app); t != nil {
			t.details_open = true
			t.details.dirty = true
		}
	}
}

app_destroy :: proc(app: ^App) {
	for p in app.projects {
		if p.session_name_editing do app_session_name_commit(p)
	}
	app_projects_destroy(app)
	view_destroy(&app.preview)
	view_destroy(&app.blank_view)
	image_viewer_close(&app.image_viewer)
	image_cache_destroy(&app.image_cache)
	delete(app.preview_title)
	delete(app.preview_subtitle)
	folder_picker_destroy(&app.folder_picker)
	attachment_picker_destroy(&app.attachment_picker)
	mcp_status_poller_destroy(app)
	app_clear_mcp_status(app)
	delete(app.project_input_error)
	delete(app.shell)
	delete(app.home)
	delete(app.cwd)
}

// --- terminal drawers ------------------------------------------------------

app_new_drawer :: proc(app: ^App) {
	p := app_active_project(app)
	if p == nil do return
	name := fmt.tprintf("shell %d", len(p.drawers) + 1)
	term := new(Terminal)
	append(&p.drawers, Drawer{
		term = term,
		name = strings.clone(name, context.allocator),
		open = true,
	})
	p.focus_drawer = len(p.drawers) - 1
}

app_toggle_drawer :: proc(app: ^App, i: int) {
	p := app_active_project(app)
	if p == nil || i < 0 || i >= len(p.drawers) do return
	d := &p.drawers[i]
	d.open = !d.open
	if d.open {
		p.focus_drawer = i
	} else if p.focus_drawer == i {
		p.focus_drawer = -1
		for j in 0 ..< len(p.drawers) {
			if p.drawers[j].open {
				p.focus_drawer = j
				break
			}
		}
	}
}

app_close_drawer :: proc(app: ^App, i: int) {
	p := app_active_project(app)
	if p == nil || i < 0 || i >= len(p.drawers) do return
	p.drawers[i].open = false
	if p.focus_drawer == i {
		p.focus_drawer = -1
		for j in 0 ..< len(p.drawers) {
			if p.drawers[j].open {
				p.focus_drawer = j
				break
			}
		}
	}
}

app_running_count :: proc(app: ^App) -> int {
	count := 0
	for p in app.projects {
		for t in p.tabs {
			if t.harness_ready && harness.harness_is_busy(&t.harness) do count += 1
		}
	}
	return count
}

drawer_max_width :: proc(app: ^App) -> f32 {
	// The drawer pushes the conversation rather than covering it, so cap it at
	// whatever still leaves the center a usable width.
	max_w := app.width - PROJECTS_PANEL_W - RAIL_W - 440
	if max_w < 300 do max_w = 300
	return max_w
}

drawer_base_width :: proc(app: ^App) -> f32 {
	w := clamp(app.width * 0.40, 380, 680)
	if app.drawer_width > 0 do w = app.drawer_width
	return clamp(w, DRAWER_MIN_W, drawer_max_width(app))
}

drawer_region_width :: proc(app: ^App) -> f32 {
	p := app_active_project(app)
	if p == nil do return 0
	return drawer_base_width(app) * ease_out_cubic(p.drawer_anim)
}

// app_update_splitter handles the draggable bar between the conversation and
// the shell drawers. It runs before drawing, so the conversation pane and the
// drawer use the new width in the same frame.
app_update_splitter :: proc(app: ^App) {
	if app.image_viewer.open {
		app.splitter_hovered = false
		app.splitter_dragging = false
		app.splitter_was_down = igIsMouseDown_Nil(0)
		return
	}
	app.splitter_hovered = false
	down := igIsMouseDown_Nil(0)
	defer app.splitter_was_down = down

	p := app_active_project(app)
	if p == nil {
		app.splitter_dragging = false
		return
	}
	any_open := false
	for &d in p.drawers {
		if d.open {
			any_open = true
			break
		}
	}
	region := drawer_region_width(app)
	if !any_open || region < 24 {
		app.splitter_dragging = false
		return
	}

	x := app.width - RAIL_W - region
	over := math.abs(app.mouse.x - x) <= SPLITTER_GRAB_W * 0.5 &&
		app.mouse.y >= 0 && app.mouse.y <= app.height
	if over do app.splitter_hovered = true

	if !app.splitter_dragging && over && down && !app.splitter_was_down {
		app.splitter_dragging = true
	}
	if app.splitter_dragging {
		if down {
			// Dragging is an explicit resize: finish the opening animation so
			// the bar tracks the pointer exactly, then map its position to the
			// open drawer width.
			p.drawer_anim = 1
			target := app.width - RAIL_W - app.mouse.x
			app.drawer_width = clamp(target, DRAWER_MIN_W, drawer_max_width(app))
		} else {
			app.splitter_dragging = false
		}
	}

	// Let the GLFW/ImGui backend choose the standard resize-EW cursor. If the
	// platform cursor theme lacks that shape, the backend falls back to the
	// default arrow.
	if app.splitter_hovered || app.splitter_dragging {
		mi_io_set_mouse_cursor(i32(CURSOR_RESIZE_EW))
	}
}

// --- MCP status card -------------------------------------------------------

mcp_status_poller_worker :: proc(p: ^Mcp_Status_Poller) {
	sync.mutex_lock(&p.mutex)
	project := strings.clone(p.project)
	sync.mutex_unlock(&p.mutex)
	status := mcp.host_status(project)
	delete(project)
	sync.mutex_lock(&p.mutex)
	mcp.host_status_destroy(&p.status)
	p.status = status
	p.done = true
	sync.mutex_unlock(&p.mutex)
}

mcp_status_poller_start :: proc(app: ^App, project: string) -> bool {
	p := &app.mcp_poller
	if p.running do return false
	mcp.host_status_destroy(&p.status)
	delete(p.project)
	p.project = strings.clone(project)
	p.done = false
	p.running = true
	p.thread = thread.create_and_start_with_poly_data(p, mcp_status_poller_worker, name = "miagent-mcp-status")
	if p.thread == nil {
		p.running = false
		return false
	}
	return true
}

mcp_status_poller_poll :: proc(app: ^App) {
	p := &app.mcp_poller
	if !p.running do return
	sync.mutex_lock(&p.mutex)
	done := p.done
	sync.mutex_unlock(&p.mutex)
	if !done do return

	p.running = false
	if p.thread != nil {
		thread.destroy(p.thread)
		p.thread = nil
	}
	sync.mutex_lock(&p.mutex)
	status := p.status
	p.status = {}
	project := p.project
	p.project = ""
	p.done = false
	sync.mutex_unlock(&p.mutex)

	if project == app.mcp_status_project {
		mcp.host_status_destroy(&app.mcp_status)
		app.mcp_status = status
	} else {
		mcp.host_status_destroy(&status)
	}
	delete(project)
}

mcp_status_poller_destroy :: proc(app: ^App) {
	p := &app.mcp_poller
	if p.running {
		if p.thread != nil do thread.destroy(p.thread)
		p.thread = nil
		p.running = false
	}
	mcp.host_status_destroy(&p.status)
	delete(p.project)
	p.project = ""
}

app_clear_mcp_status :: proc(app: ^App) {
	mcp.host_status_destroy(&app.mcp_status)
	delete(app.mcp_status_project)
	app.mcp_status_project = ""
	app.mcp_configured = false
	app.mcp_status_refreshed = false
}

app_refresh_mcp_status :: proc(app: ^App, force: bool = false) {
	p := app_active_project(app)
	if p == nil {
		app_clear_mcp_status(app)
		return
	}
	// Never queue multiple host-status requests. Polling happens on a worker
	// thread; this function only schedules and applies results.
	if app.mcp_poller.running do return
	if !force && app.mcp_status_refreshed && app.mcp_status_project == p.path {
		if app.now - app.mcp_status_at < MCP_STATUS_INTERVAL do return
	}

	configured := false
	if t := project_active_tab(p); t != nil && t.harness_ready {
		configured = harness.harness_mcp_configured(&t.harness) || harness.harness_has_mcp_tools(&t.harness)
	} else {
		cfg := mcp.config_dir_path()
		configured = mcp.config_files_present(p.path, cfg)
		delete(cfg)
	}

	if app.mcp_status_project != p.path {
		delete(app.mcp_status_project)
		app.mcp_status_project = strings.clone(p.path)
		mcp.host_status_destroy(&app.mcp_status)
	}
	app.mcp_configured = configured
	app.mcp_status_at = app.now
	app.mcp_status_refreshed = true
	if !configured {
		mcp.host_status_destroy(&app.mcp_status)
		return
	}

	if !mcp_status_poller_start(app, p.path) {
		mcp.host_status_destroy(&app.mcp_status)
		app.mcp_status.error = strings.clone("could not start MCP status worker")
	}
}


// --- frame update ----------------------------------------------------------

app_update :: proc(app: ^App) {
	mi_io_display_size(&app.width, &app.height)
	app.mouse = igGetMousePos()
	app.now = mi_io_time()
	app.dt = mi_io_dt()

	if app.f.cell_w <= 0 {
		px := app.f.mono_size > 0 ? app.f.mono_size : MONO_PX
		// Terminal cells stay tied to the configured mono size, not the UI
		// text scale used everywhere else.
		w, h := measure_raw(app.f.mono, px, "MMMMMMMMMM")
		app.f.cell_w = w / 10.0
		if app.f.cell_w <= 0 do app.f.cell_w = px * 0.6
		// A terminal cell is exactly one line tall. Padding it out (the
		// old *1.28) leaves gaps above/below powerline glyphs and makes
		// the grid look airy.
		app.f.cell_h = h > 0 ? h : px
	}

	app.shortcut_fired = app_shortcuts(app)
	folder_picker_poll(app)
	attachment_picker_poll(app)

	// Keep every project's shells alive even while that project is not visible,
	// and animate each project's drawer region independently.
	for p in app.projects {
		for &d in p.drawers {
			target: f32 = d.open ? 1.0 : 0.0
			speed := clamp(app.dt * 14.0, 0, 1)
			d.anim += (target - d.anim) * speed
			if math.abs(d.anim - target) < 0.002 do d.anim = target
			// Keep draining closed drawers too: the pty would otherwise fill
			// its kernel buffer and block the shell.
			if d.spawned {
				terminal_pump(d.term)
				if bells := terminal_take_bell(d.term); bells > 0 && !app.mute_audio {
					audio_bell_play()
				}
				terminal_compression_tick(d.term, app.now)
			}
		}
		app_reap_project_drawers(p)
		any_open := false
		for &d in p.drawers {
			if d.open do any_open = true
		}
		target_region: f32 = any_open ? 1.0 : 0.0
		p.drawer_anim += (target_region - p.drawer_anim) * clamp(app.dt * 13.0, 0, 1)
		if math.abs(p.drawer_anim - target_region) < 0.002 do p.drawer_anim = target_region
	}

	// Poll every live tab harness. A turn in one tab or project continues while
	// the user reads or starts a turn elsewhere.
	any_turn_ended := false
	for p, i in app.projects {
		any_session_changed := false
		for t in p.tabs {
			if !t.harness_ready do continue
			was_running := harness.harness_is_running(&t.harness)
			was_view_running := t.view.turn_running
			turn_ended := conversation_poll(&t.view, &t.harness)
			if turn_ended do any_turn_ended = true
			session_changed := t.view.session_changed
			if session_changed {
				t.view.session_changed = false
				any_session_changed = true
			}
			ctx := harness.harness_context(&t.harness)
			t.view.context_tokens = ctx.tokens
			t.view.context_limit = ctx.limit
			t.view.context_measured = ctx.measured

			// The details page is a snapshot, not a live redraw of every harness
			// field. Refresh it when a turn starts or ends, the session changes, or
			// the context size moves; manual Refresh covers everything else.
			if t.details_open {
				now_running := harness.harness_is_running(&t.harness)
				snap := &t.details.snapshot
				if turn_ended || session_changed || was_running != now_running ||
				   was_view_running != t.view.turn_running ||
				   ctx.tokens != snap.context_tokens || ctx.items != snap.context_items ||
				   ctx.limit != snap.context_limit || ctx.measured != snap.context_measured {
					t.details.dirty = true
				}
			}
		}
		if any_session_changed && p.expanded do project_refresh_sessions(app, i, true)
	}
	if any_turn_ended && !app.mute_audio {
		audio_alert_play()
	}

	if app.project_remove_pending >= 0 {
		if err := app_project_remove(app, app.project_remove_pending); err != "" {
			delete(app.project_input_error)
			app.project_input_error = strings.clone(err)
		}
		app.project_remove_pending = -1
	}

	app_update_splitter(app)
	mcp_status_poller_poll(app)
	app_refresh_mcp_status(app)
}

// app_reap_project_drawers removes a project's drawers whose shell has exited.
// Names are renumbered within that project and focus moves to an open survivor.
app_reap_project_drawers :: proc(p: ^Project) {
	doomed: [64]int
	n := 0
	for &d, i in p.drawers {
		if d.spawned && !d.term.alive {
			doomed[n] = i
			n += 1
			if n == len(doomed) do break
		}
	}
	if n == 0 do return

	old_focus := p.focus_drawer
	focus_removed := false
	removed_before := 0
	for j in 0 ..< n {
		idx := doomed[j]
		if idx == old_focus do focus_removed = true
		if idx < old_focus do removed_before += 1
		d := &p.drawers[idx]
		terminal_destroy(d.term)
		free(d.term)
		delete(d.name)
	}
	for j := n - 1; j >= 0; j -= 1 {
		ordered_remove(&p.drawers, doomed[j])
	}
	for &d, i in p.drawers {
		delete(d.name)
		d.name = fmt.aprintf("shell %d", i + 1)
	}

	if focus_removed {
		p.focus_drawer = -1
		for &d, i in p.drawers {
			if d.open {
				p.focus_drawer = i
				break
			}
		}
	} else if old_focus >= 0 {
		p.focus_drawer = old_focus - removed_before
		if p.focus_drawer >= len(p.drawers) do p.focus_drawer = -1
	}
}

app_shortcuts :: proc(app: ^App) -> bool {
	if app.image_viewer.open do return false
	ctrl := mi_io_key_ctrl() != 0
	shift := mi_io_key_shift() != 0
	if !(ctrl && shift) do return false
	p := app_active_project(app)
	if p == nil do return false
	// T = new shell, W = close the focused shell. ImGuiKey_A is 546.
	if igIsKeyPressed_Bool(ImGuiKey(546 + 19), false) {
		app_new_drawer(app)
		return true
	}
	if igIsKeyPressed_Bool(ImGuiKey(546 + 22), false) {
		if p.focus_drawer >= 0 do app_close_drawer(app, p.focus_drawer)
		return true
	}
	if igIsKeyPressed_Bool(ImGuiKey(546 + 17), false) { // R
		if p.focus_drawer >= 0 && p.focus_drawer < len(p.drawers) && p.drawers[p.focus_drawer].term != nil {
			terminal_reset(p.drawers[p.focus_drawer].term)
		}
		return true
	}
	return false
}

// --- frame -----------------------------------------------------------------

app_frame :: proc(app: ^App) {
	app_update(app)

	draw_projects(app)
	draw_conversation(app)
	draw_rail(app)
	draw_drawers(app)
	draw_image_viewer(app)
	app_update_terminal_focus(app)
}

app_update_terminal_focus :: proc(app: ^App) {
	active := app_active_project(app)
	for p in app.projects {
		for &d, i in p.drawers {
			if d.term == nil || !d.spawned do continue
			want := app.window_focused && !app.image_viewer.open && !app.shortcut_fired &&
			        p == active && d.open && p.focus_drawer == i &&
			        mi_io_want_text_input() == 0 && !d.term.paste_prompt
			terminal_update_focus(d.term, want)
		}
	}
}
