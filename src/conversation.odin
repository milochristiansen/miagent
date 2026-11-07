// The conversation pane: a transcript built from harness events, plus the
// composer that submits real prompts.
package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"
import "harness"

View_Kind :: enum {
	Note,
	User,
	Assistant,
	Reasoning,
	Tool,
	Error,
}

View_Status :: enum {
	None,
	Running,
	Ok,
	Failed,
}

View_Message :: struct {
	kind:    View_Kind,
	text:    string,
	name:    string,
	meta:    string,
	call_id: string,
	args:    string,
	stdout:  string,
	stderr:  string,
	status:  View_Status,
	code:    int,
	open:    bool,

	// Streaming strings are appended through builders so a long answer or a
	// chatty tool does not become an O(n^2) copy every delta. The public
	// text/stdout/stderr fields are views into these buffers while a builder
	// is in use.
	text_buf:   strings.Builder,
	stdout_buf: strings.Builder,
	stderr_buf: strings.Builder,

	// Render-height cache. Messages outside the transcript viewport are skipped
	// entirely once their height has been measured once at the current width.
	cached_height: f32,
	cached_width:  f32,
	height_valid:  bool,
}

Conversation_View :: struct {
	messages:        [dynamic]View_Message,
	assistant_index: int,
	reasoning_index: int,
	// True between a user prompt and Turn_End/Action_End. Auto-collapse is
	// deferred until the work item finishes so a block cannot be compacted the
	// moment a tool call settles while the agent is still working.
	turn_running:    bool,

	context_tokens:   int,
	context_limit:    int,
	context_measured: bool,
	message_count:    int,
	tool_count:       int,

	model:        string,
	session_path: string,

	scroll_pending:  int,
	follow:          bool,
	last_scroll_y:      f32,
	layout_width:       f32,
	pending_width:      f32,
	width_stable_frames: int,
	layout_ready:        bool,
	session_changed:     bool,
	// Reflow anchoring: distance from the bottom of the transcript that the
	// viewport should keep after message heights have been recalculated.
	reflow_pending:      bool,
	reflow_from_bottom:  f32,
	sel:                Sel_State,

	// A press that began on a link is held until release so dragging can still
	// select text over a link without opening it. The URL is cloned because the
	// frame-local link record it came from is gone by the next frame.
	link_press_url:    string,
	link_press_x:      f32,
	link_press_y:      f32,
	link_press_active: bool,

	// Image clicks open a viewer on release. The cache entry pointer is stable
	// for the lifetime of the cache, so it is safe to hold across frames.
	image_press_asset:  ^Image_Entry,
	image_press_x:      f32,
	image_press_y:      f32,
	image_press_active: bool,
}

view_init :: proc(v: ^Conversation_View) {
	v.messages = make([dynamic]View_Message, 0, 64)
	v.assistant_index = -1
	v.reasoning_index = -1
	v.scroll_pending = 4
	v.follow = true
	sel_init(&v.sel)
}

// format_count inserts thousands separators for token counts in the header.
format_count :: proc(n: int) -> string {
	if n < 0 do return fmt.tprintf("-%s", format_count(-n))
	s := fmt.tprintf("%d", n)
	if len(s) <= 3 do return s
	b := strings.builder_make(context.temp_allocator)
	head := len(s) % 3
	if head == 0 do head = 3
	strings.write_string(&b, s[:head])
	for i := head; i < len(s); i += 3 {
		strings.write_byte(&b, ',')
		strings.write_string(&b, s[i:i + 3])
	}
	return strings.to_string(b)
}

