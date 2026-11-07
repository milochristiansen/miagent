// Session archives: the CLI's gzip-compressed tar files, the naming rules for
// /new and /compact, and the atomic file operations around them.
package harness

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

TAR_BLOCK :: 512
ARCHIVE_PREFIX :: "prepak-"
NEW_ARCHIVE_PREFIX :: "archive-"
ARCHIVE_EXT :: ".tar.gz"
SESSION_NAME_ENTRY :: "session-name.md"

PERM_0644 :: os.Permissions{.Read_User, .Read_Group, .Read_Other, .Write_User}

Archive_Entry :: struct {
	name:    string,
	content: string,
}

archive_entries_destroy :: proc(entries: []Archive_Entry) {
	for &e in entries {
		delete(e.name)
		delete(e.content)
	}
	delete(entries)
}

// --- time / names ----------------------------------------------------------

utc_stamp :: proc(t: time.Time) -> string {
	dt, ok := time.time_to_datetime(t)
	if !ok do return "19700101T000000Z"
	return fmt.aprintf("%04d%02d%02dT%02d%02d%02dZ",
		dt.year, int(dt.month), dt.day, int(dt.hour), int(dt.minute), int(dt.second))
}

utc_rfc3339 :: proc(t: time.Time) -> string {
	dt, ok := time.time_to_datetime(t)
	if !ok do return "1970-01-01T00:00:00Z"
	return fmt.aprintf("%04d-%02d-%02dT%02d:%02d:%02dZ",
		dt.year, int(dt.month), dt.day, int(dt.hour), int(dt.minute), int(dt.second))
}

stamp_display :: proc(stamp: string) -> string {
	if len(stamp) != 16 do return stamp
	return fmt.aprintf("%s-%s-%s %s:%s:%sZ",
		stamp[0:4], stamp[4:6], stamp[6:8], stamp[9:11], stamp[11:13], stamp[13:15])
}

is_digit :: proc(c: u8) -> bool { return c >= '0' && c <= '9' }

stamp_at :: proc(s: string, offset: int) -> bool {
	if offset + 16 > len(s) do return false
	if s[offset + 8] != 'T' || s[offset + 15] != 'Z' do return false
	for i in 0 ..< 8 do if !is_digit(s[offset + i]) do return false
	for i in 9 ..< 15 do if !is_digit(s[offset + i]) do return false
	return true
}

archive_name_for :: proc(base: string, stamp: string) -> string {
	if len(base) > 1 && base[0] == '.' {
		return fmt.aprintf(".%s%s-%s", ARCHIVE_PREFIX, stamp, base[1:])
	}
	return fmt.aprintf("%s%s-%s", ARCHIVE_PREFIX, stamp, base)
}

new_archive_name :: proc(stamp: string, collision: int) -> string {
	if collision <= 0 do return fmt.aprintf("%s%s%s", NEW_ARCHIVE_PREFIX, stamp, ARCHIVE_EXT)
	return fmt.aprintf("%s%s-%d%s", NEW_ARCHIVE_PREFIX, stamp, collision, ARCHIVE_EXT)
}

is_new_archive_name :: proc(name: string) -> bool {
	if !strings.has_prefix(name, NEW_ARCHIVE_PREFIX) do return false
	pos := len(NEW_ARCHIVE_PREFIX)
	if !stamp_at(name, pos) do return false
	pos += 16
	if strings.has_prefix(name[pos:], ARCHIVE_EXT) do return true
	if !strings.has_prefix(name[pos:], "-") do return false
	pos += 1
	start := pos
	for pos < len(name) && is_digit(name[pos]) do pos += 1
	return pos > start && strings.has_prefix(name[pos:], ARCHIVE_EXT)
}

// is_compaction_archive_for reports whether name is a compaction archive made
// from session_base (including the -N collision suffix and a leading dot).
is_compaction_archive_for :: proc(name, session_base: string) -> bool {
	hidden := ""
	rest := session_base
	if len(rest) > 1 && rest[0] == '.' {
		hidden = "."
		rest = rest[1:]
	}
	ext := os.ext(rest)
	stem := strings.trim_suffix(rest, ext)
	prefix := fmt.aprintf("%s%s", hidden, ARCHIVE_PREFIX)
	if !strings.has_prefix(name, prefix) do return false
	pos := len(prefix)
	if !stamp_at(name, pos) do return false
	pos += 16
	expected := fmt.aprintf("-%s", stem)
	if !strings.has_prefix(name[pos:], expected) do return false
	pos += len(expected)
	// ext, or -N + ext
	if strings.has_prefix(name[pos:], ext) do return true
	if !strings.has_prefix(name[pos:], "-") do return false
	pos += 1
	start := pos
	for pos < len(name) && is_digit(name[pos]) do pos += 1
	return pos > start && strings.has_prefix(name[pos:], ext)
}

