// A small, selection-aware Markdown renderer for the conversation pane. It
// handles paragraphs, headings, fenced code, bullets, numbered lists,
// blockquotes, rules, GFM tables, inline code, and **bold**.
package main

import "core:strings"
import "core:unicode/utf8"

Md_Style :: enum {
	Text,
	Bold,
	Code,
}

Md_Word :: struct {
	text:  string,
	style: Md_Style,
	space: bool,
}

md_words_destroy :: proc(words: []Md_Word) {
	delete(words)
}

append_word_range :: proc(words: ^[dynamic]Md_Word, text: string, start, end: int, style: Md_Style, space: ^bool) {
	i, word_start := start, start
	for i <= end {
		if i == end || text[i] == ' ' || text[i] == '\t' || text[i] == '\n' || text[i] == '\r' {
			if i > word_start {
				append(words, Md_Word{text = text[word_start:i], style = style, space = space^})
				space^ = false
			}
			if i < end do space^ = true
			i += 1
			word_start = i
			continue
		}
		i += 1
	}
}

// inline_words tokenizes one paragraph segment into words with style flags.
// The word strings are views into s, so they stay valid as long as the source
// text does.
inline_words :: proc(s: string) -> []Md_Word {
	words := make([dynamic]Md_Word, 0, 32)
	space := false
	normal_start := 0
	i := 0
	for i < len(s) {
		if s[i] == '`' {
			if close := strings.index_byte(s[i + 1:], '`'); close >= 0 {
				append_word_range(&words, s, normal_start, i, .Text, &space)
				txt := s[i + 1:i + 1 + close]
				if len(txt) > 0 {
					append(&words, Md_Word{text = txt, style = .Code, space = space})
					space = false
				}
				i += close + 2
				normal_start = i
				continue
			}
		}
		if i + 1 < len(s) && s[i] == '*' && s[i + 1] == '*' {
			if close := strings.index(s[i + 2:], "**"); close >= 0 {
				append_word_range(&words, s, normal_start, i, .Text, &space)
				append_word_range(&words, s, i + 2, i + 2 + close, .Bold, &space)
				i += close + 4
				normal_start = i
				continue
			}
		}
		i += 1
	}
	append_word_range(&words, s, normal_start, len(s), .Text, &space)
	return words[:]
}

md_word_style :: proc(style: Md_Style, font: ^ImFont, mono: ^ImFont, size: f32, th: Theme) -> (^ImFont, f32, Color) {
	switch style {
	case .Code:
		return mono, size - 1.5, mix(th.fg, th.accent, 0.18)
	case .Bold:
		return font, size, th.fg
	case .Text:
		return font, size, mix(th.fg, th.bg, 0.04)
	}
	return font, size, th.fg
}

// --- tables ---------------------------------------------------------------

Md_Align :: enum {
	Left,
	Center,
	Right,
}

