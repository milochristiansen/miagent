// LiveBox renders an open code box whose rows can be appended live while a
// tool runs, interleaving stdout and stderr in arrival order. With a positive
// limit the streamed output is a window over the last rows; with limit 0 every
// row is committed as it completes.
package termark

import "core:fmt"
import "core:io"
import "core:strings"

Code_Seg :: struct {
	color: string, // "" means the code-block foreground
	text:  string,
}

Live_Box :: struct {
	w:     io.Writer,
	style: Style,
	W:     int,

	Limit:  int,
	height: int,

	open: bool,

	tail: [dynamic]Code_Seg,

	out:   [dynamic][dynamic]Code_Seg,
	drawn: int,
	total: int,

	header_label: string,
	header_set:   bool,

	inputs: int,
}

seg_destroy :: proc(s: ^Code_Seg) {
	delete(s.text)
	s^ = {}
}

row_destroy :: proc(row: [dynamic]Code_Seg) {
	for &s in row do seg_destroy(&s)
	delete(row)
}

row_concat :: proc(row: ^[dynamic]Code_Seg, color, text: string) {
	if len(text) == 0 do return
	if len(row^) > 0 && row^[len(row^) - 1].color == color {
		last := &row^[len(row^) - 1]
		joined := strings.concatenate({last.text, text})
		delete(last.text)
		last.text = joined
		return
	}
	append(row, Code_Seg{color = color, text = strings.clone(text)})
}

limit_rows :: proc(limit, height: int) -> int {
	if limit <= 0 do return 0
	if height > 0 && limit > height do return height
	return limit
}

new_live_box :: proc(w: io.Writer, width, height, limit: int) -> Live_Box {
	return Live_Box{
		w = w,
		style = dark_style(),
		W = max(width, 1),
		Limit = limit_rows(limit, height),
		height = height,
		open = true,
		tail = make([dynamic]Code_Seg, 0, 4),
		out = make([dynamic][dynamic]Code_Seg, 0, max(limit, 4)),
	}
}

live_box_destroy :: proc(b: ^Live_Box) {
	row_destroy(b.tail)
	for row in b.out do row_destroy(row)
	delete(b.out)
	delete(b.header_label)
	b^ = {}
}

elided_note :: proc(n: int) -> string {
	switch {
	case n <= 0:
		return ""
	case n == 1:
		return "1 Line Elided"
	case:
		return fmt.tprintf("%d Lines Elided", n)
	}
}

wb :: proc(w: io.Writer, s: string) {
	io.write_string(w, s)
}

wbf :: proc(w: io.Writer, format: string, args: ..any) {
	io.write_string(w, fmt.tprintf(format, ..args))
}

live_box_header :: proc(b: ^Live_Box, label: string, elided: int = 0) {
	if !b.open do return
	bld := strings.builder_make()
	defer delete(bld.buf)
	box_border(&bld, b.style, b.W, label, elided_note(elided))
	wb(b.w, strings.to_string(bld))
}

live_box_header_row :: proc(b: ^Live_Box, note: string) -> [dynamic]Code_Seg {
	row := make([dynamic]Code_Seg, 0, 1)
	append(&row, Code_Seg{color = "", text = strings.clone(code_header_note(b.header_label, note, b.W))})
	return row
}

live_box_output_header :: proc(b: ^Live_Box, label: string) {
	if !b.open do return
	if b.Limit <= 0 {
		bld := strings.builder_make()
		defer delete(bld.buf)
		box_border(&bld, b.style, b.W, label, "")
		wb(b.w, strings.to_string(bld))
		return
	}
	delete(b.header_label)
	b.header_label = strings.clone(label)
	b.header_set = true
	segs := live_box_header_row(b, "")
	write_segs(b, b.w, segs[:])
	b.drawn = physical_height(b, [][]Code_Seg{segs[:]})
	row_destroy(segs)
}