is_compaction_archive_name :: proc(name: string) -> bool {
	pos := 0
	if len(name) > 0 && name[0] == '.' do pos = 1
	if !strings.has_prefix(name[pos:], ARCHIVE_PREFIX) do return false
	pos += len(ARCHIVE_PREFIX)
	return stamp_at(name, pos)
}

// --- tar writing -----------------------------------------------------------

put_octal :: proc(block: []u8, offset, width: int, value: i64) {
	for i in 0 ..< width do block[offset + i] = '0'
	block[offset + width - 1] = 0
	if value <= 0 do return
	s := fmt.aprintf("%o", value)
	defer delete(s)
	start := offset + width - 1 - len(s)
	if start < offset do start = offset
	copy(block[start:offset + width - 1], s)
}

tar_header :: proc(buf: ^[dynamic]u8, name: string, size: int, mod_unix: i64, typeflag: u8 = '0') -> string {
	if len(name) > 100 do return fmt.aprintf("archive entry name too long: %s", name)
	block: [TAR_BLOCK]u8
	copy(block[0:100], name)
	put_octal(block[:], 100, 8, 0o644)
	put_octal(block[:], 108, 8, 0)
	put_octal(block[:], 116, 8, 0)
	put_octal(block[:], 124, 12, i64(size))
	put_octal(block[:], 136, 12, mod_unix)
	copy(block[148:156], []u8{' ', ' ', ' ', ' ', ' ', ' ', ' ', ' '})
	block[156] = typeflag
	copy(block[257:263], []u8{'u', 's', 't', 'a', 'r', 0})
	copy(block[263:265], []u8{'0', '0'})
	sum := 0
	for b in block do sum += int(b)
	chk := fmt.aprintf("%06o", sum)
	defer delete(chk)
	copy(block[148:154], chk)
	block[154] = 0
	block[155] = ' '
	append(buf, ..block[:])
	return ""
}

pax_record_length :: proc(payload_len: int) -> int {
	n := payload_len + 2
	for {
		digits := len(fmt.aprintf("%d", n))
		next := digits + 1 + payload_len
		if next == n do return n
		n = next
	}
}

tar_add :: proc(buf: ^[dynamic]u8, name: string, data: []byte, mod_unix: i64) -> string {
	if len(name) > 100 {
		payload := fmt.aprintf("path=%s\n", name)
		rec_len := pax_record_length(len(payload))
		record := fmt.aprintf("%d %s", rec_len, payload)
		pax_name := fmt.aprintf("PaxHeaders/%s", name[:min(len(name), 80)])
		err := tar_header(buf, pax_name, len(record), mod_unix, 'x')
		delete(pax_name)
		if err != "" {
			delete(payload)
			delete(record)
			return err
		}
		append(buf, ..transmute([]byte)record)
		pad := (TAR_BLOCK - (len(record) % TAR_BLOCK)) % TAR_BLOCK
		for _ in 0 ..< pad do append(buf, 0)
		delete(payload)
		delete(record)
		// The regular header's name is ignored by PAX-aware readers; keep a
		// bounded prefix so the archive stays sane for older readers too.
		err = tar_header(buf, name[:100], len(data), mod_unix)
		if err != "" do return err
	} else {
		if err := tar_header(buf, name, len(data), mod_unix); err != "" do return err
	}
	append(buf, ..data)
	pad := (TAR_BLOCK - (len(data) % TAR_BLOCK)) % TAR_BLOCK
	for _ in 0 ..< pad do append(buf, 0)
	return ""
}

tar_finish :: proc(buf: ^[dynamic]u8) {
	for _ in 0 ..< TAR_BLOCK * 2 do append(buf, 0)
}

