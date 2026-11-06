// Terminal colors and font settings. The defaults are compiled into the
// binary, so the GUI has a complete palette and font without reading another
// application's configuration. An optional theme.json in the MiAgent
// configuration directory (or MIAGENT_THEME) overrides any subset of them.
package main

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "harness"

Color :: [4]f32

THEME_CONFIG_FILE :: "theme.json"
THEME_CONFIG_ENV :: "MIAGENT_THEME"
THEME_CONFIG_VERSION :: 1
THEME_DEFAULT_SOURCE :: "built-in Tomorrow Night"

rgb :: proc(r, g, b: u8, a: f32 = 1.0) -> Color {
	return Color{f32(r) / 255.0, f32(g) / 255.0, f32(b) / 255.0, a}
}

Terminal_Theme :: struct {
	bg:          Color,
	fg:          Color,
	cursor:      Color,
	cursor_text: Color,
	sel_bg:      Color,
	sel_fg:      Color,
	ansi:        [16]Color,

	font_family:  string,
	font_size:    f32,
	// Optional explicit font files. When empty, font_family is looked up in
	// the usual Linux font directories.
	font_regular: string,
	font_bold:    string,
	font_emoji:   string,

	source: string,
}

// terminal_theme_defaults is the Tomorrow Night palette the GUI used to read
// from kitty.conf, now compiled in as the fallback.
terminal_theme_defaults :: proc(allocator := context.allocator) -> Terminal_Theme {
	return Terminal_Theme {
		bg = rgb(0x1d, 0x1f, 0x21),
		fg = rgb(0xc5, 0xc8, 0xc6),
		cursor = rgb(0xc5, 0xc8, 0xc6),
		cursor_text = rgb(0x00, 0x00, 0x00),
		sel_bg = rgb(0xc5, 0xc8, 0xc6),
		sel_fg = rgb(0x1d, 0x1f, 0x21),
		ansi = {
			rgb(0x1d, 0x1f, 0x21), // 0 black
			rgb(0xcc, 0x66, 0x66), // 1 red
			rgb(0xb5, 0xbd, 0x68), // 2 green
			rgb(0xf0, 0xc6, 0x74), // 3 yellow
			rgb(0x81, 0xa2, 0xbe), // 4 blue
			rgb(0xb2, 0x94, 0xbb), // 5 magenta
			rgb(0x8a, 0xbe, 0xb7), // 6 cyan
			rgb(0xc5, 0xc8, 0xc6), // 7 white
			rgb(0x66, 0x66, 0x66), // 8 bright black
			rgb(0xd5, 0x4e, 0x53), // 9 bright red
			rgb(0xb9, 0xca, 0x4a), // 10 bright green
			rgb(0xe7, 0xc5, 0x47), // 11 bright yellow
			rgb(0x7a, 0xa6, 0xda), // 12 bright blue
			rgb(0xc3, 0x97, 0xd8), // 13 bright magenta
			rgb(0x70, 0xc0, 0xb1), // 14 bright cyan
			rgb(0xea, 0xea, 0xea), // 15 bright white
		},
		font_family = strings.clone("Fira Code", allocator),
		font_size = 9.0,
		source = strings.clone(THEME_DEFAULT_SOURCE, allocator),
	}
}

terminal_theme_destroy :: proc(t: ^Terminal_Theme) {
	delete(t.font_family)
	delete(t.font_regular)
	delete(t.font_bold)
	delete(t.font_emoji)
	delete(t.source)
	t^ = {}
}

hex_nibble :: proc(c: u8) -> (int, bool) {
	switch {
	case c >= '0' && c <= '9': return int(c - '0'), true
	case c >= 'a' && c <= 'f': return int(c - 'a') + 10, true
	case c >= 'A' && c <= 'F': return int(c - 'A') + 10, true
	}
	return 0, false
}

hex_byte :: proc(s: string, i: int) -> (u8, bool) {
	a, ok_a := hex_nibble(s[i])
	b, ok_b := hex_nibble(s[i + 1])
	if !ok_a || !ok_b do return 0, false
	return u8(a * 16 + b), true
}

