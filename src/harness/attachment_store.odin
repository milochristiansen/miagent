// Per-session content-addressed attachment storage.
//
// Attachment bytes live outside session.jsonl. The session stores a SHA-256
// blob id; this module writes, validates, and reads the blobs. Every session
// file gets its own attachments directory so archives, cleanup, and manual
// inspection can treat a session as one unit.
package harness

import crypto_hash "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

ATTACHMENT_STORE_DIR :: "attachments"
ATTACHMENT_BLOB_HEX_LEN :: 64

Attachment_Store :: struct {
	dir: string,
}

attachment_key_char :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-'
}

// attachment_session_key turns "session-2.jsonl" into "session-2". The name is
// deliberately based only on the session filename: two sessions in the same
// directory must never share a blob directory.
attachment_session_key :: proc(session_path: string) -> string {
	base := os.base(session_path)
	ext := os.ext(base)
	stem := strings.trim_suffix(base, ext)
	if len(stem) == 0 do stem = "session"
	b := strings.builder_make()
	for i in 0 ..< len(stem) {
		c := stem[i]
		if attachment_key_char(c) {
			strings.write_byte(&b, c)
		} else {
			strings.write_byte(&b, '_')
		}
	}
	key := strings.clone(strings.to_string(b))
	delete(b.buf)
	if len(key) == 0 || key == "." || key == ".." {
		delete(key)
		return strings.clone("session")
	}
	return key
}

attachment_store_dir :: proc(session_path: string) -> string {
	key := attachment_session_key(session_path)
	defer delete(key)
	dir := os.dir(session_path)
	if len(dir) == 0 do dir = "."
	return join_path(dir, ATTACHMENT_STORE_DIR, key)
}

attachment_store_init :: proc(session_path: string) -> Attachment_Store {
	return Attachment_Store{dir = attachment_store_dir(session_path)}
}

attachment_store_destroy :: proc(store: ^Attachment_Store) {
	delete(store.dir)
	store^ = {}
}

attachment_blob_id :: proc(data: []byte) -> string {
	digest: [32]byte
	crypto_hash.hash_bytes_to_buffer(.SHA256, data, digest[:])
	id_bytes, err := hex.encode(digest[:])
	if err != nil do return ""
	id := strings.clone(string(id_bytes))
	delete(id_bytes)
	return id
}

attachment_store_valid_id :: proc(id: string) -> bool {
	if len(id) != ATTACHMENT_BLOB_HEX_LEN do return false
	for i in 0 ..< len(id) {
		c := id[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) do return false
	}
	return true
}

attachment_store_path :: proc(store: ^Attachment_Store, id: string) -> string {
	return join_path(store.dir, id)
}

attachment_store_has :: proc(store: ^Attachment_Store, id: string) -> bool {
	if !attachment_store_valid_id(id) do return false
	path := attachment_store_path(store, id)
	defer delete(path)
	return os.exists(path)
}

attachment_store_put :: proc(store: ^Attachment_Store, data: []byte) -> (id: string, err: string) {
	id = attachment_blob_id(data)
	if len(id) == 0 do return "", "hashing attachment"
	if attachment_store_has(store, id) do return id, ""

	if !os.exists(store.dir) {
		if derr := os.make_directory_all(store.dir); derr != nil {
			delete(id)
			return "", fmt.aprintf("creating attachment store %s: %v", store.dir, derr)
		}
	}

	final := attachment_store_path(store, id)
	defer delete(final)
	tmp := ""
	f: ^os.File
	for i in 0 ..< 100 {
		candidate := fmt.aprintf("%s.tmp-%d-%d-%d", final, os.get_pid(), time.to_unix_nanoseconds(time.now()), i)
		ff, oerr := os.open(candidate, {.Create, .Excl, .Write}, PERM_0644)
		if oerr == nil {
			f = ff
			tmp = candidate
			break
		}
		delete(candidate)
	}
	if f == nil {
		delete(id)
		return "", fmt.aprintf("creating temporary attachment in %s", store.dir)
	}
	ok := false
	defer {
		if f != nil do os.close(f)
		if !ok do os.remove(tmp)
		delete(tmp)
	}

	written := 0
	for written < len(data) {
		n, werr := os.write(f, data[written:])
		if werr != nil || n <= 0 {
			delete(id)
			return "", fmt.aprintf("writing attachment blob: %v", werr)
		}
		written += n
	}
	if serr := os.sync(f); serr != nil {
		delete(id)
		return "", fmt.aprintf("syncing attachment blob: %v", serr)
	}
	os.close(f)
	f = nil
	if attachment_store_has(store, id) {
		// Another writer won the race. The bytes are content-addressed, so the
		// existing file is equivalent.
		os.remove(tmp)
		ok = true
		return id, ""
	}
	if rerr := os.rename(tmp, final); rerr != nil {
		delete(id)
		return "", fmt.aprintf("installing attachment blob: %v", rerr)
	}
	ok = true
	return id, ""
}

attachment_store_get :: proc(store: ^Attachment_Store, id: string) -> (data: []byte, err: string) {
	if !attachment_store_valid_id(id) do return nil, "invalid attachment blob id"
	path := attachment_store_path(store, id)
	defer delete(path)
	blob_data, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		if os.exists(path) do return nil, fmt.aprintf("reading attachment blob %s: %v", id, rerr)
		return nil, fmt.aprintf("attachment blob %s is missing", id)
	}
	return blob_data, ""
}

// attachment_store_read_text returns a blob as text. It is used for text
// attachments and for externalized tool-output bodies.
attachment_store_read_text :: proc(store: ^Attachment_Store, id: string) -> (text: string, err: string) {
	data, derr := attachment_store_get(store, id)
	if len(derr) > 0 do return "", derr
	text = strings.clone(string(data))
	delete(data)
	return text, ""
}

attachment_store_remove_all :: proc(store: ^Attachment_Store) -> string {
	if len(store.dir) == 0 do return ""
	if err := os.remove_all(store.dir); err != nil && os.exists(store.dir) {
		return fmt.aprintf("removing %s: %v", store.dir, err)
	}
	return ""
}

attachment_store_size :: proc(store: ^Attachment_Store) -> i64 {
	total: i64 = 0
	entries, err := os.read_all_directory_by_path(store.dir, context.temp_allocator)
	if err != nil do return 0
	for e in entries {
		if e.type == .Regular do total += e.size
	}
	return total
}
