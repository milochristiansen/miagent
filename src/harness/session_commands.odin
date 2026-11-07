// Session-management slash commands: /new, /sessions, /load, /compact, and
// /desc. The archive layout, naming, prompts, and compaction plan match the
// Go CLI so archives and sessions can move between the two implementations.
package harness

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode/utf8"

SESSION_NAME_PROMPT :: "SESSION-NAME.md"
DESCRIPTION_PROMPT :: "DESCRIPTION.md"
SESSION_NAME_MAX_TOKENS :: 256
DESCRIPTION_MAX_TOKENS :: 512
SESSION_NAME_PROMPT_LIMIT :: 3

DEFAULT_KEEP_RECENT :: 20000
DEFAULT_RESERVE :: 16384
TOOL_RESULT_SUMMARY_CHARS :: 2000

// --- /new ------------------------------------------------------------------

session_name_conversation :: proc(items: []StoredItem) -> string {
	b := strings.builder_make()
	count := 0
	for it in items {
		if count == SESSION_NAME_PROMPT_LIMIT do break
		if it.role != "user" do continue
		text := strings.trim_space(it.content)
		if len(text) == 0 do continue
		if strings.builder_len(b) > 0 do strings.write_string(&b, "\n\n")
		strings.write_string(&b, "User: ")
		strings.write_string(&b, text)
		count += 1
	}
	return strings.to_string(b)
}

session_name_input :: proc(conversation: string) -> string {
	return fmt.aprintf("<conversation>\n%s\n</conversation>", conversation)
}

load_prompt_file :: proc(config_dir, name: string) -> (string, string) {
	return read_prompt(join_path(config_dir, PROMPTS_DIR, name), true)
}

cmd_new :: proc(h: ^Harness) -> string {
	if len(h.session.path) == 0 do return "no session file configured"
	// Persist any in-memory items first. /new archives files, so an
	// uncommitted turn would otherwise disappear with the old in-memory
	// session after the reset below.
	sync.mutex_lock(&h.state_mutex)
	commit_err := session_commit(&h.session)
	sync.mutex_unlock(&h.state_mutex)
	if commit_err != "" do return fmt.aprintf("saving session before archive: %s", commit_err)
	files, ferr := session_pack_files(h.session.path)
	if ferr != "" do return ferr
	defer session_files_destroy(&files)
	all := session_files_all(files)
	defer delete(all)
	if len(all) == 0 {
		if files.empty {
			h_emit_note(h, fmt.aprintf("nothing to archive: %s holds no exchanges yet", h.session.path))
		} else {
			h_emit_note(h, fmt.aprintf("nothing to archive: no session file at %s", h.session.path))
		}
		return ""
	}

	name := ""
	conversation := session_name_conversation(h.session.items[:])
	if len(conversation) > 0 {
		if len(h.config.model) == 0 {
			delete(conversation)
			return "naming the session: model not configured (set OPENAI_MODEL)"
		}
		prompt, perr := load_prompt_file(h.config.config_dir, SESSION_NAME_PROMPT)
		if perr != "" {
			delete(conversation)
			return fmt.aprintf("naming the session: %s", perr)
		}
		wrapped := session_name_input(conversation)
		text, _, serr := summarize(h, prompt, wrapped, SESSION_NAME_MAX_TOKENS)
		delete(conversation)
		delete(prompt)
		delete(wrapped)
		if serr != "" do return fmt.aprintf("naming the session: %s", serr)
		name = text
	} else {
		delete(conversation)
	}

	entries := make([dynamic]Archive_Entry, 0, 1)
	defer {
		for &e in entries {
			delete(e.name)
			delete(e.content)
		}
		delete(entries)
	}
	if len(name) > 0 {
		append(&entries, Archive_Entry{
			name = strings.clone(SESSION_NAME_ENTRY),
			content = fmt.aprintf("%s\n", name),
		})
	}
	defer delete(name)

	stamp := utc_stamp(time.now())
	stem := fmt.aprintf("%s%s", NEW_ARCHIVE_PREFIX, stamp)
	target, terr := unique_path(os.dir(h.session.path), stem, ARCHIVE_EXT)
	delete(stem)
	if terr != "" do return terr
	defer delete(target)

	if err := archive_pack(target, all, entries[:]); err != "" {
		os.remove(target)
		return err
	}
	retired, rerr := retire_files(all)
	if rerr != "" {
		os.remove(target)
		return fmt.aprintf("archiving as %s, but retiring the originals failed: %s", target, rerr)
	}
	defer {
		for path in retired do delete(path)
		delete(retired)
	}
	cleanup_err := remove_files(retired)
	sync.mutex_lock(&h.state_mutex)
	session_reset(&h.session)
	sync.mutex_unlock(&h.state_mutex)
	turn_info_reset(h)

	size: i64 = 0
	if st, serr := os.stat(target, context.temp_allocator); serr == nil do size = st.size
	refresh_context(h)
	h_emit(h, Event{kind = .Session_Changed})
	h_emit_note(h, fmt.aprintf("archived %d %s (%s) as %s",
		len(all), plural(len(all), "file", "files"), human_bytes(size), target))
	desc := session_files_describe(files)
	h_emit_note(h, fmt.aprintf("removed %s; the next prompt starts a new session", desc))
	delete(desc)
	if cleanup_err != "" {
		h_emit_note(h, fmt.aprintf("archived as %s, but deleting the retired originals failed: %s", target, cleanup_err))
		delete(cleanup_err)
	}
	h_emit_context(h)
	return ""
}

