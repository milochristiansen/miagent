// Session persistence, compatible with the MiAgent CLI's JSONL session format.
//
// One record per line: a conversation item (no "type" field), a usage record
// ("type":"usage"), or a compaction record ("type":"compaction"). The desktop
// harness reads and writes the same files as the CLI, so a session can move
// between the two without conversion.
package harness

import crypto_hash "core:crypto/hash"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

// Attachment is one file returned by a tool. Images and binary files carry a
// data: URL; text files carry their contents inline. Name is kept for display
// and is never sent as a path.
Attachment :: struct {
	name: string `json:"name,omitempty"`,
	mime: string `json:"mime,omitempty"`,
	kind: string `json:"kind,omitempty"`, // "image" | "text" | "binary"
	text: string `json:"text,omitempty"`,
	url:  string `json:"url,omitempty"`,
	size: int    `json:"size,omitempty"`,
}

// Nugget_Digest is the SHA-256 digest of a nugget's content. Nuggets are hard,
// unchanging context, so identical content is redundant no matter what name or
// source it came from. Digests are derived on demand and are not part of the
// session JSON format.
Nugget_Digest :: [32]byte

nugget_digest :: proc(content: string) -> (digest: Nugget_Digest) {
	crypto_hash.hash_string_to_buffer(.SHA256, content, digest[:])
	return
}

// session_nugget_digests seeds the duplicate check from the session's existing
// nuggets. The caller owns the returned map and deletes it.
session_nugget_digests :: proc(items: []StoredItem) -> map[Nugget_Digest]bool {
	digests := make(map[Nugget_Digest]bool, len(items))
	for it in items {
		if it.role == "nugget" do digests[nugget_digest(it.content)] = true
	}
	return digests
}

ReasoningPart :: struct {
	kind: string `json:"type,omitempty"`,
	text: string `json:"text"`,
}

Reasoning :: struct {
	id:                string          `json:"id,omitempty"`,
	summary:           []ReasoningPart `json:"summary,omitempty"`,
	content:           []ReasoningPart `json:"content,omitempty"`,
	encrypted_content: string          `json:"encrypted_content,omitempty"`,
}

// StoredItem mirrors the CLI's session item. Role is one of user, assistant,
// reasoning, function_call, function_call_output, compaction, or nugget.
StoredItem :: struct {
	role:        string          `json:"role"`,
	content:     string          `json:"content,omitempty"`,
	attachments: []Attachment    `json:"attachments,omitempty"`,
	call_id:     string          `json:"call_id,omitempty"`,
	name:        string          `json:"name,omitempty"`,
	arguments:   string          `json:"arguments,omitempty"`,
	output:      string          `json:"output,omitempty"`,
	source:      string          `json:"source,omitempty"`,
	nugget_id:   string          `json:"nugget_id,omitempty"`,
	reasoning:   Maybe(Reasoning) `json:"reasoning,omitempty"`,
}

Usage :: struct {
	input_tokens:     int `json:"input_tokens"`,
	cached_tokens:    int `json:"cached_tokens,omitempty"`,
	output_tokens:    int `json:"output_tokens"`,
	reasoning_tokens: int `json:"reasoning_tokens,omitempty"`,
	total_tokens:     int `json:"total_tokens,omitempty"`,
	at_items:         int `json:"at_items,omitempty"`,
}

usage_line :: struct {
	kind:             string `json:"type"`,
	input_tokens:     int    `json:"input_tokens"`,
	cached_tokens:    int    `json:"cached_tokens,omitempty"`,
	output_tokens:    int    `json:"output_tokens"`,
	reasoning_tokens: int    `json:"reasoning_tokens,omitempty"`,
	total_tokens:     int    `json:"total_tokens,omitempty"`,
	at_items:         int    `json:"at_items,omitempty"`,
}

usage_line_from :: proc(u: Usage) -> usage_line {
	return usage_line{
		kind = "usage",
		input_tokens = u.input_tokens,
		cached_tokens = u.cached_tokens,
		output_tokens = u.output_tokens,
		reasoning_tokens = u.reasoning_tokens,
		total_tokens = u.total_tokens,
		at_items = u.at_items,
	}
}

compaction_record :: struct {
	kind:          string `json:"type"`,
	archived:      string `json:"archived"`,
	created:       string `json:"created"`,
	tokens_before: int    `json:"tokens_before"`,
	tokens_after:  int    `json:"tokens_after"`,
	usage:         Usage  `json:"usage"`,
}

// Session is a loaded session file plus the append bookkeeping. Only one
// thread (the harness worker) mutates it; readers take the harness state lock.
Session :: struct {
	items:             [dynamic]StoredItem,
	usages:            [dynamic]Usage,
	carried:           Usage,
	compacted:         bool,
	path:              string,
	committed:         int,
	committed_usages:  int,
}