// md_split_table_row splits a GFM table row on unescaped pipes. The outer
// pipes are optional and the cells are returned trimmed. The returned strings
// are owned by the caller's temp arena so they stay valid for the frame.
md_split_table_row :: proc(s: string) -> []string {
	t := strings.trim_space(s)
	if len(t) > 0 && t[0] == '|' do t = t[1:]
	if len(t) > 0 && t[len(t) - 1] == '|' && (len(t) < 2 || t[len(t) - 2] != '\\') {
		t = t[:len(t) - 1]
	}
	cells := make([dynamic]string, 0, 8, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for {
		if i >= len(t) {
			cell := strings.trim_space(strings.to_string(b))
			append(&cells, strings.clone(cell, context.temp_allocator))
			break
		}
		if t[i] == '\\' && i + 1 < len(t) && t[i + 1] == '|' {
			strings.write_byte(&b, '|')
			i += 2
			continue
		}
		if t[i] == '|' {
			cell := strings.trim_space(strings.to_string(b))
			append(&cells, strings.clone(cell, context.temp_allocator))
			strings.builder_reset(&b)
			i += 1
			continue
		}
		strings.write_byte(&b, t[i])
		i += 1
	}
	return cells[:]
}

// md_table_delimiter parses the alignment row that makes a table. Every cell
// must contain at least one dash and only dashes, colons, and padding.
md_table_delimiter :: proc(s: string) -> (aligns: []Md_Align, ok: bool) {
	t := strings.trim_space(s)
	if !strings.contains(t, "|") do return nil, false
	cells := md_split_table_row(t)
	if len(cells) == 0 do return nil, false
	result := make([]Md_Align, len(cells), context.temp_allocator)
	for cell, i in cells {
		c := strings.trim_space(cell)
		if len(c) == 0 do return nil, false
		left := c[0] == ':'
		right := c[len(c) - 1] == ':'
		lo := left ? 1 : 0
		hi := len(c) - (right ? 1 : 0)
		if lo >= hi do return nil, false
		for j := lo; j < hi; j += 1 {
			if c[j] != '-' do return nil, false
		}
		result[i] = .Left
		if left && right {
			result[i] = .Center
		} else if right {
			result[i] = .Right
		}
	}
	return result, true
}

md_is_table_start :: proc(lines: []string, i: int) -> bool {
	if i + 1 >= len(lines) do return false
	if !strings.contains(lines[i], "|") do return false
	_, ok := md_table_delimiter(lines[i + 1])
	return ok
}

// md_ends_table reports whether a line starts a non-table block. Markdown ends
// a table at the first blank line or the beginning of another block structure,
// even when that structure directly follows the last row.
md_ends_table :: proc(lines: []string, i: int) -> bool {
	cur := strings.trim_space(lines[i])
	if len(cur) == 0 do return true
	if strings.has_prefix(cur, "```") do return true
	if _, _, ok := md_heading(cur); ok do return true
	if cur == "---" || cur == "***" || cur == "___" do return true
	if strings.has_prefix(cur, ">") do return true
	if strings.has_prefix(cur, "- ") || strings.has_prefix(cur, "* ") ||
	   strings.has_prefix(cur, "+ ") {
		return true
	}
	if _, _, ok := numbered_prefix(cur); ok do return true
	return md_is_table_start(lines, i)
}

md_word_font :: proc(style: Md_Style, font: ^ImFont, mono: ^ImFont, size: f32) -> (^ImFont, f32) {
	switch style {
	case .Code:
		return mono, size - 1.5
	case .Bold, .Text:
		return font, size
	}
	return font, size
}

// md_inline_content_width measures a cell without wrapping so table columns
// can start from their natural content widths.
md_inline_content_width :: proc(font: ^ImFont, mono: ^ImFont, size: f32, text: string, th: Theme, bold_base: bool) -> f32 {
	words := inline_words(text)
	defer md_words_destroy(words)
	total: f32 = 0
	first := true
	for word in words {
		style := word.style
		if bold_base && style == .Text do style = .Bold
		f, fs := md_word_font(style, font, mono, size)
		if word.space && !first {
			sw, _ := measure(font, size, " ")
			total += sw
		}
		ww, _ := measure(f, fs, word.text)
		total += ww
		first = false
	}
	return total
}

// md_inline_wrapped_height mirrors the word wrapping used by draw_inline, but
// only computes the height. Table rows need this before they can draw their
// backgrounds and grid lines.
md_inline_wrapped_height :: proc(font: ^ImFont, mono: ^ImFont, size: f32, width: f32, text: string, bold_base: bool) -> f32 {
	line_h := ui_text_px(size) * 1.5
	words := inline_words(text)
	defer md_words_destroy(words)
	if len(words) == 0 do return line_h
	lines := 1
	line_w: f32 = 0
	first := true
	for word in words {
		style := word.style
		if bold_base && style == .Text do style = .Bold
		f, fs := md_word_font(style, font, mono, size)
		ww, _ := measure(f, fs, word.text)
		space_w: f32 = 0
		if word.space && !first {
			sw, _ := measure(font, size, " ")
			space_w = sw
		}
		if !first && line_w + space_w + ww > width {
			lines += 1
			line_w = 0
			first = true
			space_w = 0
		}
		line_w += space_w + ww
		first = false
	}
	return f32(lines) * line_h
}

Md_Inline_Item :: struct {
	word:         Md_Word,
	line:         int,
	x:            f32, // offset from the start of its visual line
	space_before: bool,
	width:        f32,
}

Md_Inline_Layout :: struct {
	items:       []Md_Inline_Item,
	line_widths: []f32,
	line_h:      f32,
}

md_inline_layout_destroy :: proc(l: ^Md_Inline_Layout) {
	delete(l.items)
	delete(l.line_widths)
	l^ = {}
}

// md_inline_layout tokenizes and wraps one cell, recording each word's line and
// x offset. That lets a table align whole visual lines (left/center/right)
// instead of guessing where draw_inline's cursor would have stopped.
md_inline_layout :: proc(text: string, font: ^ImFont, mono: ^ImFont, size: f32, width: f32, bold_base: bool) -> (layout: Md_Inline_Layout) {
	layout.line_h = ui_text_px(size) * 1.5
	words := inline_words(text)
	defer md_words_destroy(words)
	items := make([dynamic]Md_Inline_Item, 0, len(words) + 1)
	line_widths := make([dynamic]f32, 0, 4)
	if len(words) == 0 {
		append(&line_widths, 0)
		layout.items = items[:]
		layout.line_widths = line_widths[:]
		return
	}
	line := 0
	line_w: f32 = 0
	first := true
	for word in words {
		style := word.style
		if bold_base && style == .Text do style = .Bold
		f, fs := md_word_font(style, font, mono, size)
		ww, _ := measure(f, fs, word.text)
		space_w: f32 = 0
		if word.space && !first {
			sw, _ := measure(font, size, " ")
			space_w = sw
		}
		if !first && line_w + space_w + ww > width {
			append(&line_widths, line_w)
			line += 1
			line_w = 0
			first = true
			space_w = 0
		}
		x := line_w + space_w
		append(&items, Md_Inline_Item {
			word = Md_Word{text = word.text, style = style, space = word.space},
			line = line,
			x = x,
			space_before = space_w > 0,
			width = ww,
		})
		line_w = x + ww
		first = false
	}
	append(&line_widths, line_w)
	layout.items = items[:]
	layout.line_widths = line_widths[:]
	return
}

md_align_offset :: proc(align: Md_Align, width, line_w: f32) -> f32 {
	switch align {
	case .Center:
		return max((width - line_w) * 0.5, 0)
	case .Right:
		return max(width - line_w, 0)
	case .Left:
		return 0
	}
	return 0
}

md_draw_inline_layout :: proc(
	list: ^ImDrawList,
	font: ^ImFont,
	mono: ^ImFont,
	size: f32,
	x, y, width: f32,
	col: Color,
	th: Theme,
	layout: Md_Inline_Layout,
	align: Md_Align,
	rec: ^Sel_Recorder,
) {
	for item in layout.items {
		line_w := layout.line_widths[item.line]
		wx := x + md_align_offset(align, width, line_w) + item.x
		wy := y + f32(item.line) * layout.line_h
		f, fs, wc := md_word_style(item.word.style, font, mono, size, th)
		if item.word.style == .Text do wc = col
		if item.space_before {
			sw, _ := measure(font, size, " ")
			if rec != nil do sel_record_space(rec, wx - sw, wy, sw, layout.line_h)
		}
		if item.word.style == .Code {
			panel(list, rect(wx - 2.5, wy - 1.5, item.width + 5, layout.line_h - 1), mix(th.bg, th.fg, 0.06), 3)
		}
		text_font(list, f, fs, wx, wy, wc, item.word.text)
		if item.word.style == .Bold {
			text_font(list, f, fs, wx + 0.4, wy, wc, item.word.text)
		}
		record_runes(rec, item.word.text, wx, wy, item.width, f, fs, layout.line_h)
	}
}

// md_fit_table_widths starts from natural column widths and, when the table is
// wider than the pane, gives every column a floor before distributing the
// remaining width to the columns that still need it.
md_fit_table_widths :: proc(natural: []f32, avail: f32) -> []f32 {
	widths := make([]f32, len(natural), context.temp_allocator)
	if len(natural) == 0 do return widths
	if avail <= 0 {
		for i in 0 ..< len(widths) do widths[i] = 1
		return widths
	}
	total: f32 = 0
	for n in natural do total += n
	if total <= avail {
		copy(widths, natural)
		return widths
	}
	floor_w: f32 = 28
	floor_total: f32 = 0
	for n, i in natural {
		w := min(n, floor_w)
		if w < 1 do w = 1
		widths[i] = w
		floor_total += w
	}
	if floor_total >= avail {
		scale := avail / floor_total
		for i in 0 ..< len(widths) do widths[i] = max(widths[i] * scale, 1)
		return widths
	}
	unmet: f32 = 0
	for n, i in natural do unmet += max(n - widths[i], 0)
	extra := min(avail - floor_total, unmet)
	if unmet > 0 {
		for n, i in natural {
			need := max(n - widths[i], 0)
			widths[i] += extra * (need / unmet)
		}
	}
	return widths
}

// draw_md_table renders a GFM table starting at lines[start]. It returns the
// table height and the next line to process.
draw_md_table :: proc(
	list: ^ImDrawList,
	font: ^ImFont,
	mono: ^ImFont,
	size: f32,
	x, y, w: f32,
	th: Theme,
	col: Color,
	lines: []string,
	start: int,
	rec: ^Sel_Recorder = nil,
) -> (height: f32, next: int) {
	header := md_split_table_row(lines[start])
	aligns, ok := md_table_delimiter(lines[start + 1])
	if !ok || len(header) == 0 do return 0, start + 2
	ncols := len(header)

	rows := make([dynamic][]string, 0, 8, context.temp_allocator)
	append(&rows, header)
	i := start + 2
	for i < len(lines) {
		if md_ends_table(lines, i) do break
		append(&rows, md_split_table_row(lines[i]))
		i += 1
	}
	next = i

	natural := make([]f32, ncols, context.temp_allocator)
	for row, ri in rows {
		for c := 0; c < ncols; c += 1 {
			cell := c < len(row) ? row[c] : ""
			cw := md_inline_content_width(font, mono, size, cell, th, ri == 0)
			if cw > natural[c] do natural[c] = cw
		}
	}

	pad_x: f32 = 8
	pad_y: f32 = 6
	line_h := ui_text_px(size) * 1.5
	overhead := f32(ncols + 1) + f32(ncols) * 2 * pad_x
	avail := max(w - overhead, 1)
	widths := md_fit_table_widths(natural, avail)

	row_h := make([]f32, len(rows), context.temp_allocator)
	total_h: f32 = 0
	for row, ri in rows {
		max_h := line_h
		for c := 0; c < ncols; c += 1 {
			cell := c < len(row) ? row[c] : ""
			h := md_inline_wrapped_height(font, mono, size, widths[c], cell, ri == 0)
			max_h = max(max_h, h)
		}
		row_h[ri] = max_h + pad_y * 2
		total_h += row_h[ri]
	}

	table_w := overhead
	for cw in widths do table_w += cw

	// Backgrounds and grid. The table has square corners so the header fill and
	// separators line up with the border.
	panel(list, rect(x, y, table_w, total_h), mix(th.bg, th.fg, 0.028), 4)
	if len(rows) > 0 {
		panel(list, rect(x, y, table_w, row_h[0]), mix(th.bg, th.fg, 0.075), 4)
	}

	grid_col := alpha(th.border_soft, 0.9)
	outer_col := alpha(th.border, 0.55)
	row_y := y
	for ri := 0; ri < len(rows); ri += 1 {
		if ri > 0 {
			rule(list, x, x + table_w, row_y, ri == 1 ? alpha(th.border, 0.40) : grid_col)
		}
		row_y += row_h[ri]
	}
	col_x := x
	for c := 0; c <= ncols; c += 1 {
		vrule(list, col_x, y, y + total_h, c == 0 || c == ncols ? outer_col : grid_col)
		if c < ncols do col_x += widths[c] + pad_x * 2 + 1
	}

	// Cell contents, clipped to their own column so a long unbroken token cannot
	// paint over the neighbouring cells.
	row_y = y
	for row, ri in rows {
		cell_x := x + 1
		for c := 0; c < ncols; c += 1 {
			cell := c < len(row) ? row[c] : ""
			cell_rect := rect(cell_x, row_y, widths[c] + pad_x * 2, row_h[ri])
			mi_clip_push(list, cell_rect.x, cell_rect.y, cell_rect.x + cell_rect.w, cell_rect.y + cell_rect.h)
			layout := md_inline_layout(cell, font, mono, size, widths[c], ri == 0)
			md_draw_inline_layout(
				list,
				font,
				mono,
				size,
				cell_x + pad_x,
				row_y + pad_y,
				widths[c],
				ri == 0 ? th.fg : col,
				th,
				layout,
				c < len(aligns) ? aligns[c] : .Left,
				rec,
			)
			md_inline_layout_destroy(&layout)
			mi_clip_pop(list)
			if c + 1 < ncols && rec != nil {
				sel_record_char(rec, "\t", rect(cell_x + widths[c] + pad_x, row_y, 1, line_h))
			}
			cell_x += widths[c] + pad_x * 2 + 1
		}
		if rec != nil do sel_record_newline(rec, x, row_y + row_h[ri], line_h)
		row_y += row_h[ri]
	}

	// The outer border is drawn last so the grid and header fill cannot cover it.
	panel(list, rect(x, y, table_w, total_h), {0, 0, 0, 0}, 0, outer_col, 1)
	return total_h, next
}

// record_runes records one rectangle per rune, scaled so the run covers the
// same width as the word/line just drawn. The text views stay valid for the
// frame because they point into the message text or a frame-temporary buffer.
record_runes :: proc(rec: ^Sel_Recorder, text: string, x, y, total_w: f32, font: ^ImFont, size, line_h: f32) {
	if rec == nil || len(text) == 0 do return
	measured: f32 = 0
	i := 0
	for i < len(text) {
		_, sz := utf8.decode_rune_in_string(text[i:])
		if sz <= 0 do break
		rw, _ := measure(font, size, text[i:i + sz])
		measured += rw
		i += sz
	}
	scale: f32 = 1
	if measured > 0 && total_w > 0 do scale = total_w / measured
	cx := x
	i = 0
	for i < len(text) {
		_, sz := utf8.decode_rune_in_string(text[i:])
		if sz <= 0 do break
		rw, _ := measure(font, size, text[i:i + sz])
		rw *= scale
		sel_record_char(rec, text[i:i + sz], rect(cx, y, rw, line_h))
		cx += rw
		i += sz
	}
}

// draw_inline lays out styled words with wrapping and returns the height used.
draw_inline :: proc(
	list: ^ImDrawList,
	font: ^ImFont,
	mono: ^ImFont,
	size: f32,
	x, y, w: f32,
	col: Color,
	th: Theme,
	text: string,
	rec: ^Sel_Recorder = nil,
) -> f32 {
	words := inline_words(text)
	defer md_words_destroy(words)
	if len(words) == 0 do return size * 1.5

	line_h := ui_text_px(size) * 1.5
	x0 := x
	cx, cy := x, y
	first := true
	for word in words {
		f, fs, wc := md_word_style(word.style, font, mono, size, th)
		if word.style == .Text do wc = col
		ww, _ := measure(f, fs, word.text)
		space_w: f32 = 0
		if word.space && !first {
			sw, _ := measure(font, size, " ")
			space_w = sw
		}
		wrapped := false
		if !first && cx + space_w + ww > x0 + w {
			cx = x0
			cy += line_h
			first = true
			space_w = 0
			wrapped = true
		}
		if wrapped && rec != nil && word.space {
			sw, _ := measure(font, size, " ")
			sel_record_space(rec, x0, cy, sw, line_h)
		}
		space_before := word.space && !first
		if space_before {
			if rec != nil do sel_record_space(rec, cx, cy, space_w, line_h)
			cx += space_w
		}
		if word.style == .Code {
			panel(list, rect(cx - 2.5, cy - 1.5, ww + 5, line_h - 1), mix(th.bg, th.fg, 0.06), 3)
		}
		text_font(list, f, fs, cx, cy, wc, word.text)
		if word.style == .Bold {
			text_font(list, f, fs, cx + 0.4, cy, wc, word.text)
		}
		record_runes(rec, word.text, cx, cy, ww, f, fs, line_h)
		cx += ww
		first = false
	}
	return (cy - y) + line_h
}

// plain_wrapped_height runs the same word layout as draw_plain_wrapped and
// returns its height without emitting draw commands. Boxes around plain text
// use this so their border cannot come up short of the wrapped content.
plain_wrapped_height :: proc(font: ^ImFont, size: f32, w: f32, text: string) -> f32 {
	lines := strings.split(text, "\n")
	defer delete(lines)
	line_h := ui_text_px(size) * 1.5
	total: f32 = 0
	for line in lines {
		words := make([dynamic]Md_Word, 0, 16)
		space := false
		append_word_range(&words, line, 0, len(line), .Text, &space)
		cx: f32 = 0
		first := true
		for word in words {
			ww, _ := measure(font, size, word.text)
			space_w: f32 = 0
			if word.space && !first {
				sw, _ := measure(font, size, " ")
				space_w = sw
			}
			if !first && cx + space_w + ww > w {
				total += line_h
				cx = 0
				first = true
				space_w = 0
			}
			if word.space && !first do cx += space_w
			cx += ww
			first = false
		}
		delete(words)
		total += line_h
	}
	return total
}

// code_wrapped_height mirrors draw_code_wrapped's character wrapping exactly.
code_wrapped_height :: proc(mono: ^ImFont, size: f32, w: f32, text: string) -> f32 {
	line_h := ui_text_px(size) * 1.5
	total: f32 = 0
	start := 0
	for start <= len(text) {
		end := strings.index_byte(text[start:], '\n')
		line_end := end < 0 ? len(text) : start + end
		line := text[start:line_end]
		if len(line) == 0 {
			total += line_h
		} else {
			pos := 0
			chunk_start := 0
			line_w: f32 = 0
			for pos < len(line) {
				_, sz := utf8.decode_rune_in_string(line[pos:])
				if sz <= 0 do break
				rw, _ := measure(mono, size, line[pos:pos + sz])
				if pos > chunk_start && line_w + rw > w {
					total += line_h
					chunk_start = pos
					line_w = 0
				}
				line_w += rw
				pos += sz
			}
			if chunk_start < len(line) do total += line_h
		}
		if end < 0 do break
		start = line_end + 1
	}
	return total
}

// draw_plain_wrapped lays out un-styled text, preserving explicit newlines.
draw_plain_wrapped :: proc(
	list: ^ImDrawList,
	font: ^ImFont,
	size: f32,
	x, y, w: f32,
	col: Color,
	text: string,
	rec: ^Sel_Recorder = nil,
) -> f32 {
	lines := strings.split(text, "\n")
	defer delete(lines)
	line_h := ui_text_px(size) * 1.5
	cy := y
	first_line := true
	for line in lines {
		if !first_line && rec != nil do sel_record_newline(rec, x, cy, line_h)
		words := make([dynamic]Md_Word, 0, 16)
		space := false
		append_word_range(&words, line, 0, len(line), .Text, &space)
		cx := x
		first := true
		for word in words {
			ww, _ := measure(font, size, word.text)
			space_w: f32 = 0
			if word.space && !first {
				sw, _ := measure(font, size, " ")
				space_w = sw
			}
			wrapped := false
			if !first && cx + space_w + ww > x + w {
				cx = x
				cy += line_h
				first = true
				space_w = 0
				wrapped = true
			}
			if wrapped && rec != nil && word.space {
				sw, _ := measure(font, size, " ")
				sel_record_space(rec, x, cy, sw, line_h)
			}
			space_before := word.space && !first
			if space_before {
				if rec != nil do sel_record_space(rec, cx, cy, space_w, line_h)
				cx += space_w
			}
			text_font(list, font, size, cx, cy, col, word.text)
			record_runes(rec, word.text, cx, cy, ww, font, size, line_h)
			cx += ww
			first = false
		}
		delete(words)
		cy += line_h
		first_line = false
	}
	return cy - y
}

// draw_code_wrapped wraps code/output by character so indentation and long
// tokens are preserved. Each visual line is one selection item.
draw_code_wrapped :: proc(
	list: ^ImDrawList,
	mono: ^ImFont,
	size: f32,
	x, y, w: f32,
	text: string,
	col: Color,
	rec: ^Sel_Recorder = nil,
) -> f32 {
	line_h := ui_text_px(size) * 1.5
	cy := y
	first_logical_line := true
	start := 0
	for start <= len(text) {
		end := strings.index_byte(text[start:], '\n')
		line_end := end < 0 ? len(text) : start + end
		line := text[start:line_end]
		if !first_logical_line && rec != nil do sel_record_newline(rec, x, cy, line_h)
		if len(line) == 0 {
			cy += line_h
		} else {
			pos := 0
			chunk_start := 0
			line_w: f32 = 0
			for pos < len(line) {
				_, sz := utf8.decode_rune_in_string(line[pos:])
				if sz <= 0 do break
				rw, _ := measure(mono, size, line[pos:pos + sz])
				if pos > chunk_start && line_w + rw > w {
					part := line[chunk_start:pos]
					text_font(list, mono, size, x, cy, col, part)
					record_runes(rec, part, x, cy, line_w, mono, size, line_h)
					cy += line_h
					// A visual wrap is not a new character in the source; do
					// not insert a separator when copying across it.
					chunk_start = pos
					line_w = 0
				}
				line_w += rw
				pos += sz
			}
			if chunk_start < len(line) {
				part := line[chunk_start:]
				text_font(list, mono, size, x, cy, col, part)
				record_runes(rec, part, x, cy, line_w, mono, size, line_h)
				cy += line_h
			}
		}
		first_logical_line = false
		if end < 0 do break
		start = line_end + 1
	}
	return cy - y
}

draw_fence :: proc(
	list: ^ImDrawList,
	mono: ^ImFont,
	size: f32,
	x, y, w: f32,
	lines: []string,
	th: Theme,
	rec: ^Sel_Recorder = nil,
) -> f32 {
	b := strings.builder_make(context.temp_allocator)
	for line, i in lines {
		if i > 0 do strings.write_byte(&b, '\n')
		strings.write_string(&b, line)
	}
	text := strings.to_string(b)
	box_h := code_wrapped_height(mono, size, w - 20, text) + 16
	panel(list, rect(x, y, w, box_h), mix(th.bg, rgb(0, 0, 0), 0.16), 6)
	draw_code_wrapped(list, mono, size, x + 10, y + 8, w - 20, text, mix(th.fg, th.bg, 0.20), rec)
	return box_h
}

// md_heading parses a level 1-6 ATX heading. It deliberately requires the
// space after the hashes, so a streaming "#" or a line such as "#include" is
// left as paragraph text instead of being mistaken for a block marker.
md_heading :: proc(s: string) -> (text: string, level: int, ok: bool) {
	level = 0
	for level < len(s) && level < 6 && s[level] == '#' do level += 1
	if level == 0 || level >= len(s) || s[level] != ' ' do return "", 0, false
	return strings.trim_space(s[level:]), level, true
}

// draw_markdown renders a block of Markdown and returns the height consumed.
draw_markdown :: proc(
	list: ^ImDrawList,
	font: ^ImFont,
	mono: ^ImFont,
	size: f32,
	x, y, w: f32,
	th: Theme,
	text: string,
	col: Color,
	rec: ^Sel_Recorder = nil,
) -> f32 {
	lines := strings.split(text, "\n")
	defer delete(lines)
	start_y := y
	cy := y
	i := 0
	for i < len(lines) {
		line := lines[i]
		trimmed := strings.trim_space(line)

		// Fenced code.
		if strings.has_prefix(trimmed, "```") {
			i += 1
			code_lines := make([dynamic]string, 0, 16)
			for i < len(lines) && !strings.has_prefix(strings.trim_space(lines[i]), "```") {
				append(&code_lines, lines[i])
				i += 1
			}
			if i < len(lines) do i += 1
			if len(code_lines) > 0 {
				cy += draw_fence(list, mono, size - 1.5, x, cy, w, code_lines[:], th, rec)
				cy += 12
			}
			delete(code_lines)
			continue
		}

		if len(trimmed) == 0 {
			if cy > start_y do cy += 6
			i += 1
			continue
		}

		if md_is_table_start(lines, i) {
			table_h, next := draw_md_table(list, font, mono, size, x, cy, w, th, col, lines, i, rec)
			cy += table_h + 12
			i = max(next, i + 2)
			continue
		}

		if trimmed == "---" || trimmed == "***" || trimmed == "___" {
			rule(list, x, x + w, cy + 4, th.border_soft)
			cy += 14
			i += 1
			continue
		}

		if heading, level, ok := md_heading(trimmed); ok {
			hsize := size + f32(8 - level)
			cy += draw_inline(list, font, mono, hsize, x, cy, w, th.fg, th, heading, rec) + 10
			i += 1
			continue
		}

		if strings.has_prefix(trimmed, ">") {
			quote := strings.trim_space(trimmed[1:])
			qh := draw_inline(list, font, mono, size, x + 16, cy, w - 16, th.fg_dim, th, quote, rec)
			vrule(list, x + 3, cy, cy + qh, th.border)
			cy += qh + 8
			i += 1
			continue
		}

		if strings.has_prefix(trimmed, "- ") || strings.has_prefix(trimmed, "* ") || strings.has_prefix(trimmed, "+ ") {
			item := trimmed[2:]
			dot(list, x + 5, cy + ui_text_px(size) * 0.55, 2.4, th.accent)
			cy += draw_inline(list, font, mono, size, x + 18, cy, w - 18, col, th, item, rec) + 6
			i += 1
			continue
		}
		if _, after, ok := numbered_prefix(trimmed); ok {
			label := trimmed[:after]
			text_font(list, font, size, x, cy, th.accent, label)
			cy += draw_inline(list, font, mono, size, x + 22, cy, w - 22, col, th, strings.trim_space(trimmed[after:]), rec) + 6
			i += 1
			continue
		}

		b := strings.builder_make(context.temp_allocator)
		para_start := i
		for i < len(lines) {
			cur := strings.trim_space(lines[i])
			_, _, is_heading := md_heading(cur)
			if len(cur) == 0 || strings.has_prefix(cur, "```") || is_heading ||
			   strings.has_prefix(cur, ">") || strings.has_prefix(cur, "- ") ||
			   strings.has_prefix(cur, "* ") || strings.has_prefix(cur, "+ ") || cur == "---" ||
			   md_is_table_start(lines, i) {
				break
			}
			if strings.builder_len(b) > 0 do strings.write_byte(&b, ' ')
			strings.write_string(&b, cur)
			i += 1
		}
		// Every branch above that breaks on a block marker must have consumed
		// it. If a marker was not recognized (for example a partial heading
		// such as "#" while it is still streaming), treat the line as text and
		// advance: otherwise this outer loop would spin forever on it.
		if i == para_start {
			strings.write_string(&b, trimmed)
			i += 1
		}
		para := strings.to_string(b)
		cy += draw_inline(list, font, mono, size, x, cy, w, col, th, para, rec) + 8
	}
	return cy - start_y
}

numbered_prefix :: proc(s: string) -> (n, after: int, ok: bool) {
	i := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' do i += 1
	if i == 0 || i >= len(s) || s[i] != '.' do return 0, 0, false
	if i + 1 >= len(s) || s[i + 1] != ' ' do return 0, 0, false
	return 0, i + 2, true
}