live_box_row :: proc(b: ^Live_Box, text: string) {
	if !b.open do return
	if b.Limit > 0 && b.inputs >= b.Limit do return
	b.inputs += 1
	bld := strings.builder_make()
	defer delete(bld.buf)
	box_row(&bld, b.style, text, "")
	wb(b.w, strings.to_string(bld))
}

live_box_out :: proc(b: ^Live_Box, text: string) {
	live_box_append(b, false, text)
}

live_box_err :: proc(b: ^Live_Box, text: string) {
	live_box_append(b, true, text)
}

live_box_end :: proc(b: ^Live_Box, code: int) {
	if !b.open do return
	b.open = false

	if b.Limit > 0 {
		if b.drawn > 0 do wb(b.w, "\r\n")
		row_destroy(b.tail)
		b.tail = make([dynamic]Code_Seg, 0, 1)
		if code != 0 do row_note(b, code)
		bld := strings.builder_make()
		defer delete(bld.buf)
		box_border(&bld, b.style, b.W, "", "")
		wb(b.w, strings.to_string(bld))
		return
	}

	if len(b.tail) > 0 {
		row_destroy(b.tail)
		b.tail = make([dynamic]Code_Seg, 0, 1)
		wb(b.w, "\n")
	}
	if code != 0 do row_note(b, code)
	bld := strings.builder_make()
	defer delete(bld.buf)
	box_border(&bld, b.style, b.W, "", "")
	wb(b.w, strings.to_string(bld))
}

live_box_append :: proc(b: ^Live_Box, stderr: bool, p: string) {
	if !b.open || len(p) == 0 do return
	color := ""
	if stderr do color = b.style.code_color
	if b.Limit > 0 {
		append_windowed(b, color, p)
		return
	}
	append_unlimited(b, color, p)
}

append_unlimited :: proc(b: ^Live_Box, color, p: string) {
	had := len(b.tail) > 0
	segs := b.tail
	b.tail = make([dynamic]Code_Seg, 0, 4)

	data := p
	for len(data) > 0 {
		i := strings.index_byte(data, '\n')
		if i < 0 do break
		row_concat(&segs, color, data[:i])
		if had {
			commit_live_row(b, segs[:])
		} else {
			commit_segs(b, segs[:])
		}
		row_destroy(segs)
		segs = make([dynamic]Code_Seg, 0, 4)
		had = false
		data = data[i + 1:]
	}
	if len(data) > 0 {
		row_concat(&segs, color, data)
		row_destroy(b.tail)
		b.tail = segs
		draw_tail(b)
	} else if len(segs) > 0 {
		row_destroy(segs)
	}
}

append_windowed :: proc(b: ^Live_Box, color, p: string) {
	segs := b.tail
	b.tail = make([dynamic]Code_Seg, 0, 4)

	data := p
	for len(data) > 0 {
		i := strings.index_byte(data, '\n')
		if i < 0 do break
		row_concat(&segs, color, data[:i])
		add_out(b, segs)
		segs = make([dynamic]Code_Seg, 0, 4)
		data = data[i + 1:]
	}
	if len(data) > 0 {
		row_concat(&segs, color, data)
		b.tail = segs
	} else if len(segs) > 0 {
		row_destroy(segs)
	}
	redraw(b)
}

add_out :: proc(b: ^Live_Box, segs: [dynamic]Code_Seg) {
	b.total += 1
	append(&b.out, segs)
	if len(b.out) > b.Limit {
		excess := len(b.out) - b.Limit
		for _ in 0 ..< excess {
			row_destroy(b.out[0])
			ordered_remove(&b.out, 0)
		}
	}
}