// --- /sessions -------------------------------------------------------------

cmd_sessions :: proc(h: ^Harness, args: []string) -> string {
	if len(args) > 0 do return "takes no arguments"
	if len(h.session.path) == 0 do return "no session file configured"
	dir := os.dir(h.session.path)
	if len(dir) == 0 do dir = "."
	archives, err := list_archived_sessions(dir)
	if err != "" do return err
	defer archived_sessions_destroy(archives)
	if len(archives) == 0 {
		h_emit_note(h, fmt.aprintf("no archived sessions in %s", dir))
		return ""
	}
	b := strings.builder_make()
	defer delete(b.buf)
	strings.write_string(&b, fmt.aprintf("archived sessions in %s (%d):", dir, len(archives)))
	for a in archives {
		desc := one_line(a.description)
		if len(desc) == 0 {
			delete(desc)
			desc = strings.clone("(no description)")
		}
		strings.write_string(&b, fmt.aprintf("\n  %s  %s  %s", stamp_display(a.stamp), a.name, desc))
		delete(desc)
	}
	h_emit_note(h, strings.to_string(b))
	return ""
}

// --- /load -----------------------------------------------------------------

resolve_archive_path :: proc(dir, arg: string) -> (string, string) {
	if len(arg) == 0 do return "", "empty session name"
	candidates := make([dynamic]string, 0, 2)
	defer delete(candidates)
	if os.is_absolute_path(arg) {
		append(&candidates, strings.clone(arg))
	} else if os.dir(arg) == "." {
		append(&candidates, join_path(dir, arg))
	} else {
		append(&candidates, join_path(dir, arg))
		append(&candidates, strings.clone(arg))
	}
	for c in candidates {
		if st, err := os.stat(c, context.temp_allocator); err == nil && st.type != .Directory {
			return strings.clone(c), ""
		}
	}
	defer {
		for c in candidates do delete(c)
	}
	if len(candidates) == 1 {
		return "", fmt.aprintf("no session archive at %s", candidates[0])
	}
	joined := strings.join(candidates[:], ", ")
	defer delete(joined)
	return "", fmt.aprintf("no session archive %q (tried %s)", arg, joined)
}

check_archive_names :: proc(entries: []Archive_Entry) -> string {
	for e in entries {
		if len(e.name) == 0 || e.name == "." || e.name == ".." ||
		   os.is_absolute_path(e.name) || os.base(e.name) != e.name {
			return fmt.aprintf("unsafe entry name %q", e.name)
		}
	}
	return ""
}