session_init :: proc(path: string) -> Session {
	s := Session{}
	s.path = strings.clone(path)
	s.items = make([dynamic]StoredItem, 0, 64)
	s.usages = make([dynamic]Usage, 0, 16)
	return s
}

item_destroy :: proc(it: ^StoredItem) {
	delete(it.content)
	delete(it.call_id)
	delete(it.name)
	delete(it.arguments)
	delete(it.output)
	delete(it.source)
	delete(it.nugget_id)
	for &att in it.attachments do attachment_destroy(&att)
	delete(it.attachments)
	if r, ok := it.reasoning.?; ok {
		delete(r.id)
		delete(r.encrypted_content)
		for &p in r.summary do delete(p.text)
		for &p in r.content do delete(p.text)
		delete(r.summary)
		delete(r.content)
		it.reasoning = nil
	}
}

session_destroy :: proc(s: ^Session) {
	for &it in s.items do item_destroy(&it)
	delete(s.items)
	delete(s.usages)
	delete(s.path)
}

// session_load reads the file if it exists. A missing file is an empty session,
// matching the CLI's first-run behavior.
session_load :: proc(s: ^Session) -> string {
	data, err := os.read_entire_file(s.path, context.allocator)
	if err != nil {
		if os.exists(s.path) {
			return fmt.aprintf("reading session %s: %v", s.path, err)
		}
		return ""
	}
	defer delete(data)
	if perr := session_parse(s, string(data)); perr != "" {
		session_reset(s)
		return perr
	}
	if verr := session_validate_items(s.items[:]); verr != "" {
		session_reset(s)
		return fmt.aprintf("bad session: %s", verr)
	}
	return ""
}

// session_validate_items catches pairs that cannot be replayed by the
// Responses API. It deliberately allows an unanswered trailing function call:
// a crash between committing the call and its output is recoverable by the
// turn error path, and rejecting it would make that session unreadable.
session_validate_items :: proc(items: []StoredItem) -> string {
	calls := make(map[string]int, len(items))
	defer delete(calls)
	for it, i in items {
		switch it.role {
		case "function_call":
			if len(it.call_id) == 0 do return fmt.aprintf("function_call at item %d has no call_id", i)
			if _, exists := calls[it.call_id]; exists {
				return fmt.aprintf("duplicate function_call %q at item %d", it.call_id, i)
			}
			calls[it.call_id] = 0
		case "function_call_output":
			if len(it.call_id) == 0 do return fmt.aprintf("function_call_output at item %d has no call_id", i)
			answered, exists := calls[it.call_id]
			if !exists do return fmt.aprintf("function_call_output for unknown call %q at item %d", it.call_id, i)
			if answered == 1 do return fmt.aprintf("duplicate function_call_output for %q at item %d", it.call_id, i)
			calls[it.call_id] = 1
		}
	}
	return ""
}

// session_parse appends the JSONL records in text to s, exactly as loadFrom
// does in the CLI. It is also used to probe an archive before /load adopts it.
session_parse :: proc(s: ^Session, text: string) -> string {
	lines := strings.split(text, "\n")
	defer delete(lines)
	line_no := 0
	for raw in lines {
		line_no += 1
		line := strings.trim_space(raw)
		if len(line) == 0 do continue

		tag: struct { kind: string `json:"type"` }
		if jerr := json.unmarshal_string(line, &tag); jerr != nil {
			return fmt.aprintf("bad session line %d: %v", line_no, jerr)
		}
		switch tag.kind {
		case "":
			it: StoredItem
			if jerr := json.unmarshal_string(line, &it); jerr != nil {
				return fmt.aprintf("bad session line %d: %v", line_no, jerr)
			}
			switch it.role {
			case "user", "assistant", "reasoning", "function_call", "function_call_output", "compaction", "nugget":
			case:
				return fmt.aprintf("bad session line %d: unknown item role %q", line_no, it.role)
			}
			append(&s.items, it)
		case "usage":
			u: Usage
			if jerr := json.unmarshal_string(line, &u); jerr != nil {
				return fmt.aprintf("bad session line %d: %v", line_no, jerr)
			}
			append(&s.usages, u)
		case "compaction":
			if s.compacted do return "bad session: more than one compaction record"
			rec: compaction_record
			if jerr := json.unmarshal_string(line, &rec); jerr != nil {
				return fmt.aprintf("bad session line %d: %v", line_no, jerr)
			}
			if rec.archived == "" do return `bad session: compaction record has no "archived" field`
			s.compacted = true
			s.carried = rec.usage
		case:
			return fmt.aprintf("bad session line %d: unknown record type %q", line_no, tag.kind)
		}
	}
	s.committed = len(s.items)
	s.committed_usages = len(s.usages)
	return ""
}

