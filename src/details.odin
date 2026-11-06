// The behind-the-scenes details page. It replaces the transcript inside the
// center pane and shows the harness's own view of the session: configuration,
// prompt documents, session nuggets, discovered tools, usage records, and the
// last turn's request metadata. The small strip below the composer swaps it
// with the conversation; see draw_view_strip at the bottom of this file.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "harness"

// Details gets its own zoom on top of the app-wide UI text scale. Its layout
// constants grow with it so larger text still has room.
DETAIL_TEXT_SCALE :: f32(1.20)
DETAIL_PAD        :: f32(14) * DETAIL_TEXT_SCALE
DETAIL_ROW_H      :: f32(20) * DETAIL_TEXT_SCALE
DETAIL_HEAD_H     :: f32(24) * DETAIL_TEXT_SCALE
DETAIL_GAP        :: f32(18) * DETAIL_TEXT_SCALE
DETAIL_LABEL_W    :: f32(134) * DETAIL_TEXT_SCALE
DETAIL_ROW_BODY   :: f32(42) * DETAIL_TEXT_SCALE

Details_State :: struct {
	built:    bool,
	dirty:    bool,
	built_at: f32,

	snapshot: harness.Harness_Snapshot,

	open_prompt: int,
	open_nugget: int,
	open_tool:   int,
	show_context: bool,
	show_prompts: bool,
	show_nuggets: bool,
	show_tools:   bool,
	show_usage:   bool,
}

details_init :: proc(s: ^Details_State) {
	s.open_prompt = -1
	s.open_nugget = -1
	s.open_tool = -1
	s.show_context = true
	s.show_prompts = true
	s.show_nuggets = true
	s.show_tools = true
	s.show_usage = true
}

details_destroy :: proc(s: ^Details_State) {
	harness.harness_snapshot_destroy(&s.snapshot)
	s^ = {}
}

// details_refresh rebuilds the snapshot. It is called when the page is opened,
// when a turn or session changes, and by the Refresh button.
details_refresh :: proc(p: ^Project, t: ^Conversation_Tab, now: f32) {
	harness.harness_snapshot_destroy(&t.details.snapshot)
	if t.harness_ready {
		t.details.snapshot = harness.harness_snapshot(&t.harness)
	} else {
		s := &t.details.snapshot
		s.project_dir = strings.clone(p.path)
		cfg := harness.config_dir_path()
		s.config_dir = cfg
		s.session_path = strings.clone(t.session_path)
		if st, ok := stat_file(t.session_path); ok do s.session_file_bytes = st
		note := len(p.error) > 0 ? p.error : "the session harness is not running yet"
		s.startup_notes = strings.clone(note)
	}
	t.details.built = true
	t.details.dirty = false
	t.details.built_at = now
	if t.details.open_prompt >= len(t.details.snapshot.prompts) do t.details.open_prompt = -1
	if t.details.open_nugget >= len(t.details.snapshot.nuggets) do t.details.open_nugget = -1
	if t.details.open_tool >= len(t.details.snapshot.tools) do t.details.open_tool = -1
}

// stat_file is a small local wrapper so details.odin does not need to care
// about File_Info's fields beyond the size.
stat_file :: proc(path: string) -> (int, bool) {
	st, err := os.stat(path, context.temp_allocator)
	if err != nil do return 0, false
	return int(st.size), true
}

data_size :: proc(n: int) -> string {
	if n < 1024 do return fmt.tprintf("%d B", n)
	if n < 1024 * 1024 do return fmt.tprintf("%.1f KB", f64(n) / 1024.0)
	return fmt.tprintf("%.1f MB", f64(n) / (1024.0 * 1024.0))
}

details_toggle :: proc(t: ^Conversation_Tab) {
	t.details_open = !t.details_open
	t.details.dirty = true
	if t.details_open {
		// The hidden composer must not keep keyboard focus while the details
		// page is in front.
		igClearActiveID()
	} else {
		t.composer_refocus = true
	}
}

turn_state_label :: proc(state: harness.Turn_State) -> string {
	switch state {
	case .Idle:        return "never run"
	case .Running:     return "running"
	case .Completed:   return "completed"
	case .Failed:      return "failed"
	case .Interrupted: return "interrupted"
	}
	return "unknown"
}

turn_state_col :: proc(th: Theme, state: harness.Turn_State) -> Color {
	switch state {
	case .Running:     return th.yellow
	case .Completed:   return th.green
	case .Failed:      return th.red
	case .Interrupted: return th.yellow
	case .Idle:        return th.fg_faint
	}
	return th.fg_faint
}