cmd_load :: proc(h: ^Harness, args: []string) -> string {
	if len(args) != 1 do return "takes one session (an archive name or path)"
	if len(h.session.path) == 0 do return "no session file configured"
	dir := os.dir(h.session.path)
	if len(dir) == 0 do dir = "."
	target, terr := resolve_archive_path(dir, args[0])
	if terr != "" do return terr
	defer delete(target)
	return cmd_load_target(h, target)
}

// cmd_load_target adopts an already-resolved archive path. It backs both the
// /load command and the GUI's "Load session" action, so the state change and
// emitted events stay identical. The caller keeps ownership of target.
cmd_load_target :: proc(h: ^Harness, target: string) -> string {
	if len(h.session.path) == 0 do return "no session file configured"
	dir := os.dir(h.session.path)
	if len(dir) == 0 do dir = "."

	entries, rerr := archive_read(target)
	if rerr != "" do return fmt.aprintf("reading %s: %s", target, rerr)
	defer archive_entries_destroy(entries)

	session_content := ""
	session_file_name := ""
	extra := make([dynamic]Archive_Entry, 0, 4)
	defer delete(extra)
	for e in entries {
		if e.name == SESSION_NAME_ENTRY do continue
		if is_compaction_archive_name(e.name) {
			append(&extra, e)
		} else if len(session_file_name) == 0 {
			session_file_name = e.name
			session_content = e.content
		} else {
			return fmt.aprintf("reading %s: holds more than one session file (%q and %q)", target, session_file_name, e.name)
		}
	}
	if len(session_file_name) == 0 do return fmt.aprintf("reading %s: holds no session file", target)
	if nerr := check_archive_names(extra[:]); nerr != "" do return fmt.aprintf("reading %s: %s", target, nerr)
	if perr := session_probe(session_content); perr != "" {
		return fmt.aprintf("reading %s (%s): %s", target, session_file_name, perr)
	}

	// Reject final paths that cannot be replaced by a rename before any
	// destructive work starts.
	for e in extra {
		final := join_path(dir, e.name)
		blocked := false
		if st, serr := os.stat(final, context.temp_allocator); serr == nil && st.type == .Directory do blocked = true
		delete(final)
		if blocked do return fmt.aprintf("restoring %s: target is a directory", e.name)
	}
	if st, serr := os.stat(h.session.path, context.temp_allocator); serr == nil && st.type == .Directory {
		return fmt.aprintf("writing %s: target is a directory", h.session.path)
	}

	// Stage every write before retiring the current session. Staging uses
	// unique names in the same directory, so a pre-existing compaction file
	// or a failed write cannot destroy the live session first.
	stage_id := fmt.aprintf("%d-%d", os.get_pid(), time.to_unix_nanoseconds(time.now()))
	defer delete(stage_id)
	staged_extra := make([]string, len(extra))
	defer {
		for path in staged_extra {
			if len(path) > 0 {
				os.remove(path)
				delete(path)
			}
		}
		delete(staged_extra)
	}
	for e, i in extra {
		staged := fmt.aprintf("%s/.miagent-restore-%s-%d", dir, stage_id, i)
		if werr := write_restored_file(staged, e.content); werr != "" {
			delete(staged)
			return fmt.aprintf("restoring %s: %s", e.name, werr)
		}
		staged_extra[i] = staged
	}
	staged_session := fmt.aprintf("%s/.miagent-restore-session-%s", dir, stage_id)
	defer {
		if len(staged_session) > 0 {
			os.remove(staged_session)
			delete(staged_session)
		}
	}
	if werr := write_restored_file(staged_session, session_content); werr != "" {
		return fmt.aprintf("writing %s: %s", h.session.path, werr)
	}

	// Retire the session being replaced first, exactly as /new would.
	if nerr := cmd_new(h); nerr != "" do return nerr

	for e, i in extra {
		final := join_path(dir, e.name)
		if rerr := os.rename(staged_extra[i], final); rerr != nil {
			delete(final)
			return fmt.aprintf("restoring %s: %v", e.name, rerr)
		}
		delete(final)
		delete(staged_extra[i])
		staged_extra[i] = ""
	}
	if rerr := os.rename(staged_session, h.session.path); rerr != nil {
		return fmt.aprintf("writing %s: %v", h.session.path, rerr)
	}
	delete(staged_session)
	staged_session = ""
	sync.mutex_lock(&h.state_mutex)
	lerr := session_reload(&h.session)
	sync.mutex_unlock(&h.state_mutex)
	if lerr != "" {
		return fmt.aprintf("loading %s: %s", h.session.path, lerr)
	}
	refresh_context(h)
	h_emit(h, Event{kind = .Session_Changed})
	h_emit_note(h, fmt.aprintf("loaded %s (%d %s); the next prompt continues it",
		target, len(h.session.items), plural(len(h.session.items), "item", "items")))
	h_emit_context(h)
	return ""
}

