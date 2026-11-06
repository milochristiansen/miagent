// Conversation tabs and their GUI-only session names.
//
// A project can own several session files in its .miagent directory. Each tab
// gets its own Harness rooted at the same project, so turns keep running in the
// background and switching tabs does not disturb the active request.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "harness"

SESSION_TAB_BAR_H   :: f32(38)
SESSION_NAMES_FILE  :: "gui-sessions.json"
SESSION_NAMES_VER   :: 1
SESSION_NAME_MAX    :: 128

Conversation_Tab :: struct {
	session_path: string,
	name:         string,
	default:      bool,

	harness_ready: bool,
	harness:       harness.Harness,
	view:          Conversation_View,

	composer:         [4096]u8,
	composer_refocus: bool,

	details_open: bool,
	details:      Details_State,
}

conversation_tab_init :: proc(t: ^Conversation_Tab, session_path, name: string) {
	t.session_path = strings.clone(session_path)
	t.name = strings.clone(name)
	view_init(&t.view)
	details_init(&t.details)
}

conversation_tab_destroy :: proc(t: ^Conversation_Tab) {
	if t.harness_ready do harness.harness_destroy(&t.harness)
	view_destroy(&t.view)
	details_destroy(&t.details)
	delete(t.session_path)
	delete(t.name)
	t^ = {}
}

project_active_tab :: proc(p: ^Project) -> ^Conversation_Tab {
	if p == nil || p.active_tab < 0 || p.active_tab >= len(p.tabs) do return nil
	return p.tabs[p.active_tab]
}

app_active_tab :: proc(app: ^App) -> ^Conversation_Tab {
	return project_active_tab(app_active_project(app))
}

project_any_tab_ready :: proc(p: ^Project) -> bool {
	for t in p.tabs do if t.harness_ready do return true
	return false
}

project_any_tab_running :: proc(p: ^Project) -> bool {
	for t in p.tabs {
		if t.harness_ready && harness.harness_is_running(&t.harness) do return true
	}
	return false
}

// --- session names file ----------------------------------------------------

Gui_Session_Name :: struct {
	file: string `json:"file"`,
	name: string `json:"name"`,
}

Gui_Session_Names :: struct {
	version:  int                 `json:"version"`,
	sessions: []Gui_Session_Name  `json:"sessions"`,
}

gui_session_names_destroy :: proc(n: ^Gui_Session_Names) {
	for &s in n.sessions {
		delete(s.file)
		delete(s.name)
	}
	delete(n.sessions)
	n^ = {}
}

project_session_names_path :: proc(p: ^Project) -> string {
	dir := project_state_dir(p)
	defer delete(dir)
	return fmt.aprintf("%s/%s", dir, SESSION_NAMES_FILE)
}

session_file_key :: proc(p: ^Project, path: string) -> string {
	state := project_state_dir(p)
	defer delete(state)
	if len(path) > len(state) && strings.has_prefix(path, state) && path[len(state)] == '/' {
		return strings.clone(os.base(path))
	}
	return strings.clone(path)
}

session_path_from_key :: proc(p: ^Project, key: string) -> string {
	if os.is_absolute_path(key) do return strings.clone(key)
	state := project_state_dir(p)
	defer delete(state)
	return fmt.aprintf("%s/%s", state, key)
}

project_session_names_load :: proc(p: ^Project) -> (Gui_Session_Names, string) {
	names := Gui_Session_Names{version = SESSION_NAMES_VER}
	path := project_session_names_path(p)
	defer delete(path)
	if !os.exists(path) do return names, ""

	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return names, fmt.aprintf("reading %s: %v", path, err)
	defer delete(data)
	if jerr := json.unmarshal_string(string(data), &names); jerr != nil {
		gui_session_names_destroy(&names)
		return Gui_Session_Names{version = SESSION_NAMES_VER}, fmt.aprintf("reading %s: %v", path, jerr)
	}
	if names.version <= 0 do names.version = SESSION_NAMES_VER
	return names, ""
}