usage_short :: proc(u: harness.Usage) -> string {
	return fmt.tprintf("in %s · cached %s · out %s · reasoning %s · total %s",
		format_count(u.input_tokens), format_count(u.cached_tokens),
		format_count(u.output_tokens), format_count(u.reasoning_tokens),
		format_count(u.total_tokens))
}

// --- drawing helpers -------------------------------------------------------

detail_section_header :: proc(
	list: ^ImDrawList,
	app: ^App,
	x, y, w: f32,
	title, meta: string,
	id: cstring,
	open: ^bool,
) -> (clicked: bool, h: f32) {
	th := app.th
	header := rect(x, y, w, DETAIL_HEAD_H)
	title_x := x
	if open != nil {
		clicked = hit(id, header)
		if mi_hit_hovered() do panel(list, header, th.bg_hover, 5)
		if open^ {
			glyph_chevron_down(list, x + 6, y + DETAIL_HEAD_H * 0.5, 3.8, th.fg_faint)
		} else {
			glyph_chevron_right(list, x + 6, y + DETAIL_HEAD_H * 0.5, 3.8, th.fg_faint)
		}
		title_x = x + 16
	}
	text_font(list, app.f.ui, 11.0, title_x, y + 5, th.fg_faint, title)
	if len(meta) > 0 {
		mw, _ := measure(app.f.ui, 10.5, meta)
		text_font(list, app.f.ui, 10.5, x + w - mw, y + 5, th.fg_faint, meta)
	}
	return clicked, DETAIL_HEAD_H
}

detail_card :: proc(list: ^ImDrawList, th: Theme, x, y, w, h: f32) {
	panel(list, rect(x, y, w, h), th.bg_panel, 10, th.border_soft, 1)
}

detail_label_value :: proc(
	list: ^ImDrawList,
	app: ^App,
	x, y, w: f32,
	label, value: string,
	value_col: Color = {0, 0, 0, 0},
	mono: bool = false,
) {
	th := app.th
	col := value_col
	if col[3] == 0 do col = th.fg_dim
	text_font(list, app.f.ui, 11.0, x, y + 3, th.fg_faint, label)
	vx := x + DETAIL_LABEL_W
	vw := max(w - DETAIL_LABEL_W, 20)
	font := mono ? app.f.mono : app.f.ui
	size: f32 = mono ? 11.5 : 12.0
	text_elided(list, font, size, vx, y + 2, vw, col, value)
}

detail_usage_rows :: proc(list: ^ImDrawList, app: ^App, x, y, w: f32, label, value: string,
                           col: Color = {0, 0, 0, 0}) {
	detail_label_value(list, app, x, y, w, label, value, col)
}

// --- overview --------------------------------------------------------------

draw_details_overview :: proc(app: ^App, t: ^Conversation_Tab, list: ^ImDrawList, x, top, w: f32) -> f32 {
	y := top
	th := app.th
	s := &t.details.snapshot
	_, head_h := detail_section_header(list, app, x, y, w, "SESSION & CONFIGURATION", "", nil, nil)
	y += head_h

	base := s.base_url
	if len(base) == 0 do base = harness.DEFAULT_BASE_URL
	ctx := "not configured"
	if s.context_limit > 0 {
		ctx = fmt.tprintf("%s / %s tokens", format_count(s.context_tokens), format_count(s.context_limit))
		if !s.context_measured do ctx = fmt.tprintf("%s (estimated)", ctx)
	} else if s.context_tokens > 0 {
		ctx = fmt.tprintf("%s tokens (capacity unknown)", format_count(s.context_tokens))
	}
	reasoning := s.reasoning_effort
	if len(reasoning) == 0 do reasoning = "provider default"
	api := s.api_key_set ? "set (hidden)" : "not set"
	compacted := s.session_compacted ? "yes" : "no"
	file_size := s.session_file_bytes > 0 ? data_size(s.session_file_bytes) : "not written yet"
	items := fmt.tprintf("%d in context · %d discovered", s.context_items, len(s.tools))
	instructions := data_size(s.instructions_bytes)
	headroom := s.context_headroom > 0 ? fmt.tprintf("%d%% of context", s.context_headroom) : "disabled"

	rows := [14][2]string{
		{"Project", s.project_dir},
		{"Model", s.model},
		{"Endpoint", base},
		{"API key", api},
		{"Reasoning", reasoning},
		{"Context", ctx},
		{"Headroom", headroom},
		{"Instructions", instructions},
		{"Tool display", fmt.tprintf("MIAGENT_TOOLCALL_SIZE=%d", s.tool_call_size)},
		{"Session", s.session_path},
		{"Config", s.config_dir},
		{"State", s.state_dir},
		{"Items / tools", items},
		{"History", fmt.tprintf("compacted: %s · file: %s", compacted, file_size)},
	}

	notes := s.startup_notes
	notes_h: f32 = 0
	inner_w := w - DETAIL_PAD * 2
	if len(notes) > 0 {
		notes_h = plain_wrapped_height(app.f.ui, 11.5, inner_w - 18, notes) + 24
	}
	card_h := DETAIL_PAD * 2 + f32(len(rows)) * DETAIL_ROW_H + notes_h
	detail_card(list, th, x, y, w, card_h)

	yy := y + DETAIL_PAD
	for row in rows {
		detail_label_value(list, app, x + DETAIL_PAD, yy, inner_w, row[0], row[1])
		yy += DETAIL_ROW_H
	}
	if len(notes) > 0 {
		rule(list, x + DETAIL_PAD, x + w - DETAIL_PAD, yy + 2, th.border_soft)
		yy += 10
		text_wrapped(list, app.f.ui, 11.5, x + DETAIL_PAD + 9, yy + 2, inner_w - 18,
			mix(th.fg, th.yellow, 0.22), notes)
	}
	return head_h + card_h + DETAIL_GAP
}

