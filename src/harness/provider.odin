// OpenAI Responses API client: build the same request shape the MiAgent CLI
// sends, consume its SSE stream, and reconstruct the items and usage the CLI
// persists.
package harness

import "core:encoding/json"
import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"

MI_HTTP_Write_Fn :: #type proc "c" (userdata: rawptr, data: cstring, size: uint) -> uint

foreign import harness_http "../../build/libharness.a"

@(default_calling_convention = "c")
foreign harness_http {
	mi_http_post_stream :: proc(
		url: cstring,
		api_key: cstring,
		body: cstring,
		body_len: uint,
		accept: cstring,
		fn: MI_HTTP_Write_Fn,
		userdata: rawptr,
		errbuf: [^]u8,
		errcap: uint,
		cancel: ^i32,
	) -> i32 ---
	mi_gzip_compress :: proc(data: rawptr, len: uint, out: ^^u8, outlen: ^uint) -> i32 ---
	mi_gzip_decompress :: proc(data: rawptr, len: uint, out: ^^u8, outlen: ^uint) -> i32 ---
	mi_free :: proc(p: rawptr) ---
	mi_http_get_buffered :: proc(
		url: cstring,
		api_key: cstring,
		out: [^]u8,
		outcap: uint,
		outlen: ^uint,
		errbuf: [^]u8,
		errcap: uint,
	) -> i32 ---
}

DEFAULT_BASE_URL :: "https://api.openai.com/v1"
MODEL_IDLE_TIMEOUT_SECONDS :: 120
MAX_MODEL_RETRIES :: 5
MAX_MODEL_CONTINUATIONS :: 10

COMPACTION_PREFIX :: "The conversation history before this point was compacted into the following summary:\n\n<summary>\n"
COMPACTION_SUFFIX :: "\n</summary>"
NUGGET_PREFIX :: "<miagent-nugget name=\"%s\" source=\"%s\">\n"
NUGGET_SUFFIX :: "\n</miagent-nugget>"

cstring_copy :: proc(s: string) -> cstring {
	b := make([]u8, len(s) + 1, context.temp_allocator)
	copy(b, s)
	b[len(s)] = 0
	return cstring(raw_data(b))
}

responses_url :: proc(base_url: string) -> string {
	base := strings.trim_space(base_url)
	if len(base) == 0 do base = DEFAULT_BASE_URL
	for len(base) > 0 && base[len(base) - 1] == '/' do base = base[:len(base) - 1]
	return fmt.aprintf("%s/responses", base)
}

// --- JSON helpers ----------------------------------------------------------

jget :: proc(o: json.Object, key: string) -> json.Value {
	if v, ok := o[key]; ok do return v
	return nil
}

jstr :: proc(v: json.Value) -> string {
	#partial switch x in v {
	case json.String: return string(x)
	case: return ""
	}
}

jint :: proc(v: json.Value) -> int {
	#partial switch x in v {
	case json.Integer: return int(x)
	case json.Float: return int(x)
	case: return 0
	}
}

jobj :: proc(v: json.Value) -> (json.Object, bool) {
	#partial switch x in v {
	case json.Object: return x, true
	case: return nil, false
	}
}

jarr :: proc(v: json.Value) -> (json.Array, bool) {
	#partial switch x in v {
	case json.Array: return x, true
	case: return nil, false
	}
}

obj_set :: proc(o: ^json.Object, key: string, value: json.Value) {
	// json.destroy_value frees object keys; they must be owned by the object,
	// not pointers into string literals.
	o[strings.clone(key)] = value
}

str_value :: proc(s: string) -> json.Value {
	return json.String(strings.clone(s))
}

// --- request construction --------------------------------------------------

Reasoning_Config :: struct {
	effort: string `json:"effort,omitempty"`,
}

Tools_Item :: struct {
	kind:        string     `json:"type"`,
	name:        string     `json:"name"`,
	description: string     `json:"description,omitempty"`,
	parameters:  json.Value `json:"parameters"`,
}

Request :: struct {
	model:            string                 `json:"model"`,
	instructions:     string                 `json:"instructions,omitempty"`,
	input:            []json.Value           `json:"input"`,
	tools:            []json.Value           `json:"tools,omitempty"`,
	reasoning:        Maybe(Reasoning_Config) `json:"reasoning,omitempty"`,
	max_output_tokens: Maybe(int)             `json:"max_output_tokens,omitempty"`,
	stream:           bool                   `json:"stream,omitempty"`,
}

text_part :: proc(kind, text: string) -> json.Value {
	o := make(json.Object)
	obj_set(&o, "type", str_value(kind))
	obj_set(&o, "text", str_value(text))
	return o
}

message_input :: proc(role, kind, text: string) -> json.Value {
	o := make(json.Object)
	obj_set(&o, "type", str_value("message"))
	obj_set(&o, "role", str_value(role))
	parts := make(json.Array, 0, 1)
	append(&parts, text_part(kind, text))
	obj_set(&o, "content", parts)
	return o
}