window :: proc(b: ^Live_Box) -> ([][]Code_Seg, int) {
	rows := make([dynamic][]Code_Seg, 0, b.Limit + 1)
	start := 0
	if len(b.tail) == 0 {
		for row in b.out do append(&rows, row[:])
	} else {
		max_completed := b.Limit - 1
		if len(b.out) > max_completed do start = len(b.out) - max_completed
		for i := start; i < len(b.out); i += 1 do append(&rows, b.out[i][:])
		append(&rows, b.tail[:])
	}

	if b.height > 0 {
		max_rows := b.height
		if b.header_set do max_rows -= 1
		if max_rows < 1 do max_rows = 1
		for len(rows) > 1 && physical_height(b, rows[:]) > max_rows {
			ordered_remove(&rows, 0)
			start += 1
		}
	}

	elided := b.total - len(b.out) + start
	if elided < 0 do elided = 0
	return rows[:], elided
}

redraw :: proc(b: ^Live_Box) {
	rows, elided := window(b)
	defer delete(rows)

	region := make([dynamic][]Code_Seg, 0, len(rows) + 1)
	defer delete(region)
	hdr: [dynamic]Code_Seg
	if b.header_set {
		hdr = live_box_header_row(b, elided_note(elided))
		append(&region, hdr[:])
	}
	for row in rows do append(&region, row)

	if b.drawn > 0 {
		wb(b.w, "\r")
		if b.drawn > 1 do wbf(b.w, "\x1b[%dA", b.drawn - 1)
	}
	wb(b.w, "\x1b[J")

	for row, i in region {
		if i > 0 do wb(b.w, "\r\n")
		write_segs(b, b.w, row)
	}
	b.drawn = physical_height(b, region[:])
	if b.header_set do row_destroy(hdr)
}

physical_height :: proc(b: ^Live_Box, rows: [][]Code_Seg) -> int {
	W := max(b.W, 1)
	total := 0
	for row in rows {
		n := (row_width(b, row) + W - 1) / W
		if n < 1 do n = 1
		total += n
	}
	return total
}

row_width :: proc(b: ^Live_Box, segs: []Code_Seg) -> int {
	bld := strings.builder_make()
	defer delete(bld.buf)
	write_segs(b, strings.to_writer(&bld), segs)
	return visible_width(strings.to_string(bld))
}

commit_segs :: proc(b: ^Live_Box, segs: []Code_Seg) {
	draw_segs(b, segs)
	wb(b.w, "\n")
}

commit_live_row :: proc(b: ^Live_Box, segs: []Code_Seg) {
	wb(b.w, "\r")
	draw_segs(b, segs)
	wb(b.w, "\n")
}

draw_tail :: proc(b: ^Live_Box) {
	wb(b.w, "\r")
	draw_segs(b, b.tail[:])
}

draw_segs :: proc(b: ^Live_Box, segs: []Code_Seg) {
	write_segs(b, b.w, segs)
}

write_segs :: proc(b: ^Live_Box, w: io.Writer, segs: []Code_Seg) {
	bg := ""
	if len(b.style.code_block_bg) > 0 do bg = bg_sgr(b.style.code_block_bg)
	if len(bg) > 0 do io.write_string(w, bg)
	col := 0
	for s in segs {
		c := s.color
		if len(c) == 0 do c = b.style.code_block_color
		if len(c) > 0 do io.write_string(w, fg_sgr(c))
		text, next := expand_tabs(s.text, col)
		col = next
		if len(bg) > 0 {
			reopened, allocated := strings.replace_all(text, RESET_SGR,
				strings.concatenate({RESET_SGR, bg}, context.temp_allocator))
			io.write_string(w, reopened)
			if allocated do delete(reopened)
		} else {
			io.write_string(w, text)
		}
		delete(text)
	}
	if len(bg) > 0 do io.write_string(w, EL)
	io.write_string(w, RESET_SGR)
}

row_note :: proc(b: ^Live_Box, code: int) {
	bld := strings.builder_make()
	defer delete(bld.buf)
	box_row(&bld, b.style, fmt.tprintf("(exit %d)", code), "")
	wb(b.w, strings.to_string(bld))
}