archive_pack :: proc(path: string, files: []string, entries: []Archive_Entry) -> string {
	buf := make([dynamic]u8, 0, 64 * 1024)
	defer delete(buf)

	for file in files {
		data, err := os.read_entire_file(file, context.allocator)
		if err != nil do return fmt.aprintf("reading %s: %v", file, err)
		mtime: i64 = 0
		if st, serr := os.stat(file, context.temp_allocator); serr == nil {
			mtime = time.to_unix_seconds(st.modification_time)
		}
		werr := tar_add(&buf, os.base(file), data, mtime)
		delete(data)
		if werr != "" do return werr
	}
	for e in entries {
		werr := tar_add(&buf, e.name, transmute([]byte)e.content, time.to_unix_seconds(time.now()))
		if werr != "" do return werr
	}
	tar_finish(&buf)

	compressed: ^u8
	compressed_len: uint
	rc := mi_gzip_compress(raw_data(buf), uint(len(buf)), &compressed, &compressed_len)
	if rc != 0 do return "compressing archive"
	defer mi_free(rawptr(compressed))

	f, err := os.open(path, {.Create, .Excl, .Write}, PERM_0644)
	if err != nil do return fmt.aprintf("creating %s: %v", path, err)
	ok := false
	defer {
		os.close(f)
		if !ok do os.remove(path)
	}
	cptr := cast([^]u8)compressed
	if _, werr := os.write(f, cptr[:compressed_len]); werr != nil do return fmt.aprintf("writing %s: %v", path, werr)
	if serr := os.sync(f); serr != nil do return fmt.aprintf("syncing %s: %v", path, serr)
	ok = true
	return ""
}

// --- tar reading -----------------------------------------------------------

field_string :: proc(block: []u8) -> string {
	end := 0
	for end < len(block) && block[end] != 0 do end += 1
	return strings.clone(string(block[:end]))
}

parse_octal :: proc(block: []u8) -> int {
	start := 0
	for start < len(block) && (block[start] == 0 || block[start] == ' ') do start += 1
	end := len(block)
	for end > start && (block[end - 1] == 0 || block[end - 1] == ' ') do end -= 1
	if start == end do return 0
	n, ok := strconv.parse_int(string(block[start:end]), 8)
	if !ok do return 0
	return n
}

pax_path :: proc(data: string) -> string {
	i := 0
	for i < len(data) {
		sp := strings.index_byte(data[i:], ' ')
		if sp <= 0 do break
		rec_len, ok := strconv.parse_int(data[i:i + sp])
		if !ok || rec_len <= 0 || i + rec_len > len(data) do break
		rec := data[i + sp + 1:i + rec_len - 1] // drop trailing newline
		if eq := strings.index_byte(rec, '='); eq >= 0 {
			key := rec[:eq]
			value := rec[eq + 1:]
			if key == "path" do return value
		}
		i += rec_len
	}
	return ""
}

archive_unpack_data :: proc(data: []byte, want: string) -> ([]Archive_Entry, string) {
	raw_ptr: ^u8
	raw_len: uint
	if mi_gzip_decompress(raw_data(data), uint(len(data)), &raw_ptr, &raw_len) != 0 {
		return nil, "gzip decompression failed"
	}
	if raw_ptr == nil do return nil, "gzip decompression failed"
	defer mi_free(rawptr(raw_ptr))
	raw_view := cast([^]u8)raw_ptr
	raw := raw_view[:raw_len]

	entries := make([dynamic]Archive_Entry, 0, 8)
	offset := 0
	pending_name := ""
	for offset + TAR_BLOCK <= len(raw) {
		block := raw[offset:offset + TAR_BLOCK]
		all_zero := true
		for b in block {
			if b != 0 { all_zero = false; break }
		}
		if all_zero do break

		name := field_string(block[0:100])
		prefix := field_string(block[345:500])
		if len(prefix) > 0 {
			joined := fmt.aprintf("%s/%s", prefix, name)
			delete(name)
			name = joined
		}
		delete(prefix)
		size := parse_octal(block[124:136])
		typeflag := block[156]
		data_start := offset + TAR_BLOCK
		if size < 0 || data_start + size > len(raw) {
			delete(name)
			return nil, "truncated tar archive"
		}

		if typeflag == 'x' || typeflag == 'g' {
			if typeflag == 'x' {
				if p := pax_path(string(raw[data_start:data_start + size])); len(p) > 0 {
					delete(pending_name)
					pending_name = strings.clone(p)
				}
			}
			delete(name)
			offset = data_start + ((size + TAR_BLOCK - 1) / TAR_BLOCK) * TAR_BLOCK
			continue
		}
		if typeflag == 'L' {
			delete(pending_name)
			pending_name = strings.clone(string(raw[data_start:data_start + size]))
			delete(name)
			offset = data_start + ((size + TAR_BLOCK - 1) / TAR_BLOCK) * TAR_BLOCK
			continue
		}
		if len(pending_name) > 0 {
			delete(name)
			name = strings.clone(pending_name)
			delete(pending_name)
			pending_name = ""
		}
		if typeflag == '0' || typeflag == 0 {
			clean := strings.trim_prefix(name, "./")
			if len(want) == 0 || clean == want {
				content := strings.clone(string(raw[data_start:data_start + size]))
				append(&entries, Archive_Entry{name = strings.clone(clean), content = content})
				if len(want) > 0 {
					delete(name)
					break
				}
			}
		}
		delete(name)
		offset = data_start + ((size + TAR_BLOCK - 1) / TAR_BLOCK) * TAR_BLOCK
	}
	delete(pending_name)
	return entries[:], ""
}