reasoning_input :: proc(r: ^Reasoning) -> json.Value {
	parts := make(json.Array, 0, len(r.content) + len(r.summary))
	summary := make(json.Array, 0, len(r.summary))
	for p in r.summary {
		o := make(json.Object)
		obj_set(&o, "type", str_value(p.kind))
		obj_set(&o, "text", str_value(p.text))
		append(&summary, o)
	}
	if len(r.content) > 0 {
		for p in r.content {
			o := make(json.Object)
			obj_set(&o, "type", str_value(p.kind))
			obj_set(&o, "text", str_value(p.text))
			append(&parts, o)
		}
	} else {
		for p in r.summary {
			o := make(json.Object)
			obj_set(&o, "type", str_value("reasoning_text"))
			obj_set(&o, "text", str_value(p.text))
			append(&parts, o)
		}
	}
	// A representation with no text is rejected by some providers; omit it.
	if len(parts) == 0 do return nil

	o := make(json.Object)
	obj_set(&o, "type", str_value("reasoning"))
	if len(r.id) > 0 do obj_set(&o, "id", str_value(r.id))
	obj_set(&o, "summary", summary)
	obj_set(&o, "content", parts)
	if len(r.encrypted_content) > 0 && len(r.content) > 0 {
		obj_set(&o, "encrypted_content", str_value(r.encrypted_content))
	}
	return o
}

function_call_input :: proc(it: StoredItem) -> json.Value {
	o := make(json.Object)
	obj_set(&o, "type", str_value("function_call"))
	obj_set(&o, "call_id", str_value(it.call_id))
	obj_set(&o, "name", str_value(it.name))
	obj_set(&o, "arguments", str_value(it.arguments))
	obj_set(&o, "status", str_value("completed"))
	return o
}

// append_attachment_parts emits the same attachment representation for tool
// results and user prompts: images become input_image, text files become an
// input_text part, and other files become input_file data URLs.
append_attachment_parts :: proc(parts: ^json.Array, attachments: []Attachment) {
	for att in attachments {
		switch att.kind {
		case "image":
			p := make(json.Object)
			obj_set(&p, "type", str_value("input_image"))
			obj_set(&p, "detail", str_value("high"))
			obj_set(&p, "image_url", str_value(att.url))
			append(parts, p)
		case "text":
			file_text := fmt.aprintf("[Attached file: %s]\n%s", att.name, att.text)
			append(parts, text_part("input_text", file_text))
			delete(file_text)
		case "binary":
			p := make(json.Object)
			obj_set(&p, "type", str_value("input_file"))
			obj_set(&p, "filename", str_value(att.name))
			obj_set(&p, "file_data", str_value(att.url))
			append(parts, p)
		}
	}
}

function_output_input :: proc(it: StoredItem) -> json.Value {
	o := make(json.Object)
	obj_set(&o, "type", str_value("function_call_output"))
	obj_set(&o, "call_id", str_value(it.call_id))
	if len(it.attachments) == 0 {
		obj_set(&o, "output", str_value(it.output))
		return o
	}
	parts := make(json.Array, 0, len(it.attachments) + 1)
	if len(it.output) > 0 {
		append(&parts, text_part("input_text", it.output))
	}
	append_attachment_parts(&parts, it.attachments)
	obj_set(&o, "output", parts)
	return o
}

// user_input keeps the prompt first and places the files immediately after it
// in the same message content array.
user_input :: proc(it: StoredItem) -> json.Value {
	o := make(json.Object)
	obj_set(&o, "type", str_value("message"))
	obj_set(&o, "role", str_value("user"))
	parts := make(json.Array, 0, len(it.attachments) + 1)
	if len(it.content) > 0 do append(&parts, text_part("input_text", it.content))
	append_attachment_parts(&parts, it.attachments)
	obj_set(&o, "content", parts)
	return o
}

nugget_input :: proc(it: StoredItem) -> json.Value {
	wrapped := fmt.aprintf(NUGGET_PREFIX, it.name, it.source)
	text := fmt.aprintf("%s%s%s", wrapped, it.content, NUGGET_SUFFIX)
	delete(wrapped)
	defer delete(text)
	return message_input("user", "input_text", text)
}

item_to_input :: proc(it: StoredItem) -> json.Value {
	switch it.role {
	case "user":
		return user_input(it)
	case "compaction":
		return message_input("user", "input_text", fmt.aprintf("%s%s%s", COMPACTION_PREFIX, it.content, COMPACTION_SUFFIX))
	case "assistant":
		return message_input("assistant", "output_text", it.content)
	case "reasoning":
		if r, ok := it.reasoning.?; ok do return reasoning_input(&r)
		return nil
	case "function_call":
		return function_call_input(it)
	case "function_call_output":
		return function_output_input(it)
	case "nugget":
		return nugget_input(it)
	}
	return nil
}

build_input :: proc(items: []StoredItem) -> []json.Value {
	out := make([dynamic]json.Value, 0, len(items))
	for it in items {
		v := item_to_input(it)
		if v != nil do append(&out, v)
	}
	return out[:]
}

tool_value :: proc(t: Tool) -> json.Value {
	o := make(json.Object)
	obj_set(&o, "type", str_value("function"))
	obj_set(&o, "name", str_value(t.name))
	if len(t.description) > 0 do obj_set(&o, "description", str_value(t.description))
	obj_set(&o, "parameters", json.clone_value(t.parameters))
	return o
}