// --- /compact --------------------------------------------------------------

Compaction_Prompts :: struct {
	system:      string,
	initial:     string,
	update:      string,
	turn_prefix: string,
}

compaction_prompts_destroy :: proc(p: ^Compaction_Prompts) {
	delete(p.system)
	delete(p.initial)
	delete(p.update)
	delete(p.turn_prefix)
}

load_compaction_prompts :: proc(config_dir: string) -> (Compaction_Prompts, string) {
	p: Compaction_Prompts
	names := [4]string{"COMPACT-SYSTEM.md", "COMPACT-INITIAL.md", "COMPACT-UPDATE.md", "COMPACT-PREFIX.md"}
	dests := [4]^string{&p.system, &p.initial, &p.update, &p.turn_prefix}
	for name, i in names {
		text, err := load_prompt_file(config_dir, name)
		if err != "" {
			compaction_prompts_destroy(&p)
			return {}, err
		}
		dests[i]^ = text
	}
	return p, ""
}

Compaction_Settings :: struct {
	keep_recent: int,
	reserve:     int,
}

compaction_settings :: proc(c: ^Config) -> (Compaction_Settings, string) {
	keep, kerr := parse_positive_env(c, "MIAGENT_KEEP_RECENT_TOKENS", DEFAULT_KEEP_RECENT)
	if kerr != "" do return {}, kerr
	reserve, rerr := parse_positive_env(c, "MIAGENT_RESERVE_TOKENS", DEFAULT_RESERVE)
	if rerr != "" do return {}, rerr
	return Compaction_Settings{keep_recent = keep, reserve = reserve}, ""
}

Cut_Point :: struct {
	first_kept: int,
	turn_start: int,
	split:      bool,
}

is_cut_point :: proc(it: StoredItem) -> bool {
	switch it.role {
	case "user", "assistant", "function_call", "compaction": return true
	}
	return false
}

is_turn_start :: proc(it: StoredItem) -> bool {
	return it.role == "user" || it.role == "compaction"
}

find_cut_point :: proc(x: ^Token_Index, keep_recent: int) -> Cut_Point {
	cut_points := make([dynamic]int, 0, len(x.items))
	defer delete(cut_points)
	for it, i in x.items do if is_cut_point(it) do append(&cut_points, i)
	if len(cut_points) == 0 do return Cut_Point{first_kept = 0, turn_start = -1}

	cut_index := cut_points[0]
	for i := len(x.items) - 1; i >= 0; i -= 1 {
		if token_index_suffix(x, i) < keep_recent do continue
		cut_index = cut_points[len(cut_points) - 1]
		for c in cut_points {
			if c >= i {
				cut_index = c
				break
			}
		}
		break
	}
	if cut_index > 0 && (x.items[cut_index].role == "assistant" || x.items[cut_index].role == "function_call") {
		for cut_index > 0 && x.items[cut_index - 1].role == "reasoning" do cut_index -= 1
	}

	cut := Cut_Point{first_kept = cut_index, turn_start = -1}
	if is_turn_start(x.items[cut_index]) do return cut
	for i := cut_index; i >= 0; i -= 1 {
		if is_turn_start(x.items[i]) {
			cut.turn_start = i
			cut.split = true
			break
		}
	}
	return cut
}

