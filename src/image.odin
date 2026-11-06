// Markdown image loading, texture caching, and the expanded image viewer.
//
// Files and remote URLs are loaded on a worker thread; the GUI thread only
// uploads the decoded RGBA pixels to OpenGL and draws the texture. Entries are
// heap-allocated so pointers stay valid as the cache grows.
package main

import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import gl "vendor:OpenGL"

IMAGE_MAX_BYTES :: 48 << 20
IMAGE_THUMB_MAX_W :: f32(560)
IMAGE_THUMB_MAX_H :: f32(340)
IMAGE_VIEW_MARGIN :: f32(56)
IMAGE_VIEW_MAX_SCALE :: f32(2.0)

Image_State :: enum {
	Pending,
	Ready,
	Failed,
}

Image_Entry :: struct {
	key:    string,
	source: string,
	path:   string, // resolved local path; empty for data/remote sources
	state:  Image_State,

	mutex:   sync.Mutex,
	width:   int,
	height:  int,
	pixels:  rawptr,
	error:   string,
	texture: u32,
	thread:  ^thread.Thread,
}

Image_Cache :: struct {
	entries: [dynamic]^Image_Entry,
}

Image_Viewer :: struct {
	open:  bool,
	asset: ^Image_Entry,
}

Image_Source_Kind :: enum {
	File,
	Data,
	Remote,
	Invalid,
}

image_source_kind :: proc(src: string) -> Image_Source_Kind {
	if strings.has_prefix(src, "http://") || strings.has_prefix(src, "https://") do return .Remote
	if strings.has_prefix(src, "file:") do return .File
	if strings.has_prefix(src, "data:") {
		if strings.has_prefix(src, "data:image/") do return .Data
		return .Invalid
	}
	// Reject unsupported URI schemes while still accepting relative paths.
	for i in 0 ..< len(src) {
		c := src[i]
		if c == ':' {
			if i > 0 do return .Invalid
			break
		}
		if !(c >= 'a' && c <= 'z') && !(c >= 'A' && c <= 'Z') &&
		   !(c >= '0' && c <= '9') && c != '+' && c != '-' && c != '.' {
			break
		}
	}
	return .File
}

image_source_supported :: proc(src: string) -> bool {
	if len(src) == 0 do return false
	kind := image_source_kind(src)
	if kind == .Invalid do return false
	for i in 0 ..< len(src) {
		c := src[i]
		if c < 0x20 || c == 0x7f do return false
		if kind != .File && (c == ' ' || c == '"' || c == '<' || c == '>' || c == '`') {
			return false
		}
	}
	if kind == .Data do return strings.contains(src, ",")
	return true
}

image_key_hash :: proc(s: string) -> u64 {
	h: u64 = 1469598103934665603
	for i in 0 ..< len(s) {
		h = (h ~ u64(s[i])) * 1099511628211
	}
	return h
}