build_tools :: proc(tools: []Tool) -> []json.Value {
	out := make([]json.Value, len(tools))
	for t, i in tools do out[i] = tool_value(t)
	return out
}

// --- SSE -------------------------------------------------------------------

Stream_Event :: struct {
	kind:          string     `json:"type"`,
	item_id:       string     `json:"item_id,omitempty"`,
	delta:         string     `json:"delta,omitempty"`,
	text:          string     `json:"text,omitempty"`,
	message:       string     `json:"message,omitempty"`,
	content_index: int        `json:"content_index,omitempty"`,
	summary_index: int        `json:"summary_index,omitempty"`,
	item:          json.Value `json:"item,omitempty"`,
	response:      json.Value `json:"response,omitempty"`,
	error:         json.Value `json:"error,omitempty"`,
}

Turn_Accum :: struct {
	assistant: strings.Builder,
	got_assistant_delta: bool,

	reasoning_items: [dynamic]StoredItem,
	reasoning_index: map[string]int,

	fn_items: [dynamic]StoredItem,
	fn_index: map[string]int,

	completed: bool,
	final_items: []StoredItem,
	usage: Usage,
	got_usage: bool,
	progress: bool,
	err: string,
}

turn_accum_init :: proc() -> Turn_Accum {
	a := Turn_Accum{}
	a.assistant = strings.builder_make()
	a.reasoning_items = make([dynamic]StoredItem, 0, 4)
	a.reasoning_index = make(map[string]int)
	a.fn_items = make([dynamic]StoredItem, 0, 4)
	a.fn_index = make(map[string]int)
	return a
}

turn_accum_destroy :: proc(a: ^Turn_Accum) {
	delete(a.assistant.buf)
	for &it in a.reasoning_items do item_destroy(&it)
	delete(a.reasoning_items)
	for key in a.reasoning_index do delete(key)
	delete(a.reasoning_index)
	for &it in a.fn_items do item_destroy(&it)
	delete(a.fn_items)
	for key in a.fn_index do delete(key)
	delete(a.fn_index)
	for &it in a.final_items do item_destroy(&it)
	delete(a.final_items)
	delete(a.err)
}

add_reasoning_delta :: proc(a: ^Turn_Accum, id: string, summary: bool, part_index: int, delta: string) {
	if len(id) == 0 || len(delta) == 0 do return
	idx, exists := a.reasoning_index[id]
	if !exists {
		idx = len(a.reasoning_items)
		a.reasoning_index[strings.clone(id)] = idx
		r := Reasoning{}
		r.id = strings.clone(id)
		append(&a.reasoning_items, StoredItem{role = "reasoning", reasoning = r})
	}
	r, _ := a.reasoning_items[idx].reasoning.?
	if summary {
		if part_index >= len(r.summary) {
			old := r.summary
			grown := make([]ReasoningPart, part_index + 1)
			copy(grown, old)
			for i in len(old) ..= part_index do grown[i] = ReasoningPart{kind = "summary_text", text = ""}
			delete(old)
			r.summary = grown
		}
		r.summary[part_index].text = strings.concatenate({r.summary[part_index].text, delta})
	} else {
		if part_index >= len(r.content) {
			old := r.content
			grown := make([]ReasoningPart, part_index + 1)
			copy(grown, old)
			for i in len(old) ..= part_index do grown[i] = ReasoningPart{kind = "reasoning_text", text = ""}
			delete(old)
			r.content = grown
		}
		r.content[part_index].text = strings.concatenate({r.content[part_index].text, delta})
	}
	a.reasoning_items[idx].reasoning = r
}

add_fn :: proc(a: ^Turn_Accum, id: string) -> int {
	if idx, exists := a.fn_index[id]; exists do return idx
	a.fn_index[strings.clone(id)] = len(a.fn_items)
	append(&a.fn_items, StoredItem{role = "function_call"})
	return len(a.fn_items) - 1
}

streamed_items :: proc(a: ^Turn_Accum) -> []StoredItem {
	out := make([dynamic]StoredItem, 0, len(a.reasoning_items) + 1 + len(a.fn_items))
	for it in a.reasoning_items do append(&out, clone_item(it))
	answer := strings.to_string(a.assistant)
	if len(answer) > 0 {
		append(&out, StoredItem{role = "assistant", content = strings.clone(answer)})
	}
	for call in a.fn_items {
		if len(call.name) > 0 && len(call.call_id) > 0 {
			clone := call
			clone.name = strings.clone(call.name)
			clone.call_id = strings.clone(call.call_id)
			clone.arguments = strings.clone(call.arguments)
			append(&out, clone)
		}
	}
	return out[:]
}

read_reasoning_parts :: proc(ro: json.Object, key: string, out: ^[]ReasoningPart) {
	val, ok := jarr(jget(ro, key))
	if !ok do return
	parts := make([dynamic]ReasoningPart, 0, len(val))
	for p in val {
		po, pok := jobj(p)
		if !pok do continue
		append(&parts, ReasoningPart{
			kind = strings.clone(jstr(jget(po, "type"))),
			text = strings.clone(jstr(jget(po, "text"))),
		})
	}
	out^ = parts[:]
}