project_session_names_save :: proc(p: ^Project) -> string {
	dir := project_state_dir(p)
	defer delete(dir)
	if !os.exists(dir) {
		if err := os.make_directory_all(dir); err != nil {
			return fmt.aprintf("creating %s: %v", dir, err)
		}
	}
	path := fmt.aprintf("%s/%s", dir, SESSION_NAMES_FILE)
	defer delete(path)

	names := Gui_Session_Names{
		version = SESSION_NAMES_VER,
		sessions = make([]Gui_Session_Name, len(p.tabs)),
	}
	for t, i in p.tabs {
		names.sessions[i].file = session_file_key(p, t.session_path)
		names.sessions[i].name = strings.clone(t.name)
	}
	data, err := json.marshal(names, {pretty = true, use_spaces = true, spaces = 2})
	gui_session_names_destroy(&names)
	if err != nil do return fmt.aprintf("encoding %s: %v", path, err)
	defer delete(data)

	tmp := fmt.aprintf("%s.tmp-%d", path, os.get_pid())
	defer delete(tmp)
	if werr := os.write_entire_file(tmp, data); werr != nil {
		return fmt.aprintf("writing %s: %v", tmp, werr)
	}
	if rerr := os.rename(tmp, path); rerr != nil {
		os.remove(tmp)
		return fmt.aprintf("replacing %s: %v", path, rerr)
	}
	return ""
}

// --- session file discovery ------------------------------------------------

is_digit :: proc(b: u8) -> bool {
	return b >= '0' && b <= '9'
}

session_path_less :: proc(a, b: string) -> bool {
	an := os.base(a)
	bn := os.base(b)
	i, j := 0, 0
	for i < len(an) && j < len(bn) {
		ca, cb := an[i], bn[j]
		if is_digit(ca) && is_digit(cb) {
			ai, bj := i, j
			for ai < len(an) && is_digit(an[ai]) do ai += 1
			for bj < len(bn) && is_digit(bn[bj]) do bj += 1
			as, bs := i, j
			for as < ai && an[as] == '0' do as += 1
			for bs < bj && bn[bs] == '0' do bs += 1
			al, bl := ai - as, bj - bs
			if al != bl do return al < bl
			for k in 0 ..< al {
				if an[as + k] != bn[bs + k] do return an[as + k] < bn[bs + k]
			}
			i, j = ai, bj
			continue
		}
		if ca != cb do return ca < cb
		i += 1
		j += 1
	}
	return len(an) < len(bn)
}

project_scan_session_files :: proc(p: ^Project) -> []string {
	state := project_state_dir(p)
	defer delete(state)
	entries, err := os.read_all_directory_by_path(state, context.temp_allocator)
	if err != nil do return nil
	out := make([dynamic]string, 0, len(entries))
	for entry in entries {
		if entry.type == .Directory do continue
		if !strings.has_suffix(entry.name, ".jsonl") do continue
		append(&out, strings.clone(entry.fullpath))
	}
	for i in 1 ..< len(out) {
		j := i
		for j > 0 && session_path_less(out[j], out[j - 1]) {
			out[j], out[j - 1] = out[j - 1], out[j]
			j -= 1
		}
	}
	return out[:]
}

session_name_from_path :: proc(path: string, is_default: bool) -> string {
	if is_default do return strings.clone("Default session")
	base := os.base(path)
	if strings.has_suffix(base, ".jsonl") do base = base[:len(base) - 6]
	if strings.has_prefix(base, "session-") {
		if n, ok := strconv.parse_int(base[len("session-"):]); ok && n > 0 {
			return fmt.aprintf("Session %d", n)
		}
	}
	if len(base) == 0 || base == "session" do return strings.clone("Session")
	return strings.clone(base)
}

