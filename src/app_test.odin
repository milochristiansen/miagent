package main

import "core:math"
import "core:testing"

@(test)
test_drawer_width_clamps :: proc(t: ^testing.T) {
	app := App{width = 1440}
	testing.expectf(t, math.abs(drawer_base_width(&app) - 576) < 0.01,
		"default drawer width: got %.2f", drawer_base_width(&app))

	app.drawer_width = 100
	testing.expect_value(t, drawer_base_width(&app), DRAWER_MIN_W)

	app.drawer_width = 10000
	testing.expect_value(t, drawer_base_width(&app), drawer_max_width(&app))

	// A narrower window lowers the cap so the conversation always keeps its
	// usable width.
	app.width = 1120
	testing.expect_value(t, drawer_base_width(&app), drawer_max_width(&app))
	testing.expect(t, drawer_max_width(&app) >= DRAWER_MIN_W)
}

@(test)
test_ui_text_sizes_are_integral :: proc(t: ^testing.T) {
	sizes := [?]f32{9.5, 10.0, 10.5, 11.0, 11.5, 12.0, 12.5, 13.0, 15.0}
	for size in sizes {
		px := ui_text_px(size)
		testing.expectf(t, px == math.round(px),
			"ui_text_px(%.1f) should be a whole pixel, got %.3f", size, px)
	}
}
