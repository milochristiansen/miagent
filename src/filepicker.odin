// Native folder picking for the projects pane. The app re-executes itself in
// a hidden mode, where portal.c talks to the XDG Desktop Portal over D-Bus.
// The helper runs as a child process so the GUI never blocks on the dialog.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

FOLDER_PICKER_FLAG :: "--miagent-pick-folder"
FOLDER_PICKER_TITLE :: "Add project"

foreign import filepicker_portal "../build/libmiagent.a"

@(default_calling_convention = "c")
foreign filepicker_portal {
	mi_portal_pick_folder :: proc(title: cstring, out: [^]u8, out_size: uint) -> i32 ---
}

Folder_Picker :: struct {
	running:   bool,
	process:   os.Process,
	stdout:    ^os.File,
	stderr:    ^os.File,
	thread:    ^thread.Thread,
	mutex:     sync.Mutex,
	done:      bool,
	cancelled: bool,
	path:      string,
	error:     string,
}

Folder_Picker_Reader :: struct {
	file: ^os.File,
	buf:  ^strings.Builder,
}

// folder_picker_helper is the hidden child mode. It writes the selected path
// to stdout and exits 0, exits 1 when the user cancels, and exits 2 when the
// portal is unavailable or fails.
folder_picker_helper :: proc(args: []string) {
	title := len(args) >= 3 ? args[2] : "Choose a project folder"
	buf: [4096]u8
	rc := mi_portal_pick_folder(zstr(title), &buf[0], uint(len(buf)))
	switch rc {
	case 0:
		path := string(cstring(&buf[0]))
		if len(path) == 0 do os.exit(2)
		fmt.printf("%s\n", path)
		os.exit(0)
	case 1:
		os.exit(1)
	case:
		os.exit(2)
	}
}

folder_picker_read :: proc(r: ^Folder_Picker_Reader) {
	tmp: [4096]u8
	for {
		n, err := os.read(r.file, tmp[:])
		if n > 0 do strings.write_bytes(r.buf, tmp[:n])
		if err != nil || n == 0 do break
	}
}

folder_picker_worker :: proc(fp: ^Folder_Picker) {
	out_buf := strings.builder_make()
	err_buf := strings.builder_make()

	out_ctx := Folder_Picker_Reader{file = fp.stdout, buf = &out_buf}
	err_ctx := Folder_Picker_Reader{file = fp.stderr, buf = &err_buf}
	out_thread := thread.create_and_start_with_poly_data(&out_ctx, folder_picker_read)
	err_thread := thread.create_and_start_with_poly_data(&err_ctx, folder_picker_read)

	state: os.Process_State
	wait_error: os.Error
	for {
		s, err := os.process_wait(fp.process, 100 * time.Millisecond)
		if err == nil && s.exited {
			state = s
			break
		}
		// A timeout just means the child is still waiting for the user in
		// the portal dialog. Keep polling; only a real wait failure is fatal.
		if err != nil {
			if ge, is_general := err.(os.General_Error); is_general && ge == .Timeout {
				continue
			}
			wait_error = err
			break
		}
	}

	if out_thread != nil do thread.join(out_thread)
	if err_thread != nil do thread.join(err_thread)
	if fp.stdout != nil do os.close(fp.stdout)
	if fp.stderr != nil do os.close(fp.stderr)

	out_text := strings.trim_right(strings.to_string(out_buf), "\r\n")
	err_text := strings.trim_space(strings.to_string(err_buf))

	sync.mutex_lock(&fp.mutex)
	fp.done = true
	switch {
	case wait_error != nil:
		fp.error = fmt.aprintf("folder picker: %v", wait_error)
	case state.exit_code == 0 && len(out_text) > 0:
		fp.path = strings.clone(out_text)
	case state.exit_code == 1:
		fp.cancelled = true
	case len(err_text) > 0:
		fp.error = strings.clone(err_text)
	case:
		fp.error = fmt.aprintf("folder picker exited %d without a folder", state.exit_code)
	}
	sync.mutex_unlock(&fp.mutex)

	delete(out_buf.buf)
	delete(err_buf.buf)
}