// #rgb, #rrggbb, and #rrggbbaa.
parse_hex_color :: proc(s: string) -> (Color, bool) {
	v := s
	if len(v) > 0 && v[0] == '#' do v = v[1:]
	switch len(v) {
	case 3:
		r, ok_r := hex_nibble(v[0])
		g, ok_g := hex_nibble(v[1])
		b, ok_b := hex_nibble(v[2])
		if !ok_r || !ok_g || !ok_b do return {}, false
		return rgb(u8(r * 17), u8(g * 17), u8(b * 17)), true
	case 6, 8:
		r, ok_r := hex_byte(v, 0)
		g, ok_g := hex_byte(v, 2)
		b, ok_b := hex_byte(v, 4)
		if !ok_r || !ok_g || !ok_b do return {}, false
		a: u8 = 0xff
		if len(v) == 8 {
			if av, ok := hex_byte(v, 6); ok do a = av
		}
		return rgb(r, g, b, f32(a) / 255.0), true
	}
	return {}, false
}

// The JSON representation keeps colors as strings and leaves every field
// optional, so a theme.json only needs the settings a user wants to change.
// Missing fields keep the compiled-in defaults (json.unmarshal only assigns
// the keys that are present).
Terminal_Theme_File :: struct {
	version:              int      `json:"version"`,
	background:           string   `json:"background"`,
	foreground:           string   `json:"foreground"`,
	cursor:               string   `json:"cursor"`,
	cursor_text:          string   `json:"cursor_text"`,
	selection_background: string   `json:"selection_background"`,
	selection_foreground: string   `json:"selection_foreground"`,
	palette:              []string `json:"palette"`,
	font_family:          string   `json:"font_family"`,
	font_size:            f32      `json:"font_size"`,
	font_regular:         string   `json:"font_regular"`,
	font_bold:            string   `json:"font_bold"`,
	font_emoji:           string   `json:"font_emoji"`,
}

theme_config_path :: proc() -> string {
	if p := os.get_env(THEME_CONFIG_ENV, context.temp_allocator); len(p) > 0 {
		if os.is_absolute_path(p) do return strings.clone(p)
		dir := harness.config_dir_path()
		defer delete(dir)
		return fmt.aprintf("%s/%s", dir, p)
	}
	dir := harness.config_dir_path()
	defer delete(dir)
	return fmt.aprintf("%s/%s", dir, THEME_CONFIG_FILE)
}

theme_append_note :: proc(note: ^string, msg: string) {
	if len(note^) == 0 {
		note^ = strings.clone(msg)
		return
	}
	old := note^
	note^ = fmt.aprintf("%s\n%s", old, msg)
	delete(old)
}

terminal_theme_file_destroy :: proc(f: ^Terminal_Theme_File) {
	delete(f.background)
	delete(f.foreground)
	delete(f.cursor)
	delete(f.cursor_text)
	delete(f.selection_background)
	delete(f.selection_foreground)
	for value in f.palette do delete(value)
	delete(f.palette)
	delete(f.font_family)
	delete(f.font_regular)
	delete(f.font_bold)
	delete(f.font_emoji)
	f^ = {}
}

theme_apply_color :: proc(dst: ^Color, value, path, field: string, note: ^string) {
	v := strings.trim_space(value)
	if len(v) == 0 do return
	c, ok := parse_hex_color(v)
	if !ok {
		theme_append_note(note, fmt.tprintf("%s: invalid %s color %q", path, field, value))
		return
	}
	dst^ = c
}

theme_apply_string :: proc(dst: ^string, value: string, allocator: mem.Allocator) {
	v := strings.trim_space(value)
	if len(v) == 0 do return
	delete(dst^)
	dst^ = strings.clone(v, allocator)
}

