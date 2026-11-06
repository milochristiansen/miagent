package main

import "core:math"
import "core:testing"

@(test)
test_parse_hex_color :: proc(t: ^testing.T) {
	c, ok := parse_hex_color("#abc")
	testing.expect(t, ok)
	testing.expect(t, c == rgb(0xaa, 0xbb, 0xcc))

	c, ok = parse_hex_color("#11223380")
	testing.expect(t, ok)
	testing.expect(t, c == rgb(0x11, 0x22, 0x33, f32(0x80) / 255.0))

	_, ok = parse_hex_color("#12")
	testing.expect(t, !ok)
	_, ok = parse_hex_color("not-a-color")
	testing.expect(t, !ok)
}

@(test)
test_terminal_theme_defaults :: proc(t: ^testing.T) {
	th := terminal_theme_defaults()
	defer terminal_theme_destroy(&th)

	testing.expect_value(t, th.bg, rgb(0x1d, 0x1f, 0x21))
	testing.expect_value(t, th.ansi[1], rgb(0xcc, 0x66, 0x66))
	testing.expect_value(t, th.font_family, "Fira Code")
	testing.expect(t, math.abs(th.font_size - 9.0) < 0.001)
	testing.expect_value(t, th.source, THEME_DEFAULT_SOURCE)
}

@(test)
test_theme_config_partial_override :: proc(t: ^testing.T) {
	th := terminal_theme_defaults()
	defer terminal_theme_destroy(&th)

	json := `{
		"background": "#010203",
		"font_family": "Hack",
		"font_size": 12,
		"font_emoji": "/tmp/emoji-font.ttf",
		"palette": [
			"#000000", "#111111", "#222222", "#333333",
			"#444444", "#555555", "#666666", "#777777",
			"#888888", "#999999", "#aaaaaa", "#bbbbbb",
			"#cccccc", "#dddddd", "#eeeeee", "#ffffff"
		]
	}`
	note := theme_config_apply_json(&th, json, "test-theme.json")
	defer if len(note) > 0 { delete(note) }
	testing.expect_value(t, note, "")
	testing.expect_value(t, th.bg, rgb(0x01, 0x02, 0x03))
	// Fields the file did not mention keep the compiled-in defaults.
	testing.expect_value(t, th.fg, rgb(0xc5, 0xc8, 0xc6))
	testing.expect_value(t, th.ansi[4], rgb(0x44, 0x44, 0x44))
	testing.expect_value(t, th.font_family, "Hack")
	testing.expect_value(t, th.font_emoji, "/tmp/emoji-font.ttf")
	testing.expect(t, math.abs(th.font_size - 12.0) < 0.001)
}

@(test)
test_theme_config_reports_bad_values :: proc(t: ^testing.T) {
	th := terminal_theme_defaults()
	defer terminal_theme_destroy(&th)
	original := th.bg

	note := theme_config_apply_json(&th, `{"background": "nope", "palette": ["#fff"]}`, "bad.json")
	defer if len(note) > 0 { delete(note) }
	testing.expect(t, len(note) > 0)
	testing.expect_value(t, th.bg, original)
}