image_percent_decode :: proc(s: string, allocator := context.temp_allocator) -> string {
	if !strings.contains(s, "%") do return s
	b := strings.builder_make(allocator)
	i := 0
	for i < len(s) {
		if s[i] == '%' && i + 2 < len(s) {
			hi, ok_hi := hex_digit(s[i + 1])
			lo, ok_lo := hex_digit(s[i + 2])
			if ok_hi && ok_lo {
				strings.write_byte(&b, u8(hi * 16 + lo))
				i += 3
				continue
			}
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	return strings.to_string(b)
}

// image_resolve_local_path maps a file: URI or filesystem path to an absolute
// path. Relative paths are anchored at base_dir (the project root).
image_resolve_local_path :: proc(src, base_dir: string) -> (path: string, ok: bool) {
	p := src
	if strings.has_prefix(p, "file:") {
		rest := p[5:]
		if strings.has_prefix(rest, "//") {
			rest = rest[2:]
			if !strings.has_prefix(rest, "/") {
				if slash := strings.index_byte(rest, '/'); slash >= 0 {
					rest = rest[slash:]
				} else {
					return "", false
				}
			}
		}
		p = rest
	}
	p = image_percent_decode(p)
	if len(p) == 0 do return "", false
	if strings.has_prefix(p, "~/") {
		if home, err := os.user_home_dir(context.temp_allocator); err == nil && len(home) > 0 {
			p = strings.concatenate({home, p[1:]}, context.temp_allocator)
		}
	}
	if !filepath.is_abs(p) {
		base := base_dir
		if len(base) == 0 {
			if cwd, err := os.get_working_directory(context.temp_allocator); err == nil {
				base = cwd
			}
		}
		if joined, err := filepath.join({base, p}, context.temp_allocator); err == nil {
			p = joined
		}
	}
	if cleaned, err := filepath.clean(p, context.temp_allocator); err == nil {
		p = cleaned
	}
	return p, true
}

image_cache_init :: proc(c: ^Image_Cache) {
	c.entries = make([dynamic]^Image_Entry, 0, 8)
}

image_cache_destroy :: proc(c: ^Image_Cache) {
	for e in c.entries {
		if e.thread != nil {
			thread.destroy(e.thread)
			e.thread = nil
		}
		if e.texture != 0 {
			tex := e.texture
			gl.DeleteTextures(1, &tex)
		}
		if e.pixels != nil {
			mi_image_free(e.pixels)
			e.pixels = nil
		}
		delete(e.key)
		delete(e.source)
		delete(e.path)
		delete(e.error)
		free(e)
	}
	delete(c.entries)
}

// image_cache_get returns a stable cache entry, starting a background load on
// first use. Ready entries have their texture uploaded on the GUI thread.
image_cache_get :: proc(c: ^Image_Cache, source, base_dir: string) -> ^Image_Entry {
	if c == nil do return nil
	src := strings.trim_space(source)
	if !image_source_supported(src) do return nil

	kind := image_source_kind(src)
	path := ""
	if kind == .File {
		resolved, ok := image_resolve_local_path(src, base_dir)
		if !ok do return nil
		path = resolved
	}
	key := kind == .File ? path : src
	if kind == .Data do key = fmt.tprintf("data:%x:%d", image_key_hash(src), len(src))

	for e in c.entries {
		if e.key == key {
			image_entry_sync(e)
			return e
		}
	}

	e := new(Image_Entry)
	e.key = strings.clone(key)
	e.source = strings.clone(src)
	if kind == .File do e.path = strings.clone(path)
	e.state = .Pending
	append(&c.entries, e)

	e.thread = thread.create_and_start_with_poly_data(e, image_load_worker, name = "miagent-image")
	if e.thread == nil {
		e.state = .Failed
		e.error = strings.clone("could not start image loader")
	}
	return e
}

image_entry_sync :: proc(e: ^Image_Entry) {
	if e == nil do return
	t: ^thread.Thread
	done := false
	sync.lock(&e.mutex)
	if e.state == .Ready && e.texture == 0 && e.pixels != nil {
		image_upload_texture(e)
	}
	if e.state != .Pending {
		done = true
		t = e.thread
		e.thread = nil
	}
	sync.unlock(&e.mutex)
	if done && t != nil do thread.destroy(t)
}

image_entry_snapshot :: proc(e: ^Image_Entry) -> (state: Image_State, texture: u32, width, height: int) {
	if e == nil do return
	sync.lock(&e.mutex)
	state = e.state
	texture = e.texture
	width = e.width
	height = e.height
	sync.unlock(&e.mutex)
	return
}

image_upload_texture :: proc(e: ^Image_Entry) {
	if e.width <= 0 || e.height <= 0 {
		mi_image_free(e.pixels)
		e.pixels = nil
		e.state = .Failed
		delete(e.error)
		e.error = strings.clone("image has no usable dimensions")
		return
	}
	tex: u32
	gl.GenTextures(1, &tex)
	if tex == 0 {
		mi_image_free(e.pixels)
		e.pixels = nil
		e.state = .Failed
		delete(e.error)
		e.error = strings.clone("could not create image texture")
		return
	}
	gl.BindTexture(gl.TEXTURE_2D, tex)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, i32(gl.LINEAR))
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, i32(gl.LINEAR))
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, i32(gl.CLAMP_TO_EDGE))
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, i32(gl.CLAMP_TO_EDGE))
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	gl.TexImage2D(
		gl.TEXTURE_2D,
		0,
		i32(gl.RGBA),
		i32(e.width),
		i32(e.height),
		0,
		gl.RGBA,
		gl.UNSIGNED_BYTE,
		e.pixels,
	)
	gl.BindTexture(gl.TEXTURE_2D, 0)
	mi_image_free(e.pixels)
	e.pixels = nil
	e.texture = tex
}