session_file_stem :: proc(p: ^Project) -> string {
	if len(p.tabs) > 0 {
		state := project_state_dir(p)
		defer delete(state)
		path := p.tabs[0].session_path
		if len(path) > len(state) && strings.has_prefix(path, state) && path[len(state)] == '/' {
			base := os.base(path)
			if strings.has_suffix(base, ".jsonl") do base = base[:len(base) - 6]
			// If the default itself is session-3.jsonl, continue the sequence at
			// session-4.jsonl rather than producing session-3-2.jsonl.
			if dash := strings.last_index_byte(base, '-'); dash > 0 {
				suffix := base[dash + 1:]
				all_digits := len(suffix) > 0
				for ch in suffix do if ch < '0' || ch > '9' do all_digits = false
				if all_digits do base = base[:dash]
			}
			if len(base) > 0 do return strings.clone(base)
		}
	}
	return strings.clone("session")
}

project_has_session_path :: proc(p: ^Project, path: string) -> bool {
	for t in p.tabs do if t.session_path == path do return true
	return false
}

project_next_session_path :: proc(p: ^Project) -> string {
	state := project_state_dir(p)
	defer delete(state)
	os.make_directory_all(state)
	base := session_file_stem(p)
	defer delete(base)
	for n := 2; ; n += 1 {
		candidate := fmt.aprintf("%s/%s-%d.jsonl", state, base, n)
		if !os.exists(candidate) && !project_has_session_path(p, candidate) {
			return candidate
		}
		delete(candidate)
	}
	return ""
}

// --- tab lifecycle ---------------------------------------------------------

tab_ensure_runtime :: proc(p: ^Project, t: ^Conversation_Tab) {
	if t.harness_ready do return

	if !os.exists(p.path) {
		if len(t.view.session_path) == 0 {
			if len(t.session_path) > 0 {
				t.view.session_path = strings.clone(t.session_path)
			} else {
				path := project_default_session_path(p)
				t.view.session_path = path
			}
		}
		if len(t.view.messages) == 0 {
			note := fmt.aprintf("%s: project directory not found", p.path)
			view_add_error(&t.view, note)
			delete(note)
		}
		t.view.scroll_pending = 6
		return
	}

	// A project that was missing at startup may have appeared since then.
	delete(p.error)
	p.error = ""
	view_clear_messages(&t.view)
	delete(t.view.session_path)
	t.view.session_path = ""

	init_err: string
	if t.default || len(t.session_path) == 0 {
		init_err = harness.harness_init_project(&t.harness, p.path)
	} else {
		init_err = harness.harness_init_project_session(&t.harness, p.path, t.session_path)
	}
	t.harness_ready = true

	sp := harness.harness_session_path(&t.harness)
	delete(t.session_path)
	t.session_path = sp
	t.view.session_path = strings.clone(t.session_path)

	t.view.model = harness.harness_model(&t.harness)
	ctx := harness.harness_context(&t.harness)
	t.view.context_tokens = ctx.tokens
	t.view.context_limit = ctx.limit
	t.view.context_measured = ctx.measured

	history := harness.harness_history(&t.harness)
	view_load_history(&t.view, history, t.view.session_path)
	harness.harness_free_items(history)
	if len(init_err) > 0 {
		view_add_error(&t.view, init_err)
		delete(init_err)
	}
	notes := harness.harness_startup_notes(&t.harness)
	if len(notes) > 0 do view_add_note(&t.view, notes)
	delete(notes)
	t.view.scroll_pending = 6
	t.composer_refocus = true
}

session_names_find :: proc(names: ^Gui_Session_Names, key: string) -> string {
	for &s in names.sessions do if s.file == key do return s.name
	return ""
}