reasoning_destroy :: proc(r: ^Reasoning) {
	delete(r.id)
	delete(r.encrypted_content)
	for &p in r.summary do delete(p.text)
	for &p in r.content do delete(p.text)
	delete(r.summary)
	delete(r.content)
	r^ = {}
}

// parse_output_items converts response.output into stored items, matching the
// CLI's responseItems.
parse_output_items :: proc(response: json.Value) -> []StoredItem {
	ro, ok := jobj(response)
	if !ok do return nil
	output_value := jget(ro, "output")
	arr, ok2 := jarr(output_value)
	if !ok2 do return nil

	items := make([dynamic]StoredItem, 0, len(arr))
	for raw in arr {
		item_obj, is_obj := jobj(raw)
		if !is_obj do continue
		kind := jstr(jget(item_obj, "type"))
		switch kind {
		case "message":
			if jstr(jget(item_obj, "role")) != "assistant" do continue
			content, cok := jarr(jget(item_obj, "content"))
			if !cok do continue
			b := strings.builder_make()
			for part in content {
				po, pok := jobj(part)
				if !pok do continue
				if jstr(jget(po, "type")) == "output_text" {
					strings.write_string(&b, jstr(jget(po, "text")))
				}
			}
			text := strings.clone(strings.to_string(b))
			delete(b.buf)
			if len(text) > 0 do append(&items, StoredItem{role = "assistant", content = text})
		case "reasoning":
			r := Reasoning{}
			r.id = strings.clone(jstr(jget(item_obj, "id")))
			r.encrypted_content = strings.clone(jstr(jget(item_obj, "encrypted_content")))
			read_reasoning_parts(item_obj, "summary", &r.summary)
			read_reasoning_parts(item_obj, "content", &r.content)
			has_text := false
			for p in r.summary do if len(strings.trim_space(p.text)) > 0 do has_text = true
			for p in r.content do if len(strings.trim_space(p.text)) > 0 do has_text = true
			if !has_text && len(r.encrypted_content) == 0 {
				reasoning_destroy(&r)
				continue
			}
			append(&items, StoredItem{role = "reasoning", reasoning = r})
		case "function_call":
			call_id := jstr(jget(item_obj, "call_id"))
			name := jstr(jget(item_obj, "name"))
			if len(call_id) == 0 || len(name) == 0 do continue
			append(&items, StoredItem{
				role = "function_call",
				call_id = strings.clone(call_id),
				name = strings.clone(name),
				arguments = strings.clone(jstr(jget(item_obj, "arguments"))),
			})
		}
	}
	return items[:]
}

parse_usage :: proc(response: json.Value) -> (Usage, bool) {
	ro, ok := jobj(response)
	if !ok do return Usage{}, false
	uo, uok := jobj(jget(ro, "usage"))
	if !uok do return Usage{}, false
	u := Usage{
		input_tokens = jint(jget(uo, "input_tokens")),
		output_tokens = jint(jget(uo, "output_tokens")),
		total_tokens = jint(jget(uo, "total_tokens")),
	}
	if d, dok := jobj(jget(uo, "input_tokens_details")); dok {
		u.cached_tokens = jint(jget(d, "cached_tokens"))
	}
	if d, dok := jobj(jget(uo, "output_tokens_details")); dok {
		u.reasoning_tokens = jint(jget(d, "reasoning_tokens"))
	}
	return u, true
}

SSE_State :: struct {
	h:       ^Harness,
	turn:    ^Turn_Accum,
	pending: strings.Builder,
	data:    strings.Builder,
	aborted: bool,
}

sse_write_cb :: proc "c" (userdata: rawptr, data: cstring, size: uint) -> uint {
	context = runtime.default_context()
	state := cast(^SSE_State)userdata
	if h_cancelled(state.h) {
		state.aborted = true
		return 0
	}
	ptr := cast([^]u8)data
	chunk := string(ptr[:size])
	strings.write_string(&state.pending, chunk)

	text := strings.to_string(state.pending)
	start := 0
	for i in 0 ..< len(text) {
		if text[i] != '\n' do continue
		line := text[start:i]
		if len(line) > 0 && line[len(line) - 1] == '\r' do line = line[:len(line) - 1]
		start = i + 1
		if len(line) == 0 {
			if strings.builder_len(state.data) > 0 {
				payload := strings.to_string(state.data)
				handle_stream_event(state, payload)
				strings.builder_reset(&state.data)
			}
			continue
		}
		if strings.has_prefix(line, "data:") {
			value := line[5:]
			if len(value) > 0 && value[0] == ' ' do value = value[1:]
			if strings.builder_len(state.data) > 0 do strings.write_byte(&state.data, '\n')
			strings.write_string(&state.data, value)
		}
	}
	if start > 0 {
		remaining := strings.clone(text[start:])
		strings.builder_reset(&state.pending)
		strings.write_string(&state.pending, remaining)
		delete(remaining)
	}
	return uint(size)
}

stream_event_destroy :: proc(ev: ^Stream_Event) {
	delete(ev.kind)
	delete(ev.item_id)
	delete(ev.delta)
	delete(ev.text)
	delete(ev.message)
	if ev.item != nil do json.destroy_value(ev.item)
	if ev.response != nil do json.destroy_value(ev.response)
	if ev.error != nil do json.destroy_value(ev.error)
	ev^ = {}
}

