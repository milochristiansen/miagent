// Markdown rendering for the terminal. The block scanner covers the constructs
// an LLM emits (headings, paragraphs, lists, blockquotes, fenced/indented code,
// rules, tables) and the inline renderer covers emphasis, strong, inline code,
// links, images, autolinks, and strikethrough. The visible output follows the
// Go CLI's termark renderer.
package termark

import "core:fmt"
import "core:strings"

Line :: struct {
	text:  string,
	width: int,
}

Render_Output :: struct {
	data:  string,
	lines: []Line,
}

render_output_destroy :: proc(o: ^Render_Output) {
	delete(o.lines)
	delete(o.data)
	o^ = {}
}

Source_Line :: struct {
	text:  string,
	start: int,
	end:   int, // just past the newline (or len(buf))
}

Block_Kind :: enum {
	Paragraph,
	Heading,
	Fence,
	Indented_Code,
	Blockquote,
	List,
	Table,
	Rule,
	HTML,
}

Block :: struct {
	lo:   int,
	hi:   int, // exclusive
	kind: Block_Kind,
}

leading_spaces :: proc(s: string) -> int {
	i := 0
	for i < len(s) && s[i] == ' ' do i += 1
	return i
}

is_blank :: proc(s: string) -> bool {
	for i := 0; i < len(s); i += 1 {
		if s[i] != ' ' && s[i] != '\t' && s[i] != '\r' do return false
	}
	return true
}

split_source_lines :: proc(buf: string) -> []Source_Line {
	lines := make([dynamic]Source_Line, 0, 32)
	start := 0
	i := 0
	for i <= len(buf) {
		if i == len(buf) {
			if i > start {
				text := strings.trim_right(buf[start:i], "\r")
				append(&lines, Source_Line{text = text, start = start, end = i})
			}
			break
		}
		if buf[i] == '\n' {
			text := strings.trim_right(buf[start:i], "\r")
			append(&lines, Source_Line{text = text, start = start, end = i + 1})
			start = i + 1
		}
		i += 1
	}
	return lines[:]
}

heading_level :: proc(s: string) -> int {
	indent := leading_spaces(s)
	if indent > 3 do return 0
	i := indent
	level := 0
	for i < len(s) && level < 6 && s[i] == '#' {
		level += 1
		i += 1
	}
	if level == 0 do return 0
	if i < len(s) && s[i] != ' ' && s[i] != '\t' do return 0
	return level
}

is_rule_line :: proc(line: string) -> bool {
	k := leading_spaces(line)
	if k > 3 || k + 3 > len(line) do return false
	c := line[k]
	if c != '-' && c != '*' && c != '_' do return false
	j := k
	for j < len(line) && line[j] == c do j += 1
	if j - k < 3 do return false
	for j < len(line) {
		if line[j] != ' ' && line[j] != '\t' && line[j] != '\r' do return false
		j += 1
	}
	return true
}

is_setext_underline :: proc(line: string) -> bool {
	t := strings.trim_space(line)
	if len(t) == 0 do return false
	c := t[0]
	if c != '=' && c != '-' do return false
	for i := 0; i < len(t); i += 1 {
		if t[i] != c do return false
	}
	return true
}

fence_info :: proc(line: string) -> (ok, closing_check: bool, marker: u8, count: int, indent: int) {
	indent = leading_spaces(line)
	if indent > 3 || indent >= len(line) do return false, false, 0, 0, 0
	c := line[indent]
	if c != '`' && c != '~' do return false, false, 0, 0, 0
	n := 0
	for indent + n < len(line) && line[indent + n] == c do n += 1
	if n < 3 do return false, false, 0, 0, 0
	return true, false, c, n, indent
}

is_closing_fence :: proc(line: string, marker: u8, count: int) -> bool {
	indent := leading_spaces(line)
	if indent > 3 || indent >= len(line) do return false
	if line[indent] != marker do return false
	n := 0
	for indent + n < len(line) && line[indent + n] == marker do n += 1
	if n < count do return false
	for indent + n < len(line) {
		if line[indent + n] != ' ' && line[indent + n] != '\t' && line[indent + n] != '\r' do return false
		indent += 1
	}
	return true
}

is_blockquote_line :: proc(s: string) -> bool {
	i := leading_spaces(s)
	return i <= 3 && i < len(s) && s[i] == '>'
}

List_Marker :: struct {
	ok:          bool,
	ordered:     bool,
	number:      int,
	indent:      int,
	content_at:  int, // index of first content byte after the marker
}

list_marker :: proc(s: string) -> List_Marker {
	m := List_Marker{}
	m.indent = leading_spaces(s)
	if m.indent >= len(s) do return m
	c := s[m.indent]
	if c == '-' || c == '*' || c == '+' {
		if m.indent + 1 == len(s) {
			m.ok = true
			m.content_at = len(s)
			return m
		}
		if s[m.indent + 1] == ' ' || s[m.indent + 1] == '\t' {
			m.ok = true
			m.content_at = m.indent + 1
			for m.content_at < len(s) && (s[m.content_at] == ' ' || s[m.content_at] == '\t') do m.content_at += 1
			return m
		}
		return m
	}
	if c >= '0' && c <= '9' {
		j := m.indent
		for j < len(s) && s[j] >= '0' && s[j] <= '9' do j += 1
		if j < len(s) && (s[j] == '.' || s[j] == ')') && (j + 1 == len(s) || s[j + 1] == ' ' || s[j + 1] == '\t') {
			m.ok = true
			m.ordered = true
			m.number = 0
			for k := m.indent; k < j; k += 1 do m.number = m.number * 10 + int(s[k] - '0')
			if m.number == 0 do m.number = 1
			m.content_at = j + 1
			for m.content_at < len(s) && (s[m.content_at] == ' ' || s[m.content_at] == '\t') do m.content_at += 1
			return m
		}
	}
	return m
}