archive_read :: proc(path: string, want := "") -> ([]Archive_Entry, string) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return nil, fmt.aprintf("reading %s: %v", path, err)
	defer delete(data)
	entries, uerr := archive_unpack_data(data, want)
	if uerr != "" do return nil, fmt.aprintf("reading %s: %s", path, uerr)
	return entries, ""
}

archive_description :: proc(path: string) -> (string, string) {
	entries, err := archive_read(path, SESSION_NAME_ENTRY)
	if err != "" do return "", err
	defer archive_entries_destroy(entries)
	if len(entries) == 0 do return "", ""
	return strings.clone(strings.trim_space(entries[0].content)), ""
}

// --- filesystem helpers ----------------------------------------------------

unique_path :: proc(dir, stem, ext: string) -> (string, string) {
	for i in 0 ..< 1000 {
		name := i == 0 ? fmt.aprintf("%s%s", stem, ext) : fmt.aprintf("%s-%d%s", stem, i, ext)
		path := join_path(dir, name)
		delete(name)
		if !os.exists(path) do return path, ""
		delete(path)
	}
	return "", fmt.aprintf("cannot find a free name for %s%s in %s", stem, ext, dir)
}

copy_file :: proc(src, dst: string) -> string {
	src_file, err := os.open(src)
	if err != nil do return fmt.aprintf("opening %s: %v", src, err)
	defer os.close(src_file)
	mode := PERM_0644
	if st, serr := os.stat(src, context.temp_allocator); serr == nil do mode = st.mode
	out, oerr := os.open(dst, {.Create, .Excl, .Write}, mode)
	if oerr != nil do return fmt.aprintf("creating %s: %v", dst, oerr)
	ok := false
	defer {
		os.close(out)
		if !ok do os.remove(dst)
	}
	buf: [64 * 1024]u8
	for {
		n, rerr := os.read(src_file, buf[:])
		if n > 0 {
			if _, werr := os.write(out, buf[:n]); werr != nil do return fmt.aprintf("copying %s: %v", src, werr)
		}
		if rerr != nil || n == 0 do break
	}
	if serr := os.sync(out); serr != nil do return fmt.aprintf("syncing %s: %v", dst, serr)
	ok = true
	return ""
}

archive_session :: proc(session_path: string) -> (string, string) {
	stamp := utc_stamp(time.now())
	name := archive_name_for(os.base(session_path), stamp)
	ext := os.ext(name)
	stem := strings.trim_suffix(name, ext)
	target, terr := unique_path(os.dir(session_path), stem, ext)
	if terr != "" do return "", terr
	if cerr := copy_file(session_path, target); cerr != "" {
		os.remove(target)
		return "", cerr
	}
	return target, ""
}

// retire_files renames originals out of their live names before deleting
// them. If any rename fails, the already-renamed files are moved back. This
// keeps /new from leaving a half-removed session when one path is not
// removable.
retire_files :: proc(paths: []string) -> ([]string, string) {
	if len(paths) == 0 do return nil, ""
	suffix := fmt.aprintf(".archived-%d-%d", os.get_pid(), time.to_unix_nanoseconds(time.now()))
	defer delete(suffix)
	retired := make([dynamic]string, 0, len(paths))
	for path, i in paths {
		target := fmt.aprintf("%s%s-%d", path, suffix, i)
		if rerr := os.rename(path, target); rerr != nil {
			for j := len(retired) - 1; j >= 0; j -= 1 {
				_ = os.rename(retired[j], paths[j])
			}
			for p in retired do delete(p)
			delete(retired)
			delete(target)
			return nil, fmt.aprintf("renaming %s: %v", path, rerr)
		}
		append(&retired, target)
	}
	return retired[:], ""
}