// theme_config_apply_json applies a parsed JSON document to a theme. It keeps
// going after a bad field so one typo does not discard the rest of a user's
// configuration.
theme_config_apply_json :: proc(t: ^Terminal_Theme, data, path: string, allocator := context.allocator) -> string {
	f: Terminal_Theme_File
	defer terminal_theme_file_destroy(&f)
	if err := json.unmarshal_string(data, &f); err != nil {
		return fmt.aprintf("reading %s: %v", path, err)
	}

	note := ""
	if f.version > THEME_CONFIG_VERSION {
		theme_append_note(&note, fmt.tprintf("%s: unsupported version %d (this build understands %d)", path, f.version, THEME_CONFIG_VERSION))
	}
	theme_apply_color(&t.bg, f.background, path, "background", &note)
	theme_apply_color(&t.fg, f.foreground, path, "foreground", &note)
	theme_apply_color(&t.cursor, f.cursor, path, "cursor", &note)
	theme_apply_color(&t.cursor_text, f.cursor_text, path, "cursor_text", &note)
	theme_apply_color(&t.sel_bg, f.selection_background, path, "selection_background", &note)
	theme_apply_color(&t.sel_fg, f.selection_foreground, path, "selection_foreground", &note)

	if len(f.palette) > 0 {
		if len(f.palette) != 16 {
			theme_append_note(&note, fmt.tprintf("%s: palette must contain 16 colors, got %d", path, len(f.palette)))
		} else {
			for value, i in f.palette {
				field := fmt.tprintf("palette[%d]", i)
				theme_apply_color(&t.ansi[i], value, path, field, &note)
			}
		}
	}

	theme_apply_string(&t.font_family, f.font_family, allocator)
	if f.font_size > 0 {
		if f.font_size < 5 || f.font_size > 72 {
			theme_append_note(&note, fmt.tprintf("%s: font_size must be between 5 and 72 (got %g)", path, f.font_size))
		} else {
			t.font_size = f.font_size
		}
	}
	theme_apply_string(&t.font_regular, f.font_regular, allocator)
	theme_apply_string(&t.font_bold, f.font_bold, allocator)
	theme_apply_string(&t.font_emoji, f.font_emoji, allocator)
	return note
}

theme_config_load :: proc(allocator := context.allocator) -> (Terminal_Theme, string) {
	t := terminal_theme_defaults(allocator)
	path := theme_config_path()
	defer delete(path)
	if !os.exists(path) do return t, ""

	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return t, fmt.aprintf("reading %s: %v", path, err)

	note := theme_config_apply_json(&t, string(data), path, allocator)
	delete(t.source)
	t.source = strings.clone(path, allocator)
	return t, note
}

// font_family_stem turns a fontconfig-style family ("Fira Code", "JetBrains
// Mono") into the stem commonly used by font files ("FiraCode",
// "JetBrainsMono").
font_family_stem :: proc(family: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for r in family {
		if r == ' ' || r == '\t' || r == '-' || r == '_' do continue
		strings.write_rune(&b, r)
	}
	return strings.to_string(b)
}

// font_find_in_dir is the last-resort family lookup: it walks the font tree
// and matches the same filename stems as the direct search, so a family
// installed in a distro-specific subdirectory still works. Depth keeps the
// scan bounded.
font_find_in_dir :: proc(dir: string, names: []string, depth: int, allocator: mem.Allocator) -> string {
	if depth < 0 do return ""
	infos, err := os.read_all_directory_by_path(dir, allocator)
	if err != nil do return ""
	defer os.file_info_slice_delete(infos, allocator)

	for fi in infos {
		if fi.type != .Regular do continue
		for name in names {
			if strings.equal_fold(fi.name, name) {
				return strings.clone(fi.fullpath, allocator)
			}
		}
	}
	for fi in infos {
		if fi.type != .Directory do continue
		if path := font_find_in_dir(fi.fullpath, names, depth - 1, allocator); len(path) > 0 {
			return path
		}
	}
	return ""
}

