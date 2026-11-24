package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:time"
import glfw "vendor:glfw"
import gl "vendor:OpenGL"

// Wayland/X11 may ask us to repaint after the surface is exposed or resized by
// the compositor even when no input arrived.
window_refresh_requested: bool

on_window_refresh :: proc "c" (window: glfw.WindowHandle) {
	window_refresh_requested = true
}

// ImGui's GLFW backend intentionally ignores GLFW_REPEAT events and implements
// typematic repeat itself. Non-text keys such as arrows and backspace therefore
// produce no queued ImGui input event, so an on-demand renderer must wake on the
// repeat callback explicitly.
key_repeat_requested: bool

on_key :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
	if action == glfw.REPEAT do key_repeat_requested = true
	ImGui_ImplGlfw_KeyCallback(cast(^GLFWwindow)window, key, scancode, action, mods)
}

FONT_REGULAR := [?]string{
	"/usr/share/fonts/TTF/FiraCode-Regular.ttf",
	"/usr/share/fonts/truetype/firacode/FiraCode-Regular.ttf",
	"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
}

// Fallbacks for the terminal when the configured family cannot be found:
// Fira Code first, with a Nerd Font merged in only for the prompt's
// private-use glyphs (powerline, icons).
FONT_MONO := [?]string{
	"/usr/share/fonts/TTF/FiraCode-Regular.ttf",
	"/usr/share/fonts/truetype/firacode/FiraCode-Regular.ttf",
	"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
}

FONT_MONO_BOLD := [?]string{
	"/usr/share/fonts/TTF/FiraCode-Bold.ttf",
	"/usr/share/fonts/truetype/firacode/FiraCode-Bold.ttf",
	"/usr/share/fonts/TTF/DejaVuSansMono-Bold.ttf",
}

FONT_NERD := [?]string{
	"/usr/share/fonts/TTF/HackNerdFontMono-Regular.ttf",
	"/usr/share/fonts/TTF/HackNerdFont-Regular.ttf",
}

FONT_NERD_BOLD := [?]string{
	"/usr/share/fonts/TTF/HackNerdFontMono-Bold.ttf",
	"/usr/share/fonts/TTF/HackNerdFont-Bold.ttf",
}

// Symbols neither Fira Code nor Hack Nerd Font carry (e.g. U+2714, the check
// used by p10k's right prompt). DejaVu Sans is a common fallback here too.
FONT_SYMBOL := [?]string{
	"/usr/share/fonts/TTF/DejaVuSans.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
}

load_font_path :: proc(path: string, px: f32) -> ^ImFont {
	if len(path) > 0 && os.exists(path) {
		if f := mi_font_add(zstr(path), px); f != nil do return f
	}
	return nil
}

load_font :: proc(candidates: []string, px: f32) -> ^ImFont {
	for p in candidates {
		if os.exists(p) {
			if f := mi_font_add(zstr(p), px); f != nil do return f
		}
	}
	return nil
}

find_font :: proc(candidates: []string) -> string {
	for p in candidates do if os.exists(p) do return p
	return ""
}

merge_fallback :: proc(primary: ^ImFont, candidates: []string, px: f32) {
	if primary == nil do return
	if p := find_font(candidates); len(p) > 0 {
		mi_font_merge(primary, zstr(p), px)
	}
}

// Emoji comes last so the primary, Nerd, and symbol fonts keep their glyphs
// wherever they overlap. Noto Emoji supplies the emoji that would otherwise
// fall back to the replacement rune.
merge_emoji :: proc(primary: ^ImFont, theme: Terminal_Theme, px: f32) {
	if primary == nil do return
	if path := theme_emoji_font_path(theme); len(path) > 0 {
		mi_font_merge(primary, zstr(path), px)
	}
}