format_tool_call :: proc(it: StoredItem) -> string {
	raw := strings.trim_space(it.arguments)
	if len(raw) == 0 do return fmt.aprintf("%s()", it.name)
	value, err := json.parse_string(raw)
	if err != nil do return fmt.aprintf("%s(%s)", it.name, raw)
	defer json.destroy_value(value)
	obj, ok := jobj(value)
	if !ok do return fmt.aprintf("%s(%s)", it.name, raw)

	keys := make([dynamic]string, 0, len(obj))
	for k in obj do append(&keys, k)
	slice.sort(keys[:])
	defer delete(keys)
	b := strings.builder_make()
	defer delete(b.buf)
	for k, i in keys {
		if i > 0 do strings.write_string(&b, ", ")
		data, merr := json.marshal(obj[k])
		if merr != nil do continue
		strings.write_string(&b, fmt.aprintf("%s=%s", k, string(data)))
		delete(data)
	}
	return fmt.aprintf("%s(%s)", it.name, strings.to_string(b))
}

truncate_for_summary :: proc(text: string, max_chars: int) -> string {
	if len(text) <= max_chars do return strings.clone(text)
	cut := max_chars
	for cut > 0 && !utf8.rune_start(text[cut]) do cut -= 1
	return fmt.aprintf("%s\n\n[... %d more characters truncated]", text[:cut], utf8.rune_count_in_string(text[cut:]))
}

attachment_note :: proc(attachments: []Attachment) -> string {
	switch len(attachments) {
	case 0:
		return ""
	case 1:
		name := strings.trim_space(attachments[0].name)
		if len(name) > 0 do return fmt.aprintf("[file attached: %s]", name)
		return strings.clone("[file attached]")
	case:
		return fmt.aprintf("[%d files attached]", len(attachments))
	}
}

serialize_conversation :: proc(items: []StoredItem) -> string {
	b := strings.builder_make()
	defer delete(b.buf)
	first := true
	append_part :: proc(b: ^strings.Builder, first: ^bool, text: string) {
		if !first^ do strings.write_string(b, "\n\n")
		strings.write_string(b, text)
		first^ = false
	}
	for it in items {
		switch it.role {
		case "compaction":
			// The summary is carried separately as the previous summary.
		case "nugget":
			// Nuggets are hard context and are never summarized.
		case "user":
			if len(it.content) > 0 do append_part(&b, &first, fmt.aprintf("[User]: %s", it.content))
		case "assistant":
			if len(it.content) > 0 do append_part(&b, &first, fmt.aprintf("[Assistant]: %s", it.content))
		case "reasoning":
			if r, ok := it.reasoning.?; ok {
				thinking := strings.builder_make()
				for p in r.content do strings.write_string(&thinking, p.text)
				for p in r.summary do strings.write_string(&thinking, p.text)
				text := strings.trim_space(strings.to_string(thinking))
				if len(text) > 0 do append_part(&b, &first, fmt.aprintf("[Assistant thinking]: %s", text))
				delete(thinking.buf)
			}
		case "function_call":
			append_part(&b, &first, fmt.aprintf("[Assistant tool calls]: %s", format_tool_call(it)))
		case "function_call_output":
			if len(it.output) > 0 || len(it.attachments) > 0 {
				text := truncate_for_summary(it.output, TOOL_RESULT_SUMMARY_CHARS)
				if note := attachment_note(it.attachments); len(note) > 0 {
					if len(text) > 0 {
						text = fmt.aprintf("%s\n%s", text, note)
					} else {
						text = strings.clone(note)
					}
					delete(note)
				}
				append_part(&b, &first, fmt.aprintf("[Tool result]: %s", text))
				delete(text)
			}
		}
	}
	return strings.clone(strings.to_string(b))
}

previous_summary :: proc(items: []StoredItem) -> string {
	for it in items do if it.role == "compaction" do return it.content
	return ""
}