// session_probe validates session text without keeping it.
session_probe :: proc(text: string) -> string {
	probe := Session{}
	probe.items = make([dynamic]StoredItem, 0, 8)
	probe.usages = make([dynamic]Usage, 0, 4)
	err := session_parse(&probe, text)
	if err == "" do err = session_validate_items(probe.items[:])
	session_destroy(&probe)
	return err
}

// clone_session_items deep-copies a session's conversation items so a reader can
// own them independently of the Session that parsed them.
clone_session_items :: proc(s: ^Session) -> []StoredItem {
	out := make([]StoredItem, len(s.items))
	for it, i in s.items do out[i] = clone_item(it)
	return out
}

// harness_read_session_items loads a session file without touching a live
// harness. The GUI uses it to preview a known project's current conversation.
// The caller owns the returned items and frees them with harness_free_items.
harness_read_session_items :: proc(path: string) -> ([]StoredItem, string) {
	s := session_init(path)
	defer session_destroy(&s)
	if err := session_load(&s); err != "" do return nil, err
	return clone_session_items(&s), ""
}

// harness_read_archive_items extracts the session file from a /new archive and
// returns a copy of its conversation. Compaction archives and the generated
// session-name.md entry are not the session itself. As above, the caller owns
// the returned items.
harness_read_archive_items :: proc(path: string) -> ([]StoredItem, string) {
	entries, err := archive_read(path)
	if err != "" do return nil, err
	defer archive_entries_destroy(entries)

	content := ""
	name := ""
	for e in entries {
		if e.name == SESSION_NAME_ENTRY do continue
		if is_compaction_archive_name(e.name) do continue
		if len(name) > 0 {
			return nil, fmt.aprintf("archive holds more than one session file (%q and %q)", name, e.name)
		}
		name = e.name
		content = e.content
	}
	if len(name) == 0 do return nil, "archive holds no session file"

	s := Session{}
	s.items = make([dynamic]StoredItem, 0, 8)
	s.usages = make([dynamic]Usage, 0, 4)
	defer session_destroy(&s)
	if perr := session_parse(&s, content); perr != "" do return nil, perr
	if verr := session_validate_items(s.items[:]); verr != "" do return nil, fmt.aprintf("bad session: %s", verr)
	return clone_session_items(&s), ""
}

// session_reset empties the in-memory session, leaving its path alone. It is
// what /new leaves behind after the session file has been archived and removed.
session_reset :: proc(s: ^Session) {
	for &it in s.items do item_destroy(&it)
	clear(&s.items)
	clear(&s.usages)
	s.carried = Usage{}
	s.compacted = false
	s.committed = 0
	s.committed_usages = 0
}

// session_reload replaces the in-memory session with the file at s.path.
session_reload :: proc(s: ^Session) -> string {
	session_reset(s)
	return session_load(s)
}

append_session :: proc(path: string, items: []StoredItem, usages: []Usage) -> string {
	if len(items) == 0 && len(usages) == 0 do return ""
	f, err := os.open(path, {.Append, .Create, .Write})
	if err != nil do return fmt.aprintf("opening session %s: %v", path, err)
	defer os.close(f)

	start_size, size_err := os.file_size(f)
	if size_err != nil do return fmt.aprintf("sizing session %s: %v", path, size_err)

	rollback := proc(f: ^os.File, size: i64) {
		_ = os.truncate(f, size)
		_ = os.sync(f)
	}

	b := strings.builder_make()
	defer delete(b.buf)
	for it in items {
		data, jerr := json.marshal(it)
		if jerr != nil do return fmt.aprintf("encoding session item: %v", jerr)
		strings.write_bytes(&b, data)
		strings.write_byte(&b, '\n')
		delete(data)
	}
	for u in usages {
		line := usage_line_from(u)
		data, jerr := json.marshal(line)
		if jerr != nil do return fmt.aprintf("encoding usage: %v", jerr)
		strings.write_bytes(&b, data)
		strings.write_byte(&b, '\n')
		delete(data)
	}

	payload := strings.to_string(b)
	bytes := transmute([]byte)payload
	written := 0
	for written < len(bytes) {
		n, werr := os.write(f, bytes[written:])
		if werr != nil || n <= 0 {
			rollback(f, start_size)
			if werr != nil do return fmt.aprintf("writing session: %v", werr)
			return "writing session: short write"
		}
		written += n
	}
	if serr := os.sync(f); serr != nil {
		rollback(f, start_size)
		return fmt.aprintf("syncing session: %v", serr)
	}
	return ""
}

session_commit :: proc(s: ^Session) -> string {
	items := s.items[s.committed:]
	usages := s.usages[s.committed_usages:]
	if len(items) == 0 && len(usages) == 0 do return ""
	if err := append_session(s.path, items, usages); err != "" do return err
	s.committed = len(s.items)
	s.committed_usages = len(s.usages)
	return ""
}