// strip_ansi removes terminal SGR/CSI sequences from tool output for display.
// The model still receives the raw bytes in the tool envelope.
strip_ansi :: proc(s: string) -> string {
	if !strings.contains(s, "\x1b") do return s
	b := strings.builder_make()
	i := 0
	for i < len(s) {
		if s[i] == 0x1b && i + 1 < len(s) {
			if s[i + 1] == '[' {
				i += 2
				for i < len(s) && !(s[i] >= 0x40 && s[i] <= 0x7e) do i += 1
				if i < len(s) do i += 1
				continue
			}
			i += 2
			continue
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	return strings.to_string(b)
}

view_clear_messages :: proc(v: ^Conversation_View) {
	for &m in v.messages do view_message_destroy(&m)
	clear(&v.messages)
	v.assistant_index = -1
	v.reasoning_index = -1
	v.message_count = 0
	v.tool_count = 0
	v.layout_width = 0
	v.pending_width = 0
	v.width_stable_frames = 0
	v.layout_ready = false
	v.last_scroll_y = 0
	v.reflow_pending = false
	v.reflow_from_bottom = 0
	v.turn_running = false
	delete(v.link_press_url)
	v.link_press_url = ""
	v.link_press_active = false
	v.image_press_asset = nil
	v.image_press_active = false
	sel_clear(&v.sel)
}

// view_arm_reflow_anchor records how far the viewport is from the bottom so
// the next frame can restore that position after message heights change.
view_arm_reflow_anchor :: proc(v: ^Conversation_View, old_max, old_scroll: f32) {
	if v.reflow_pending do return
	distance := max(old_max - old_scroll, 0)
	if v.follow || old_scroll >= old_max - 2 do distance = 0
	v.reflow_from_bottom = distance
	v.reflow_pending = true
	v.scroll_pending = 0
}

view_message_destroy :: proc(m: ^View_Message) {
	if m.text_buf.buf != nil {
		delete(m.text_buf.buf)
	} else {
		delete(m.text)
	}
	if m.stdout_buf.buf != nil {
		delete(m.stdout_buf.buf)
	} else {
		delete(m.stdout)
	}
	if m.stderr_buf.buf != nil {
		delete(m.stderr_buf.buf)
	} else {
		delete(m.stderr)
	}
	delete(m.name)
	delete(m.meta)
	delete(m.call_id)
	delete(m.args)
	m^ = {}
}

view_destroy :: proc(v: ^Conversation_View) {
	for &m in v.messages do view_message_destroy(&m)
	delete(v.messages)
	delete(v.model)
	delete(v.session_path)
	delete(v.link_press_url)
	sel_destroy(&v.sel)
}

view_append :: proc(v: ^Conversation_View, m: View_Message) {
	msg := m
	msg.text = strings.clone(m.text)
	msg.name = strings.clone(m.name)
	msg.meta = strings.clone(m.meta)
	msg.call_id = strings.clone(m.call_id)
	msg.args = strings.clone(m.args)
	msg.stdout = strings.clone(m.stdout)
	msg.stderr = strings.clone(m.stderr)
	append(&v.messages, msg)
	v.message_count = len(v.messages)
	v.scroll_pending = 4
}

view_add_note :: proc(v: ^Conversation_View, text: string) {
	view_append(v, View_Message{kind = .Note, text = text})
}

view_add_error :: proc(v: ^Conversation_View, text: string) {
	view_append(v, View_Message{kind = .Error, text = text})
}

view_add_user :: proc(v: ^Conversation_View, text: string) {
	view_append(v, View_Message{kind = .User, text = text})
	v.follow = true
}

view_add_user_meta :: proc(v: ^Conversation_View, text, meta: string) {
	view_append(v, View_Message{kind = .User, text = text, meta = meta})
	v.follow = true
}

view_append_to :: proc(v: ^Conversation_View, idx: int, text: string, field: int) {
	if idx < 0 || idx >= len(v.messages) || len(text) == 0 do return
	m := &v.messages[idx]
	switch field {
	case 0:
		if m.text_buf.buf == nil {
			m.text_buf = strings.builder_make()
			if len(m.text) > 0 do strings.write_string(&m.text_buf, m.text)
			delete(m.text)
		}
		strings.write_string(&m.text_buf, text)
		m.text = strings.to_string(m.text_buf)
	case 1:
		clean := strip_ansi(text)
		if m.stdout_buf.buf == nil {
			m.stdout_buf = strings.builder_make()
			if len(m.stdout) > 0 do strings.write_string(&m.stdout_buf, m.stdout)
			delete(m.stdout)
		}
		strings.write_string(&m.stdout_buf, clean)
		m.stdout = strings.to_string(m.stdout_buf)
		if clean != text do delete(clean)
	case 2:
		clean := strip_ansi(text)
		if m.stderr_buf.buf == nil {
			m.stderr_buf = strings.builder_make()
			if len(m.stderr) > 0 do strings.write_string(&m.stderr_buf, m.stderr)
			delete(m.stderr)
		}
		strings.write_string(&m.stderr_buf, clean)
		m.stderr = strings.to_string(m.stderr_buf)
		if clean != text do delete(clean)
	}
	m.height_valid = false
	v.scroll_pending = 2
}

view_set_assistant_text :: proc(v: ^Conversation_View, text: string) {
	idx := v.assistant_index
	if idx >= 0 && idx < len(v.messages) && v.messages[idx].kind == .Assistant {
		m := &v.messages[idx]
		if m.text_buf.buf != nil {
			delete(m.text_buf.buf)
			m.text_buf = {}
		}
		delete(m.text)
		if len(text) == 0 {
			view_message_destroy(m)
			ordered_remove(&v.messages, idx)
			v.assistant_index = -1
			if v.reasoning_index > idx do v.reasoning_index -= 1
			v.message_count = len(v.messages)
			v.scroll_pending = 2
			return
		}
		m.text = strings.clone(text)
		m.height_valid = false
		v.message_count = len(v.messages)
		v.scroll_pending = 2
		return
	}
	if len(text) == 0 do return
	view_append(v, View_Message{kind = .Assistant, name = "MiAgent", text = text})
	v.assistant_index = len(v.messages) - 1
}

view_discard_reasoning :: proc(v: ^Conversation_View) {
	idx := v.reasoning_index
	if idx >= 0 && idx < len(v.messages) && v.messages[idx].kind == .Reasoning {
		view_message_destroy(&v.messages[idx])
		ordered_remove(&v.messages, idx)
		if v.assistant_index > idx do v.assistant_index -= 1
		v.message_count = len(v.messages)
		v.scroll_pending = 2
	}
	v.reasoning_index = -1
}

view_find_tool :: proc(v: ^Conversation_View, call_id: string) -> int {
	for i := len(v.messages) - 1; i >= 0; i -= 1 {
		if v.messages[i].kind == .Tool && v.messages[i].call_id == call_id do return i
	}
	return -1
}

TGI_Env :: struct {
	exit_code: int    `json:"exit_code"`,
	stdout:    string `json:"stdout"`,
	stderr:    string `json:"stderr"`,
}

pretty_args :: proc(s: string) -> string {
	trimmed := strings.trim_space(s)
	if len(trimmed) == 0 do return ""
	v, err := json.parse_string(trimmed)
	if err != nil do return strings.clone(trimmed)
	defer json.destroy_value(v)
	data, merr := json.marshal(v, {pretty = true, use_spaces = true, spaces = 4})
	if merr != nil do return strings.clone(trimmed)
	defer delete(data)
	return strings.clone(string(data))
}

view_load_history :: proc(v: ^Conversation_View, items: []harness.StoredItem, session_path: string) {
	v.turn_running = false
	label := len(items) > 0 ? "Session resumed" : "Session started"
	view_add_note(v, fmt.aprintf("%s  ·  %s", label, session_path))
	for it in items {
		switch it.role {
		case "user":
			if len(it.attachments) > 0 {
				meta := fmt.aprintf("%d attachment%s", len(it.attachments), len(it.attachments) == 1 ? "" : "s")
				view_add_user_meta(v, it.content, meta)
				delete(meta)
			} else {
				view_add_user(v, it.content)
			}
		case "assistant":
			view_append(v, View_Message{kind = .Assistant, text = it.content, name = "MiAgent"})
		case "reasoning":
			if r, ok := it.reasoning.?; ok {
				b := strings.builder_make()
				for p in r.content do strings.write_string(&b, p.text)
				if strings.builder_len(b) == 0 {
					for p in r.summary do strings.write_string(&b, p.text)
				}
				if strings.builder_len(b) > 0 {
					view_append(v, View_Message{kind = .Reasoning, text = strings.to_string(b), open = false})
				}
				delete(b.buf)
			}
		case "compaction":
			view_add_note(v, "Compacted session summary")
		case "nugget":
			name := len(it.name) > 0 ? it.name : "nugget"
			view_add_note(v, fmt.aprintf("Nugget · %s", name))
		case "function_call":
			args := pretty_args(it.arguments)
			view_append(v, View_Message{
				kind = .Tool, call_id = it.call_id, name = it.name, args = args, status = .None, open = false,
			})
			delete(args)
			v.tool_count += 1
		case "function_call_output":
			idx := view_find_tool(v, it.call_id)
			if idx < 0 do continue
			env: TGI_Env
			if err := json.unmarshal_string(it.output, &env); err != nil {
				v.messages[idx].stdout = strings.clone(it.output)
				v.messages[idx].status = .Ok
			} else {
				stdout := strip_ansi(env.stdout)
				stderr := strip_ansi(env.stderr)
				v.messages[idx].stdout = strings.clone(stdout)
				v.messages[idx].stderr = strings.clone(stderr)
				if stdout != env.stdout do delete(stdout)
				if stderr != env.stderr do delete(stderr)
				v.messages[idx].code = env.exit_code
				v.messages[idx].status = env.exit_code == 0 ? .Ok : .Failed
			}
			if len(it.attachments) > 0 {
				v.messages[idx].meta = fmt.aprintf("%d attachment%s", len(it.attachments), len(it.attachments) == 1 ? "" : "s")
			}
		}
	}
	v.message_count = len(v.messages)
	v.scroll_pending = 6
}

view_apply_event :: proc(v: ^Conversation_View, ev: ^harness.Event) {
	switch ev.kind {
	case .Note:
		view_add_note(v, ev.text)
	case .Error:
		view_add_error(v, ev.text)
	case .User:
		v.turn_running = true
		view_add_user_meta(v, ev.text, ev.meta)
	case .Assistant_Start:
		view_append(v, View_Message{kind = .Assistant, name = len(ev.name) > 0 ? ev.name : "MiAgent"})
		v.assistant_index = len(v.messages) - 1
	case .Assistant_Delta:
		if v.assistant_index < 0 || v.assistant_index >= len(v.messages) {
			view_append(v, View_Message{kind = .Assistant, name = "MiAgent"})
			v.assistant_index = len(v.messages) - 1
		}
		view_append_to(v, v.assistant_index, ev.text, 0)
	case .Assistant_Replace:
		view_set_assistant_text(v, ev.text)
	case .Assistant_End:
		if v.assistant_index >= 0 && v.assistant_index < len(v.messages) {
			delete(v.messages[v.assistant_index].meta)
			v.messages[v.assistant_index].meta = strings.clone(ev.meta)
		}
		v.assistant_index = -1
	case .Reasoning_Start:
		view_append(v, View_Message{kind = .Reasoning, open = true})
		v.reasoning_index = len(v.messages) - 1
	case .Reasoning_Delta:
		if v.reasoning_index < 0 || v.reasoning_index >= len(v.messages) {
			view_append(v, View_Message{kind = .Reasoning, open = true})
			v.reasoning_index = len(v.messages) - 1
		}
		view_append_to(v, v.reasoning_index, ev.text, 0)
	case .Reasoning_Discard:
		view_discard_reasoning(v)
	case .Reasoning_End:
		// Leave live reasoning expanded: it is part of the turn the user just
		// watched. Historical reasoning from a session starts collapsed.
		v.reasoning_index = -1
	case .Tool_Start:
		view_append(v, View_Message{
			kind = .Tool, call_id = ev.call_id, name = ev.name, args = ev.text,
			status = .Running, open = true,
		})
		v.tool_count += 1
	case .Tool_Output:
		idx := view_find_tool(v, ev.call_id)
		if idx >= 0 {
			view_append_to(v, idx, ev.text, ev.stream == .Stdout ? 1 : 2)
		}
	case .Tool_End:
		idx := view_find_tool(v, ev.call_id)
		if idx >= 0 {
			v.messages[idx].code = ev.code
			v.messages[idx].status = ev.code == 0 ? .Ok : .Failed
			delete(v.messages[idx].meta)
			v.messages[idx].meta = strings.clone(ev.meta)
		}
	case .Context:
		v.context_tokens = ev.tokens
		v.context_limit = ev.limit
		v.context_measured = ev.measured
	case .Turn_End, .Action_End:
		v.assistant_index = -1
		v.reasoning_index = -1
		v.turn_running = false
	case .Session_Changed:
		// Handled by conversation_poll, which can reload immediately.
	}
}

// view_copy_all renders the transcript's source text directly from the view
// model. It is used by Ctrl+C when there is no selection, so copying the whole
// conversation does not depend on which messages happened to be on screen.
view_copy_all :: proc(v: ^Conversation_View) -> string {
	b := strings.builder_make()
	for m, i in v.messages {
		if i > 0 do strings.write_byte(&b, '\n')
		switch m.kind {
		case .Note, .Error, .User, .Assistant, .Reasoning:
			strings.write_string(&b, m.text)
		case .Tool:
			strings.write_string(&b, m.name)
			if len(m.args) > 0 {
				strings.write_byte(&b, '\n')
				strings.write_string(&b, m.args)
			}
			if len(m.stdout) > 0 {
				strings.write_byte(&b, '\n')
				strings.write_string(&b, m.stdout)
			}
			if len(m.stderr) > 0 {
				strings.write_byte(&b, '\n')
				strings.write_string(&b, m.stderr)
			}
		}
	}
	return strings.to_string(b)
}

conversation_reload :: proc(v: ^Conversation_View, h: ^harness.Harness) {
	view_clear_messages(v)
	delete(v.session_path)
	v.session_path = harness.harness_session_path(h)
	history := harness.harness_history(h)
	view_load_history(v, history, v.session_path)
	harness.harness_free_items(history)
	ctx := harness.harness_context(h)
	v.context_tokens = ctx.tokens
	v.context_limit = ctx.limit
	v.context_measured = ctx.measured
	v.follow = true
	v.scroll_pending = 6
	v.session_changed = true
}

// conversation_poll drains a harness event queue into the view. It reports
// whether the batch contained an agent turn end, so the caller can ring the
// audio alert alongside the project card's running/idle status change. A
// slash command or other Action_End must not ring it.
conversation_poll :: proc(v: ^Conversation_View, h: ^harness.Harness) -> bool {
	agent_turn_ended := false
	for {
		ev: harness.Event
		if !harness.harness_poll_event(h, &ev) do break
		if ev.kind == .Session_Changed {
			// The worker has already finished mutating the session before it
			// emits this event. Reloading now lets the command's notes, which
			// follow, land at the bottom of the new transcript.
			conversation_reload(v, h)
		} else {
			view_apply_event(v, &ev)
		}
		if ev.kind == .Turn_End do agent_turn_ended = true
		harness.event_destroy(&ev)
	}
	return agent_turn_ended
}

draw_message :: proc(
	app: ^App,
	list: ^ImDrawList,
	m: ^View_Message,
	index: int,
	x, y, w: f32,
	sel: ^Sel_State,
	active: bool = false,
	links: ^[dynamic]Md_Link_Rect = nil,
	images: ^Md_Image_Context = nil,
) -> f32 {
	th := app.th
	rec_local: Sel_Recorder
	rec: ^Sel_Recorder
	if sel != nil {
		rec_local = Sel_Recorder{items = &sel.items, msg_index = index}
		rec = &rec_local
	}
	switch m.kind {
	case .Note:
		nw, _ := measure(app.f.ui, 11.5, m.text)
		nx := nw < w ? x + (w - nw) * 0.5 : x
		return draw_plain_wrapped(list, app.f.ui, 11.5, nx, y + 2, min(nw, w), th.fg_faint, m.text, rec) + 14

	case .Error:
		hh := plain_wrapped_height(app.f.ui, 13.0, w - 38, m.text)
		card := rect(x, y, w, hh + 22)
		panel(list, card, over(th.bg, alpha(th.red, 0.10)), 8, alpha(th.red, 0.28), 1)
		dot(list, x + 13, y + 14, 3, th.red)
		draw_plain_wrapped(list, app.f.ui, 13.0, x + 24, y + 9, w - 38, mix(th.fg, th.red, 0.18), m.text, rec)
		return card.h + 16

	case .User:
		max_bubble := w * 0.74
		tw, _ := measure(app.f.ui, 15.0, m.text)
		bubble_w := min(tw + 28, max_bubble)
		tht := plain_wrapped_height(app.f.ui, 15.0, bubble_w - 28, m.text)
		meta_h: f32 = len(m.meta) > 0 ? 16 : 0
		bx := x + w - bubble_w
		br := rect(bx, y, bubble_w, tht + 22 + meta_h)
		panel(list, br, over(th.bg, alpha(th.accent, 0.16)), 10, alpha(th.accent, 0.22), 1)
		if meta_h > 0 {
			text_font(list, app.f.ui, 10.5, br.x + 14, br.y + 7, th.fg_faint, m.meta)
		}
		draw_plain_wrapped(list, app.f.ui, 15.0, br.x + 14, br.y + 11 + meta_h, bubble_w - 28, th.fg, m.text, rec)
		return br.h + 18

	case .Assistant:
		dot(list, x + 4, y + 6, 3.2, th.accent)
		text_font(list, app.f.ui, 12.0, x + 13, y, th.accent, len(m.name) > 0 ? m.name : "MiAgent")
		lw, _ := measure(app.f.ui, 12.0, len(m.name) > 0 ? m.name : "MiAgent")
		if len(m.meta) > 0 {
			text_font(list, app.f.ui, 11.5, x + 13 + lw + 8, y + 0.5, th.fg_faint, m.meta)
		}
		body_w := w * 0.90
		bh := draw_markdown(list, app.f.ui, app.f.mono, 15.0, x + 13, y + 20, body_w, th, m.text, mix(th.fg, th.bg, 0.04), rec, links, images)
		return 20 + bh + 18

	case .Reasoning:
		header := rect(x, y, w, 24)
		idbuf: [64]u8
		clicked := hit(id_cstr(idbuf[:], "reason%d", index), header)
		if mi_hit_hovered() do panel(list, header, th.bg_hover, 6)
		if clicked && !active do m.open = !m.open
		if m.open {
			glyph_chevron_down(list, x + 8, y + 11, 4.0, th.fg_faint)
		} else {
			glyph_chevron_right(list, x + 8, y + 11, 4.0, th.fg_faint)
		}
		text_font(list, app.f.ui, 11.5, x + 18, y + 5, th.fg_faint, "Thinking")
		if !m.open do return 34
		body_y := y + 26
		bh := draw_markdown(list, app.f.ui, app.f.mono, 13.0, x + 4, body_y, w - 10, th, m.text, mix(th.fg, th.bg, 0.38), rec, links, images)
		vrule(list, x + 1, body_y - 4, body_y + bh, th.border_soft)
		return 26 + bh + 12

	case .Tool:
		header_h: f32 = 30
		idbuf: [64]u8
		clicked := hit(id_cstr(idbuf[:], "toolhead%d", index), rect(x, y, w, header_h))
		if clicked && !active do m.open = !m.open

		args_h: f32 = 0
		stdout_h: f32 = 0
		stderr_h: f32 = 0
		if m.open {
			if len(m.args) > 0 {
				args_h = code_wrapped_height(app.f.mono, 12.0, w - 24, m.args) + 14
			}
			if len(m.stdout) > 0 {
				stdout_h = code_wrapped_height(app.f.mono, 12.0, w - 24, m.stdout) + 12
			}
			if len(m.stderr) > 0 {
				stderr_h = code_wrapped_height(app.f.mono, 12.0, w - 24, m.stderr) + 12
			}
		}
		body_h := args_h + stdout_h + stderr_h
		card_h := header_h + body_h
		card := rect(x, y, w, card_h)
		panel(list, card, th.bg_panel, 9, th.border_soft, 1)
		if mi_hit_hovered() do panel(list, rect(x + 1, y + 1, w - 2, header_h - 1), th.bg_hover, 8)

		status_col := th.green
		switch m.status {
		case .Ok: status_col = th.green
		case .Running: status_col = th.yellow
		case .Failed: status_col = th.red
		case .None: status_col = th.fg_faint
		}

		if m.open {
			glyph_chevron_down(list, x + 9, y + header_h * 0.5, 4.0, th.fg_faint)
		} else {
			glyph_chevron_right(list, x + 9, y + header_h * 0.5, 4.0, th.fg_faint)
		}
		// Fixed status slot so the tool name does not shift when a running
		// tool settles into success/failure.
		if m.status == .Running {
			phase := app.now * 3.0
			for i in 0 ..< 3 {
				a := 0.25 + 0.75 * (0.5 + 0.5 * math.sin(phase + f32(i) * 1.1))
				dot(list, x + 24 + f32(i) * 6, y + header_h * 0.5, 2.2, alpha(status_col, a))
			}
		} else {
			dot(list, x + 27, y + header_h * 0.5, 3, status_col)
		}
		text_font(list, app.f.mono, 13.0, x + 44, y + 8, th.fg_dim, m.name)
		meta := m.meta
		if m.status == .Failed && len(meta) == 0 do meta = fmt.tprintf("exit %d", m.code)
		if len(meta) > 0 {
			mw, _ := measure(app.f.ui, 11.5, meta)
			text_font(list, app.f.ui, 11.5, card.x + card.w - mw - 14, y + 9, th.fg_faint, meta)
		}

		if !m.open do return card.h + 16

		cy := y + header_h
		if args_h > 0 {
			draw_code_wrapped(list, app.f.mono, 12.0, x + 14, cy + 5, w - 24, m.args, mix(th.fg, th.bg, 0.35), rec)
			cy += args_h
		}
		if stdout_h > 0 {
			rule(list, x + 1, x + w - 1, cy, th.border_soft)
			draw_code_wrapped(list, app.f.mono, 12.0, x + 14, cy + 6, w - 24, m.stdout, mix(th.fg, th.bg, 0.22), rec)
			cy += stdout_h
		}
		if stderr_h > 0 {
			draw_code_wrapped(list, app.f.mono, 12.0, x + 14, cy + 6, w - 24, m.stderr, mix(th.fg, th.red, 0.25), rec)
		}
		return card.h + 16
	}
	return 0
}


ATTACHMENT_CHIP_H :: f32(22)
ATTACHMENT_CHIP_GAP :: f32(6)
ATTACHMENT_CHIP_MAX_W :: f32(460)

attachment_chip_width :: proc(font: ^ImFont, path: string, max_w: f32) -> f32 {
	tw, _ := measure(font, 11.5, path)
	return min(tw + 34, max_w)
}

attachment_chips_height :: proc(font: ^ImFont, width: f32, paths: []string) -> f32 {
	if len(paths) == 0 || width <= 0 do return 0
	max_w := min(width, ATTACHMENT_CHIP_MAX_W)
	rows := 1
	cx: f32 = 0
	for path in paths {
		w := attachment_chip_width(font, path, max_w)
		if cx > 0 && cx + w > width {
			rows += 1
			cx = 0
		}
		cx += w + ATTACHMENT_CHIP_GAP
	}
	return f32(rows) * ATTACHMENT_CHIP_H + f32(rows - 1) * ATTACHMENT_CHIP_GAP + 12
}

draw_attachment_chips :: proc(app: ^App, list: ^ImDrawList, tab: ^Conversation_Tab, x, y, width: f32) {
	th := app.th
	max_w := min(width, ATTACHMENT_CHIP_MAX_W)
	cx, cy := x, y + 6
	for path, i in tab.attachments {
		chip_w := attachment_chip_width(app.f.ui, path, max_w)
		if cx > x && cx + chip_w > x + width {
			cx = x
			cy += ATTACHMENT_CHIP_H + ATTACHMENT_CHIP_GAP
		}
		chip := rect(cx, cy, chip_w, ATTACHMENT_CHIP_H)
		panel(list, chip, mix(th.bg_raised, th.fg, 0.035), 5, th.border_soft, 1)
		text_elided(list, app.f.ui, 11.5, chip.x + 8, chip.y + (ATTACHMENT_CHIP_H - ui_text_px(11.5)) * 0.5 - 1,
			max(chip.w - 30, 4), th.fg_dim, path)

		idbuf: [64]u8
		close_r := rect(chip.x + chip.w - 20, chip.y, 20, ATTACHMENT_CHIP_H)
		remove_clicked := hit(id_cstr(idbuf[:], "attachmentremove%d", i), close_r)
		remove_hovered := mi_hit_hovered()
		if remove_hovered do panel(list, rect(close_r.x + 3, close_r.y + 3, 14, 16), th.bg_hover, 4)
		glyph_close(list, close_r.x + 10, close_r.y + ATTACHMENT_CHIP_H * 0.5, 3.1,
			remove_hovered ? th.fg : th.fg_faint, 1.3)
		if rect_contains(chip, app.mouse.x, app.mouse.y) && !remove_hovered do tooltip(path)
		if remove_clicked {
			conversation_tab_remove_attachment(tab, i)
			return
		}
		cx += chip_w + ATTACHMENT_CHIP_GAP
	}
}

draw_conversation :: proc(app: ^App) {
	th := app.th
	project := app_active_project(app)
	center_w := app.width - PROJECTS_PANEL_W - RAIL_W - drawer_region_width(app)
	if center_w < 220 do center_w = 220
	r := rect(PROJECTS_PANEL_W, 0, center_w, app.height)
	if !mi_begin_panel("##conversation", r.x, r.y, r.w, r.h, true) {
		igEnd()
		return
	}
	list := igGetWindowDrawList()
	panel(list, r, th.bg, 0)

	tabs_h: f32 = 0
	if project != nil {
		draw_session_tabs(app, project, r)
		rule(list, r.x, r.x + r.w, r.y + SESSION_TAB_BAR_H - 1, th.border_soft)
		tabs_h = SESSION_TAB_BAR_H
	}
	// A tab click or the add button can change the active tab during this
	// frame, so resolve the tab after drawing the tab bar.
	tab := project_active_tab(project)
	view := app_active_view(app)
	active_harness := app_active_harness(app)
	no_project := project == nil && !app.preview_active
	live := !app.preview_active && tab != nil && tab.harness_ready
	details_mode := tab != nil && tab.details_open

	header_y := r.y + tabs_h
	header_bottom := header_y + 94
	head_h: f32 = 94
	title := app_active_title(app)
	model_owned := active_harness != nil ? harness.harness_model(active_harness) : ""
	defer delete(model_owned)
	model := model_owned
	if len(model) == 0 do model = "no model"
	if app.preview_active do model = "preview"

	editing_name := project != nil && tab != nil && project.session_name_editing && !app.preview_active
	if editing_name {
		field := rect(r.x + 22, header_y + 9, r.w - 44, 32)
		panel(list, field, th.bg_raised, 7, th.border_soft, 1)
		igPushStyleColor_Vec4(COL_FRAME_BG, ImVec4{0, 0, 0, 0})
		igPushStyleColor_Vec4(COL_FRAME_BG_HOVERED, ImVec4{0, 0, 0, 0})
		igPushStyleColor_Vec4(COL_FRAME_BG_ACTIVE, ImVec4{0, 0, 0, 0})
		mi_set_cursor_screen(field.x + 8, field.y + 5)
		if project.session_name_focus {
			igSetKeyboardFocusHere(0)
			project.session_name_focus = false
		}
		igSetNextItemWidth(field.w - 16)
		igInputText("##sessionname", &project.session_name_input[0], uint(len(project.session_name_input)), 0, nil, nil)
		active := igIsItemActive()
		igPopStyleColor(3)
		if active {
			project.session_name_was_active = true
			if igIsKeyPressed_Bool(KEY_ENTER, false) do app_session_name_commit(project)
			if igIsKeyPressed_Bool(KEY_ESCAPE, false) do app_session_name_cancel(project)
		} else if project.session_name_editing && project.session_name_was_active {
			// Clicking elsewhere commits the rename instead of leaving an
			// orphaned field that can no longer be focused.
			app_session_name_commit(project)
		}
	} else {
		title_w := r.w - 52
		show_edit := project != nil && tab != nil && !app.preview_active
		if show_edit do title_w -= 30
		text_elided(list, app.f.ui, 19.5, r.x + 26, header_y + 15, title_w, th.fg, title)
		if show_edit {
			edit_r := rect(r.x + r.w - 26 - 24, header_y + 11, 24, 24)
			if icon_button(list, cstr("##sessionedit"), edit_r, "", app.f.ui, 11.0, th.fg_faint, th.bg_hover, 6) {
				app_session_name_begin(project)
			}
			glyph_pencil(list, edit_r.x + 12, edit_r.y + 12, 5.0, th.fg_faint)
			if rect_contains(edit_r, app.mouse.x, app.mouse.y) do tooltip("Rename session")
		}
	}

	path := pwd_display(view.session_path, app.home)
	ctx_info := active_harness != nil ? harness.harness_context(active_harness) : harness.Context_Info{}
	item_count := app.preview_active ? view.message_count : ctx_info.items
	sub := fmt.tprintf("%s  ·  %s  ·  %d items  ·  %d tools", model, path, item_count, view.tool_count)
	if no_project do sub = "Add a project with + in the projects pane"
	if details_mode do sub = fmt.tprintf("details  ·  %s", sub)
	text_elided(list, app.f.ui, 12.0, r.x + 26, header_y + 42, r.w - 52, th.fg_faint, sub)

	ctx_tokens := view.context_tokens
	ctx_limit := view.context_limit
	ctx_measured := view.context_measured
	ctx_text := ""
	if !no_project && !app.preview_active {
		if live && active_harness != nil {
			ctx_tokens = ctx_info.tokens
			ctx_limit = ctx_info.limit
			ctx_measured = ctx_info.measured
		}
		ctx_text = "context  not configured"
		if ctx_limit > 0 {
			ctx_text = fmt.tprintf("context  %s / %s tokens", format_count(ctx_tokens), format_count(ctx_limit))
			if !ctx_measured do ctx_text = fmt.tprintf("%s  (estimated)", ctx_text)
		} else if ctx_tokens > 0 {
			ctx_text = fmt.tprintf("context  %s tokens  (capacity unknown)", format_count(ctx_tokens))
		}
	} else if app.preview_active {
		ctx_text = "context  not measured for archive preview"
	}
	if len(ctx_text) > 0 {
		text_elided(list, app.f.ui, 11.5, r.x + 26, header_y + 63, r.w - 52, th.fg_faint, ctx_text)
	}

	rule(list, r.x, r.x + r.w, header_bottom, th.border_soft)

	if details_mode {
		draw_details_page(app, project, tab, r, header_bottom)
		draw_view_strip(app, tab, r)
		igEnd()
		return
	}

	chip_width := r.w - 44 - 28
	chips_h := live && tab != nil ? attachment_chips_height(app.f.ui, chip_width, tab.attachments[:]) : 0
	composer_h: f32 = 118 + chips_h
	composer := rect(r.x + 22, r.y + r.h - 20 - composer_h, r.w - 44, composer_h)

	tx := r.x + 22
	ty := header_bottom + 14
	tw := r.w - 44
	tth := composer.y - 14 - ty
	if tth < 80 do tth = 80

	mi_set_cursor_screen(tx, ty)
	if igBeginChild_Str("##transcript", ivec2(tw, tth), CHILD_NONE, ImGuiWindowFlags(0)) {
		child_list := igGetWindowDrawList()
		transcript_rect := rect(tx, ty, tw, tth)
		hover_transcript := !app.image_viewer.open && rect_contains(transcript_rect, app.mouse.x, app.mouse.y)
		if hover_transcript {
			wheel := mi_io_wheel()
			if wheel > 0 do view.follow = false
			if wheel < 0 && igGetScrollY() >= igGetScrollMaxY() - 24 do view.follow = true
		}
		// The previous frame may have invalidated every message height because
		// the pane width changed. ImGui has now recomputed its content extent;
		// restore the same distance from the bottom of the transcript.
		if view.reflow_pending {
			max_y := igGetScrollMaxY()
			target := max(max_y - view.reflow_from_bottom, 0)
			igSetScrollY_Float(target)
			view.follow = view.reflow_from_bottom <= 0.5
			view.last_scroll_y = target
			view.reflow_pending = false
			view.scroll_pending = 0
		}
		if view.scroll_pending > 0 {
			if view.follow do igSetScrollY_Float(igGetScrollMaxY())
			view.scroll_pending -= 1
		}
		// Keep a following view pinned when content or viewport height changes
		// without a width reflow (for example, a vertical window resize).
		if view.follow && igGetScrollY() < igGetScrollMaxY() - 1 {
			igSetScrollY_Float(igGetScrollMaxY())
		}
		scroll_y := igGetScrollY()
		if math.abs(scroll_y - view.last_scroll_y) > 0.5 {
			view.last_scroll_y = scroll_y
			if view.sel.dragging || sel_has_selection(&view.sel) do sel_clear(&view.sel)
		}
		origin := mi_cursor_screen()
		sx := origin.x
		sy := origin.y
		content_w := tw - 16 - 12

		// Width changes come from the drawer animation. Keep using the old
		// cached heights while the width is moving, then invalidate once it has
		// settled instead of reflowing every message on every animation frame.
		if view.layout_width == 0 {
			view.layout_width = content_w
			view.pending_width = content_w
		} else if math.abs(content_w - view.layout_width) > 0.5 {
			if math.abs(content_w - view.pending_width) <= 0.5 {
				view.width_stable_frames += 1
			} else {
				view.pending_width = content_w
				view.width_stable_frames = 0
			}
			if view.width_stable_frames >= 2 {
				view_arm_reflow_anchor(view, igGetScrollMaxY(), igGetScrollY())
				for &m in view.messages do m.height_valid = false
				view.layout_width = content_w
				view.width_stable_frames = 0
				view.layout_ready = false
				sel_clear(&view.sel)
			}
		}

		links := make([dynamic]Md_Link_Rect, 0, 32)
		defer delete(links)
		image_rects := make([dynamic]Md_Image_Rect, 0, 8)
		defer delete(image_rects)
		image_base := project != nil ? project.path : app.cwd
		image_ctx := Md_Image_Context{cache = &app.image_cache, base_dir = image_base, rects = &image_rects}
		sel_interest := view.layout_ready &&
			(hover_transcript || view.sel.dragging || sel_has_selection(&view.sel))
		sel_begin_frame(&view.sel)
		y := sy
		for &m, i in view.messages {
			h := m.cached_height
			cached := m.height_valid
			block := m.kind == .Reasoning || m.kind == .Tool
			active := (m.kind == .Reasoning && i == view.reasoning_index) ||
				(m.kind == .Tool && m.status == .Running)

			// Active blocks stay open.
			if active && !m.open {
				m.open = true
				m.height_valid = false
				cached = false
			}
			// Blocks stay expanded for the whole turn. Auto-collapse only runs
			// after Turn_End/Action_End, so a tool call settling cannot immediately take
			// itself and the rest of the live turn with it. Even then a block
			// must have scrolled fully off the top while the live tail is
			// being followed.
			if !active && block && m.open && cached && view.follow && !view.turn_running {
				above := y + h < ty - 32
				if above {
					m.open = false
					m.height_valid = false
					cached = false
					// A collapse above the viewport shrinks the content the user
					// is already scrolled past; anchor the tail so it does not jump.
					view_arm_reflow_anchor(view, igGetScrollMaxY(), igGetScrollY())
				}
			}

			if cached && (y + h < ty - 32 || y > ty + tth + 32) {
				y += h
				continue
			}
			was_open := m.open
			h = draw_message(app, child_list, &m, i, sx + 2, y, content_w, sel_interest ? &view.sel : nil, active, &links, &image_ctx)
			// Expanding a block is an explicit exception to bottom anchoring:
			// keep its header where the pointer clicked it while the body grows
			// downward, so stop following the live bottom.
			if m.open && !was_open {
				view.follow = false
				view.scroll_pending = 0
				view.reflow_pending = false
			}
			m.cached_height = h
			m.cached_width = content_w
			m.height_valid = true
			y += h
		}
		view.layout_ready = true
		sel_draw_highlights(child_list, &view.sel, th)
		if live && active_harness != nil && harness.harness_is_busy(active_harness) {
			phase := app.now * 3.0
			for i in 0 ..< 3 {
				a := 0.25 + 0.75 * (0.5 + 0.5 * math.sin(phase + f32(i) * 1.1))
				dot(child_list, sx + 8 + f32(i) * 9, y + 7, 2.4, alpha(th.accent, a))
			}
			text_font(child_list, app.f.ui, 12.5, sx + 38, y, th.fg_faint, "MiAgent is working...")
			y += 30
		}
		mi_set_cursor_screen(sx, y)
		igDummy(ivec2(1, 1))

		// Links and images are drawn manually, so hit-test the recorded
		// rectangles after the transcript has been laid out.
		hovered_link := -1
		hovered_image := -1
		if hover_transcript {
			for link, li in links {
				if rect_contains(link.rect, app.mouse.x, app.mouse.y) {
					hovered_link = li
					break
				}
			}
			for image, ii in image_rects {
				if rect_contains(image.rect, app.mouse.x, app.mouse.y) {
					hovered_image = ii
					break
				}
			}
		}

		if igIsMouseClicked_Bool(0, false) {
			delete(view.link_press_url)
			view.link_press_url = ""
			view.link_press_active = false
			view.image_press_asset = nil
			view.image_press_active = false
			if hovered_image >= 0 {
				view.image_press_asset = image_rects[hovered_image].asset
				view.image_press_x = app.mouse.x
				view.image_press_y = app.mouse.y
				view.image_press_active = true
			} else if hovered_link >= 0 {
				view.link_press_url = strings.clone(links[hovered_link].url)
				view.link_press_x = app.mouse.x
				view.link_press_y = app.mouse.y
				view.link_press_active = true
			}
		}

		// A press that started on an image never anchors a text selection;
		// the image is a self-contained click target.
		suppress_selection := view.image_press_active || app.image_viewer.open
		if !suppress_selection {
			sel_process_mouse(&view.sel, transcript_rect, app.mouse)
		} else {
			view.sel.mouse_was_down = igIsMouseDown_Nil(0)
		}

		if igIsMouseReleased_Nil(0) {
			if view.link_press_active {
				moved_x := math.abs(app.mouse.x - view.link_press_x)
				moved_y := math.abs(app.mouse.y - view.link_press_y)
				if hovered_link >= 0 && moved_x <= 4 && moved_y <= 4 &&
				   links[hovered_link].url == view.link_press_url {
					mi_open_uri(zstr(links[hovered_link].url))
				}
				delete(view.link_press_url)
				view.link_press_url = ""
				view.link_press_active = false
			}
			if view.image_press_active {
				moved_x := math.abs(app.mouse.x - view.image_press_x)
				moved_y := math.abs(app.mouse.y - view.image_press_y)
				if hovered_image >= 0 && moved_x <= 4 && moved_y <= 4 &&
				   image_rects[hovered_image].asset == view.image_press_asset {
					image_viewer_open(&app.image_viewer, view.image_press_asset)
				}
				view.image_press_asset = nil
				view.image_press_active = false
			}
		}

		if hover_transcript && sel_hovered(&view.sel, app.mouse.x, app.mouse.y) {
			mi_io_set_mouse_cursor(i32(CURSOR_TEXT))
		}
		if hovered_link >= 0 {
			mi_io_set_mouse_cursor(i32(CURSOR_HAND))
			if len(links[hovered_link].tip) > 0 do tooltip(links[hovered_link].tip)
		}
		if hovered_image >= 0 {
			mi_io_set_mouse_cursor(i32(CURSOR_HAND))
			if len(image_rects[hovered_image].alt) > 0 do tooltip(image_rects[hovered_image].alt)
		}
		if mi_io_key_ctrl() != 0 && mi_io_key_shift() == 0 && mi_io_want_text_input() == 0 &&
		   igIsKeyPressed_Bool(KEY_C, false) && (sel_has_selection(&view.sel) || hover_transcript) {
			// Consume Ctrl+C so the focused shell does not also receive it as
			// SIGINT. Drawers are drawn after the conversation and would
			// otherwise forward the same keypress.
			app.shortcut_fired = true
			copied := ""
			if sel_has_selection(&view.sel) {
				copied = sel_copy(&view.sel)
			} else {
				copied = view_copy_all(view)
			}
			if len(copied) > 0 {
				mi_set_clipboard(zstr(copied))
				delete(copied)
			}
		}
	}
	igEndChild()

	// Composer.
	panel(list, composer, th.bg_panel, 12, th.border, 1)
	if live && tab != nil && chips_h > 0 {
		draw_attachment_chips(app, list, tab, composer.x + 14, composer.y + 6, composer.w - 28)
	}
	if !live {
		preview := app.preview_active
		dot(list, composer.x + 24, composer.y + composer.h * 0.5 - 10, 3.6, th.fg_faint)
		title_text := preview ? "Read-only preview" : no_project ? "No project selected" : "Project unavailable"
		detail := preview ? (len(app.preview_subtitle) > 0 ? app.preview_subtitle : app.preview.session_path) : no_project ? "Add a project with + in the projects pane" : "the project harness could not be started"
		hint := preview ? "Load this archive to continue it" : no_project ? "Nothing to send yet" : "Choose another project"

		// A preview can be resumed directly from here. The button queues the
		// same operation as `/load <archive>`; the preview closes immediately so
		// the live transcript and the command's notes are visible while it runs.
		show_load := preview && active_harness != nil && len(app.preview.session_path) > 0
		btn_w: f32 = 128
		btn_h: f32 = 32
		btn_r := rect(composer.x + composer.w - 16 - btn_w, composer.y + 18, btn_w, btn_h)
		text_w := composer.w - 52
		if show_load do text_w = btn_r.x - (composer.x + 36) - 14
		text_elided(list, app.f.ui, 15.0, composer.x + 36, composer.y + composer.h * 0.5 - 24, text_w, th.fg_dim, title_text)
		text_elided(list, app.f.ui, 12.0, composer.x + 36, composer.y + composer.h * 0.5 + 2, text_w, th.fg_faint, detail)
		text_elided(list, app.f.ui, 11.0, composer.x + 36, composer.y + composer.h - 28, composer.w - 52, th.fg_faint, hint)
		if show_load {
			load_bg := mix(th.bg_raised, th.accent, 0.14)
			if button(list, cstr("##loadpreview"), btn_r, "Load session", app.f.ui, 12.0, th.fg, load_bg,
				mix(load_bg, th.accent, 0.24), mix(load_bg, th.accent, 0.38), 8, alpha(th.accent, 0.42)) {
				app_load_previewed_archive(app)
			}
			if rect_contains(btn_r, app.mouse.x, app.mouse.y) {
				tooltip("Archive the current session and load this one (like /load)")
			}
		}
		draw_view_strip(app, tab, r)
		igEnd()
		return
	}
	input_r := rect(composer.x + 14, composer.y + 10 + chips_h, composer.w - 28, 52)
	igPushStyleColor_Vec4(COL_FRAME_BG, ImVec4{0, 0, 0, 0})
	igPushStyleColor_Vec4(COL_FRAME_BG_HOVERED, ImVec4{0, 0, 0, 0})
	igPushStyleColor_Vec4(COL_FRAME_BG_ACTIVE, ImVec4{0, 0, 0, 0})
	mi_set_cursor_screen(input_r.x, input_r.y)
	if tab.composer_refocus {
		igSetKeyboardFocusHere(0)
		tab.composer_refocus = false
	}
	igSetNextItemWidth(input_r.w)
	igInputTextMultiline(
		"##composer",
		&tab.composer[0],
		uint(len(tab.composer)),
		ivec2(input_r.w, input_r.h),
		INPUT_TEXT_WORD_WRAP,
		nil,
		nil,
	)
	active := igIsItemActive()
	igPopStyleColor(3)
	if tab.composer[0] == 0 {
		text_font(list, app.f.ui, 15.0,
			input_r.x + mi_style_frame_padding_x(),
			input_r.y + mi_style_frame_padding_y(),
			th.fg_faint, "Message MiAgent...")
	}

	submit :: proc(app: ^App) {
		t := app_active_tab(app)
		if t == nil || !t.harness_ready do return
		s := string(cstring(&t.composer[0]))
		trimmed := strings.trim_space(s)
		if len(trimmed) == 0 do return
		if harness.harness_submit_files(&t.harness, trimmed, t.attachments[:]) {
			t.composer[0] = 0
			t.composer_refocus = true
			conversation_tab_clear_attachments(t)
			// The input widget keeps its own text buffer while active; dropping
			// the active id makes it re-read the cleared buffer next frame.
			igClearActiveID()
			t.view.scroll_pending = 4
		}
	}

	entered := igIsKeyPressed_Bool(KEY_ENTER, false) && mi_io_key_shift() == 0
	if active && entered do submit(app)
	if !app.image_viewer.open && igIsKeyPressed_Bool(KEY_ESCAPE, false) && active_harness != nil && harness.harness_is_busy(active_harness) {
		harness.harness_cancel(active_harness)
	}

	row_y := composer.y + composer.h - 44
	btn_h: f32 = 30
	send_w: f32 = 58
	send_r := rect(composer.x + composer.w - 14 - send_w, row_y - 4, send_w, btn_h)
	has_text := tab.composer[0] != 0
	running := active_harness != nil && harness.harness_is_busy(active_harness)
	send_bg := has_text ? th.accent : th.bg_raised
	send_fg := has_text ? th.bg_deep : th.fg_faint
	if button(list, cstr("##send"), send_r, "Send", app.f.ui, 12.0, send_fg, send_bg,
		mix(send_bg, th.fg, 0.08), mix(send_bg, th.fg, 0.16), 8) {
		submit(app)
	}

	stop_r := rect(send_r.x - 38, send_r.y, 30, 30)
	if running {
		// Stop remains a compact button beside Send while a turn is live.
		if button(list, cstr("##stop"), stop_r, "", app.f.ui, 12.0, th.fg, th.bg_raised,
			mix(th.bg_raised, th.red, 0.18), mix(th.bg_raised, th.red, 0.30), 8) {
			if active_harness != nil do harness.harness_cancel(active_harness)
		}
		panel(list, rect(stop_r.x + 10, stop_r.y + 10, 10, 10), th.red, 2)
	}

	attach_r := rect(composer.x + 14, row_y + 4, 30, 30)
	attach_clicked := icon_button(list, cstr("##attachfiles"), attach_r, "", app.f.ui, 12.0, th.fg_faint, th.bg_hover, 6)
	attach_hovered := mi_hit_hovered()
	glyph_paperclip(list, attach_r.x + 15, attach_r.y + 15, 5.2, attach_hovered ? th.fg : th.fg_faint)
	if attach_hovered {
		mi_io_set_mouse_cursor(i32(CURSOR_HAND))
		tooltip(app.attachment_picker.running ? "Choosing files..." : "Attach files")
	}
	if attach_clicked && !app.attachment_picker.running {
		if !attachment_picker_start(app, FILES_PICKER_TITLE) {
			view_add_error(&tab.view, "could not open the system file chooser")
		}
	}

	hint := "Enter to send  ·  Shift+Enter for a new line  ·  Esc to stop"
	hint_w, _ := measure(app.f.ui, 11.0, hint)
	right_limit := running ? stop_r.x : send_r.x
	if composer.x + 52 + hint_w < right_limit - 12 {
		text_font(list, app.f.ui, 11.0, composer.x + 52, row_y + 7, th.fg_faint, hint)
	}

	draw_view_strip(app, tab, r)
	igEnd()
}