validate_kept :: proc(kept: []StoredItem) -> string {
	calls := make(map[string]bool, context.temp_allocator)
	for it in kept do if it.role == "function_call" do calls[it.call_id] = true
	for it, i in kept {
		switch it.role {
		case "function_call_output":
			if !calls[it.call_id] do return fmt.aprintf("internal error: tool result %q would be kept without its call", it.call_id)
		case "reasoning":
			next := ""
			for j := i + 1; j < len(kept); j += 1 {
				if kept[j].role != "nugget" {
					next = kept[j].role
					break
				}
			}
			if next == "" || next == "assistant" || next == "function_call" || next == "reasoning" || next == "user" do continue
			return "internal error: thinking would be kept without the reply it belongs to"
		}
	}
	return ""
}

Compaction_Plan :: struct {
	history_text: string,
	prefix_text:  string,
	previous:     string,
	first_kept:   int,
	size:         Token_Index,
}

compaction_plan_destroy :: proc(p: ^Compaction_Plan) {
	delete(p.history_text)
	delete(p.prefix_text)
	delete(p.previous)
	token_index_destroy(&p.size)
}

plan_compaction :: proc(s: ^Session, keep_recent: int) -> (Compaction_Plan, bool, string) {
	if len(s.items) == 0 do return {}, false, ""
	size := token_index_make(s.items[:], s.usages[:])
	cut := find_cut_point(&size, keep_recent)
	if cut.first_kept <= 0 {
		token_index_destroy(&size)
		return {}, false, ""
	}
	history_end := cut.first_kept
	if cut.split do history_end = cut.turn_start
	history_text := serialize_conversation(s.items[:history_end])
	prefix_text := ""
	if cut.split do prefix_text = serialize_conversation(s.items[cut.turn_start:cut.first_kept])
	previous := strings.clone(previous_summary(s.items[:cut.first_kept]))
	if len(history_text) == 0 && len(prefix_text) == 0 {
		delete(history_text)
		delete(prefix_text)
		delete(previous)
		token_index_destroy(&size)
		return {}, false, ""
	}
	if err := validate_kept(s.items[cut.first_kept:]); err != "" {
		delete(history_text)
		delete(prefix_text)
		delete(previous)
		token_index_destroy(&size)
		return {}, false, err
	}
	return Compaction_Plan{
		history_text = history_text,
		prefix_text = prefix_text,
		previous = previous,
		first_kept = cut.first_kept,
		size = size,
	}, true, ""
}

summarization_prompt :: proc(base, conversation, previous: string) -> string {
	if len(previous) > 0 {
		return fmt.aprintf("<conversation>\n%s\n</conversation>\n\n<previous-summary>\n%s\n</previous-summary>\n\n%s",
			conversation, previous, base)
	}
	return fmt.aprintf("<conversation>\n%s\n</conversation>\n\n%s", conversation, base)
}

summarize_plan :: proc(h: ^Harness, prompts: ^Compaction_Prompts, plan: ^Compaction_Plan, settings: Compaction_Settings) -> (string, Usage, string) {
	history_max := settings.reserve * 8 / 10
	prefix_max := settings.reserve / 2

	history := ""
	usage := Usage{}
	if len(plan.history_text) > 0 {
		base := prompts.initial
		if len(plan.previous) > 0 do base = prompts.update
		prompt := summarization_prompt(base, plan.history_text, plan.previous)
		text, u, err := summarize(h, prompts.system, prompt, history_max)
		delete(prompt)
		if err != "" do return "", Usage{}, err
		history = text
		usage = u
	} else if len(plan.previous) > 0 {
		history = strings.clone(plan.previous)
	} else {
		history = strings.clone("No prior history.")
	}

	if len(plan.prefix_text) == 0 do return history, usage, ""
	prompt := summarization_prompt(prompts.turn_prefix, plan.prefix_text, "")
	prefix, prefix_usage, err := summarize(h, prompts.system, prompt, prefix_max)
	delete(prompt)
	if err != "" {
		delete(history)
		return "", Usage{}, err
	}
	out := fmt.aprintf("%s\n\n---\n\n**Turn Context (split turn):**\n\n%s", history, prefix)
	delete(history)
	delete(prefix)
	return out, usage_add(usage, prefix_usage), ""
}