// --- last turn -------------------------------------------------------------

draw_details_last_turn :: proc(app: ^App, t: ^Conversation_Tab, list: ^ImDrawList, x, top, w: f32) -> f32 {
	y := top
	th := app.th
	s := &t.details.snapshot
	t := &s.last_turn
	_, head_h := detail_section_header(list, app, x, y, w, "LAST TURN", turn_state_label(t.status), nil, nil)
	y += head_h

	inner_w := w - DETAIL_PAD * 2
	if t.status == .Idle || len(t.prompt) == 0 && len(t.started) == 0 {
		card_h := DETAIL_PAD * 2 + 24
		detail_card(list, th, x, y, w, card_h)
		msg := "No turn has run in this harness yet."
		if s.context_items > 0 do msg = "No turn has run in this process yet; the loaded session is shown below."
		text_font(list, app.f.ui, 11.5, x + DETAIL_PAD, y + DETAIL_PAD + 3, th.fg_faint, msg)
		return head_h + card_h + DETAIL_GAP
	}

	prompt_h: f32 = 0
	if len(t.prompt) > 0 {
		prompt_h = plain_wrapped_height(app.f.ui, 12.5, inner_w, t.prompt) + 18
	}
	error_h: f32 = 0
	if len(t.error) > 0 {
		error_h = plain_wrapped_height(app.f.ui, 11.5, inner_w - 16, t.error) + 22
	}
	rows := 6
	card_h := DETAIL_PAD * 2 + 24 + prompt_h + f32(rows) * DETAIL_ROW_H + error_h
	detail_card(list, th, x, y, w, card_h)

	yy := y + DETAIL_PAD
	col := turn_state_col(th, t.status)
	label := turn_state_label(t.status)
	pw, _ := measure(app.f.ui, 10.5, label)
	panel(list, rect(x + DETAIL_PAD, yy, pw + 20, 20), over(th.bg_panel, alpha(col, 0.16)), 10,
		alpha(col, 0.40), 1)
	dot(list, x + DETAIL_PAD + 10, yy + 10, 3.0, col)
	text_font(list, app.f.ui, 10.5, x + DETAIL_PAD + 18, yy + 3, mix(th.fg, col, 0.30), label)

	when_text := ""
	if len(t.started) > 0 && len(t.finished) > 0 {
		when_text = fmt.tprintf("started %s · finished %s", t.started, t.finished)
	} else if len(t.started) > 0 {
		when_text = fmt.tprintf("started %s", t.started)
	}
	if len(when_text) > 0 {
		ww, _ := measure(app.f.ui, 10.5, when_text)
		text_font(list, app.f.ui, 10.5, x + w - DETAIL_PAD - ww, yy + 3, th.fg_faint, when_text)
	}
	yy += 24

	if len(t.prompt) > 0 {
		text_font(list, app.f.ui, 10.0, x + DETAIL_PAD, yy, th.fg_faint, "PROMPT")
		yy += 16
		text_wrapped(list, app.f.ui, 12.5, x + DETAIL_PAD, yy, inner_w, th.fg_dim, t.prompt)
		yy += prompt_h - 18 + 2
	}

	tool_line := fmt.tprintf("%d", t.tool_calls)
	if len(t.last_tool) > 0 do tool_line = fmt.tprintf("%d · last: %s", t.tool_calls, t.last_tool)
	detail_usage_rows(list, app, x + DETAIL_PAD, yy, inner_w, "Tool calls", tool_line)
	yy += DETAIL_ROW_H
	detail_usage_rows(list, app, x + DETAIL_PAD, yy, inner_w, "Model requests", fmt.tprintf("%d", t.model_calls))
	yy += DETAIL_ROW_H

	r := t.request
	req_line := "no request recorded"
	if r.input_items > 0 || r.body_bytes > 0 {
		req_line = fmt.tprintf("%d items · %d tools · %s body · %s instructions",
			r.input_items, r.tools, data_size(r.body_bytes), data_size(r.instructions_bytes))
	}
	detail_usage_rows(list, app, x + DETAIL_PAD, yy, inner_w, "Last request", req_line)
	yy += DETAIL_ROW_H

	req_ctx := "not measured"
	if r.context_limit > 0 {
		req_ctx = fmt.tprintf("%s / %s tokens", format_count(r.context_tokens), format_count(r.context_limit))
		if !r.context_measured do req_ctx = fmt.tprintf("%s (estimated)", req_ctx)
	} else if r.context_tokens > 0 {
		req_ctx = fmt.tprintf("%s tokens", format_count(r.context_tokens))
	}
	detail_usage_rows(list, app, x + DETAIL_PAD, yy, inner_w, "At request", req_ctx)
	yy += DETAIL_ROW_H

	last := "no usage reported"
	if t.request.got_usage do last = usage_short(t.request.usage)
	detail_usage_rows(list, app, x + DETAIL_PAD, yy, inner_w, "Last response", last)
	yy += DETAIL_ROW_H

	total := "no usage reported"
	if t.got_usage do total = usage_short(t.turn_usage)
	detail_usage_rows(list, app, x + DETAIL_PAD, yy, inner_w, "Turn total", total)
	yy += DETAIL_ROW_H

	if len(t.error) > 0 {
		rule(list, x + DETAIL_PAD, x + w - DETAIL_PAD, yy + 1, alpha(th.red, 0.22))
		yy += 7
		text_wrapped(list, app.f.ui, 11.5, x + DETAIL_PAD + 8, yy + 3, inner_w - 16,
			mix(th.fg, th.red, 0.25), t.error)
	}
	return head_h + card_h + DETAIL_GAP
}