handle_stream_event :: proc(state: ^SSE_State, payload: string) {
	if len(strings.trim_space(payload)) == 0 do return
	ev: Stream_Event
	if err := json.unmarshal_string(payload, &ev); err != nil {
		if len(state.turn.err) == 0 do state.turn.err = fmt.aprintf("bad stream event: %v", err)
		return
	}
	defer stream_event_destroy(&ev)
	a := state.turn
	h := state.h

	switch ev.kind {
	case "response.reasoning_text.delta":
		if len(ev.delta) > 0 {
			a.progress = true
			add_reasoning_delta(a, ev.item_id, false, ev.content_index, ev.delta)
			h_emit_reasoning_delta(h, ev.delta)
		}
	case "response.reasoning_summary_text.delta":
		if len(ev.delta) > 0 {
			a.progress = true
			add_reasoning_delta(a, ev.item_id, true, ev.summary_index, ev.delta)
			h_emit_reasoning_delta(h, ev.delta)
		}
	case "response.output_text.delta":
		if len(ev.delta) > 0 {
			a.progress = true
			a.got_assistant_delta = true
			strings.write_string(&a.assistant, ev.delta)
			h_emit_assistant_delta(h, ev.delta)
		}
	case "response.function_call_arguments.delta":
		if len(ev.item_id) > 0 {
			a.progress = true
			idx := add_fn(a, ev.item_id)
			a.fn_items[idx].arguments = strings.concatenate({a.fn_items[idx].arguments, ev.delta})
		}
	case "response.output_item.added":
		if item, ok := jobj(ev.item); ok {
			kind := jstr(jget(item, "type"))
			if kind == "function_call" {
				a.progress = true
				id := jstr(jget(item, "id"))
				idx := add_fn(a, id)
				name := jstr(jget(item, "name"))
				call_id := jstr(jget(item, "call_id"))
				if len(name) > 0 do a.fn_items[idx].name = strings.clone(name)
				if len(call_id) > 0 do a.fn_items[idx].call_id = strings.clone(call_id)
			}
		}
	case "response.output_item.done":
		// The completed item may carry fields the deltas did not, notably
		// reasoning IDs and encrypted content. It is also authoritative for a
		// function call's call_id.
		if item, ok := jobobj_item(ev.item); ok {
			kind := jstr(jget(item, "type"))
			if kind == "function_call" {
				id := jstr(jget(item, "id"))
				if len(id) > 0 {
					idx := add_fn(a, id)
					if n := jstr(jget(item, "name")); len(n) > 0 do a.fn_items[idx].name = strings.clone(n)
					if c := jstr(jget(item, "call_id")); len(c) > 0 do a.fn_items[idx].call_id = strings.clone(c)
					if len(a.fn_items[idx].arguments) == 0 {
						a.fn_items[idx].arguments = strings.clone(jstr(jget(item, "arguments")))
					}
				}
			}
		}
	case "response.completed":
		a.completed = true
		a.final_items = parse_output_items(ev.response)
		if u, ok := parse_usage(ev.response); ok {
			a.usage = u
			a.got_usage = true
		}
		// Some compatible servers stream no text deltas but put the answer in
		// the completed response's output. Emit it now so the UI is not empty.
		if !a.got_assistant_delta {
			if text := assistant_text_of(a.final_items); len(text) > 0 {
				strings.write_string(&a.assistant, text)
				h_emit_assistant_delta(h, text)
				a.progress = true
			}
		}
	case "response.failed":
		msg := "response failed"
		if ro, ok := jobj(ev.response); ok {
			if eo, eok := jobj(jget(ro, "error")); eok {
				if m := jstr(jget(eo, "message")); len(m) > 0 do msg = m
			}
		}
		a.err = fmt.aprintf("%s", msg)
	case "response.incomplete":
		msg := "response incomplete"
		if ro, ok := jobj(ev.response); ok {
			if eo, eok := jobj(jget(ro, "error")); eok {
				if m := jstr(jget(eo, "message")); len(m) > 0 do msg = fmt.aprintf("response incomplete: %s", m)
			}
		}
		if len(a.err) == 0 do a.err = strings.clone(msg)
	case "error":
		msg := ev.message
		if len(msg) == 0 {
			if eo, ok := jobj(ev.error); ok do msg = jstr(jget(eo, "message"))
		}
		if len(msg) == 0 do msg = "unknown stream error"
		a.err = fmt.aprintf("%s", msg)
	}
}

jobobj_item :: proc(v: json.Value) -> (json.Object, bool) {
	return jobj(v)
}

assistant_text_of :: proc(items: []StoredItem) -> string {
	b := strings.builder_make()
	defer delete(b.buf)
	for it in items {
		if it.role == "assistant" do strings.write_string(&b, it.content)
	}
	return strings.clone(strings.to_string(b))
}

// marshal_request encodes a request body with a deterministic key order.
//
// Requests are assembled from json.Value objects, and a json.Object is a map
// whose iteration order varies between allocations. Marshal it as-is and every
// turn re-emits the same tools and items with a different key order. Providers
// cache on an exact token prefix, and the Responses API flattens the tool
// schemas ahead of the conversation, so that alone makes every request a cache
// miss from its first token. Sorted maps also match what the Go CLI produces:
// its tool definitions go through map[string]any, which encoding/json sorts.
marshal_request :: proc(request: Request) -> ([]byte, json.Marshal_Error) {
	return json.marshal(request, {sort_maps_by_key = true})
}