table_delimiter_row :: proc(s: string) -> bool {
	if !strings.contains(s, "|") do return false
	parts := strings.split(s, "|")
	defer delete(parts)
	cell_count := 0
	for raw in parts {
		cell := strings.trim_space(raw)
		if len(cell) == 0 do continue
		has_dash := false
		for i := 0; i < len(cell); i += 1 {
			c := cell[i]
			if c == '-' {
				has_dash = true
			} else if c != ':' && c != ' ' && c != '\t' {
				return false
			}
		}
		if !has_dash do return false
		cell_count += 1
	}
	return cell_count > 0
}

is_html_block_start :: proc(s: string) -> bool {
	t := strings.trim_space(s)
	if !strings.has_prefix(t, "<") do return false
	if strings.has_prefix(t, "<http://") || strings.has_prefix(t, "<https://") do return false
	close := strings.index_byte(t, '>')
	if close < 0 do return false
	if strings.contains(t[:close], "@") do return false
	return true
}

classify_line :: proc(s: string, next: string, has_next: bool) -> Block_Kind {
	if is_blank(s) do return .Paragraph
	indent := leading_spaces(s)
	if indent >= 4 do return .Indented_Code
	if ok, _, _, _, _ := fence_info(s); ok do return .Fence
	if heading_level(s) > 0 do return .Heading
	if is_rule_line(s) do return .Rule
	if is_blockquote_line(s) do return .Blockquote
	if is_html_block_start(s) do return .HTML
	if lm := list_marker(s); lm.ok do return .List
	if has_next && strings.contains(s, "|") && table_delimiter_row(next) do return .Table
	return .Paragraph
}

scan_blocks :: proc(lines: []Source_Line, lo, hi: int) -> []Block {
	blocks := make([dynamic]Block, 0, 16)
	i := lo
	for i < hi {
		for i < hi && is_blank(lines[i].text) do i += 1
		if i >= hi do break
		start := i
		next_text := i + 1 < hi ? lines[i + 1].text : ""
		kind := classify_line(lines[i].text, next_text, i + 1 < hi)
		switch kind {
		case .Fence:
			_, _, marker, count, _ := fence_info(lines[i].text)
			i += 1
			for i < hi {
				if is_closing_fence(lines[i].text, marker, count) {
					i += 1
					break
				}
				i += 1
			}
		case .Heading, .Rule:
			i += 1
		case .Blockquote:
			i += 1
			for i < hi {
				if is_blockquote_line(lines[i].text) {
					i += 1
					continue
				}
				if is_blank(lines[i].text) {
					j := i
					for j < hi && is_blank(lines[j].text) do j += 1
					if j < hi && is_blockquote_line(lines[j].text) {
						i = j
						continue
					}
				}
				break
			}
		case .List:
			base_lm := list_marker(lines[start].text)
			i += 1
			for i < hi {
				if is_blank(lines[i].text) {
					j := i
					for j < hi && is_blank(lines[j].text) do j += 1
					if j < hi {
						lm := list_marker(lines[j].text)
						if lm.ok {
							if lm.indent == base_lm.indent && lm.ordered == base_lm.ordered {
								i = j
								continue
							}
							break
						}
						if leading_spaces(lines[j].text) >= 2 {
							i = j
							continue
						}
					}
					break
				}
				lm := list_marker(lines[i].text)
				if lm.ok {
					if lm.indent == base_lm.indent && lm.ordered != base_lm.ordered {
						break
					}
					i += 1
					continue
				}
				if leading_spaces(lines[i].text) >= 2 {
					i += 1
					continue
				}
				break
			}
		case .Table:
			i += 2
			for i < hi && !is_blank(lines[i].text) && strings.contains(lines[i].text, "|") do i += 1
		case .HTML:
			i += 1
			for i < hi && !is_blank(lines[i].text) do i += 1
		case .Indented_Code:
			i += 1
			for i < hi && (is_blank(lines[i].text) || leading_spaces(lines[i].text) >= 4) do i += 1
		case .Paragraph:
			i += 1
			for i < hi {
				if is_blank(lines[i].text) do break
				if is_setext_underline(lines[i].text) && i > start {
					i += 1
					break
				}
				nxt := i + 1 < hi ? lines[i + 1].text : ""
				k2 := classify_line(lines[i].text, nxt, i + 1 < hi)
				switch k2 {
				case .Fence, .Heading, .Blockquote, .List, .Rule, .Table, .HTML:
					break
				case .Indented_Code:
					// Four-space indentation continues a paragraph.
					i += 1
					continue
				case .Paragraph:
				}
				if k2 != .Paragraph do break
				i += 1
			}
		}
		append(&blocks, Block{lo = start, hi = i, kind = kind})
	}
	return blocks[:]
}