project_init_tabs :: proc(p: ^Project) {
	if p.tabs_initialized do return
	p.tabs_initialized = true
	p.active_tab = -1
	if p.tabs == nil do p.tabs = make([dynamic]^Conversation_Tab, 0, 4)

	if !os.exists(p.path) {
		path := project_default_session_path(p)
		defer delete(path)
		t := new(Conversation_Tab)
		conversation_tab_init(t, path, "Default session")
		t.default = true
		append(&p.tabs, t)
		p.active_tab = 0
		tab_ensure_runtime(p, t)
		return
	}

	default_tab := new(Conversation_Tab)
	conversation_tab_init(default_tab, "", "")
	default_tab.default = true
	append(&p.tabs, default_tab)
	p.active_tab = 0
	tab_ensure_runtime(p, default_tab)

	names, name_err := project_session_names_load(p)
	defer gui_session_names_destroy(&names)
	if len(name_err) > 0 {
		view_add_error(&default_tab.view, name_err)
		delete(name_err)
	}

	default_key := session_file_key(p, default_tab.session_path)
	defer delete(default_key)
	if from_names := session_names_find(&names, default_key); len(from_names) > 0 {
		delete(default_tab.name)
		default_tab.name = strings.clone(from_names)
	} else {
		delete(default_tab.name)
		default_tab.name = session_name_from_path(default_tab.session_path, true)
	}

	paths := make([dynamic]string, 0, 8)
	append(&paths, strings.clone(default_tab.session_path))
	// add_path takes ownership of path on success.
	add_path :: proc(paths: ^[dynamic]string, path: string) -> bool {
		for p in paths^ do if p == path do return false
		append(paths, path)
		return true
	}

	for &s in names.sessions {
		path := session_path_from_key(p, s.file)
		if path == default_tab.session_path || os.exists(path) {
			if !add_path(&paths, path) do delete(path)
		} else {
			delete(path)
		}
	}

	scanned := project_scan_session_files(p)
	for path in scanned {
		if !add_path(&paths, path) do delete(path)
	}
	delete(scanned)

	for path, i in paths {
		if i == 0 do continue
		key := session_file_key(p, path)
		name := session_names_find(&names, key)
		delete(key)
		owned_name := ""
		if len(name) == 0 {
			owned_name = session_name_from_path(path, false)
			name = owned_name
		}
		t := new(Conversation_Tab)
		conversation_tab_init(t, path, name)
		delete(owned_name)
		append(&p.tabs, t)
	}
	for path in paths do delete(path)
	delete(paths)

	if err := project_session_names_save(p); len(err) > 0 {
		view_add_note(&default_tab.view, err)
		delete(err)
	}
}

// app_project_ensure_runtime is retained as the project-activation entry point.
app_project_ensure_runtime :: proc(app: ^App, p: ^Project) {
	project_init_tabs(p)
	if t := project_active_tab(p); t != nil do tab_ensure_runtime(p, t)
}

app_select_tab :: proc(app: ^App, p: ^Project, index: int) {
	if index < 0 || index >= len(p.tabs) do return
	if p.session_name_editing do app_session_name_commit(p)
	changed := index != p.active_tab
	p.active_tab = index
	p.session_name_editing = false
	p.session_name_was_active = false
	p.session_name_input[0] = 0
	app.preview_active = false
	app.selected_session = -1
	t := p.tabs[index]
	tab_ensure_runtime(p, t)
	if changed {
		t.view.follow = true
		t.view.scroll_pending = 4
		t.composer_refocus = true
		t.details.dirty = true
	}
	app.mcp_status_refreshed = false
	app_refresh_mcp_status(app, true)
}

app_add_session_tab :: proc(app: ^App, p: ^Project) -> int {
	project_init_tabs(p)
	if p.session_name_editing do app_session_name_commit(p)
	if !os.exists(p.path) {
		if t := project_active_tab(p); t != nil {
			note := fmt.aprintf("%s: project directory not found", p.path)
			view_add_error(&t.view, note)
			delete(note)
		}
		return -1
	}
	path := project_next_session_path(p)
	defer delete(path)
	if err := os.write_entire_file_from_string(path, ""); err != nil {
		if t := project_active_tab(p); t != nil {
			note := fmt.aprintf("creating session %s: %v", path, err)
			view_add_error(&t.view, note)
			delete(note)
		}
		return -1
	}

	name := session_name_from_path(path, false)
	defer delete(name)
	t := new(Conversation_Tab)
	conversation_tab_init(t, path, name)
	append(&p.tabs, t)
	p.active_tab = len(p.tabs) - 1
	p.session_name_editing = false
	p.session_name_was_active = false
	p.session_name_input[0] = 0
	app.preview_active = false
	app.selected_session = -1
	tab_ensure_runtime(p, t)

	if err := project_session_names_save(p); len(err) > 0 {
		view_add_note(&t.view, err)
		delete(err)
	}
	app.mcp_status_refreshed = false
	app_refresh_mcp_status(app, true)
	return p.active_tab
}