// stream_model_turn performs one streaming request. On success it returns the
// response items and usage. On failure it returns the partial items plus
// whether any model output arrived.
stream_model_turn :: proc(h: ^Harness, input: []json.Value, tools: []json.Value) -> (Turn_Accum, string) {
	a := turn_accum_init()
	request := Request{
		model = h.config.model,
		instructions = h.config.instructions,
		input = input,
		tools = tools,
		stream = true,
	}
	if len(h.config.reasoning_effort) > 0 &&
	   h.config.reasoning_effort != "none" &&
	   h.config.reasoning_effort != "off" &&
	   h.config.reasoning_effort != "default" {
		request.reasoning = Reasoning_Config{effort = h.config.reasoning_effort}
	}
	body, jerr := marshal_request(request)
	if jerr != nil {
		a.err = fmt.aprintf("encoding request: %v", jerr)
		return a, a.err
	}
	defer delete(body)

	endpoint := responses_url(h.config.base_url)
	defer delete(endpoint)
	turn_info_request(h, request.model, endpoint, len(input), len(tools), len(body), len(h.config.instructions))

	state := SSE_State{h = h, turn = &a}
	state.pending = strings.builder_make()
	state.data = strings.builder_make()
	defer {
		delete(state.pending.buf)
		delete(state.data.buf)
	}

	errbuf: [2048]u8
	status := mi_http_post_stream(
		cstring_copy(endpoint),
		cstring_copy(h.config.api_key),
		cstring(raw_data(body)),
		uint(len(body)),
		cstring_copy("text/event-stream"),
		sse_write_cb,
		&state,
		&errbuf[0],
		uint(len(errbuf)),
		&h.cancel,
	)
	if status == -2 || state.aborted || h_cancelled(h) {
		a.err = strings.clone("interrupted")
		return a, a.err
	}
	if status != 0 {
		msg := strings.trim_space(string(cstring(&errbuf[0])))
		if len(msg) == 0 do msg = "request failed"
		a.err = strings.clone(msg)
		return a, a.err
	}
	if len(a.err) > 0 do return a, a.err
	if !a.completed {
		a.err = strings.clone("stream ended before response.completed")
		return a, a.err
	}
	return a, ""
}

// take_turn_items transfers ownership of the turn's items to the caller. The
// accumulator is left empty so its destructor cannot free them twice.
take_turn_items :: proc(a: ^Turn_Accum) -> []StoredItem {
	if len(a.final_items) > 0 {
		items := a.final_items
		a.final_items = nil
		for &it in a.reasoning_items do item_destroy(&it)
		clear(&a.reasoning_items)
		for &it in a.fn_items do item_destroy(&it)
		clear(&a.fn_items)
		strings.builder_reset(&a.assistant)
		return items
	}

	items := streamed_items(a)
	// streamed_items copied the reasoning and call items by value; move their
	// contents out of the accumulator and leave the accumulator empty.
	for &it in a.reasoning_items do item_destroy(&it)
	clear(&a.reasoning_items)
	for &it in a.fn_items do item_destroy(&it)
	clear(&a.fn_items)
	strings.builder_reset(&a.assistant)
	return items
}

turn_has_function_call :: proc(items: []StoredItem) -> bool {
	for it in items do if it.role == "function_call" do return true
	return false
}


// --- non-streaming summarization ------------------------------------------

HTTP_Collect_State :: struct {
	body: strings.Builder,
}

http_collect_cb :: proc "c" (userdata: rawptr, data: cstring, size: uint) -> uint {
	context = runtime.default_context()
	state := cast(^HTTP_Collect_State)userdata
	ptr := cast([^]u8)data
	strings.write_string(&state.body, string(ptr[:size]))
	return uint(size)
}

response_output_text :: proc(response: json.Value) -> string {
	ro, ok := jobj(response)
	if !ok do return ""
	if top := jstr(jget(ro, "output_text")); len(top) > 0 do return strings.clone(top)
	output, ok2 := jarr(jget(ro, "output"))
	if !ok2 do return ""
	b := strings.builder_make()
	defer delete(b.buf)
	for raw in output {
		item, iok := jobj(raw)
		if !iok do continue
		if jstr(jget(item, "type")) != "message" do continue
		if jstr(jget(item, "role")) != "assistant" do continue
		content, cok := jarr(jget(item, "content"))
		if !cok do continue
		for part in content {
			po, pok := jobj(part)
			if !pok do continue
			if jstr(jget(po, "type")) == "output_text" do strings.write_string(&b, jstr(jget(po, "text")))
		}
	}
	return strings.clone(strings.to_string(b))
}

