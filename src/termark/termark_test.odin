package termark

import "core:strings"
import "core:testing"

visible_lines :: proc(md: string, width: int, style := "dark") -> []string {
	st, _ := resolve_style_name(style)
	out := render_markdown(md, st, width)
	lines := make([dynamic]string, 0, len(out.lines))
	for line in out.lines {
		plain := strip_ansi(line.text)
		append(&lines, strings.clone(plain))
	}
	render_output_destroy(&out)
	return lines[:]
}

free_lines :: proc(lines: []string) {
	for l in lines do delete(l)
	delete(lines)
}

@(test)
test_markdown_blocks :: proc(t: ^testing.T) {
	md := "# Heading One\n\n- first\n- second\n\n1. one\n2. two\n\n> quote\n\n```go\nfunc main() {}\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |\n"
	got := visible_lines(md, 40)
	defer free_lines(got)
	code_header := strings.concatenate({"─ go ", strings.repeat("─", 35)})
	code_footer := strings.repeat("─", 40)
	defer delete(code_header)
	defer delete(code_footer)
	want := []string{
		"# Heading One",
		"",
		"  • first",
		"  • second",
		"",
		"  1. one",
		"  2. two",
		"",
		"│ quote",
		"",
		code_header,
		"func main() {}",
		code_footer,
		"",
		"┌───┬───┐",
		"│ A │ B │",
		"├───┼───┤",
		"│ 1 │ 2 │",
		"└───┴───┘",
	}
	if !testing.expect_value(t, len(got), len(want)) {
		for g in got do testing.expectf(t, false, "got %q", g)
		return
	}
	for g, i in got do testing.expect_value(t, g, want[i])
}

@(test)
test_reasoning_heading_is_not_subdued :: proc(t: ^testing.T) {
	got := visible_lines("# Heading\n", 40, "reasoning")
	defer free_lines(got)
	testing.expect_value(t, got[0], "# Heading")
}

@(test)
test_code_highlight_preserves_visible_text :: proc(t: ^testing.T) {
	md := "```python\ndef f(x):\n\treturn \"hi\" + str(42)\n```\n"
	got := visible_lines(md, 60)
	defer free_lines(got)
	testing.expect_value(t, got[1], "def f(x):")
	testing.expect_value(t, got[2], "    return \"hi\" + str(42)")
}

// The screen manager appends an EL after every tail line to clear stale cells.
// A code row must therefore end with the code-block background active, or that
// second EL erases the row's background fill back to the terminal default.
@(test)
test_code_rows_leave_background_active_for_screen_el :: proc(t: ^testing.T) {
	st, _ := resolve_style_name("dark")
	bg := bg_sgr(st.code_block_bg)
	want_suffix := strings.concatenate({bg, EL}, context.temp_allocator)

	cases := []struct {
		md, needle, suffix: string
	}{
		// Syntax-highlighted rows reset after each token, so the highlighter
		// must reopen the background before the fill EL.
		{"```go\nfunc main() {}\n```\n", "func", want_suffix},
		// Plain rows are written with the background active from the start.
		{"```text\nplain code\n```\n", "plain code", EL},
	}
	for c in cases {
		out := render_markdown(c.md, st, 40)
		defer render_output_destroy(&out)
		found := false
		for line in out.lines {
			if strings.contains(line.text, c.needle) {
				found = true
				testing.expectf(t, strings.has_suffix(line.text, c.suffix),
					"code row must end with %q, got %q", c.suffix, line.text)
			}
		}
		testing.expect(t, found, "code content row was not rendered")
	}
}

@(test)
test_expand_tabs :: proc(t: ^testing.T) {
	cases := [][3]string{
		{"\talpha", "    alpha", ""},
		{"\t\talpha", "        alpha", ""},
		{"ab\tcd", "ab  cd", ""},
	}
	for c in cases {
		got, _ := expand_tabs(c[0], 0)
		testing.expect_value(t, got, c[1])
		delete(got)
	}
}

@(test)
test_width_and_elided_note :: proc(t: ^testing.T) {
	testing.expect_value(t, visible_width("ab界"), 4)
	testing.expect_value(t, elided_note(0), "")
	testing.expect_value(t, elided_note(1), "1 Line Elided")
	testing.expect_value(t, elided_note(3), "3 Lines Elided")
	testing.expect_value(t, limit_rows(30, 24), 24)
	testing.expect_value(t, limit_rows(0, 24), 0)
}