// theme_font_path resolves the terminal font. An explicit font_regular /
// font_bold path wins; otherwise the family is looked up in the conventional
// system and user font directories, falling back to the caller's built-in
// Fira Code / DejaVu candidates.
theme_font_path :: proc(t: Terminal_Theme, bold: bool, allocator := context.temp_allocator) -> string {
	explicit := bold ? t.font_bold : t.font_regular
	if len(explicit) > 0 {
		if os.exists(explicit) do return explicit
	}

	family := strings.trim_space(t.font_family)
	if len(family) == 0 do return ""
	if strings.contains(family, "/") || strings.has_suffix(family, ".ttf") || strings.has_suffix(family, ".otf") {
		if os.exists(family) do return family
		return ""
	}

	stem := font_family_stem(family, allocator)
	weight := bold ? "Bold" : "Regular"
	names := []string{
		fmt.tprintf("%s-%s.ttf", stem, weight),
		fmt.tprintf("%s-%s.otf", stem, weight),
		fmt.tprintf("%s.ttf", stem),
		fmt.tprintf("%s.otf", stem),
	}

	lower := strings.to_lower(stem, allocator)
	dirs := make([dynamic]string, 0, 16, allocator)
	append(&dirs,
		"/usr/share/fonts/TTF",
		"/usr/share/fonts/truetype",
		"/usr/share/fonts/opentype",
		fmt.tprintf("/usr/share/fonts/truetype/%s", lower),
		fmt.tprintf("/usr/share/fonts/opentype/%s", lower),
		"/usr/local/share/fonts",
		"/usr/local/share/fonts/TTF",
	)
	if home, err := os.user_home_dir(allocator); err == nil {
		append(&dirs,
			fmt.tprintf("%s/.local/share/fonts", home),
			fmt.tprintf("%s/.local/share/fonts/TTF", home),
			fmt.tprintf("%s/.fonts", home),
			fmt.tprintf("%s/.fonts/TTF", home),
		)
	}
	if data_home := os.get_env("XDG_DATA_HOME", allocator); len(data_home) > 0 {
		append(&dirs,
			fmt.tprintf("%s/fonts", data_home),
			fmt.tprintf("%s/fonts/TTF", data_home),
		)
	}

	for dir in dirs {
		for name in names {
			path := fmt.tprintf("%s/%s", dir, name)
			if os.exists(path) do return path
		}
	}

	roots := make([dynamic]string, 0, 8, allocator)
	append(&roots, "/usr/share/fonts", "/usr/local/share/fonts")
	if home, err := os.user_home_dir(allocator); err == nil {
		append(&roots, fmt.tprintf("%s/.local/share/fonts", home), fmt.tprintf("%s/.fonts", home))
	}
	if data_home := os.get_env("XDG_DATA_HOME", allocator); len(data_home) > 0 {
		append(&roots, fmt.tprintf("%s/fonts", data_home))
	}
	for root in roots {
		if path := font_find_in_dir(root, names, 4, allocator); len(path) > 0 do return path
	}
	return ""
}

// Scalable emoji fonts. Noto Color Emoji is deliberately absent: current
// releases are CBDT bitmap fonts with a single 109px strike, which neither
// stb_truetype nor imgui_freetype can scale down to UI sizes. These names are
// monochrome outline fonts that the existing rasterizer can use.
FONT_EMOJI_NAMES := [?]string{
	"NotoEmoji-Regular.ttf",
	"NotoEmoji-VariableFont_wght.ttf",
	"NotoEmoji[wght].ttf",
	"OpenMoji-Black.ttf",
	"Symbola.ttf",
	"Symbola_hint.ttf",
}

// theme_emoji_font_path finds the emoji fallback. The bundled Noto Emoji is
// installed under <config>/fonts (or found next to a development build), then
// system fonts are searched in name order.
theme_emoji_font_path :: proc(t: Terminal_Theme, allocator := context.temp_allocator) -> string {
	if len(t.font_emoji) > 0 && os.exists(t.font_emoji) do return t.font_emoji

	dir := harness.config_dir_path()
	defer delete(dir)
	bundled := fmt.tprintf("%s/fonts/NotoEmoji-Regular.ttf", dir)
	if os.exists(bundled) do return bundled

	for candidate in ([]string{
		"assets/fonts/NotoEmoji-Regular.ttf",
		"../assets/fonts/NotoEmoji-Regular.ttf",
	}) {
		if os.exists(candidate) do return candidate
	}
	if exe_dir, err := os.get_executable_directory(allocator); err == nil {
		for candidate in ([]string{
			fmt.tprintf("%s/assets/fonts/NotoEmoji-Regular.ttf", exe_dir),
			fmt.tprintf("%s/../assets/fonts/NotoEmoji-Regular.ttf", exe_dir),
		}) {
			if os.exists(candidate) do return candidate
		}
	}

	roots := make([dynamic]string, 0, 8, allocator)
	append(&roots, "/usr/share/fonts", "/usr/local/share/fonts")
	if home, err := os.user_home_dir(allocator); err == nil {
		append(&roots, fmt.tprintf("%s/.local/share/fonts", home), fmt.tprintf("%s/.fonts", home))
	}
	if data_home := os.get_env("XDG_DATA_HOME", allocator); len(data_home) > 0 {
		append(&roots, fmt.tprintf("%s/fonts", data_home))
	}
	for name in FONT_EMOJI_NAMES {
		for root in roots {
			if path := font_find_in_dir(root, []string{name}, 4, allocator); len(path) > 0 do return path
		}
	}
	return ""
}