// summarize is the non-streaming model call /new, /desc, and /compact use.
// It sends the CLI's summarization request shape: one user message, the given
// system prompt, max_output_tokens, and reasoning disabled.
summarize :: proc(h: ^Harness, system, prompt: string, max_tokens: int) -> (string, Usage, string) {
	input := make([]json.Value, 1)
	input[0] = message_input("user", "input_text", prompt)
	defer {
		json.destroy_value(input[0])
		delete(input)
	}
	request := Request{
		model = h.config.model,
		instructions = system,
		input = input,
		reasoning = Reasoning_Config{effort = "none"},
		max_output_tokens = max_tokens,
		stream = false,
	}
	body, jerr := marshal_request(request)
	if jerr != nil do return "", Usage{}, fmt.aprintf("encoding summarization request: %v", jerr)
	defer delete(body)

	endpoint := responses_url(h.config.base_url)
	defer delete(endpoint)
	state := HTTP_Collect_State{body = strings.builder_make()}
	defer delete(state.body.buf)
	errbuf: [2048]u8
	status := mi_http_post_stream(
		cstring_copy(endpoint),
		cstring_copy(h.config.api_key),
		cstring(raw_data(body)),
		uint(len(body)),
		cstring_copy("application/json"),
		http_collect_cb,
		&state,
		&errbuf[0],
		uint(len(errbuf)),
		&h.cancel,
	)
	if status == -2 || h_cancelled(h) do return "", Usage{}, "interrupted"
	if status != 0 {
		msg := strings.trim_space(string(cstring(&errbuf[0])))
		if len(msg) == 0 do msg = "summarization request failed"
		return "", Usage{}, strings.clone(msg)
	}

	payload := strings.to_string(state.body)
	if len(strings.trim_space(payload)) == 0 do return "", Usage{}, "summarization returned an empty response"
	value, perr := json.parse_string(payload)
	if perr != nil do return "", Usage{}, fmt.aprintf("bad summarization response: %v", perr)
	defer json.destroy_value(value)

	ro, ok := jobj(value)
	if !ok do return "", Usage{}, "bad summarization response"
	if status_text := jstr(jget(ro, "status")); len(status_text) > 0 && status_text != "completed" {
		msg := status_text
		if eo, eok := jobj(jget(ro, "error")); eok {
			if m := jstr(jget(eo, "message")); len(m) > 0 do msg = m
		}
		return "", Usage{}, fmt.aprintf("summarization response %s", msg)
	}
	extracted := response_output_text(value)
	text := strings.trim_space(extracted)
	if len(text) == 0 {
		delete(extracted)
		return "", Usage{}, "summarization returned no text"
	}
	result := strings.clone(text)
	delete(extracted)
	u: Usage
	if parsed, uok := parse_usage(value); uok do u = parsed
	return result, u, ""
}


// --- model listing (/models) ----------------------------------------------

Model_Info :: struct {
	id:      string,
	efforts: []string,
	known:   bool,
}

endpoint_label :: proc(base_url: string) -> string {
	base := strings.trim_space(base_url)
	if len(base) == 0 do return strings.clone(DEFAULT_BASE_URL)
	for len(base) > 0 && base[len(base) - 1] == '/' do base = base[:len(base) - 1]
	return strings.clone(base)
}

models_url :: proc(base_url: string) -> string {
	base := endpoint_label(base_url)
	defer delete(base)
	return fmt.aprintf("%s/models", base)
}

normalize_efforts :: proc(input: []string) -> []string {
	documented := [4]string{"minimal", "low", "medium", "high"}
	seen := make(map[string]bool, context.temp_allocator)
	order := make([dynamic]string, 0, len(input))
	for raw in input {
		e := strings.to_lower(strings.trim_space(raw))
		if len(e) == 0 || seen[e] do continue
		seen[e] = true
		append(&order, e)
	}
	out := make([dynamic]string, 0, len(order))
	for e in documented {
		if seen[e] {
			append(&out, strings.clone(e))
			delete_key(&seen, e)
		}
	}
	for e in order {
		if seen[e] {
			append(&out, strings.clone(e))
			delete_key(&seen, e)
		}
	}
	return out[:]
}

Reasoning_Capability :: struct {
	match: string,
	efforts: []string,
}

reasoning_capabilities := [?]Reasoning_Capability{
	{"gpt-5-chat", nil},
	{"gpt-5", {"minimal", "low", "medium", "high"}},
	{"o4", {"low", "medium", "high"}},
	{"o3-pro", nil},
	{"o3-deep-research", nil},
	{"o3", {"low", "medium", "high"}},
	{"o1", {"low", "medium", "high"}},
	{"gpt-4o", nil},
	{"gpt-4.1", nil},
	{"gpt-4", nil},
	{"gpt-3", nil},
	{"chatgpt", nil},
	{"embedding", nil},
	{"whisper", nil},
	{"tts", nil},
	{"dall-e", nil},
	{"moderation", nil},
}

infer_reasoning_efforts :: proc(id: string) -> ([]string, bool) {
	lower := strings.to_lower(id)
	for c in reasoning_capabilities {
		if strings.contains(lower, c.match) {
			out := make([]string, len(c.efforts))
			for e, i in c.efforts do out[i] = strings.clone(e)
			return out, true
		}
	}
	return nil, false
}

annotate_model :: proc(id: string, reported: []string) -> Model_Info {
	m := Model_Info{id = strings.clone(id)}
	if efforts := normalize_efforts(reported); len(efforts) > 0 {
		m.efforts = efforts
		m.known = true
		return m
	}
	if efforts, known := infer_reasoning_efforts(id); known {
		m.efforts = efforts
		m.known = true
	}
	return m
}