Block_Line_Text :: struct {
	lines: []Source_Line,
	lo:    int,
	hi:    int,
}

block_text :: proc(lines: []Source_Line, b: Block) -> string {
	bld := strings.builder_make()
	for i := b.lo; i < b.hi; i += 1 {
		if i > b.lo do strings.write_byte(&bld, '\n')
		strings.write_string(&bld, lines[i].text)
	}
	return strings.to_string(bld)
}

strip_indent :: proc(s: string, n: int) -> string {
	i := 0
	for i < n && i < len(s) && s[i] == ' ' do i += 1
	return s[i:]
}

// --- block rendering -------------------------------------------------------

Ctx :: struct {
	style:  Style,
	width:  int,
	prefix: string,
	out:    ^strings.Builder,
}

ctx_write :: proc(ctx: ^Ctx, s: string) {
	strings.write_string(ctx.out, s)
}

ctx_prefix_width :: proc(ctx: ^Ctx) -> int {
	return display_width(ctx.prefix)
}

write_wrapped :: proc(ctx: ^Ctx, text: string, first_prefix, cont_prefix: string, avail: int) {
	if strings.trim_space(strip_ansi(text)) == "" do return
	a := max(avail, 1)
	chunks := wrap_ansi(text, a)
	defer {
		for c in chunks do delete(c)
		delete(chunks)
	}
	for chunk, i in chunks {
		if i == 0 {
			ctx_write(ctx, first_prefix)
		} else {
			ctx_write(ctx, cont_prefix)
		}
		ctx_write(ctx, chunk)
		ctx_write(ctx, "\n")
	}
}

render_paragraph_like :: proc(ctx: ^Ctx, text: string, first_bullet: string) {
	inline := inline_render(text, ctx.style)
	defer delete(inline)
	pw := ctx_prefix_width(ctx)
	bw := display_width(first_bullet)
	first := strings.concatenate({ctx.prefix, first_bullet}, context.temp_allocator)
	cont := strings.concatenate({ctx.prefix, strings.repeat(" ", bw, context.temp_allocator)}, context.temp_allocator)
	write_wrapped(ctx, inline, first, cont, ctx.width - pw - bw)
}

render_heading :: proc(ctx: ^Ctx, level: int, text: string, first_bullet: string) {
	if len(strings.trim_space(text)) == 0 do return
	s := ctx.style
	b := strings.builder_make(context.temp_allocator)
	if level == 1 && s.h1_bold {
		strings.write_string(&b, BOLD_SGR)
	} else if s.heading_bold {
		strings.write_string(&b, BOLD_SGR)
	}
	color := s.heading_color
	if level == 1 && len(s.h1_color) > 0 do color = s.h1_color
	if len(color) > 0 do strings.write_string(&b, fg_sgr(color))
	strings.write_string(&b, strings.repeat("#", level, context.temp_allocator))
	strings.write_string(&b, " ")
	inner := inline_run(text, ctx.style, Inline_Flags{heading = true})
	defer delete(inner)
	strings.write_string(&b, inner)
	strings.write_string(&b, RESET_SGR)
	styled := strings.to_string(b)

	pw := ctx_prefix_width(ctx)
	bw := display_width(first_bullet)
	first := strings.concatenate({ctx.prefix, first_bullet}, context.temp_allocator)
	cont := strings.concatenate({ctx.prefix, strings.repeat(" ", bw, context.temp_allocator)}, context.temp_allocator)
	write_wrapped(ctx, styled, first, cont, ctx.width - pw - bw)
}

render_rule :: proc(ctx: ^Ctx) {
	pw := ctx_prefix_width(ctx)
	w := max(ctx.width - pw, 1)
	ctx_write(ctx, ctx.prefix)
	if len(ctx.style.rule_color) > 0 do ctx_write(ctx, fg_sgr(ctx.style.rule_color))
	ctx_write(ctx, strings.repeat("─", w, context.temp_allocator))
	ctx_write(ctx, RESET_SGR)
	ctx_write(ctx, "\n")
}

code_header :: proc(lang: string, width: int) -> string {
	w := max(width, 1)
	if len(lang) == 0 do return strings.repeat("─", w, context.temp_allocator)
	label := fmt.tprintf("─ %s ", lang)
	lw := display_width(label)
	if lw < w do return strings.concatenate({label, strings.repeat("─", w - lw, context.temp_allocator)}, context.temp_allocator)
	return label
}

code_header_note :: proc(label, note: string, width: int) -> string {
	if len(note) == 0 do return code_header(label, width)
	left := ""
	if len(label) > 0 do left = fmt.tprintf("─ %s ", label)
	right := fmt.tprintf(" %s ─", note)
	lw := display_width(left)
	rw := display_width(right)
	if lw + rw > width do return code_header(label, width)
	return strings.concatenate({left, strings.repeat("─", width - lw - rw, context.temp_allocator), right}, context.temp_allocator)
}

code_border :: proc(ctx: ^Ctx, label: string, note: string = "") {
	s := ctx.style
	if len(s.code_block_bg) > 0 do ctx_write(ctx, bg_sgr(s.code_block_bg))
	if len(s.code_block_color) > 0 do ctx_write(ctx, fg_sgr(s.code_block_color))
	ctx_write(ctx, code_header_note(label, note, ctx.width))
	ctx_write(ctx, RESET_SGR)
	ctx_write(ctx, "\n")
}