// --- prompt documents ------------------------------------------------------

prompt_doc_meta :: proc(d: harness.Doc_Info) -> string {
	if len(d.error) > 0 do return "error"
	if !d.exists do return d.required ? "missing" : "not found"
	if len(d.content) == 0 do return "empty"
	return data_size(len(d.content))
}

prompt_doc_height :: proc(app: ^App, d: harness.Doc_Info, open: bool, inner_w: f32) -> f32 {
	if !open do return DETAIL_ROW_BODY
	if !d.exists || len(d.content) == 0 do return DETAIL_ROW_BODY
	code_w := inner_w - 20
	return DETAIL_ROW_BODY + code_wrapped_height(app.f.mono, 11.5, code_w, d.content) + 24
}

draw_details_prompts :: proc(
	app: ^App,
	t: ^Conversation_Tab,
	list: ^ImDrawList,
	x, top, w: f32,
	clip_top, clip_bottom: f32,
) -> f32 {
	y := top
	th := app.th
	s := &t.details.snapshot
	meta := fmt.tprintf("%d document%s", len(s.prompts), len(s.prompts) == 1 ? "" : "s")
	clicked, head_h := detail_section_header(list, app, x, y, w, "PROMPT DOCUMENTS",
		meta, cstr("##detailprompts"), &t.details.show_prompts)
	if clicked do t.details.show_prompts = !t.details.show_prompts
	y += head_h
	if !t.details.show_prompts do return head_h

	inner_w := w - DETAIL_PAD * 2
	card_h := DETAIL_PAD * 2
	for d, i in s.prompts {
		open := t.details.open_prompt == i
		card_h += prompt_doc_height(app, d, open, inner_w)
	}
	detail_card(list, th, x, y, w, card_h)

	yy := y + DETAIL_PAD
	for d, i in s.prompts {
		open := t.details.open_prompt == i
		row := rect(x + DETAIL_PAD, yy, inner_w, DETAIL_ROW_BODY)
		idbuf: [32]u8
		clickable := d.exists && len(d.content) > 0
		if clickable {
			row_clicked := hit(id_cstr(idbuf[:], "detailprompt%d", i), row)
			if mi_hit_hovered() do panel(list, row, th.bg_hover, 6)
			if open {
				glyph_chevron_down(list, row.x + 7, row.y + DETAIL_ROW_BODY * 0.5, 3.8, th.fg_faint)
			} else {
				glyph_chevron_right(list, row.x + 7, row.y + DETAIL_ROW_BODY * 0.5, 3.8, th.fg_faint)
			}
			if row_clicked {
				t.details.open_prompt = open ? -1 : i
				open = !open
			}
		}
		name_col := d.required && !d.exists ? th.red : th.fg_dim
		text_font(list, app.f.mono, 12.0, row.x + 18, row.y + 4, name_col, d.label)
		text_elided(list, app.f.mono, 9.5, row.x + 18, row.y + 23, max(inner_w - 110, 20), th.fg_faint, d.path)
		m := prompt_doc_meta(d)
		mw, _ := measure(app.f.ui, 10.0, m)
		mcol := len(d.error) > 0 || (d.required && !d.exists) ? th.red : th.fg_faint
		text_font(list, app.f.ui, 10.0, row.x + inner_w - mw - 4, row.y + 7, mcol, m)

		yy += DETAIL_ROW_BODY
		if open && clickable && yy < clip_bottom + 50 && yy + 20 > clip_top - 50 {
			code_w := inner_w - 20
			code_h := code_wrapped_height(app.f.mono, 11.5, code_w, d.content)
			code_r := rect(x + DETAIL_PAD + 10, yy, code_w + 20, code_h + 16)
			panel(list, code_r, th.bg_deep, 7, th.border_soft, 1)
			draw_code_wrapped(list, app.f.mono, 11.5, code_r.x + 10, code_r.y + 8, code_w,
				d.content, th.fg_dim, nil)
			yy += code_h + 24
		} else if open && clickable {
			yy += prompt_doc_height(app, d, true, inner_w) - DETAIL_ROW_BODY
		}
		if len(d.error) > 0 && yy < clip_bottom + 50 && yy + 20 > clip_top - 50 {
			eh := plain_wrapped_height(app.f.ui, 10.5, inner_w - 20, d.error)
			text_wrapped(list, app.f.ui, 10.5, x + DETAIL_PAD + 18, yy, inner_w - 20,
				mix(th.fg, th.red, 0.25), d.error)
			yy += eh + 6
		}
	}
	return head_h + card_h + DETAIL_GAP
}