// Dev aid: MIAGENT_SCREENSHOT=/path/out.ppm renders a few frames, dumps the
// framebuffer and exits. Handy when grabbing the X root window isn't possible.
capture :: proc(w, h: i32, path: string) {
	px := make([]u8, int(w) * int(h) * 4, context.temp_allocator)
	gl.ReadPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(px))
	f, err := os.create(path)
	if err != nil {
		fmt.eprintln("screenshot:", err)
		return
	}
	defer os.close(f)
	fmt.fprintf(f, "P6\n%d %d\n255\n", w, h)
	row := make([]u8, int(w) * 3, context.temp_allocator)
	for y := int(h) - 1; y >= 0; y -= 1 {
		for x := 0; x < int(w); x += 1 {
			i := (y * int(w) + x) * 4
			row[x * 3 + 0] = px[i + 0]
			row[x * 3 + 1] = px[i + 1]
			row[x * 3 + 2] = px[i + 2]
		}
		os.write(f, row)
	}
}

main :: proc() {
	// Hidden child mode for the XDG portal folder picker. This runs before
	// GLFW is initialized, so the helper has no window or other GUI state.
	args := os.args
	if len(args) >= 2 && (args[1] == FOLDER_PICKER_FLAG || args[1] == FILES_PICKER_FLAG) {
		folder_picker_helper(args)
		return
	}

	// GLFW 3.5 can run natively on Wayland or through XWayland. Let a launch
	// select the platform explicitly; this is useful for isolating driver
	// paths and as a workaround for compositor/EGL driver leaks.
	if requested := os.get_env("MIAGENT_GLFW_PLATFORM", context.temp_allocator); len(requested) > 0 {
		switch requested {
		case "x11":
			glfw.InitHint(glfw.PLATFORM, glfw.PLATFORM_X11)
		case "wayland":
			glfw.InitHint(glfw.PLATFORM, glfw.PLATFORM_WAYLAND)
		}
	}
	if !glfw.Init() {
		fmt.eprintln("failed to initialize GLFW")
		return
	}
	defer glfw.Terminate()

	// Global GUI settings live beside the agent's .env. Load them first so the
	// window opens at its previous position and size.
	gui, gui_note := gui_config_load()
	defer gui_config_destroy(&gui)

	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 3)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 3)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
	glfw.WindowHint(glfw.VISIBLE, 1)
	glfw.WindowHint(glfw.SAMPLES, 0)
	if gui.window.has_position {
		glfw.WindowHint_int(glfw.POSITION_X, i32(gui.window.x))
		glfw.WindowHint_int(glfw.POSITION_Y, i32(gui.window.y))
	}
	win := glfw.CreateWindow(i32(gui.window.width), i32(gui.window.height), "MiAgent Desktop", nil, nil)
	if win == nil {
		fmt.eprintln("failed to create window")
		return
	}
	defer glfw.DestroyWindow(win)
	glfw.MakeContextCurrent(win)
	glfw.SwapInterval(1)
	glfw.SetWindowSizeLimits(win, GUI_MIN_WINDOW_W, GUI_MIN_WINDOW_H, glfw.DONT_CARE, glfw.DONT_CARE)
	glfw.SetWindowRefreshCallback(win, on_window_refresh)
	gl.load_up_to(3, 3, glfw.gl_set_proc_address)

	ctx := igCreateContext(nil)
	defer igDestroyContext(ctx)
	mi_io_setup(nil)
	mi_style_apply(1.0)

	if !ImGui_ImplGlfw_InitForOpenGL(cast(^GLFWwindow)win, true) {
		fmt.eprintln("failed to initialize the GLFW backend")
		return
	}
	glfw.SetKeyCallback(win, on_key)
	defer ImGui_ImplGlfw_Shutdown()
	if !ImGui_ImplOpenGL3_Init("#version 330 core") {
		fmt.eprintln("failed to initialize the OpenGL3 backend")
		return
	}
	defer ImGui_ImplOpenGL3_Shutdown()

	// Terminal colors and fonts come from compiled-in defaults plus the
	// optional theme.json in the MiAgent configuration directory.
	theme, theme_note := theme_config_load()
	defer terminal_theme_destroy(&theme)
	th := theme_init(theme)
	theme_apply_imgui(th)
	fmt.printf("theme: %s (font_size %.1f)\n", th.source, theme.font_size)
	if len(theme_note) > 0 {
		gui_note = len(gui_note) > 0 ? fmt.aprintf("%s\n%s", gui_note, theme_note) : theme_note
	}

	// Themes size fonts in points; ImGui wants the font's line box in pixels.
	// 1.25 is the ascent+descent ratio of Fira Code / Hack at these sizes, so
	// the default 9pt lands on the 15px we were using before. Round to whole
	// pixels for the same reason as ui_text_px: ImGui otherwise rescales the
	// baked glyph bitmap by the fractional remainder.
	mono_px: f32 = MONO_PX
	if theme.font_size > 0 {
		mono_px = math.round(clamp(theme.font_size * (96.0 / 72.0) * 1.25, 10.0, 32.0))
	}

	// One font per family; ImGui bakes any size we ask for at draw time. The
	// terminal prefers the configured family, then falls back to the bundled
	// candidates so a missing font cannot leave an empty grid. Emoji is merged
	// last into every face, after symbol fallbacks, so it only fills gaps.
	ui_px := ui_text_px(UI_PX)
	ui := load_font(FONT_REGULAR[:], ui_px)
	merge_fallback(ui, FONT_SYMBOL[:], ui_px)
	merge_emoji(ui, theme, ui_px)

	mono := load_font_path(theme_font_path(theme, false), mono_px)
	if mono == nil do mono = load_font(FONT_MONO[:], mono_px)
	merge_fallback(mono, FONT_NERD[:], mono_px)
	merge_fallback(mono, FONT_SYMBOL[:], mono_px)
	merge_emoji(mono, theme, mono_px)

	mono_bold := load_font_path(theme_font_path_style(theme, .Bold), mono_px)
	if mono_bold == nil do mono_bold = load_font(FONT_MONO_BOLD[:], mono_px)
	if mono_bold == nil do mono_bold = mono
	merge_fallback(mono_bold, FONT_NERD_BOLD[:], mono_px)
	merge_fallback(mono_bold, FONT_SYMBOL[:], mono_px)
	merge_emoji(mono_bold, theme, mono_px)

	mono_italic := load_font_path(theme_font_path_style(theme, .Italic), mono_px)
	if mono_italic == nil do mono_italic = mono
	merge_fallback(mono_italic, FONT_SYMBOL[:], mono_px)
	merge_emoji(mono_italic, theme, mono_px)

	mono_bold_italic := load_font_path(theme_font_path_style(theme, .Bold_Italic), mono_px)
	if mono_bold_italic == nil do mono_bold_italic = mono_bold
	merge_fallback(mono_bold_italic, FONT_SYMBOL[:], mono_px)
	merge_emoji(mono_bold_italic, theme, mono_px)
	if ui != nil do mi_font_set_default(ui)

	app := App{}
	app_init(&app, Fonts{
		ui = ui,
		mono = mono,
		mono_bold = mono_bold,
		mono_italic = mono_italic,
		mono_bold_italic = mono_bold_italic,
		ui_size = ui_text_px(UI_PX),
		mono_size = mono_px,
	}, th, &gui, gui_note)
	defer app_destroy(&app)

	shot := os.get_env("MIAGENT_SCREENSHOT", context.allocator)
	profile := len(os.get_env("MIAGENT_PROFILE", context.temp_allocator)) > 0
	frame_count := 0
	render_count := 0
	start_time := glfw.GetTime()

	last_render: f64 = -1000.0
	next_frame_at: f64 = 0
	prev_fw: i32 = -1
	prev_fh: i32 = -1
	prev_focused := false

	for !glfw.WindowShouldClose(win) {
		glfw.PollEvents()
		focused := glfw.GetWindowAttrib(win, glfw.FOCUSED) != 0
		app.window_focused = focused
		fw, fh := glfw.GetFramebufferSize(win)
		pending_input := mi_io_input_pending_count() > 0
		repeat_pending := key_repeat_requested
		key_repeat_requested = false
		forced := frame_count < 3 || fw != prev_fw || fh != prev_fh ||
			focused != prev_focused || window_refresh_requested ||
			repeat_pending || len(shot) > 0
		realtime := app_wants_realtime_frames(&app)
		animating := app_wants_animation_frames(&app)
		was_animating := animating
		now := glfw.GetTime()

		// A worker can start a turn or emit an event while the UI is sleeping
		// on a long idle timer. Shorten the next wakeup as soon as that happens
		// so streaming stays responsive without returning to a 60 Hz swap loop.
		if realtime && next_frame_at > now + 1.0 / 30.0 {
			next_frame_at = now + 1.0 / 30.0
		}

		// Build and present a frame only when something needs it. In
		// particular, do not touch the GL/compositor swap path just because the
		// event loop woke up: repeated no-op presents are exactly what lets a
		// compositor/EGL driver leak slowly while the app is idle.
		if !(forced || pending_input || animating || glfw.GetTime() >= next_frame_at) {
			if focused {
				time.sleep(4 * time.Millisecond)
			} else {
				time.sleep(50 * time.Millisecond)
			}
			continue
		}
		window_refresh_requested = false

		ImGui_ImplOpenGL3_NewFrame()
		ImGui_ImplGlfw_NewFrame()
		igNewFrame()

		gl.Viewport(0, 0, fw, fh)
		gl.ClearColor(th.bg[0], th.bg[1], th.bg[2], 1.0)
		gl.Clear(gl.COLOR_BUFFER_BIT)

		frame_start := time.tick_now()
		app_changed := app_frame(&app)
		frame_count += 1
		if profile && (frame_count <= 3 || frame_count % 60 == 0) {
			view := app_active_view(&app)
			fmt.eprintf("frame %d: %.2f ms, %d messages, %d selection cells, %d presents\n",
				frame_count,
				time.duration_milliseconds(time.tick_since(frame_start)),
				len(view.messages), len(view.sel.items), render_count)
		}

		now = glfw.GetTime()
		animating = app_wants_animation_frames(&app)
		realtime = app_wants_realtime_frames(&app)
		changed := forced || pending_input || repeat_pending || app_changed ||
			animating || was_animating

		// Streaming deltas and shell output can arrive faster than the eye can
		// use them. Coalesce non-input updates to 20 Hz; animations still run at
		// the display rate.
		if !animating && !forced && !pending_input && app_changed &&
		   now - last_render < 1.0 / 20.0 {
			changed = false
		}

		// Keep spinners, status cards, and text cursors alive at low rates.
		if !changed && realtime && now - last_render >= 0.25 {
			changed = true
		}
		if !changed && mi_io_want_text_input() != 0 && now - last_render >= 0.5 {
			changed = true
		}
		if !changed && app.mcp_configured && now - last_render >= 1.0 {
			changed = true
		}

		igRender()
		if changed {
			ImGui_ImplOpenGL3_RenderDrawData(igGetDrawData())
			glfw.SwapBuffers(win)
			last_render = now
			render_count += 1
		}

		// Schedule the next frame. Animations need every loop; background work
		// is polled at 30 Hz; a focused idle window keeps a slow repaint timer
		// for compositor/expose safety, and an unfocused one waits for events.
		switch {
		case animating:
			next_frame_at = now
		case realtime:
			next_frame_at = now + 1.0 / 30.0
		case mi_io_want_text_input() != 0:
			next_frame_at = now + 0.5
		case app.mcp_configured:
			next_frame_at = now + 1.0
		case focused:
			next_frame_at = now + 2.0
		case:
			next_frame_at = now + 3600.0
		}

		prev_fw = fw
		prev_fh = fh
		prev_focused = focused

		if len(shot) > 0 && glfw.GetTime() - start_time > 2.0 {
			capture(fw, fh, shot)
			break
		}

		free_all(context.temp_allocator)
	}

	// A screenshot run is a development aid; do not let it rewrite the user's
	// normal window geometry or project list.
	if len(shot) == 0 {
		capture_window_metrics(&gui, win)
		app_sync_gui_config(&app, &gui)
		if err := gui_config_save(&gui); err != "" {
			fmt.eprintln("gui config:", err)
		}
	}
}

capture_window_metrics :: proc(gui: ^Gui_Config, win: glfw.WindowHandle) {
	w, h := glfw.GetWindowSize(win)
	if w > 0 && h > 0 {
		gui.window.width = int(w)
		gui.window.height = int(h)
	}
	x, y := glfw.GetWindowPos(win)
	gui.window.x = int(x)
	gui.window.y = int(y)
	gui.window.has_position = true
}