image_load_worker :: proc(e: ^Image_Entry) {
	width, height: i32
	pixels: rawptr
	failure := ""

	switch image_source_kind(e.source) {
	case .File:
		if e.path == "" {
			failure = strings.clone("image path is empty")
			break
		}
		data, err := os.read_entire_file(e.path, context.allocator)
		if err != nil {
			failure = fmt.aprintf("could not read image: %v", err)
			break
		}
		defer delete(data)
		if len(data) > IMAGE_MAX_BYTES {
			failure = strings.clone("image is too large")
			break
		}
		pixels = mi_image_decode(raw_data(data), i32(len(data)), &width, &height)

	case .Data:
		comma := strings.index_byte(e.source, ',')
		if comma < 0 {
			failure = strings.clone("malformed data URI")
			break
		}
		meta := e.source[5:comma]
		if !strings.contains(meta, "base64") {
			failure = strings.clone("only base64 data URIs are supported")
			break
		}
		decoded, derr := base64.decode(e.source[comma + 1:])
		if derr != nil {
			failure = strings.clone("could not decode data URI")
			break
		}
		defer delete(decoded)
		if len(decoded) > IMAGE_MAX_BYTES {
			failure = strings.clone("image is too large")
			break
		}
		pixels = mi_image_decode(raw_data(decoded), i32(len(decoded)), &width, &height)

	case .Remote:
		out_len: uint
		data := mi_image_http_get(zstr(e.source), uint(IMAGE_MAX_BYTES), &out_len)
		if data == nil {
			failure = strings.clone("could not download image")
			break
		}
		defer mi_image_buf_free(data)
		pixels = mi_image_decode(data, i32(out_len), &width, &height)

	case .Invalid:
		failure = strings.clone("unsupported image source")
	}

	if pixels == nil && len(failure) == 0 {
		failure = strings.clone("could not decode image")
	}

	sync.lock(&e.mutex)
	e.width = int(width)
	e.height = int(height)
	e.pixels = pixels
	if len(failure) > 0 {
		e.state = .Failed
		e.error = strings.clone(failure)
	} else {
		e.state = .Ready
	}
	sync.unlock(&e.mutex)
	if len(failure) > 0 do delete(failure)
}

image_fit_rect :: proc(src_w, src_h: int, max_w, max_h: f32, allow_upscale: bool, max_scale: f32 = 0) -> Rect {
	if src_w <= 0 || src_h <= 0 || max_w <= 0 || max_h <= 0 do return {}
	scale := min(max_w / f32(src_w), max_h / f32(src_h))
	if !allow_upscale do scale = min(scale, 1.0)
	if max_scale > 0 do scale = min(scale, max_scale)
	if scale <= 0 do return {}
	return rect(0, 0, f32(src_w) * scale, f32(src_h) * scale)
}

// image_draw_markdown draws one block-level Markdown image and returns its
// height. Pending and failed loads render a small placeholder so the message
// does not jump around more than necessary.
image_draw_markdown :: proc(
	list: ^ImDrawList,
	font: ^ImFont,
	alt, src: string,
	x, y, w: f32,
	th: Theme,
	ctx: ^Md_Image_Context,
) -> f32 {
	if ctx == nil || ctx.cache == nil do return 0
	entry := image_cache_get(ctx.cache, src, ctx.base_dir)
	state, texture, img_w, img_h := image_entry_snapshot(entry)

	placeholder_h: f32 = 40
	if entry == nil || state == .Failed || texture == 0 {
		if entry != nil && state == .Pending {
			label := len(alt) > 0 ? fmt.tprintf("Loading image: %s", alt) : "Loading image..."
			panel(list, rect(x, y, min(w, 360), placeholder_h), mix(th.bg, th.fg, 0.025), 6, th.border_soft, 1)
			text_elided(list, font, 12.0, x + 12, y + 12, min(w, 360) - 24, th.fg_faint, label)
			return placeholder_h
		}
		label := len(alt) > 0 ? fmt.tprintf("Image unavailable: %s", alt) : "Image unavailable"
		panel(list, rect(x, y, min(w, 460), placeholder_h), over(th.bg, alpha(th.red, 0.07)), 6, alpha(th.red, 0.22), 1)
		text_elided(list, font, 12.0, x + 12, y + 12, min(w, 460) - 24, th.fg_faint, label)
		return placeholder_h
	}

	fit := image_fit_rect(img_w, img_h, min(w, IMAGE_THUMB_MAX_W) - 8, IMAGE_THUMB_MAX_H - 8, false)
	if fit.w <= 0 || fit.h <= 0 do return 0
	outer := rect(x, y, fit.w + 8, fit.h + 8)
	panel(list, outer, mix(th.bg, th.fg, 0.035), 7, alpha(th.border_soft, 0.95), 1)
	mi_draw_image(
		list,
		u64(texture),
		outer.x + 4,
		outer.y + 4,
		outer.x + 4 + fit.w,
		outer.y + 4 + fit.h,
		0, 0, 1, 1,
		color_u32(rgb(255, 255, 255)),
		5,
	)
	if ctx.rects != nil {
		append(ctx.rects, Md_Image_Rect{rect = outer, asset = entry, source = src, alt = alt})
	}
	return outer.h
}