// --- session nuggets -------------------------------------------------------

nugget_meta :: proc(n: harness.Nugget_Info) -> string {
	size := data_size(len(n.content))
	if n.tokens > 0 do return fmt.tprintf("%s · %s tokens", size, format_count(n.tokens))
	return size
}

nugget_height :: proc(app: ^App, n: harness.Nugget_Info, open: bool, inner_w: f32) -> f32 {
	if !open do return DETAIL_ROW_BODY
	if len(n.content) == 0 do return DETAIL_ROW_BODY
	code_w := inner_w - 20
	return DETAIL_ROW_BODY + code_wrapped_height(app.f.mono, 11.5, code_w, n.content) + 24
}

draw_details_nuggets :: proc(
	app: ^App,
	t: ^Conversation_Tab,
	list: ^ImDrawList,
	x, top, w: f32,
	clip_top, clip_bottom: f32,
) -> f32 {
	y := top
	th := app.th
	s := &t.details.snapshot
	meta := fmt.tprintf("%d nugget%s", len(s.nuggets), len(s.nuggets) == 1 ? "" : "s")
	clicked, head_h := detail_section_header(list, app, x, y, w, "NUGGETS",
		meta, cstr("##detailnuggets"), &t.details.show_nuggets)
	if clicked do t.details.show_nuggets = !t.details.show_nuggets
	y += head_h
	if !t.details.show_nuggets do return head_h

	inner_w := w - DETAIL_PAD * 2
	empty_text := "No dynamic nuggets in this session. SYSTEM.md and AGENTS.md are static nuggets shown under prompt documents."
	empty_h: f32 = 0
	if len(s.nuggets) == 0 {
		empty_h = plain_wrapped_height(app.f.ui, 11.5, inner_w, empty_text) + 8
	}
	card_h := DETAIL_PAD * 2 + empty_h
	for n, i in s.nuggets {
		open := t.details.open_nugget == i
		card_h += nugget_height(app, n, open, inner_w)
	}
	detail_card(list, th, x, y, w, card_h)

	yy := y + DETAIL_PAD
	if len(s.nuggets) == 0 {
		text_wrapped(list, app.f.ui, 11.5, x + DETAIL_PAD, yy + 2, inner_w, th.fg_faint, empty_text)
		yy += empty_h
	}
	for n, i in s.nuggets {
		open := t.details.open_nugget == i
		row := rect(x + DETAIL_PAD, yy, inner_w, DETAIL_ROW_BODY)
		idbuf: [32]u8
		row_clicked := hit(id_cstr(idbuf[:], "detailnugget%d", i), row)
		if mi_hit_hovered() do panel(list, row, th.bg_hover, 6)
		if open {
			glyph_chevron_down(list, row.x + 7, row.y + DETAIL_ROW_BODY * 0.5, 3.8, th.fg_faint)
		} else {
			glyph_chevron_right(list, row.x + 7, row.y + DETAIL_ROW_BODY * 0.5, 3.8, th.fg_faint)
		}
		if row_clicked {
			t.details.open_nugget = open ? -1 : i
			open = !open
		}

		name := len(n.name) > 0 ? n.name : "(unnamed nugget)"
		text_font(list, app.f.mono, 12.0, row.x + 18, row.y + 4, th.fg_dim, name)
		detail := n.source
		if len(detail) == 0 do detail = n.nugget_id
		text_elided(list, app.f.ui, 9.5, row.x + 18, row.y + 23,
			max(inner_w - 130, 20), th.fg_faint, detail)
		m := nugget_meta(n)
		mw, _ := measure(app.f.ui, 10.0, m)
		text_font(list, app.f.ui, 10.0, row.x + inner_w - mw - 4, row.y + 7, th.fg_faint, m)

		yy += DETAIL_ROW_BODY
		if !open do continue
		h := nugget_height(app, n, true, inner_w)
		in_view := yy < clip_bottom + 50 && yy + h > clip_top - 50
		if in_view && len(n.content) > 0 {
			code_w := inner_w - 20
			code_h := code_wrapped_height(app.f.mono, 11.5, code_w, n.content)
			code_r := rect(x + DETAIL_PAD + 10, yy, code_w + 20, code_h + 16)
			panel(list, code_r, th.bg_deep, 7, th.border_soft, 1)
			draw_code_wrapped(list, app.f.mono, 11.5, code_r.x + 10, code_r.y + 8, code_w,
				n.content, th.fg_dim, nil)
		}
		yy += h - DETAIL_ROW_BODY
	}
	return head_h + card_h + DETAIL_GAP
}