folder_picker_start :: proc(app: ^App, title: string) -> bool {
	fp := &app.folder_picker
	if fp.running do return false

	delete(fp.path)
	fp.path = ""
	delete(fp.error)
	fp.error = ""
	fp.done = false
	fp.cancelled = false

	stdout_r, stdout_w, stdout_err := os.pipe()
	if stdout_err != nil do return false
	stderr_r, stderr_w, stderr_err := os.pipe()
	if stderr_err != nil {
		os.close(stdout_r)
		os.close(stdout_w)
		return false
	}

	exe, exe_err := os.get_executable_path(context.temp_allocator)
	if exe_err != nil || len(exe) == 0 {
		if len(os.args) == 0 do return false
		exe = os.args[0]
	}
	command := []string{exe, FOLDER_PICKER_FLAG, title}

	process, perr := os.process_start({
		command = command,
		stdout = stdout_w,
		stderr = stderr_w,
	})
	os.close(stdout_w)
	os.close(stderr_w)
	if perr != nil {
		os.close(stdout_r)
		os.close(stderr_r)
		return false
	}

	fp.process = process
	fp.stdout = stdout_r
	fp.stderr = stderr_r
	fp.running = true
	fp.thread = thread.create_and_start_with_poly_data(fp, folder_picker_worker)
	if fp.thread == nil {
		fp.running = false
		_ = os.process_kill(process)
		os.close(stdout_r)
		os.close(stderr_r)
		return false
	}
	return true
}

// folder_picker_poll applies a finished picker result. It is called once per
// frame from app_update.
folder_picker_poll :: proc(app: ^App) {
	fp := &app.folder_picker
	if !fp.running do return

	sync.mutex_lock(&fp.mutex)
	done := fp.done
	if !done {
		sync.mutex_unlock(&fp.mutex)
		return
	}
	path := fp.path
	fp.path = ""
	err := fp.error
	fp.error = ""
	cancelled := fp.cancelled
	fp.cancelled = false
	fp.done = false
	sync.mutex_unlock(&fp.mutex)

	fp.running = false
	if fp.thread != nil {
		thread.join(fp.thread)
		fp.thread = nil
	}

	if len(path) > 0 {
		if add_err := app_add_project_from_input(app, path); add_err != "" {
			app_project_path_fallback(app, add_err)
			app_set_project_input(app, path)
		}
		delete(path)
		delete(err)
		return
	}
	delete(path)
	if cancelled {
		delete(err)
		return
	}
	app_project_path_fallback(app, err)
	delete(err)
}

folder_picker_destroy :: proc(fp: ^Folder_Picker) {
	if fp.running {
		_ = os.process_kill(fp.process)
		if fp.thread != nil do thread.join(fp.thread)
		fp.thread = nil
		fp.running = false
	}
	delete(fp.path)
	delete(fp.error)
	fp.path = ""
	fp.error = ""
}

// app_open_project_picker tries the portal first and only reveals the manual
// path field when the picker cannot be started at all. An asynchronous portal
// failure is handled later by folder_picker_poll.
app_open_project_picker :: proc(app: ^App) {
	if app.folder_picker.running do return
	if app.project_input_open {
		app.project_input_open = false
		app.project_input_focus = false
		app.project_input[0] = 0
		delete(app.project_input_error)
		app.project_input_error = ""
		return
	}
	if folder_picker_start(app, FOLDER_PICKER_TITLE) {
		app.project_input_open = false
		app.project_input_focus = false
		delete(app.project_input_error)
		app.project_input_error = ""
		return
	}
	app_project_path_fallback(app, "could not open the system folder chooser")
}

app_project_path_fallback :: proc(app: ^App, reason: string) {
	app.project_input_open = true
	app.project_input_focus = true
	if len(reason) > 0 {
		delete(app.project_input_error)
		app.project_input_error = strings.clone(reason)
	}
}

app_set_project_input :: proc(app: ^App, text: string) {
	n := min(len(text), len(app.project_input) - 1)
	copy(app.project_input[:n], text[:n])
	app.project_input[n] = 0
}