code_content_line :: proc(ctx: ^Ctx, line: string, plain: bool, lang: string, highlight: bool) {
	s := ctx.style
	expanded, _ := expand_tabs(line, 0)
	defer delete(expanded)
	if highlight {
		hl := highlight_line(lang, expanded)
		ctx_write(ctx, hl)
		delete(hl)
		ctx_write(ctx, "\n")
		return
	}
	if len(s.code_block_bg) > 0 {
		ctx_write(ctx, bg_sgr(s.code_block_bg))
		if plain && len(s.code_block_color) > 0 do ctx_write(ctx, fg_sgr(s.code_block_color))
		reopened, allocated := strings.replace_all(expanded, RESET_SGR, strings.concatenate({RESET_SGR, bg_sgr(s.code_block_bg)}, context.temp_allocator))
		ctx_write(ctx, reopened)
		if allocated do delete(reopened)
		ctx_write(ctx, EL)
	} else if plain && len(s.code_block_color) > 0 {
		ctx_write(ctx, fg_sgr(s.code_block_color))
		ctx_write(ctx, expanded)
		ctx_write(ctx, RESET_SGR)
	} else {
		ctx_write(ctx, expanded)
	}
	ctx_write(ctx, "\n")
}

render_code_block :: proc(ctx: ^Ctx, lines: []Source_Line, b: Block) {
	lang := ""
	content_lo := b.lo
	content_hi := b.hi
	if b.kind == .Fence {
		opening := lines[b.lo].text
		indent := leading_spaces(opening)
		marker := opening[indent]
		count := 0
		for indent + count < len(opening) && opening[indent + count] == marker do count += 1
		rest := strings.trim_space(opening[indent + count:])
		// The info string is the first word of the fence line.
		word_end := 0
		for word_end < len(rest) && rest[word_end] != ' ' && rest[word_end] != '\t' do word_end += 1
		lang = rest[:word_end]
		content_lo = b.lo + 1
		content_hi = b.hi
		if content_hi > content_lo && is_closing_fence(lines[content_hi - 1].text, marker, count) do content_hi -= 1
	}

	// Drop trailing blank lines: a block scanner may include the separator
	// before the next block, but it is not code.
	for content_hi > content_lo && is_blank(lines[content_hi - 1].text) do content_hi -= 1

	// Check for any visible code.
	has_code := false
	for i := content_lo; i < content_hi; i += 1 {
		if len(strings.trim_space(lines[i].text)) > 0 {
			has_code = true
			break
		}
	}
	if !has_code do return

	code_border(ctx, lang)
	highlight := len(lang) > 0 && known_language(lang) && len(ctx.style.code_block_bg) > 0
	for i := content_lo; i < content_hi; i += 1 {
		line := lines[i].text
		if b.kind == .Fence {
			indent := leading_spaces(lines[b.lo].text)
			line = strip_indent(line, indent)
		} else {
			line = strip_indent(line, 4)
		}
		code_content_line(ctx, line, true, lang, highlight)
	}
	code_border(ctx, "")
}

split_table_row :: proc(s: string) -> []string {
	t := strings.trim_space(s)
	if strings.has_prefix(t, "|") do t = t[1:]
	if strings.has_suffix(t, "|") do t = t[:len(t) - 1]
	parts := strings.split(t, "|", context.temp_allocator)
	out := make([]string, len(parts))
	for p, i in parts do out[i] = strings.trim_space(p)
	return out
}

fit_table_widths :: proc(natural: []int, avail: int) -> []int {
	widths := make([]int, len(natural))
	copy(widths, natural)
	sum := proc(w: []int) -> int {
		t := 0
		for x in w do t += x
		return t
	}
	if sum(widths) <= avail do return widths
	for floor := 3; floor >= 1; floor -= 1 {
		for {
			if sum(widths) <= avail do return widths
			bi := -1
			for w, i in widths {
				if w > floor && (bi < 0 || w > widths[bi]) do bi = i
			}
			if bi < 0 do break
			widths[bi] -= 1
		}
	}
	return widths
}