// --- tools -----------------------------------------------------------------

tool_expanded_height :: proc(app: ^App, t: harness.Tool_Info, inner_w: f32) -> f32 {
	h: f32 = 8
	h += 18 + 18  // Executable label + value
	if len(t.description) > 0 {
		h += plain_wrapped_height(app.f.ui, 11.5, inner_w - 20, t.description) + 10
	}
	h += 18 // parameters label
	code_w := inner_w - 20
	h += code_wrapped_height(app.f.mono, 11.0, code_w, t.parameters) + 16
	return h
}

draw_details_tools :: proc(
	app: ^App,
	t: ^Conversation_Tab,
	list: ^ImDrawList,
	x, top, w: f32,
	clip_top, clip_bottom: f32,
) -> f32 {
	y := top
	th := app.th
	s := &t.details.snapshot
	meta := fmt.tprintf("%d tool%s", len(s.tools), len(s.tools) == 1 ? "" : "s")
	clicked, head_h := detail_section_header(list, app, x, y, w, "TOOLS",
		meta, cstr("##detailtools"), &t.details.show_tools)
	if clicked do t.details.show_tools = !t.details.show_tools
	y += head_h
	if !t.details.show_tools do return head_h

	inner_w := w - DETAIL_PAD * 2
	card_h := DETAIL_PAD * 2
	for tool, i in s.tools {
		card_h += DETAIL_ROW_BODY
		if t.details.open_tool == i do card_h += tool_expanded_height(app, tool, inner_w)
	}
	if len(s.tools) == 0 do card_h += 24
	detail_card(list, th, x, y, w, card_h)

	yy := y + DETAIL_PAD
	if len(s.tools) == 0 {
		text_font(list, app.f.ui, 11.5, x + DETAIL_PAD, yy + 2, th.fg_faint,
			"No TGI tools were discovered for this project.")
		yy += 24
	}
	for tool, i in s.tools {
		open := t.details.open_tool == i
		row := rect(x + DETAIL_PAD, yy, inner_w, DETAIL_ROW_BODY)
		idbuf: [32]u8
		row_clicked := hit(id_cstr(idbuf[:], "detailtool%d", i), row)
		if mi_hit_hovered() do panel(list, row, th.bg_hover, 6)
		if open {
			glyph_chevron_down(list, row.x + 7, row.y + DETAIL_ROW_BODY * 0.5, 3.8, th.fg_faint)
		} else {
			glyph_chevron_right(list, row.x + 7, row.y + DETAIL_ROW_BODY * 0.5, 3.8, th.fg_faint)
		}
		if row_clicked {
			t.details.open_tool = open ? -1 : i
			open = !open
		}
		text_font(list, app.f.mono, 12.0, row.x + 18, row.y + 4, th.fg_dim, tool.name)
		is_mcp := strings.has_prefix(tool.name, "mcp__")
		exec_x := row.x + 18
		if is_mcp {
			text_font(list, app.f.ui, 9.5, exec_x, row.y + 23, th.magenta, "MCP bridge")
			// Place the executable after the measured badge width. The details
			// page uses an extra text scale, so a fixed offset overlaps once the
			// label grows.
			label_w, _ := measure(app.f.ui, 9.5, "MCP bridge")
			exec_x += label_w + 10
		}
		exec := os.base(tool.exec_path)
		text_elided(list, app.f.ui, 9.5, exec_x, row.y + 23,
			max(row.x + inner_w - exec_x - 4, 20), th.fg_faint, exec)
		yy += DETAIL_ROW_BODY

		if !open do continue
		h := tool_expanded_height(app, tool, inner_w)
		in_view := yy < clip_bottom + 50 && yy + h > clip_top - 50
		if in_view {
			text_font(list, app.f.ui, 9.5, row.x + 18, yy + 5, th.fg_faint, "EXECUTABLE")
			text_elided(list, app.f.mono, 10.5, row.x + 18, yy + 18, inner_w - 20, th.fg_dim, tool.exec_path)
			yy2 := yy + 36
			if len(tool.description) > 0 {
				dh := plain_wrapped_height(app.f.ui, 11.5, inner_w - 20, tool.description)
				text_wrapped(list, app.f.ui, 11.5, row.x + 18, yy2, inner_w - 20, th.fg_dim, tool.description)
				yy2 += dh + 10
			}
			text_font(list, app.f.ui, 9.5, row.x + 18, yy2, th.fg_faint, "PARAMETERS")
			yy2 += 16
			code_w := inner_w - 20
			code_h := code_wrapped_height(app.f.mono, 11.0, code_w, tool.parameters)
			code_r := rect(row.x + 10, yy2, code_w + 20, code_h + 16)
			panel(list, code_r, th.bg_deep, 7, th.border_soft, 1)
			draw_code_wrapped(list, app.f.mono, 11.0, code_r.x + 10, code_r.y + 8, code_w,
				tool.parameters, th.fg_dim, nil)
		}
		yy += h
	}
	return head_h + card_h + DETAIL_GAP
}