remove_files :: proc(paths: []string) -> string {
	failures := make([dynamic]string, 0, 2)
	defer delete(failures)
	for path in paths {
		if err := os.remove(path); err != nil {
			append(&failures, fmt.aprintf("%s: %v", path, err))
		}
	}
	if len(failures) > 0 do return strings.join(failures[:], "; ")
	return ""
}

write_restored_file :: proc(path, content: string) -> string {
	f, err := os.open(path, {.Create, .Excl, .Write}, PERM_0644)
	if err != nil do return fmt.aprintf("creating %s: %v", path, err)
	ok := false
	defer {
		os.close(f)
		if !ok do os.remove(path)
	}
	if _, werr := os.write(f, transmute([]byte)content); werr != nil do return fmt.aprintf("writing %s: %v", path, werr)
	if serr := os.sync(f); serr != nil do return fmt.aprintf("syncing %s: %v", path, serr)
	ok = true
	return ""
}

write_session_file :: proc(path: string, content: []byte) -> string {
	dir := os.dir(path)
	mode := PERM_0644
	if st, err := os.stat(path, context.temp_allocator); err == nil do mode = st.mode
	tmp := ""
	f: ^os.File
	for i in 0 ..< 100 {
		candidate := fmt.aprintf("%s.tmp-%d-%d-%d", path, os.get_pid(), time.to_unix_nanoseconds(time.now()), i)
		ff, err := os.open(candidate, {.Create, .Excl, .Write}, mode)
		if err == nil {
			f = ff
			tmp = candidate
			break
		}
		delete(candidate)
	}
	if f == nil do return fmt.aprintf("creating temporary session file in %s", dir)
	ok := false
	defer {
		if f != nil do os.close(f)
		if !ok && len(tmp) > 0 do os.remove(tmp)
	}
	if _, err := os.write(f, content); err != nil do return fmt.aprintf("writing session: %v", err)
	if err := os.sync(f); err != nil do return fmt.aprintf("syncing session: %v", err)
	os.close(f)
	f = nil
	if err := os.rename(tmp, path); err != nil {
		os.remove(tmp)
		return fmt.aprintf("replacing %s: %v", path, err)
	}
	ok = true
	// Best-effort directory sync, matching the CLI's durability intent.
	if d, derr := os.open(dir); derr == nil {
		_ = os.sync(d)
		os.close(d)
	}
	return ""
}

// --- reports ---------------------------------------------------------------

plural :: proc(n: int, singular, plural_word: string) -> string {
	return n == 1 ? singular : plural_word
}

commas :: proc(n: int) -> string {
	s := fmt.aprintf("%d", n)
	defer delete(s)
	if len(s) <= 3 do return strings.clone(s)
	b := strings.builder_make()
	head := len(s) % 3
	if head == 0 do head = 3
	strings.write_string(&b, s[:head])
	for i := head; i < len(s); i += 3 {
		strings.write_byte(&b, ',')
		strings.write_string(&b, s[i:i + 3])
	}
	return strings.to_string(b)
}

human_bytes :: proc(n: i64) -> string {
	switch {
	case n < 1024: return fmt.aprintf("%d B", n)
	case n < 1024 * 1024: return fmt.aprintf("%.1f KB", f64(n) / 1024.0)
	case: return fmt.aprintf("%.1f MB", f64(n) / (1024.0 * 1024.0))
	}
}

one_line :: proc(s: string) -> string {
	fields := strings.fields(s)
	defer delete(fields)
	return strings.join(fields[:], " ")
}

// --- archive packing sets --------------------------------------------------

Session_Files :: struct {
	path:     string,
	archives: []string,
	empty:    bool,
}

session_files_destroy :: proc(f: ^Session_Files) {
	for a in f.archives do delete(a)
	delete(f.archives)
}