session_append_item :: proc(s: ^Session, it: StoredItem) {
	append(&s.items, it)
}

session_append_usage :: proc(s: ^Session, u: Usage) {
	append(&s.usages, u)
}

usage_add :: proc(a, b: Usage) -> Usage {
	return Usage{
		input_tokens = a.input_tokens + b.input_tokens,
		cached_tokens = a.cached_tokens + b.cached_tokens,
		output_tokens = a.output_tokens + b.output_tokens,
		reasoning_tokens = a.reasoning_tokens + b.reasoning_tokens,
		total_tokens = a.total_tokens + b.total_tokens,
	}
}

// session_total is the session's complete usage: what earlier turns carried
// through the last compaction plus every turn measured since.
session_total :: proc(s: ^Session) -> Usage {
	total := s.carried
	for u in s.usages do total = usage_add(total, u)
	return total
}

// --- context sizing --------------------------------------------------------

// A token estimate for text no measurement covers. The CLI uses four
// characters per token; the same heuristic keeps the GUI's context chip close
// to what /context reports.
CHARS_PER_TOKEN :: 4
IMAGE_TOKEN_ESTIMATE :: 1024

estimate_item_tokens :: proc(it: StoredItem) -> int {
	chars := 0
	switch it.role {
	case "user", "assistant", "compaction", "nugget":
		chars = len(it.content) + len(it.name)
	case "reasoning":
		if r, ok := it.reasoning.?; ok {
			for p in r.content do chars += len(p.text)
			for p in r.summary do chars += len(p.text)
		}
	case "function_call":
		chars = len(it.name) + len(it.arguments)
	case "function_call_output":
		chars = len(it.output)
	}
	tokens := 0
	if chars > 0 do tokens = (chars + CHARS_PER_TOKEN - 1) / CHARS_PER_TOKEN
	for att in it.attachments {
		switch att.kind {
		case "text":
			tokens += (len(att.text) + CHARS_PER_TOKEN - 1) / CHARS_PER_TOKEN
		case:
			tokens += IMAGE_TOKEN_ESTIMATE
		}
	}
	return tokens
}

Measurement :: struct {
	items:  int,
	tokens: int,
}

Token_Index :: struct {
	items:    []StoredItem,
	prefix:   []int,
	floor:    int,
	measured: bool,
}

token_index_make :: proc(items: []StoredItem, usages: []Usage) -> Token_Index {
	est := make([]int, len(items) + 1)
	for it, i in items do est[i + 1] = est[i] + estimate_item_tokens(it)

	anchors := make([dynamic]Measurement, 0, 8)
	floor := 0
	for u in usages {
		tokens := u.input_tokens + u.output_tokens
		if u.at_items <= 0 {
			floor = max(floor, tokens)
			continue
		}
		if u.at_items > len(items) || tokens <= 0 do continue
		if len(anchors) > 0 && tokens <= anchors[len(anchors) - 1].tokens do continue
		append(&anchors, Measurement{items = u.at_items, tokens = tokens})
	}

	x := Token_Index{
		items = items,
		prefix = make([]int, len(items) + 1),
		floor = floor,
		measured = len(anchors) > 0 || floor > 0,
	}

	a, v, next := 0, 0, 0
	if len(anchors) > 0 {
		a, v = anchors[0].items, anchors[0].tokens
		next = 1
	}
	for i in 0 ..= len(items) {
		for next < len(anchors) && anchors[next].items <= i {
			a, v = anchors[next].items, anchors[next].tokens
			next += 1
		}
		if i >= a && next < len(anchors) {
			span := est[anchors[next].items] - est[a]
			total := anchors[next].tokens - v
			if span > 0 && total > 0 {
				x.prefix[i] = v + (est[i] - est[a]) * total / span
				continue
			}
		}
		x.prefix[i] = v + est[i] - est[a]
	}
	delete(est)
	delete(anchors)
	return x
}

token_index_total :: proc(x: ^Token_Index) -> int {
	last := 0
	if len(x.prefix) > 0 do last = x.prefix[len(x.prefix) - 1]
	return max(last, x.floor)
}

token_index_suffix :: proc(x: ^Token_Index, i: int) -> int {
	if len(x.prefix) == 0 do return 0
	return x.prefix[len(x.prefix) - 1] - x.prefix[i]
}

token_index_destroy :: proc(x: ^Token_Index) {
	delete(x.prefix)
}

// session_context reports the next request's context size and whether a
// provider measurement backs it.
session_context :: proc(s: ^Session) -> (tokens: int, measured: bool) {
	x := token_index_make(s.items[:], s.usages[:])
	tokens = token_index_total(&x)
	measured = x.measured
	token_index_destroy(&x)
	return
}