// --- usage history ---------------------------------------------------------

draw_details_usage :: proc(app: ^App, t: ^Conversation_Tab, list: ^ImDrawList, x, top, w: f32) -> f32 {
	y := top
	th := app.th
	s := &t.details.snapshot
	meta := fmt.tprintf("%d recent · total %s", len(s.recent_usages), format_count(s.total_usage.total_tokens))
	clicked, head_h := detail_section_header(list, app, x, y, w, "MODEL USAGE",
		meta, cstr("##detailusage"), &t.details.show_usage)
	if clicked do t.details.show_usage = !t.details.show_usage
	y += head_h
	if !t.details.show_usage do return head_h

	inner_w := w - DETAIL_PAD * 2
	rows := len(s.recent_usages)
	card_h := DETAIL_PAD * 2 + 24 + f32(rows) * DETAIL_ROW_H + 24
	detail_card(list, th, x, y, w, card_h)

	yy := y + DETAIL_PAD
	text_font(list, app.f.ui, 10.5, x + DETAIL_PAD, yy, th.fg_faint,
		"One row per usage record; newest is last. Context items is the item count at that request.")
	yy += 24
	if rows == 0 {
		text_font(list, app.f.ui, 11.5, x + DETAIL_PAD, yy + 1, th.fg_faint, "No usage records yet.")
		yy += DETAIL_ROW_H
	}
	for u, i in s.recent_usages {
		line := fmt.tprintf("#%-2d  %4d items   in %8s   cached %8s   out %8s   think %7s   total %9s",
			i + 1, u.at_items, format_count(u.input_tokens), format_count(u.cached_tokens),
			format_count(u.output_tokens), format_count(u.reasoning_tokens), format_count(u.total_tokens))
		text_elided(list, app.f.mono, 10.0, x + DETAIL_PAD, yy + 4, inner_w, th.fg_dim, line)
		yy += DETAIL_ROW_H
	}
	rule(list, x + DETAIL_PAD, x + w - DETAIL_PAD, yy + 1, th.border_soft)
	yy += 6
	total := fmt.tprintf("session total   in %s   cached %s   out %s   reasoning %s   total %s",
		format_count(s.total_usage.input_tokens), format_count(s.total_usage.cached_tokens),
		format_count(s.total_usage.output_tokens), format_count(s.total_usage.reasoning_tokens),
		format_count(s.total_usage.total_tokens))
	text_elided(list, app.f.mono, 10.5, x + DETAIL_PAD, yy + 3, inner_w, th.fg_faint, total)
	return head_h + card_h + DETAIL_GAP
}

// --- page ------------------------------------------------------------------