estimate_note :: proc(measured: bool) -> string {
	return measured ? strings.clone("") : strings.clone(", estimated")
}

after_note :: proc(measured: bool) -> string {
	return measured ? strings.clone("kept tail measured, summary estimated") : strings.clone("estimated")
}

// build_compacted_items deep-clones the surviving items so the caller can
// destroy the old session wholesale after the new file is written. Prefix
// nuggets move immediately after the summary; kept-tail items, including
// nuggets, retain their order.
build_compacted_items :: proc(items: []StoredItem, first_kept: int, summary_item: StoredItem) -> (
	new_items: []StoredItem,
	moved_count: int,
	kept_nuggets: int,
) {
	for it in items[:first_kept] do if it.role == "nugget" do moved_count += 1
	kept := items[first_kept:]
	for it in kept do if it.role == "nugget" do kept_nuggets += 1

	new_items = make([]StoredItem, 1 + moved_count + len(kept))
	new_items[0] = summary_item
	out := 1
	for it in items[:first_kept] {
		if it.role == "nugget" {
			new_items[out] = clone_item(it)
			out += 1
		}
	}
	for it in kept {
		new_items[out] = clone_item(it)
		out += 1
	}
	return
}

cmd_compact :: proc(h: ^Harness, args: []string) -> string {
	if len(args) > 0 do return "takes no arguments"
	if len(h.config.model) == 0 do return "model not configured (set OPENAI_MODEL)"
	if len(h.session.path) == 0 do return "no session file to compact"
	if !os.exists(h.session.path) {
		h_emit_note(h, fmt.aprintf("nothing to compact: no session file at %s", h.session.path))
		return ""
	}
	prompts, perr := load_compaction_prompts(h.config.config_dir)
	if perr != "" do return perr
	defer compaction_prompts_destroy(&prompts)
	settings, serr := compaction_settings(&h.config)
	if serr != "" do return serr
	plan, ok, plerr := plan_compaction(&h.session, settings.keep_recent)
	if plerr != "" do return plerr
	if !ok {
		size := token_index_make(h.session.items[:], h.session.usages[:])
		suffix := token_index_suffix(&size, 0)
		measured := size.measured
		token_index_destroy(&size)
		note := estimate_note(measured)
		h_emit_note(h, fmt.aprintf("nothing to compact: the conversation (%s tokens%s) is already within the retention budget (%s tokens)",
			commas(suffix), note, commas(settings.keep_recent)))
		delete(note)
		return ""
	}
	defer compaction_plan_destroy(&plan)

	planned := token_index_total(&plan.size)
	measured := plan.size.measured
	estimate := estimate_note(measured)
	h_emit_note(h, fmt.aprintf("compacting: replacing %d %s with a summary (%s tokens%s)…",
		plan.first_kept, plural(plan.first_kept, "item", "items"), commas(planned), estimate))
	delete(estimate)

	carried := session_total(&h.session)
	summary, usage, serr2 := summarize_plan(h, &prompts, &plan, settings)
	if serr2 != "" do return serr2
	carried = usage_add(carried, usage)
	summary_item := StoredItem{role = "compaction", content = summary}
	kept_count := len(h.session.items) - plan.first_kept
	new_items, moved_count, kept_nuggets := build_compacted_items(
		h.session.items[:], plan.first_kept, summary_item)

	after := estimate_item_tokens(new_items[0])
	for i in 1 ..< 1 + moved_count do after += estimate_item_tokens(new_items[i])
	after += token_index_suffix(&plan.size, plan.first_kept)
	archive, aerr := archive_session(h.session.path)
	if aerr != "" {
		harness_free_items(new_items)
		return aerr
	}
	rec := compaction_record{
		kind = "compaction",
		archived = os.base(archive),
		created = utc_rfc3339(time.now()),
		tokens_before = planned,
		tokens_after = after,
		usage = carried,
	}
	content, cerr := compacted_session_bytes(rec, new_items)
	if cerr != "" {
		os.remove(archive)
		harness_free_items(new_items)
		delete(archive)
		return cerr
	}
	defer delete(content)
	if werr := write_session_file(h.session.path, content); werr != "" {
		os.remove(archive)
		harness_free_items(new_items)
		delete(archive)
		return werr
	}

	// Replace the in-memory session. new_items owns a full copy, so the old
	// session can be destroyed wholesale.
	sync.mutex_lock(&h.state_mutex)
	for &it in h.session.items do item_destroy(&it)
	delete(h.session.items)
	h.session.items = make([dynamic]StoredItem, len(new_items), len(new_items))
	copy(h.session.items[:], new_items)
	delete(new_items)
	delete(h.session.usages)
	h.session.usages = make([dynamic]Usage, 0, 4)
	h.session.carried = carried
	h.session.compacted = true
	h.session.committed = len(h.session.items)
	h.session.committed_usages = 0
	sync.mutex_unlock(&h.state_mutex)

	refresh_context(h)
	h_emit(h, Event{kind = .Session_Changed})
	note := after_note(measured)
	nugget_note := ""
	if moved_count > 0 || kept_nuggets > 0 {
		nugget_note = fmt.aprintf("; nuggets: %d relocated, %d kept in place", moved_count, kept_nuggets)
	}
	h_emit_note(h, fmt.aprintf("compacted %s -> %s tokens (%s); replaced %d %s, kept %d as they were%s",
		commas(planned), commas(after), note,
		plan.first_kept, plural(plan.first_kept, "item", "items"), kept_count, nugget_note))
	delete(nugget_note)
	delete(note)
	h_emit_note(h, fmt.aprintf("archived as %s", archive))
	delete(archive)
	h_emit_context(h)
	return ""
}