// --- session rename --------------------------------------------------------

session_name_copy :: proc(buf: []u8, s: string) {
	n := min(len(s), len(buf) - 1)
	copy(buf[:n], s)
	buf[n] = 0
}

app_session_name_begin :: proc(p: ^Project) {
	t := project_active_tab(p)
	if t == nil do return
	p.session_name_editing = true
	p.session_name_focus = true
	p.session_name_was_active = false
	session_name_copy(p.session_name_input[:], t.name)
}

app_session_name_commit :: proc(p: ^Project) {
	if !p.session_name_editing do return
	t := project_active_tab(p)
	name := strings.trim_space(string(cstring(&p.session_name_input[0])))
	if t != nil && len(name) > 0 {
		delete(t.name)
		t.name = strings.clone(name)
		if err := project_session_names_save(p); len(err) > 0 {
			view_add_note(&t.view, err)
			delete(err)
		}
	}
	p.session_name_editing = false
	p.session_name_focus = false
	p.session_name_was_active = false
	p.session_name_input[0] = 0
	igClearActiveID()
}

app_session_name_cancel :: proc(p: ^Project) {
	p.session_name_editing = false
	p.session_name_focus = false
	p.session_name_was_active = false
	p.session_name_input[0] = 0
	igClearActiveID()
}

// --- tab bar ---------------------------------------------------------------

draw_session_tabs :: proc(app: ^App, p: ^Project, r: Rect) {
	th := app.th
	list := igGetWindowDrawList()
	x := r.x + 22
	y := r.y + 7
	h: f32 = 26
	gap: f32 = 6
	avail := r.w - 44
	plus_w: f32 = 26

	n := len(p.tabs)
	tab_w: f32 = 120
	if n > 0 {
		tab_w = (avail - plus_w - gap * f32(n + 1)) / f32(n)
		tab_w = clamp(tab_w, 54, 210)
	}

	for t, i in p.tabs {
		tr := rect(x, y, tab_w, h)
		idbuf: [32]u8
		clicked := hit(id_cstr(idbuf[:], "sessiontab%d", i), tr)
		hovered := mi_hit_hovered()
		active := i == p.active_tab
		if active {
			panel(list, tr, th.bg_active, 7)
			panel(list, rect(tr.x + 10, tr.y + tr.h - 2, tr.w - 20, 2), th.accent, 1)
		} else if hovered {
			panel(list, tr, th.bg_hover, 7)
		}
		name_x := tr.x + 10
		if t.harness_ready && harness.harness_is_running(&t.harness) {
			dot(list, tr.x + 8, tr.y + tr.h * 0.5, 2.4, th.yellow)
			name_x = tr.x + 16
		}
		text_elided(list, app.f.ui, 12.0, name_x, tr.y + 5, tr.w - (name_x - tr.x) - 10,
			active ? th.fg : th.fg_dim, t.name)
		if hovered do tooltip(t.name)
		if clicked do app_select_tab(app, p, i)
		x += tab_w + gap
	}

	add_r := rect(x, y, plus_w, h)
	add_clicked := hit(cstr("##addsessiontab"), add_r)
	add_hovered := mi_hit_hovered()
	if add_hovered do panel(list, add_r, th.bg_hover, 7)
	glyph_plus(list, add_r.x + plus_w * 0.5, add_r.y + h * 0.5, 4.5, th.fg_dim, 1.4)
	if add_hovered do tooltip("New session")
	if add_clicked do app_add_session_tab(app, p)
}
