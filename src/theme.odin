// The UI palette, derived from the terminal theme so the app and the embedded
// shells agree on every color.
package main



Theme :: struct {
	// Surfaces
	bg:         Color,
	bg_deep:    Color,
	bg_panel:   Color,
	bg_raised:  Color,
	bg_hover:   Color,
	bg_active:  Color,
	border:     Color,
	border_soft: Color,

	// Text
	fg:       Color,
	fg_dim:   Color,
	fg_faint: Color,

	// Semantic
	accent:    Color,
	accent_hi: Color,
	green:     Color,
	yellow:    Color,
	red:       Color,
	magenta:   Color,
	cyan:      Color,

	// Terminal
	ansi:   [16]Color,
	term_bg: Color,
	term_fg: Color,
	cursor: Color,
	sel_bg: Color,
	sel_fg: Color,

	source: string,
}

mix :: proc(a, b: Color, t: f32) -> Color {
	u := clamp(t, 0, 1)
	return Color {
		a[0] + (b[0] - a[0]) * u,
		a[1] + (b[1] - a[1]) * u,
		a[2] + (b[2] - a[2]) * u,
		a[3] + (b[3] - a[3]) * u,
	}
}

alpha :: proc(c: Color, a: f32) -> Color {
	return Color{c[0], c[1], c[2], a}
}

// Overlay `c` on top of an opaque backdrop, keeping the result opaque. Used to
// get tinted cards without introducing real alpha blending.
over :: proc(backdrop, c: Color) -> Color {
	t := c[3]
	return Color {
		backdrop[0] * (1 - t) + c[0] * t,
		backdrop[1] * (1 - t) + c[1] * t,
		backdrop[2] * (1 - t) + c[2] * t,
		1.0,
	}
}

color_u32 :: proc(c: Color) -> ImU32 {
	return pack_color(c[0], c[1], c[2], c[3])
}

theme_init :: proc(k: Terminal_Theme, allocator := context.allocator) -> Theme {
	t := Theme{}
	t.term_bg = k.bg
	t.term_fg = k.fg
	t.cursor = k.cursor
	t.sel_bg = k.sel_bg
	t.sel_fg = k.sel_fg
	t.ansi = k.ansi
	t.source = k.source

	t.bg = k.bg
	t.bg_deep = mix(k.bg, rgb(0, 0, 0), 0.35)
	t.bg_panel = mix(k.bg, k.fg, 0.035)
	t.bg_raised = mix(k.bg, k.fg, 0.065)
	t.bg_hover = mix(k.bg, k.fg, 0.055)
	t.bg_active = mix(k.bg, k.fg, 0.10)

	t.border = mix(k.bg, k.fg, 0.14)
	t.border_soft = mix(k.bg, k.fg, 0.075)

	t.fg = k.fg
	t.fg_dim = mix(k.fg, k.bg, 0.42)
	t.fg_faint = mix(k.fg, k.bg, 0.64)

	t.accent = k.ansi[4]
	t.accent_hi = k.ansi[12]
	t.green = k.ansi[2]
	t.yellow = k.ansi[3]
	t.red = k.ansi[1]
	t.magenta = k.ansi[5]
	t.cyan = k.ansi[6]

	return t
}

// Push the palette into Dear ImGui so the few stock widgets we use (the
// composer's text field, scrollbars, popups) match the hand-drawn ones.
theme_apply_imgui :: proc(t: Theme) {

	set :: proc(idx: ImGuiCol, c: Color) {
		mi_style_color(i32(idx), c[0], c[1], c[2], c[3])
	}
	set(COL_TEXT, t.fg)
	set(COL_TEXT_DISABLED, t.fg_faint)
	set(COL_WINDOW_BG, t.bg)
	set(COL_CHILD_BG, Color{0, 0, 0, 0})
	set(COL_POPUP_BG, t.bg_panel)
	set(COL_BORDER, t.border)
	set(COL_FRAME_BG, t.bg_raised)
	set(COL_FRAME_BG_HOVERED, mix(t.bg_raised, t.fg, 0.06))
	set(COL_FRAME_BG_ACTIVE, mix(t.bg_raised, t.fg, 0.10))
	set(COL_SCROLLBAR_BG, Color{0, 0, 0, 0})
	set(COL_SCROLLBAR_GRAB, alpha(t.fg, 0.18))
	set(COL_SCROLLBAR_GRAB_HOVERED, alpha(t.fg, 0.30))
	set(COL_SCROLLBAR_GRAB_ACTIVE, alpha(t.fg, 0.40))
	set(COL_CHECK_MARK, t.accent)
	set(COL_BUTTON, t.bg_raised)
	set(COL_BUTTON_HOVERED, t.bg_hover)
	set(COL_BUTTON_ACTIVE, t.bg_active)
	set(COL_HEADER, t.bg_active)
	set(COL_HEADER_HOVERED, t.bg_hover)
	set(COL_HEADER_ACTIVE, t.bg_active)
	set(COL_SEPARATOR, t.border_soft)
	set(COL_TEXT_SELECTED_BG, alpha(t.accent, 0.35))
	set(COL_NAV_CURSOR, t.accent)
}