wrap_table_text :: proc(s: string, width: int) -> []string {
	w := max(width, 1)
	lines := make([dynamic]string, 0, 4)
	line := strings.builder_make()
	col := 0
	active := ""
	need_space := false

	start_line :: proc(line: ^strings.Builder, active: string) {
		if len(active) > 0 do strings.write_string(line, fmt.tprintf("\x1b[%sm", active))
	}
	end_line :: proc(lines: ^[dynamic]string, line: ^strings.Builder, active: ^string, col: ^int, need_space: ^bool) {
		if len(active^) > 0 do strings.write_string(line, RESET_SGR)
		append(lines, strings.clone(strings.to_string(line^)))
		strings.builder_reset(line)
		col^ = 0
		need_space^ = false
		start_line(line, active^)
	}

	i := 0
	for i < len(s) {
		c := s[i]
		if c == 0x1b {
			if need_space && col > 0 {
				strings.write_byte(&line, ' ')
				col += 1
				need_space = false
			}
			j := csi_end(s, i)
			strings.write_string(&line, s[i:j])
			active = apply_sgr(active, s[i:j])
			i = j
			continue
		}
		if c == ' ' {
			need_space = true
			i += 1
			continue
		}
		j := i
		for j < len(s) && s[j] != ' ' && s[j] != 0x1b do j += 1
		word := s[i:j]
		i = j
		if need_space && col > 0 {
			if col + 1 + display_width(word) <= w {
				strings.write_byte(&line, ' ')
				col += 1
			} else {
				end_line(&lines, &line, &active, &col, &need_space)
			}
		} else if col > 0 && col + display_width(word) > w {
			end_line(&lines, &line, &active, &col, &need_space)
		}
		need_space = false
		pieces := split_cells(word, w)
		for piece in pieces {
			pw := display_width(piece)
			if col > 0 && col + pw > w do end_line(&lines, &line, &active, &col, &need_space)
			strings.write_string(&line, piece)
			col += pw
		}
		for piece in pieces do delete(piece)
		delete(pieces)
	}
	if col > 0 || strings.builder_len(line) > 0 do end_line(&lines, &line, &active, &col, &need_space)
	if len(lines) == 0 do append(&lines, "")
	delete(line.buf)
	return lines[:]
}

pad_cell :: proc(s: string, width: int) -> string {
	w := display_width(s)
	if w < width do return strings.concatenate({s, strings.repeat(" ", width - w, context.temp_allocator)}, context.temp_allocator)
	return s
}

render_table :: proc(ctx: ^Ctx, lines: []Source_Line, b: Block) {
	header := split_table_row(lines[b.lo].text)
	for &cell in header do cell = inline_render(cell, ctx.style)
	if b.hi <= b.lo + 1 do return
	rows := make([dynamic][]string, 0, b.hi - b.lo)
	append(&rows, header)
	for i := b.lo + 2; i < b.hi; i += 1 {
		if is_blank(lines[i].text) do continue
		row := split_table_row(lines[i].text)
		for &cell in row do cell = inline_render(cell, ctx.style)
		append(&rows, row)
	}

	ncols := 0
	for row in rows do ncols = max(ncols, len(row))
	if ncols == 0 do return
	natural := make([]int, ncols)
	for row in rows {
		for cell, i in row {
			w := display_width(strip_ansi(cell))
			if i < ncols && w > natural[i] do natural[i] = w
		}
	}
	overhead := 3 * ncols + 1
	avail := ctx.width - ctx_prefix_width(ctx) - overhead
	widths := fit_table_widths(natural, avail)
	defer delete(widths)

	// Wrap each cell to its column width.
	grid := make([][][]string, len(rows))
	for row, ri in rows {
		grid[ri] = make([][]string, ncols)
		for ci := 0; ci < ncols; ci += 1 {
			if ci >= len(row) {
				grid[ri][ci] = make([]string, 1)
				continue
			}
			cell := row[ci]
			if display_width(strip_ansi(cell)) <= widths[ci] {
				grid[ri][ci] = make([]string, 1)
				grid[ri][ci][0] = cell
			} else {
				grid[ri][ci] = wrap_table_text(cell, widths[ci])
			}
		}
	}
	defer {
		for ri in 0 ..< len(grid) {
			for ci in 0 ..< ncols {
				delete(grid[ri][ci])
			}
			delete(grid[ri])
		}
		delete(grid)
	}

	border := proc(left, mid, right: string, widths: []int) -> string {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, left)
		for w, ci in widths {
			strings.write_string(&b, strings.repeat("─", w + 2, context.temp_allocator))
			if ci < len(widths) - 1 do strings.write_string(&b, mid)
		}
		strings.write_string(&b, right)
		return strings.to_string(b)
	}

	row_lines :: proc(ctx: ^Ctx, grid_row: [][]string, widths: []int) {
		height := 1
		for cell in grid_row do height = max(height, len(cell))
		for k := 0; k < height; k += 1 {
			ctx_write(ctx, "│")
			for ci := 0; ci < len(widths); ci += 1 {
				seg := ""
				if k < len(grid_row[ci]) do seg = grid_row[ci][k]
				ctx_write(ctx, " ")
				ctx_write(ctx, pad_cell(seg, widths[ci]))
				ctx_write(ctx, " ")
				ctx_write(ctx, "│")
			}
			ctx_write(ctx, "\n")
		}
	}

	ctx_write(ctx, ctx.prefix)
	ctx_write(ctx, border("┌", "┬", "┐", widths))
	ctx_write(ctx, "\n")
	for row, ri in grid {
		_ = row
		row_lines(ctx, grid[ri], widths)
		if ri == 0 {
			ctx_write(ctx, ctx.prefix)
			ctx_write(ctx, border("├", "┼", "┤", widths))
			ctx_write(ctx, "\n")
		}
	}
	ctx_write(ctx, ctx.prefix)
	ctx_write(ctx, border("└", "┴", "┘", widths))
	ctx_write(ctx, "\n")

	// Row strings that are views into source cells are not owned; only the
	// wrapping output owned its strings, which the grid cleanup above handles.
}