model_destroy :: proc(m: ^Model_Info) {
	delete(m.id)
	for e in m.efforts do delete(e)
	delete(m.efforts)
	m^ = {}
}

model_list_destroy :: proc(models: []Model_Info) {
	for &m in models do model_destroy(&m)
	delete(models)
}

reported_efforts :: proc(obj: json.Object) -> []string {
	if rv, ok := jobj(jget(obj, "reasoning")); ok {
		if arr, aok := jarr(jget(rv, "supported_efforts")); aok && len(arr) > 0 {
			out := make([]string, len(arr))
			for v, i in arr do out[i] = jstr(v)
			return out
		}
		if arr, aok := jarr(jget(rv, "efforts")); aok && len(arr) > 0 {
			out := make([]string, len(arr))
			for v, i in arr do out[i] = jstr(v)
			return out
		}
		if one := jstr(jget(rv, "supported_effort")); len(one) > 0 {
			out := make([]string, 1)
			out[0] = one
			return out
		}
	}
	if arr, ok := jarr(jget(obj, "reasoning_efforts")); ok && len(arr) > 0 {
		out := make([]string, len(arr))
		for v, i in arr do out[i] = jstr(v)
		return out
	}
	if arr, ok := jarr(jget(obj, "supported_reasoning_levels")); ok && len(arr) > 0 {
		out := make([]string, len(arr))
		for v, i in arr do out[i] = jstr(v)
		return out
	}
	return nil
}

fetch_models :: proc(h: ^Harness) -> ([]Model_Info, string) {
	MAX_MODELS_BYTES :: 8 << 20
	buf := make([]u8, MAX_MODELS_BYTES)
	defer delete(buf)
	errbuf: [2048]u8
	outlen: uint
	status := mi_http_get_buffered(
		cstring_copy(models_url(h.config.base_url)),
		cstring_copy(h.config.api_key),
		raw_data(buf),
		uint(len(buf)),
		&outlen,
		&errbuf[0],
		uint(len(errbuf)),
	)
	if status != 0 {
		msg := strings.trim_space(string(cstring(&errbuf[0])))
		if len(msg) == 0 do msg = "model list request failed"
		return nil, strings.clone(msg)
	}
	payload := string(buf[:outlen])
	if len(strings.trim_space(payload)) == 0 do return nil, "model list: empty response"
	root, err := json.parse_string(payload)
	if err != nil do return nil, fmt.aprintf("model list: %v", err)
	defer json.destroy_value(root)
	ro, ok := jobj(root)
	if !ok do return nil, "model list: unexpected response"
	data, ok2 := jarr(jget(ro, "data"))
	if !ok2 do return nil, "model list: response has no data array"
	models := make([dynamic]Model_Info, 0, len(data))
	for raw in data {
		obj, oo := jobj(raw)
		if !oo do continue
		id := strings.trim_space(jstr(jget(obj, "id")))
		if len(id) == 0 do continue
		reported := reported_efforts(obj)
		append(&models, annotate_model(id, reported))
		delete(reported)
	}
	return models[:], ""
}

reasoning_summary :: proc(m: Model_Info) -> string {
	if !m.known do return strings.clone("reasoning: unknown")
	if len(m.efforts) == 0 do return strings.clone("reasoning: none")
	return fmt.aprintf("reasoning: %s", strings.join(m.efforts, ", "))
}

pad_right :: proc(s: string, width: int) -> string {
	if len(s) >= width do return s
	return strings.concatenate({s, strings.repeat(" ", width - len(s), context.temp_allocator)}, context.temp_allocator)
}

model_list_text :: proc(h: ^Harness) -> (string, string) {
	models, err := fetch_models(h)
	if err != "" do return "", err
	defer model_list_destroy(models)
	slice.sort_by(models, proc(a, b: Model_Info) -> bool { return a.id < b.id })

	b := strings.builder_make()
	endpoint := endpoint_label(h.config.base_url)
	defer delete(endpoint)
	fmt.sbprintf(&b, "models at %s (%d):\n", endpoint, len(models))
	if len(models) == 0 do strings.write_string(&b, "  (none)\n")
	width := 0
	for m in models do width = max(width, len(m.id))
	for m in models {
		marker := "  "
		if len(h.config.model) > 0 && m.id == h.config.model do marker = "* "
		summary := reasoning_summary(m)
		defer delete(summary)
		fmt.sbprintf(&b, "%s%s  %s\n", marker, pad_right(m.id, width), summary)
	}
	switch {
	case len(h.config.model) == 0:
		strings.write_string(&b, "no model configured; set OPENAI_MODEL\n")
	case len(h.config.reasoning_effort) > 0:
		fmt.sbprintf(&b, "configured: %s, reasoning effort %q (%s)\n",
			h.config.model, h.config.reasoning_effort, "OPENAI_REASONING_EFFORT")
	case:
		fmt.sbprintf(&b, "configured: %s, reasoning effort default\n", h.config.model)
	}
	return strings.to_string(b), ""
}

cmd_models :: proc(h: ^Harness) -> string {
	text, err := model_list_text(h)
	if err != "" do return err
	defer delete(text)
	h_emit_note(h, text)
	return ""
}
