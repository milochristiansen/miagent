// The public streaming Renderer: Markdown arrives in chunks, and each tick
// re-renders the last top-level block while committing everything before it.
package termark

import "core:io"
import "core:strings"
import "core:unicode/utf8"

Renderer :: struct {
	w:     io.Writer,
	style: Style,

	width:      int,
	auto_width: bool,

	buf:           strings.Builder,
	committed_end: int,

	screen: Screen,

	tail_data:  string,
	tail_lines: []Line,

	closed: bool,
}

ERR_CLOSED :: "termark: renderer is closed"
ERR_NOT_TTY :: "termark: output is not a TTY"

// new_renderer creates a streaming renderer. width 0 means auto: the terminal
// width is re-polled on every tick.
new_renderer :: proc(w: io.Writer, style_name: string, width: int) -> (^Renderer, string) {
	style, err := resolve_style_name(style_name)
	if err != "" do return nil, err

	auto := width == 0
	W := width
	if auto {
		if !stdout_is_tty() do return nil, ERR_NOT_TTY
		if tw, _, ok := stdout_size(); ok {
			W = tw
		} else {
			W = 80
		}
	}
	W = max(W, 1)

	r := new(Renderer)
	r.w = w
	r.style = style
	r.width = W
	r.auto_width = auto
	r.buf = strings.builder_make()
	r.screen = new_screen(W, w)
	return r, ""
}

renderer_destroy :: proc(r: ^Renderer) {
	if r == nil do return
	delete(r.buf.buf)
	delete(r.tail_data)
	delete(r.tail_lines)
	free(r)
}

renderer_write :: proc(r: ^Renderer, s: string) {
	if r.closed do return
	strings.write_string(&r.buf, s)
	renderer_tick(r)
}

renderer_flush :: proc(r: ^Renderer) {
	if r.closed do return
	renderer_tick(r)
}

renderer_close :: proc(r: ^Renderer) {
	if r == nil || r.closed do return
	renderer_tick(r)
	screen_close(&r.screen)
	r.closed = true
}

line_start :: proc(b: string, s: int) -> int {
	i := s - 1
	for i >= 0 {
		if b[i] == '\n' do return i + 1
		i -= 1
	}
	return 0
}

// preceding_blank_start returns the start of the run of blank (newline-only)
// lines immediately before offset. The committed part ends here: the blank
// separator between blocks belongs to the tail, not the cache.
preceding_blank_start :: proc(b: string, offset: int) -> int {
	i := offset
	for i > 0 && b[i - 1] == '\n' {
		if line_start(b, i - 1) != i - 1 do break
		i -= 1
	}
	return i
}

trim_incomplete_rune :: proc(b: string) -> string {
	if len(b) == 0 || b[len(b) - 1] < 0x80 do return b
	start := len(b) - 1
	for start > 0 && (b[start] & 0xc0) == 0x80 do start -= 1
	_, size := utf8.decode_rune_in_string(b[start:])
	if size != len(b) - start {
		return b[:start]
	}
	return b
}

renderer_tick :: proc(r: ^Renderer) {
	free_all(context.temp_allocator)
	if r.auto_width {
		if w, _, ok := stdout_size(); ok && w != r.width && w > 0 {
			r.width = w
			screen_resize(&r.screen, w)
		}
	}

	input := trim_incomplete_rune(strings.to_string(r.buf))
	lines := split_source_lines(input)
	defer delete(lines)
	if len(lines) == 0 {
		screen_update_tail(&r.screen, nil)
		delete(r.tail_data)
		delete(r.tail_lines)
		r.tail_data = ""
		r.tail_lines = nil
		return
	}
	blocks := scan_blocks(lines, 0, len(lines))
	defer delete(blocks)
	nonempty := make([dynamic]Block, 0, len(blocks))
	defer delete(nonempty)
	for b in blocks {
		if !block_is_empty(lines, b) do append(&nonempty, b)
	}
	if len(nonempty) == 0 {
		screen_update_tail(&r.screen, nil)
		delete(r.tail_data)
		delete(r.tail_lines)
		r.tail_data = ""
		r.tail_lines = nil
		return
	}

	last := nonempty[len(nonempty) - 1]
	stable_end := preceding_blank_start(input, lines[last.lo].start)
	new_committed: []Line
	stable_out: Render_Output
	have_stable := false
	if stable_end > r.committed_end {
		stable_out = render_markdown(input[r.committed_end:stable_end], r.style, r.width)
		if len(stable_out.lines) > 0 {
			combined := make([]Line, len(stable_out.lines) + 1)
			copy(combined, stable_out.lines)
			combined[len(stable_out.lines)] = Line{}
			new_committed = combined
			have_stable = true
		} else {
			render_output_destroy(&stable_out)
			stable_out = {}
		}
		r.committed_end = stable_end
	}

	tail_text := input[stable_end:]
	out := render_markdown(tail_text, r.style, r.width)
	if have_stable {
		screen_commit_and_update(&r.screen, new_committed, out.lines)
		delete(new_committed)
		render_output_destroy(&stable_out)
	} else {
		screen_update_tail(&r.screen, out.lines)
	}

	delete(r.tail_data)
	delete(r.tail_lines)
	r.tail_data = out.data
	r.tail_lines = out.lines
}