session_files_all :: proc(f: Session_Files) -> []string {
	out := make([dynamic]string, 0, len(f.archives) + 1)
	if len(f.path) > 0 do append(&out, f.path)
	append(&out, ..f.archives)
	return out[:]
}

session_files_describe :: proc(f: Session_Files) -> string {
	switch {
	case len(f.path) == 0 && len(f.archives) == 0:
		return strings.clone("nothing")
	case len(f.archives) == 0:
		return strings.clone(f.path)
	case len(f.path) == 0:
		return fmt.aprintf("%d session %s", len(f.archives), plural(len(f.archives), "archive", "archives"))
	case:
		return fmt.aprintf("%s and %d session %s", f.path, len(f.archives), plural(len(f.archives), "archive", "archives"))
	}
}

session_pack_files :: proc(path: string) -> (Session_Files, string) {
	f := Session_Files{}
	dir := os.dir(path)
	if st, err := os.stat(path, context.temp_allocator); err == nil {
		if st.size == 0 {
			f.empty = true
		} else {
			f.path = strings.clone(path)
		}
	} else if !os.exists(path) {
		// A missing explicit session path is reported by the caller.
	} else {
		return f, fmt.aprintf("session file: %v", err)
	}

	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		if !os.exists(dir) do return f, ""
		return f, fmt.aprintf("reading %s: %v", dir, err)
	}
	archives := make([dynamic]string, 0, 4)
	for entry in entries {
		if entry.type == .Directory do continue
		if is_compaction_archive_for(entry.name, os.base(path)) {
			append(&archives, strings.clone(entry.fullpath))
		}
	}
	// Names carry their timestamp; lexical order is oldest first.
	for i in 1 ..< len(archives) {
		j := i
		for j > 0 && archives[j] < archives[j - 1] {
			archives[j], archives[j - 1] = archives[j - 1], archives[j]
			j -= 1
		}
	}
	f.archives = archives[:]
	return f, ""
}

// --- archive listing -------------------------------------------------------

Archived_Session :: struct {
	name:        string,
	path:        string,
	stamp:       string,
	description: string,
}

archived_sessions_destroy :: proc(items: []Archived_Session) {
	for &a in items {
		delete(a.name)
		delete(a.path)
		delete(a.description)
	}
	delete(items)
}

list_archived_sessions :: proc(dir: string) -> ([]Archived_Session, string) {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		if !os.exists(dir) do return nil, ""
		return nil, fmt.aprintf("reading %s: %v", dir, err)
	}
	out := make([dynamic]Archived_Session, 0, 8)
	for entry in entries {
		if entry.type == .Directory || !is_new_archive_name(entry.name) do continue
		stamp := entry.name[len(NEW_ARCHIVE_PREFIX):len(NEW_ARCHIVE_PREFIX) + 16]
		desc, derr := archive_description(entry.fullpath)
		if derr != "" {
			archived_sessions_destroy(out[:])
			return nil, fmt.aprintf("reading %s: %s", entry.name, derr)
		}
		append(&out, Archived_Session{
			name = strings.clone(entry.name),
			path = strings.clone(entry.fullpath),
			stamp = strings.clone(stamp),
			description = desc,
		})
	}
	for i in 1 ..< len(out) {
		j := i
		for j > 0 && (out[j].stamp < out[j - 1].stamp || (out[j].stamp == out[j - 1].stamp && out[j].name < out[j - 1].name)) {
			out[j], out[j - 1] = out[j - 1], out[j]
			j -= 1
		}
	}
	return out[:], ""
}

// --- session-file content --------------------------------------------------

compacted_session_bytes :: proc(rec: compaction_record, items: []StoredItem) -> ([]byte, string) {
	b := strings.builder_make()
	data, err := json.marshal(rec)
	if err != nil {
		delete(b.buf)
		return nil, fmt.aprintf("encoding compaction record: %v", err)
	}
	strings.write_bytes(&b, data)
	strings.write_byte(&b, '\n')
	delete(data)
	for it in items {
		idata, ierr := json.marshal(it)
		if ierr != nil {
			delete(b.buf)
			return nil, fmt.aprintf("encoding session item: %v", ierr)
		}
		strings.write_bytes(&b, idata)
		strings.write_byte(&b, '\n')
		delete(idata)
	}
	out := strings.to_string(b)
	copied := make([]byte, len(out))
	copy(copied, out)
	delete(b.buf)
	return copied, ""
}