render_blockquote :: proc(ctx: ^Ctx, lines: []Source_Line, b: Block) {
	inner := strings.builder_make()
	for i := b.lo; i < b.hi; i += 1 {
		if i > b.lo do strings.write_byte(&inner, '\n')
		t := lines[i].text
		k := leading_spaces(t)
		if k < len(t) && t[k] == '>' {
			k += 1
			if k < len(t) && t[k] == ' ' do k += 1
			strings.write_string(&inner, t[k:])
		} else {
			strings.write_string(&inner, t)
		}
	}
	inner_text := strings.to_string(inner)
	defer delete(inner.buf)
	child := ctx^
	child.prefix = strings.concatenate({ctx.prefix, "│ "}, context.temp_allocator)
	render_document(&child, inner_text, false)
}

item_text_from_lines :: proc(lines: []Source_Line, lo, hi, content_at: int) -> string {
	b := strings.builder_make()
	first := true
	for i := lo; i < hi; i += 1 {
		if !first do strings.write_byte(&b, '\n')
		first = false
		t := lines[i].text
		if i == lo {
			if content_at <= len(t) {
				t = t[content_at:]
			} else {
				t = ""
			}
			strings.write_string(&b, t)
		} else {
			strings.write_string(&b, strip_indent(t, content_at))
		}
	}
	return strings.to_string(b)
}

render_bullet_item :: proc(ctx: ^Ctx, text: string, bullet: string) {
	child := ctx^

	lines := split_source_lines(text)
	defer delete(lines)
	blocks := scan_blocks(lines, 0, len(lines))
	defer delete(blocks)
	if len(blocks) == 0 do return
	for block, i in blocks {
		_ = i
		if i == 0 && (block.kind == .Paragraph || block.kind == .Heading) {
			text_lines := paragraph_text(lines, block)
			defer delete(text_lines)
			if block.kind == .Heading {
				level := heading_level(lines[block.lo].text)
				heading_text := strings.trim_space(strip_heading_marker(lines[block.lo].text))
				render_heading(&child, level, heading_text, bullet)
			} else {
				render_paragraph_like(&child, text_lines, bullet)
			}
		} else {
			render_block(&child, lines, block)
		}
	}
}

strip_heading_marker :: proc(s: string) -> string {
	i := leading_spaces(s)
	for i < len(s) && s[i] == '#' do i += 1
	return strings.trim_space(s[i:])
}

render_list :: proc(ctx: ^Ctx, lines: []Source_Line, b: Block) {
	first_marker := list_marker(lines[b.lo].text)
	base_indent := first_marker.indent
	ordered := first_marker.ordered
	counter := first_marker.number
	item_ctx := ctx^
	item_ctx.prefix = strings.concatenate({ctx.prefix, "  "}, context.temp_allocator)

	i := b.lo
	for i < b.hi {
		lm := list_marker(lines[i].text)
		if !lm.ok || lm.indent != base_indent {
			i += 1
			continue
		}
		// Find the next item at the same indentation.
		j := i + 1
		for j < b.hi {
			nm := list_marker(lines[j].text)
			if nm.ok && nm.indent == base_indent do break
			j += 1
		}
		item_text := item_text_from_lines(lines, i, j, lm.content_at)
		bullet := ""
		if ordered {
			bullet = fmt.tprintf("%d. ", counter)
			counter += 1
		} else {
			bullet = "• "
		}
		render_bullet_item(&item_ctx, item_text, bullet)
		delete(item_text)
		i = j
	}
}

paragraph_text :: proc(lines: []Source_Line, b: Block) -> string {
	bld := strings.builder_make()
	first := true
	prev_hard := false
	for i := b.lo; i < b.hi; i += 1 {
		if is_setext_underline(lines[i].text) && i > b.lo do break
		raw := strings.trim_space(lines[i].text)
		if len(raw) == 0 do continue
		hard := strings.has_suffix(lines[i].text, "  ") || strings.has_suffix(raw, "\\")
		if hard && len(raw) > 0 && raw[len(raw) - 1] == '\\' do raw = raw[:len(raw) - 1]
		if !first {
			if prev_hard {
				strings.write_byte(&bld, '\n')
			} else {
				strings.write_byte(&bld, ' ')
			}
		}
		strings.write_string(&bld, raw)
		first = false
		prev_hard = hard
	}
	return strings.to_string(bld)
}

render_block :: proc(ctx: ^Ctx, lines: []Source_Line, b: Block) {
	switch b.kind {
	case .Paragraph:
		if b.hi - b.lo >= 2 && is_setext_underline(lines[b.hi - 1].text) {
			underline := strings.trim_space(lines[b.hi - 1].text)
			level := underline[0] == '=' ? 1 : 2
			hb := b
			hb.hi -= 1
			text := paragraph_text(lines, hb)
			render_heading(ctx, level, text, "")
			delete(text)
			break
		}
		text := paragraph_text(lines, b)
		defer delete(text)
		render_paragraph_like(ctx, text, "")
	case .Heading:
		level := heading_level(lines[b.lo].text)
		text := strings.trim_space(strip_heading_marker(lines[b.lo].text))
		render_heading(ctx, level, text, "")
	case .Rule:
		render_rule(ctx)
	case .Fence, .Indented_Code:
		render_code_block(ctx, lines, b)
	case .Blockquote:
		render_blockquote(ctx, lines, b)
	case .List:
		render_list(ctx, lines, b)
	case .Table:
		render_table(ctx, lines, b)
	case .HTML:
		// Raw HTML blocks are dropped, matching goldmark's renderNothing.
	}
}