image_viewer_open :: proc(v: ^Image_Viewer, asset: ^Image_Entry) {
	if asset == nil do return
	_, texture, _, _ := image_entry_snapshot(asset)
	if texture == 0 do return
	v.open = true
	v.asset = asset
	// The image overlay takes focus away from the composer/terminal without
	// changing their widget state; drop any active text edit so keystrokes do
	// not keep flowing into the pane behind it.
	igClearActiveID()
}

image_viewer_close :: proc(v: ^Image_Viewer) {
	v.open = false
	v.asset = nil
}

image_open_external :: proc(asset: ^Image_Entry) {
	if asset == nil do return
	if len(asset.path) > 0 {
		mi_open_path(zstr(asset.path))
		return
	}
	if len(asset.source) > 0 do mi_open_uri(zstr(asset.source))
}

// draw_image_viewer is a top-level overlay drawn after every other panel. It
// uses the foreground draw list so the image cannot end up underneath a window
// that was created later in the frame.
draw_image_viewer :: proc(app: ^App) {
	v := &app.image_viewer
	if !v.open || v.asset == nil || v.asset.texture == 0 {
		if v.open do image_viewer_close(v)
		return
	}

	if !mi_begin_overlay("##imageviewer", 0, 0, app.width, app.height) {
		igEnd()
		return
	}
	defer igEnd()

	th := app.th
	mi_io_set_mouse_cursor(i32(CURSOR_ARROW))
	// A full-screen invisible item makes the overlay own hover and click
	// handling, keeping the UI underneath inert.
	_ = hit(cstr("##imageviewerblock"), rect(0, 0, app.width, app.height))

	if igIsKeyPressed_Bool(KEY_ESCAPE, false) {
		app.shortcut_fired = true
		image_viewer_close(v)
		return
	}

	list := igGetForegroundDrawList_Nil()
	panel(list, rect(0, 0, app.width, app.height), rgb(0, 0, 0, 0.84), 0)

	margin := IMAGE_VIEW_MARGIN
	area := rect(margin, margin, max(app.width - margin * 2, 40), max(app.height - margin * 2, 40))
	fit := image_fit_rect(v.asset.width, v.asset.height, area.w, area.h, true, IMAGE_VIEW_MAX_SCALE)
	img := rect(
		area.x + (area.w - fit.w) * 0.5,
		area.y + (area.h - fit.h) * 0.5,
		fit.w,
		fit.h,
	)

	panel(list, rect(img.x - 10, img.y - 10, img.w + 20, img.h + 20), rgb(0, 0, 0, 0.35), 10)
	mi_draw_image(
		list,
		u64(v.asset.texture),
		img.x,
		img.y,
		img.x + img.w,
		img.y + img.h,
		0, 0, 1, 1,
		color_u32(rgb(255, 255, 255)),
		6,
	)
	panel(list, img, {0, 0, 0, 0}, 6, alpha(th.fg, 0.16), 1)

	label := "Open externally"
	tw, _ := measure(app.f.ui, 12.0, label)
	btn := rect(0, 0, tw + 24, 28)
	btn.x = img.x + img.w - btn.w - 10
	btn.y = img.y + 10
	if img.w < btn.w + 32 || img.h < 56 {
		btn.x = img.x + img.w - btn.w
		btn.y = max(img.y - btn.h - 8, area.y)
	}
	over_btn := rect_contains(btn, app.mouse.x, app.mouse.y)
	fill := alpha(th.bg_raised, over_btn ? 0.96 : 0.72)
	panel(list, btn, fill, 6, alpha(th.fg, over_btn ? 0.22 : 0.10), 1)
	ts := ui_text_px(12.0)
	text_font(list, app.f.ui, 12.0, btn.x + 12, btn.y + (btn.h - ts) * 0.5 - ts * 0.06,
		over_btn ? th.fg : th.fg_dim, label)

	over_img := rect_contains(img, app.mouse.x, app.mouse.y)
	if over_btn || over_img do mi_io_set_mouse_cursor(i32(CURSOR_HAND))

	if igIsMouseClicked_Bool(0, false) {
		if over_btn {
			image_open_external(v.asset)
		} else {
			// Clicking the image returns to the conversation. A click on the
			// dimmed backdrop behaves the same way.
			image_viewer_close(v)
		}
	}
}