draw_details_page :: proc(app: ^App, p: ^Project, t: ^Conversation_Tab, r: Rect, header_bottom: f32) {
	old_text_scale := ui_text_set_extra_scale(DETAIL_TEXT_SCALE)
	defer ui_text_set_extra_scale(old_text_scale)
	th := app.th
	if !t.details.built || t.details.dirty do details_refresh(p, t, app.now)

	x := r.x + 22
	w := r.w - 44
	top := header_bottom + 14
	bottom := r.y + r.h - 34
	if w < 120 || bottom - top < 60 do return

	mi_set_cursor_screen(x, top)
	if !igBeginChild_Str("##details", ivec2(w, bottom - top), CHILD_NONE, ImGuiWindowFlags(0)) {
		igEndChild()
		return
	}
	list := igGetWindowDrawList()
	origin := mi_cursor_screen()
	cx := origin.x
	cy := origin.y
	content_w := w - 28
	clip_top := top
	clip_bottom := bottom

	// Header row with refresh control. Clicking refresh replaces the snapshot
	// only after the previous one has stopped being referenced by this frame.
	text_font(list, app.f.ui, 11.0, cx, cy + 4, th.fg_faint, "BEHIND THE SCENES")
	age := int(max(app.now - t.details.built_at, 0))
	age_text := age <= 0 ? "snapshot just now" : fmt.tprintf("snapshot %ds ago", age)
	refresh_w: f32 = 62
	refresh_r := rect(cx + content_w - refresh_w, cy - 1, refresh_w, 24)
	sw, _ := measure(app.f.ui, 10.0, age_text)
	text_font(list, app.f.ui, 10.0, refresh_r.x - sw - 8, cy + 4, th.fg_faint, age_text)
	refresh_clicked := button(list, cstr("##detailrefresh"), refresh_r, "Refresh", app.f.ui, 10.5,
		th.fg_dim, th.bg_raised, th.bg_hover, th.bg_active, 6, th.border_soft)
	if refresh_clicked do details_refresh(p, t, app.now)
	cy += 34

	if !t.harness_ready {
		h := DETAIL_PAD * 2 + 30
		detail_card(list, th, cx, cy, content_w, h)
		text_wrapped(list, app.f.ui, 11.5, cx + DETAIL_PAD, cy + DETAIL_PAD, content_w - DETAIL_PAD * 2,
			mix(th.fg, th.yellow, 0.22),
			"The project harness is not running, so live session internals are unavailable. The configuration paths below are still useful when diagnosing why it could not start.")
		cy += h + DETAIL_GAP
	} else if app.preview_active {
		h := DETAIL_PAD * 2 + 28
		detail_card(list, th, cx, cy, content_w, h)
		text_wrapped(list, app.f.ui, 11.5, cx + DETAIL_PAD, cy + DETAIL_PAD, content_w - DETAIL_PAD * 2,
			th.fg_faint,
			"An archive preview is open. These details describe the project's live harness, not the archived transcript.")
		cy += h + DETAIL_GAP
	}

	cy += draw_details_overview(app, t, list, cx, cy, content_w)
	cy += draw_details_last_turn(app, t, list, cx, cy, content_w)
	cy += draw_details_usage(app, t, list, cx, cy, content_w)
	cy += draw_details_prompts(app, t, list, cx, cy, content_w, clip_top, clip_bottom)
	cy += draw_details_nuggets(app, t, list, cx, cy, content_w, clip_top, clip_bottom)
	cy += draw_details_tools(app, t, list, cx, cy, content_w, clip_top, clip_bottom)

	// Place the cursor at the end of the drawn content so ImGui computes the
	// correct scroll extent. A one-pixel dummy item keeps it there.
	mi_set_cursor_screen(origin.x, cy)
	igDummy(ivec2(1, 1))
	igEndChild()
}

// draw_view_strip is the unlabeled switch between the conversation and the
// details page. It sits just below the composer. Orange means the conversation
// is showing (the click takes you to details); blue means details is showing
// (the click takes you back to the conversation).
draw_view_strip :: proc(app: ^App, t: ^Conversation_Tab, r: Rect) {
	if t == nil do return
	th := app.th
	strip_w := max(r.w * 0.20, 56)
	hit_r := rect(r.x + (r.w - strip_w) * 0.5 - 8, r.y + r.h - 17, strip_w + 16, 16)
	clicked := hit(cstr("##viewstrip"), hit_r)
	hovered := mi_hit_hovered()

	col := mix(th.yellow, th.red, 0.32)
	if t.details_open do col = th.accent
	if hovered do col = mix(col, th.fg, 0.18)

	bar_w := hovered ? min(strip_w + 8, r.w - 44) : strip_w
	bar := rect(r.x + (r.w - bar_w) * 0.5, hit_r.y + 5.5, bar_w, 5)
	list := igGetWindowDrawList()
	panel(list, bar, alpha(col, hovered ? 0.85 : 0.55), 2.5)
	if hovered do tooltip(t.details_open ? "conversation" : "details")
	if clicked do details_toggle(t)
}
