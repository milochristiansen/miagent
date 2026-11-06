// Global GUI settings that do not belong in the agent's dotenv files: window
// geometry and the list of known projects. The file is gui.json beside the
// installation .env in the MiAgent configuration directory.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "harness"

GUI_CONFIG_FILE :: "gui.json"
GUI_CONFIG_VERSION :: 1
GUI_DEFAULT_WINDOW_W :: 1440
GUI_DEFAULT_WINDOW_H :: 900
GUI_MIN_WINDOW_W :: 1120
GUI_MIN_WINDOW_H :: 700

Gui_Window :: struct {
	x:            int  `json:"x"`,
	y:            int  `json:"y"`,
	width:        int  `json:"width"`,
	height:       int  `json:"height"`,
	has_position: bool `json:"has_position"`,
}

Gui_Project :: struct {
	path: string `json:"path"`,
}

Gui_Config :: struct {
	version:    int           `json:"version"`,
	window:     Gui_Window    `json:"window"`,
	projects:   []Gui_Project `json:"projects"`,
	// False by default, so existing gui.json files gain the agent
	// turn-end tone.
	mute_audio: bool          `json:"mute_audio"`,
	// User-dragged shell-drawer width in pixels. Omitted/zero means the
	// automatic default.
	drawer_width: int         `json:"drawer_width,omitempty"`,
}

gui_config_file_path :: proc() -> string {
	dir := harness.config_dir_path()
	defer delete(dir)
	return fmt.aprintf("%s/%s", dir, GUI_CONFIG_FILE)
}

gui_config_default :: proc() -> Gui_Config {
	return Gui_Config{
		version = GUI_CONFIG_VERSION,
		window = Gui_Window{
			width = GUI_DEFAULT_WINDOW_W,
			height = GUI_DEFAULT_WINDOW_H,
		},
	}
}

gui_config_destroy :: proc(c: ^Gui_Config) {
	for &p in c.projects do delete(p.path)
	delete(c.projects)
	c^ = {}
}

gui_window_sanitize :: proc(w: ^Gui_Window) {
	if w.width <= 0 || w.width > 10000 {
		w.width = GUI_DEFAULT_WINDOW_W
	} else if w.width < GUI_MIN_WINDOW_W {
		w.width = GUI_MIN_WINDOW_W
	}
	if w.height <= 0 || w.height > 10000 {
		w.height = GUI_DEFAULT_WINDOW_H
	} else if w.height < GUI_MIN_WINDOW_H {
		w.height = GUI_MIN_WINDOW_H
	}
}

gui_project_index :: proc(c: ^Gui_Config, path: string) -> int {
	for p, i in c.projects {
		if p.path == path do return i
	}
	return -1
}

// gui_project_sync_current ensures the launch directory is in the known set.
gui_project_sync_current :: proc(c: ^Gui_Config) {
	cwd, err := os.get_working_directory(context.allocator)
	if err != nil || len(cwd) == 0 do return
	if gui_project_index(c, cwd) >= 0 {
		delete(cwd)
		return
	}
	out := make([]Gui_Project, len(c.projects) + 1)
	out[0] = Gui_Project{path = cwd}
	copy(out[1:], c.projects)
	delete(c.projects)
	c.projects = out
}

gui_config_sanitize :: proc(c: ^Gui_Config) {
	if c.version <= 0 do c.version = GUI_CONFIG_VERSION
	gui_window_sanitize(&c.window)
	if c.drawer_width < 0 do c.drawer_width = 0

	// Drop empty entries and duplicate paths while preserving order.
	out := make([dynamic]Gui_Project, 0, len(c.projects))
	for &p in c.projects {
		if len(strings.trim_space(p.path)) == 0 {
			delete(p.path)
			continue
		}
		cleaned, cerr := filepath.clean(p.path, context.allocator)
		if cerr == nil {
			delete(p.path)
			p.path = cleaned
		}
		duplicate := false
		for seen in out {
			if seen.path == p.path {
				duplicate = true
				break
			}
		}
		if duplicate {
			delete(p.path)
			continue
		}
		append(&out, p)
	}
	delete(c.projects)
	c.projects = out[:]
	gui_project_sync_current(c)
}

gui_config_load :: proc() -> (Gui_Config, string) {
	path := gui_config_file_path()
	defer delete(path)

	cfg := gui_config_default()
	if !os.exists(path) {
		gui_project_sync_current(&cfg)
		return cfg, ""
	}

	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		gui_project_sync_current(&cfg)
		return cfg, fmt.aprintf("reading %s: %v", path, err)
	}
	defer delete(data)

	if jerr := json.unmarshal_string(string(data), &cfg); jerr != nil {
		gui_config_destroy(&cfg)
		cfg = gui_config_default()
		gui_project_sync_current(&cfg)
		return cfg, fmt.aprintf("reading %s: %v", path, jerr)
	}
	gui_config_sanitize(&cfg)
	return cfg, ""
}

gui_config_save :: proc(c: ^Gui_Config) -> string {
	path := gui_config_file_path()
	defer delete(path)

	dir := harness.config_dir_path()
	defer delete(dir)
	if !os.exists(dir) {
		if err := os.make_directory_all(dir); err != nil {
			return fmt.aprintf("creating %s: %v", dir, err)
		}
	}

	data, err := json.marshal(c^, {pretty = true, use_spaces = true, spaces = 2})
	if err != nil do return fmt.aprintf("encoding %s: %v", path, err)
	defer delete(data)

	// Write beside the destination and rename, so a crash cannot leave a
	// half-written gui.json behind.
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