// --- /desc -----------------------------------------------------------------

describe_conversation :: proc(items: []StoredItem) -> string {
	b := strings.builder_make()
	defer delete(b.buf)
	first := true
	for it in items {
		switch it.role {
		case "compaction":
			if s := strings.trim_space(it.content); len(s) > 0 {
				if !first do strings.write_string(&b, "\n\n")
				strings.write_string(&b, "Summary of earlier work: ")
				strings.write_string(&b, s)
				first = false
			}
		case "user":
			if s := strings.trim_space(it.content); len(s) > 0 {
				if !first do strings.write_string(&b, "\n\n")
				strings.write_string(&b, "User: ")
				strings.write_string(&b, s)
				first = false
			}
		case "assistant":
			if s := strings.trim_space(it.content); len(s) > 0 {
				if !first do strings.write_string(&b, "\n\n")
				strings.write_string(&b, "Assistant: ")
				strings.write_string(&b, s)
				first = false
			}
		}
	}
	return strings.clone(strings.to_string(b))
}

cmd_desc :: proc(h: ^Harness, args: []string) -> string {
	if len(args) > 0 do return "takes no arguments"
	if len(h.config.model) == 0 do return "model not configured (set OPENAI_MODEL)"
	conversation := describe_conversation(h.session.items[:])
	if len(conversation) == 0 {
		delete(conversation)
		h_emit_note(h, "nothing to describe: the session has no prompts or answers yet")
		return ""
	}
	prompt, perr := load_prompt_file(h.config.config_dir, DESCRIPTION_PROMPT)
	if perr != "" {
		delete(conversation)
		return perr
	}
	wrapped := fmt.aprintf("<conversation>\n%s\n</conversation>", conversation)
	delete(conversation)
	text, _, serr := summarize(h, prompt, wrapped, DESCRIPTION_MAX_TOKENS)
	delete(prompt)
	delete(wrapped)
	if serr != "" do return serr
	h_emit(h, Event{kind = .Assistant_Start, name = "MiAgent · description"})
	h_emit(h, Event{kind = .Assistant_Delta, text = text})
	h_emit(h, Event{kind = .Assistant_End, meta = clock_string()})
	delete(text)
	return ""
}