// block_is_empty reports whether a block would render no visible content.
// Go's topLevelBlocks drops such nodes (an empty list item or heading has no
// content lines), which keeps a transient empty item from being mistaken for
// the document's stable last block while it is still arriving.
block_is_empty :: proc(lines: []Source_Line, b: Block) -> bool {
	switch b.kind {
	case .Heading:
		return len(strings.trim_space(strip_heading_marker(lines[b.lo].text))) == 0
	case .Paragraph:
		for i := b.lo; i < b.hi; i += 1 {
			if !is_blank(lines[i].text) do return false
		}
		return true
	case .Fence:
		if b.hi - b.lo < 2 do return true
		marker := lines[b.lo].text[leading_spaces(lines[b.lo].text)]
		count := 0
		indent := leading_spaces(lines[b.lo].text)
		for indent + count < len(lines[b.lo].text) && lines[b.lo].text[indent + count] == marker do count += 1
		hi := b.hi
		if hi > b.lo + 1 && is_closing_fence(lines[hi - 1].text, marker, count) do hi -= 1
		for i := b.lo + 1; i < hi; i += 1 {
			if !is_blank(lines[i].text) do return false
		}
		return true
	case .Indented_Code:
		for i := b.lo; i < b.hi; i += 1 {
			if !is_blank(lines[i].text) do return false
		}
		return true
	case .List:
		for i := b.lo; i < b.hi; i += 1 {
			t := lines[i].text
			if is_blank(t) do continue
			lm := list_marker(t)
			if lm.ok {
				if len(strings.trim_space(t[lm.content_at:])) > 0 do return false
				continue
			}
			if len(strings.trim_space(t)) > 0 do return false
		}
		return true
	case .Rule, .Table, .Blockquote, .HTML:
		return false
	}
	return false
}

render_document :: proc(ctx: ^Ctx, text: string, top_level := true) {
	lines := split_source_lines(text)
	defer delete(lines)
	blocks := scan_blocks(lines, 0, len(lines))
	defer delete(blocks)
	had_block := false
	for b in blocks {
		skip_output := b.kind == .HTML
		if b.kind == .Heading {
			heading_text := strings.trim_space(strip_heading_marker(lines[b.lo].text))
			if len(heading_text) == 0 do skip_output = true
		}
		if skip_output {
			had_block = true
			continue
		}
		if top_level && had_block do ctx_write(ctx, "\n")
		render_block(ctx, lines, b)
		had_block = true
	}
}

// render_markdown renders a complete markdown string at the given width.
render_markdown :: proc(text: string, style: Style, width: int) -> Render_Output {
	out := strings.builder_make()
	ctx := Ctx{style = style, width = max(width, 1), prefix = "", out = &out}
	render_document(&ctx, text)
	data := strings.to_string(out)
	lines := split_lines(data)
	return Render_Output{data = data, lines = lines}
}

split_lines :: proc(data: string) -> []Line {
	lines := make([dynamic]Line, 0, 16)
	start := 0
	i := 0
	for i <= len(data) {
		if i == len(data) {
			if i > start {
				text := data[start:i]
				append(&lines, Line{text = text, width = display_width(text)})
			}
			break
		}
		if data[i] == '\n' {
			if i == len(data) - 1 && i == start {
				break
			}
			text := data[start:i]
			append(&lines, Line{text = text, width = display_width(text)})
			start = i + 1
		}
		i += 1
	}
	return lines[:]
}

// --- inline rendering ------------------------------------------------------

Inline_Flags :: struct {
	emph:    bool,
	strong:  bool,
	code:    bool,
	link:    bool,
	strike:  bool,
	heading: bool,
	image:   bool,
}

body_prefix :: proc(style: Style, flags: Inline_Flags) -> string {
	if len(style.text_color) == 0 do return ""
	if flags.emph {
		return fg_sgr(style.text_color)
	}
	if flags.strong || flags.code || flags.link || flags.strike || flags.heading || flags.image do return ""
	pre := ""
	if style.text_italic do pre = ITALIC_SGR
	return strings.concatenate({pre, fg_sgr(style.text_color)}, context.temp_allocator)
}

write_plain :: proc(b: ^strings.Builder, text: string, style: Style, flags: Inline_Flags) {
	if len(text) == 0 do return
	pre := body_prefix(style, flags)
	if len(pre) > 0 {
		strings.write_string(b, pre)
		strings.write_string(b, text)
		strings.write_string(b, RESET_SGR)
	} else {
		strings.write_string(b, text)
	}
}

inline_run :: proc(text: string, style: Style, flags: Inline_Flags) -> string {
	b := strings.builder_make()
	i := 0
	plain_start := 0
	flush_plain :: proc(b: ^strings.Builder, text: string, start, end: int, style: Style, flags: Inline_Flags) {
		if end > start do write_plain(b, text[start:end], style, flags)
	}
	for i < len(text) {
		c := text[i]
		if c == '\\' && i + 1 < len(text) {
			flush_plain(&b, text, plain_start, i, style, flags)
			write_plain(&b, text[i + 1:i + 2], style, flags)
			i += 2
			plain_start = i
			continue
		}
		if c == '`' {
			close := strings.index_byte(text[i + 1:], '`')
			if close >= 0 {
				flush_plain(&b, text, plain_start, i, style, flags)
				body := text[i + 1:i + 1 + close]
				if len(style.code_color) > 0 {
					strings.write_string(&b, fg_sgr(style.code_color))
					strings.write_string(&b, body)
					strings.write_string(&b, RESET_SGR)
				} else {
					strings.write_string(&b, body)
				}
				i += close + 2
				plain_start = i
				continue
			}
		}
		if c == '!' && i + 1 < len(text) && text[i + 1] == '[' {
			if end := strings.index(text[i + 2:], "]("); end >= 0 {
				rest := i + 2 + end + 2
				if rp := strings.index_byte(text[rest:], ')'); rp >= 0 {
					flush_plain(&b, text, plain_start, i, style, flags)
					alt := text[i + 2:i + 2 + end]
					dest := text[rest:rest + rp]
					image_flags := flags
					image_flags.image = true
					alt_styled := inline_run(alt, style, image_flags)
					strings.write_string(&b, "[")
					strings.write_string(&b, alt_styled)
					strings.write_string(&b, "]")
					delete(alt_styled)
					if len(dest) > 0 {
						strings.write_string(&b, " (")
						strings.write_string(&b, dest)
						strings.write_string(&b, ")")
					}
					i = rest + rp + 1
					plain_start = i
					continue
				}
			}
		}
		if c == '[' {
			if end := strings.index(text[i + 1:], "]("); end >= 0 {
				rest := i + 1 + end + 2
				if rp := strings.index_byte(text[rest:], ')'); rp >= 0 {
					flush_plain(&b, text, plain_start, i, style, flags)
					label := text[i + 1:i + 1 + end]
					dest := text[rest:rest + rp]
					label_flags := flags
					label_flags.link = true
					label_styled := inline_run(label, style, label_flags)
					if len(style.link_color) > 0 do strings.write_string(&b, fg_sgr(style.link_color))
					if style.link_underline do strings.write_string(&b, UNDERLINE_SGR)
					strings.write_string(&b, label_styled)
					if len(style.link_color) > 0 || style.link_underline do strings.write_string(&b, RESET_SGR)
					delete(label_styled)
					if len(dest) > 0 {
						strings.write_string(&b, " (")
						strings.write_string(&b, dest)
						strings.write_string(&b, ")")
					}
					i = rest + rp + 1
					plain_start = i
					continue
				}
			}
		}
		if c == '<' {
			if close := strings.index_byte(text[i + 1:], '>'); close >= 0 {
				flush_plain(&b, text, plain_start, i, style, flags)
				label := text[i + 1:i + 1 + close]
				if strings.has_prefix(label, "http://") || strings.has_prefix(label, "https://") || strings.contains(label, "@") {
					if len(style.link_color) > 0 do strings.write_string(&b, fg_sgr(style.link_color))
					if style.link_underline do strings.write_string(&b, UNDERLINE_SGR)
					strings.write_string(&b, label)
					if len(style.link_color) > 0 || style.link_underline do strings.write_string(&b, RESET_SGR)
				}
				// Other angle-bracket content is raw HTML and is dropped.
				i += close + 2
				plain_start = i
				continue
			}
		}
		if (c == '*' || c == '_') && i + 1 < len(text) && text[i + 1] == c {
			if close := strings.index(text[i + 2:], text[i:i + 2]); close >= 0 {
				flush_plain(&b, text, plain_start, i, style, flags)
				if style.strong_bold do strings.write_string(&b, BOLD_SGR)
				inner_flags := flags
				inner_flags.strong = true
				inner := inline_run(text[i + 2:i + 2 + close], style, inner_flags)
				strings.write_string(&b, inner)
				delete(inner)
				if style.strong_bold do strings.write_string(&b, RESET_SGR)
				i += close + 4
				plain_start = i
				continue
			}
		}
		if c == '~' && i + 1 < len(text) && text[i + 1] == '~' {
			if close := strings.index(text[i + 2:], "~~"); close >= 0 {
				flush_plain(&b, text, plain_start, i, style, flags)
				if style.strike_through do strings.write_string(&b, STRIKE_SGR)
				inner_flags := flags
				inner_flags.strike = true
				inner := inline_run(text[i + 2:i + 2 + close], style, inner_flags)
				strings.write_string(&b, inner)
				delete(inner)
				if style.strike_through do strings.write_string(&b, RESET_SGR)
				i += close + 4
				plain_start = i
				continue
			}
		}
		if (c == '*' || c == '_') && i + 1 < len(text) && text[i + 1] != c {
			if close := strings.index_byte(text[i + 1:], c); close >= 0 {
				flush_plain(&b, text, plain_start, i, style, flags)
				if style.emph_italic do strings.write_string(&b, ITALIC_SGR)
				inner_flags := flags
				inner_flags.emph = true
				inner := inline_run(text[i + 1:i + 1 + close], style, inner_flags)
				strings.write_string(&b, inner)
				delete(inner)
				if style.emph_italic do strings.write_string(&b, RESET_SGR)
				i += close + 2
				plain_start = i
				continue
			}
		}
		i += 1
	}
	flush_plain(&b, text, plain_start, len(text), style, flags)
	return strings.to_string(b)
}

inline_render :: proc(text: string, style: Style) -> string {
	return inline_run(text, style, Inline_Flags{})
}
