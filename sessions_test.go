package main

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// writeTarGz writes a gzip-compressed tar archive holding the given entries.
func writeTarGz(t *testing.T, path string, entries []archiveEntry) {
	t.Helper()
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	gz := gzip.NewWriter(f)
	tw := tar.NewWriter(gz)
	for _, e := range entries {
		if err := addContentToArchive(tw, e.name, e.content); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
}

// TestNewArchivePattern covers which files /sessions considers archives: the
// names /new builds, with the collision suffix uniquePath may add, and nothing
// else.
func TestNewArchivePattern(t *testing.T) {
	cases := []struct {
		name string
		ok   bool
	}{
		{"archive-20260912T133000Z.tar.gz", true},
		{"archive-20260912T133000Z-1.tar.gz", true},
		{"archive-20260912T133000Z-10.tar.gz", true},
		{"archive-20260912T133000Z.tar", false},
		{"archive-20260912T133000Z.tgz", false},
		{"archive-20260912T133000.tar.gz", false}, // no trailing Z
		{"archive-20260912T133000Z-.tar.gz", false},
		{"archive-20260912T133000Z.tar.gz.bak", false},
		{"xarchive-20260912T133000Z.tar.gz", false},
		{"prepak-20260912T133000Z-session.jsonl", false},
		{"archive-20260912T133000Z", false},
	}
	for _, tc := range cases {
		if got := newArchivePattern.MatchString(tc.name); got != tc.ok {
			t.Errorf("newArchivePattern.MatchString(%q) = %v, want %v", tc.name, got, tc.ok)
		}
	}

	// The timestamp is captured and parses back to the UTC time the name
	// encodes.
	m := newArchivePattern.FindStringSubmatch("archive-20260912T133000Z-1.tar.gz")
	if len(m) != 2 || m[1] != "20260912T133000Z" {
		t.Fatalf("FindStringSubmatch = %v, want the captured timestamp", m)
	}
	got, err := time.Parse(archiveStampLayout, m[1])
	if err != nil {
		t.Fatalf("time.Parse(%q): %v", m[1], err)
	}
	if want := time.Date(2026, 9, 12, 13, 30, 0, 0, time.UTC); !got.Equal(want) {
		t.Fatalf("parsed %v, want %v", got, want)
	}
}

// TestArchiveDescription covers reading the stored session name: the entry when
// present, empty when the archive holds none, and an error for an archive that
// cannot be read.
func TestArchiveDescription(t *testing.T) {
	dir := t.TempDir()

	with := filepath.Join(dir, "with.tar.gz")
	writeTarGz(t, with, []archiveEntry{
		{name: "session.jsonl", content: "{}"},
		{name: sessionNameArchiveEntry, content: "  A named session.\n"},
	})
	got, err := archiveDescription(with)
	if err != nil {
		t.Fatalf("archiveDescription: %v", err)
	}
	if got != "A named session." {
		t.Fatalf("description = %q, want it trimmed", got)
	}

	without := filepath.Join(dir, "without.tar.gz")
	writeTarGz(t, without, []archiveEntry{{name: "session.jsonl", content: "{}"}})
	if got, err = archiveDescription(without); err != nil || got != "" {
		t.Fatalf("description = %q, err = %v; want empty with no error", got, err)
	}

	// A hand-packed archive may prefix entries with "./"; the description is
	// still found.
	dotted := filepath.Join(dir, "dotted.tar.gz")
	writeTarGz(t, dotted, []archiveEntry{
		{name: "./session.jsonl", content: "{}"},
		{name: "./" + sessionNameArchiveEntry, content: "Dotted name\n"},
	})
	if got, err = archiveDescription(dotted); err != nil || got != "Dotted name" {
		t.Fatalf("description = %q, err = %v; want the ./ entry found", got, err)
	}

	if _, err := archiveDescription(filepath.Join(dir, "missing.tar.gz")); err == nil {
		t.Fatal("archiveDescription accepted a missing archive")
	}
}

// TestCmdSessionsListsByDate covers the listing: header, oldest-first order,
// one-line descriptions, the placeholder when an archive holds none, and the
// exclusion of files that are not /new archives.
func TestCmdSessionsListsByDate(t *testing.T) {
	dir := t.TempDir()
	write := func(name string, entries []archiveEntry) {
		t.Helper()
		writeTarGz(t, filepath.Join(dir, name), entries)
	}
	write("archive-20260301T000000Z.tar.gz", []archiveEntry{
		{name: "session.jsonl", content: "{}"},
		{name: sessionNameArchiveEntry, content: "March work\n"},
	})
	write("archive-20260101T000000Z.tar.gz", []archiveEntry{
		{name: "session.jsonl", content: "{}"},
	})
	write("archive-20260201T000000Z.tar.gz", []archiveEntry{
		{name: "session.jsonl", content: "{}"},
		{name: sessionNameArchiveEntry, content: "Feb\nwork\n"},
	})
	// Files the listing must not pick up.
	for _, name := range []string{"prepak-20250101T000000Z-session.jsonl", "notes.txt"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	sess := newSession(filepath.Join(dir, "session.jsonl"))
	var out string
	out = captureStdout(t, func() {
		if err := cmdSessions(context.Background(), nil, sess, newDisplay(), nil); err != nil {
			t.Fatalf("cmdSessions: %v", err)
		}
	})

	if !strings.Contains(out, "archived sessions in "+dir+" (3):") {
		t.Fatalf("output = %q, want a header naming the directory and count", out)
	}
	jan := strings.Index(out, "archive-20260101T000000Z.tar.gz")
	feb := strings.Index(out, "archive-20260201T000000Z.tar.gz")
	mar := strings.Index(out, "archive-20260301T000000Z.tar.gz")
	if jan < 0 || feb < 0 || mar < 0 || !(jan < feb && feb < mar) {
		t.Fatalf("output = %q, want the archives oldest first", out)
	}
	if !strings.Contains(out, "2026-01-01 00:00:00Z  archive-20260101T000000Z.tar.gz  (no description)") {
		t.Errorf("January line missing or wrong:\n%s", out)
	}
	if !strings.Contains(out, "archive-20260201T000000Z.tar.gz  Feb work") {
		t.Errorf("February description not collapsed to one line:\n%s", out)
	}
	if !strings.Contains(out, "archive-20260301T000000Z.tar.gz  March work") {
		t.Errorf("March description missing:\n%s", out)
	}
	if strings.Contains(out, "prepak-") || strings.Contains(out, "notes.txt") {
		t.Errorf("output lists a file that is not a /new archive:\n%s", out)
	}
}

// TestCmdSessionsNoArchives covers the empty listing, including a directory
// that does not exist yet.
func TestCmdSessionsNoArchives(t *testing.T) {
	dir := t.TempDir()
	sess := newSession(filepath.Join(dir, "session.jsonl"))
	var out string
	out = captureStdout(t, func() {
		if err := cmdSessions(context.Background(), nil, sess, newDisplay(), nil); err != nil {
			t.Fatalf("cmdSessions: %v", err)
		}
	})
	if want := "no archived sessions in " + dir + "\n"; out != want {
		t.Fatalf("stdout = %q, want %q", out, want)
	}

	sess = newSession(filepath.Join(dir, "gone", "session.jsonl"))
	out = captureStdout(t, func() {
		if err := cmdSessions(context.Background(), nil, sess, newDisplay(), nil); err != nil {
			t.Fatalf("cmdSessions: %v", err)
		}
	})
	if !strings.Contains(out, "no archived sessions") {
		t.Fatalf("stdout = %q, want no archived sessions", out)
	}
}

// TestCmdSessionsRejectsArguments keeps the command's contract with the
// dispatcher.
func TestCmdSessionsRejectsArguments(t *testing.T) {
	sess := newSession(filepath.Join(t.TempDir(), "session.jsonl"))
	if err := cmdSessions(context.Background(), nil, sess, newDisplay(), []string{"x"}); err == nil {
		t.Fatal("cmdSessions accepted an argument, want an error")
	}
}

// TestResolveArchivePath covers how /load finds a session: a bare name beside
// the session file, a path as given, and a miss that names what it tried.
func TestResolveArchivePath(t *testing.T) {
	dir := t.TempDir()
	name := "archive-20260101T000000Z.tar.gz"
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	if got, err := resolveArchivePath(dir, name); err != nil || got != path {
		t.Fatalf("resolveArchivePath(%q, %q) = %q, %v; want %q", dir, name, got, err, path)
	}
	if got, err := resolveArchivePath(dir, path); err != nil || got != path {
		t.Fatalf("resolveArchivePath(%q, %q) = %q, %v; want %q", dir, path, got, err, path)
	}

	sub := filepath.Join(dir, "sub")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	subPath := filepath.Join(sub, "a.tar.gz")
	if err := os.WriteFile(subPath, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got, err := resolveArchivePath(dir, filepath.Join("sub", "a.tar.gz")); err != nil || got != subPath {
		t.Fatalf("resolveArchivePath relative path = %q, %v; want %q", got, err, subPath)
	}

	if _, err := resolveArchivePath(dir, "nope.tar.gz"); err == nil {
		t.Fatal("resolveArchivePath accepted a missing archive")
	}
}

// TestCmdSessionsReadsNewArchives is the round trip: /new writes an archive and
// /sessions lists it under the description it stored.
func TestCmdSessionsReadsNewArchives(t *testing.T) {
	dir := t.TempDir()
	t.Chdir(dir)

	prompts := promptsFixture(t)
	if err := os.WriteFile(filepath.Join(prompts, sessionNamePromptName), []byte("Name it.\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"status":"completed","output":[{"type":"message","role":"assistant",` +
			`"content":[{"type":"output_text","text":"Interop session"}]}]}`))
	}))
	t.Cleanup(srv.Close)
	prov := &provider{client: newTestClient(srv.URL), model: "stub"}

	sessionPath := filepath.Join(dir, stateDir, "session.jsonl")
	if err := os.MkdirAll(filepath.Dir(sessionPath), 0o755); err != nil {
		t.Fatal(err)
	}
	s := newSession(sessionPath)
	s.Items = []StoredItem{{Role: "user", Content: "hello"}}
	if err := s.commit(); err != nil {
		t.Fatal(err)
	}
	captureStdout(t, func() {
		if err := cmdNew(context.Background(), prov, s, newDisplay(), nil); err != nil {
			t.Fatalf("cmdNew: %v", err)
		}
	})

	var out string
	out = captureStdout(t, func() {
		if err := cmdSessions(context.Background(), nil, newSession(sessionPath), newDisplay(), nil); err != nil {
			t.Fatalf("cmdSessions: %v", err)
		}
	})
	if !strings.Contains(out, "Interop session") || !strings.Contains(out, "archive-") {
		t.Fatalf("output = %q, want the /new archive listed with its name", out)
	}
}

// TestCmdLoadEndToEnd covers /load: the current session is retired through
// /new, and the named archive is unpacked in its place — session file,
// compaction archives, and in-memory state.
func TestCmdLoadEndToEnd(t *testing.T) {
	dir := t.TempDir()
	t.Chdir(dir)

	prompts := promptsFixture(t)
	if err := os.WriteFile(filepath.Join(prompts, sessionNamePromptName), []byte("Name this session.\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"status":"completed","output":[{"type":"message","role":"assistant",` +
			`"content":[{"type":"output_text","text":"Work being retired"}]}]}`))
	}))
	t.Cleanup(srv.Close)
	prov := &provider{client: newTestClient(srv.URL), model: "stub"}

	sessionPath := filepath.Join(dir, stateDir, "session.jsonl")
	if err := os.MkdirAll(filepath.Dir(sessionPath), 0o755); err != nil {
		t.Fatal(err)
	}
	cur := newSession(sessionPath)
	cur.Items = []StoredItem{
		{Role: "user", Content: "current work"},
		{Role: "assistant", Content: "ok"},
	}
	cur.Usages = []Usage{{InputTokens: 5, OutputTokens: 1, AtItems: 2}}
	if err := cur.commit(); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(sessionPath)
	if err != nil {
		t.Fatal(err)
	}

	target := filepath.Join(dir, stateDir, "archive-20260101T000000Z.tar.gz")
	loaded := `{"role":"user","content":"loaded work"}` + "\n" +
		`{"role":"assistant","content":"hello again"}` + "\n"
	writeTarGz(t, target, []archiveEntry{
		{name: "session.jsonl", content: loaded},
		{name: "prepak-20251231T000000Z-session.jsonl", content: "older archive\n"},
		{name: sessionNameArchiveEntry, content: "Earlier session\n"},
	})

	var out string
	out = captureStdout(t, func() {
		if err := cmdLoad(context.Background(), prov, cur, newDisplay(), []string{filepath.Base(target)}); err != nil {
			t.Fatalf("cmdLoad: %v", err)
		}
	})
	if !strings.Contains(out, "archived 1 file") {
		t.Errorf("output = %q, want the current session retired through /new", out)
	}
	if !strings.Contains(out, "loaded "+target) {
		t.Errorf("output = %q, want the loaded archive named", out)
	}

	// The current session was archived, name and all.
	archives, err := filepath.Glob(filepath.Join(dir, stateDir, "archive-*.tar.gz"))
	if err != nil || len(archives) != 2 {
		t.Fatalf("archives = %v (err %v), want the target plus the one /new wrote", archives, err)
	}
	var newArchive string
	for _, a := range archives {
		if a != target {
			newArchive = a
		}
	}
	if newArchive == "" {
		t.Fatal("the current session was not archived")
	}
	packed := readTarGz(t, newArchive)
	if packed["session.jsonl"] != string(before) {
		t.Fatalf("the retired session file = %q, want %q", packed["session.jsonl"], before)
	}
	if packed[sessionNameArchiveEntry] != "Work being retired\n" {
		t.Fatalf("the retired name = %q, want the generated one", packed[sessionNameArchiveEntry])
	}

	// The target was unpacked: session file at the configured path, its
	// compaction archive restored beside it.
	got, err := os.ReadFile(sessionPath)
	if err != nil || string(got) != loaded {
		t.Fatalf("session file = %q (err %v), want the loaded %q", got, err, loaded)
	}
	prepak := filepath.Join(dir, stateDir, "prepak-20251231T000000Z-session.jsonl")
	if b, err := os.ReadFile(prepak); err != nil || string(b) != "older archive\n" {
		t.Fatalf("restored compaction archive = %q (err %v)", b, err)
	}

	// The in-memory session matches, and is committed, so the next exchange
	// appends to the loaded file rather than rewriting it.
	if len(cur.Items) != 2 || cur.Items[0].Content != "loaded work" || cur.Items[1].Content != "hello again" {
		t.Fatalf("session items = %+v, want the loaded conversation", cur.Items)
	}
	cur.Items = append(cur.Items, StoredItem{Role: "user", Content: "next turn"})
	if err := cur.commit(); err != nil {
		t.Fatal(err)
	}
	after, err := os.ReadFile(sessionPath)
	if err != nil {
		t.Fatal(err)
	}
	if want := loaded + `{"role":"user","content":"next turn"}` + "\n"; string(after) != want {
		t.Fatalf("session after appending = %q, want %q", after, want)
	}
}

// TestCmdLoadMapsSessionFileToConfiguredPath covers loading an archive whose
// session file was named differently: it lands at the configured session path.
func TestCmdLoadMapsSessionFileToConfiguredPath(t *testing.T) {
	dir := t.TempDir()
	sessionPath := filepath.Join(dir, "current.jsonl")
	sess := newSession(sessionPath)

	target := filepath.Join(dir, "archive-20260101T000000Z.tar.gz")
	// A "./" prefix, as a hand-packed archive may carry, is normalized away.
	writeTarGz(t, target, []archiveEntry{
		{name: "./other.jsonl", content: `{"role":"user","content":"hi"}` + "\n"},
	})

	var out string
	out = captureStdout(t, func() {
		if err := cmdLoad(context.Background(), nil, sess, newDisplay(), []string{filepath.Base(target)}); err != nil {
			t.Fatalf("cmdLoad: %v", err)
		}
	})
	if _, err := os.Stat(sessionPath); err != nil {
		t.Fatalf("the session was not written at the configured path: %v", err)
	}
	if len(sess.Items) != 1 || sess.Items[0].Content != "hi" {
		t.Fatalf("session items = %+v, want the loaded conversation", sess.Items)
	}
	if !strings.Contains(out, "loaded ") {
		t.Fatalf("output = %q, want the loaded archive named", out)
	}
}

// TestCmdLoadLeavesSessionOnBadArchive covers the promise that a /load which
// cannot proceed leaves the current session exactly as it was: the target is
// read and checked before /new retires anything.
func TestCmdLoadLeavesSessionOnBadArchive(t *testing.T) {
	dir := t.TempDir()
	sessionPath := filepath.Join(dir, "session.jsonl")
	content := []byte(`{"role":"user","content":"keep me"}` + "\n")
	if err := os.WriteFile(sessionPath, content, 0o644); err != nil {
		t.Fatal(err)
	}
	sess := newSession(sessionPath)
	if err := sess.load(); err != nil {
		t.Fatal(err)
	}

	// No provider: if /load reached /new it would panic, which is the point.
	if err := cmdLoad(context.Background(), nil, sess, newDisplay(), []string{"missing.tar.gz"}); err == nil {
		t.Fatal("cmdLoad succeeded with a missing archive")
	}
	if len(sess.Items) != 1 || sess.Items[0].Content != "keep me" {
		t.Fatalf("in-memory session changed: %+v", sess.Items)
	}
	got, err := os.ReadFile(sessionPath)
	if err != nil || string(got) != string(content) {
		t.Fatalf("session file = %q (err %v), want it untouched", got, err)
	}
	if archives, _ := filepath.Glob(filepath.Join(dir, "archive-*.tar.gz")); len(archives) != 0 {
		t.Fatalf("a failed /load wrote %v", archives)
	}
}

// TestCmdLoadRejectsBadSessionFile covers an archive whose session file does
// not parse: the current session is left alone.
func TestCmdLoadRejectsBadSessionFile(t *testing.T) {
	dir := t.TempDir()
	sessionPath := filepath.Join(dir, "session.jsonl")
	content := []byte(`{"role":"user","content":"keep me"}` + "\n")
	if err := os.WriteFile(sessionPath, content, 0o644); err != nil {
		t.Fatal(err)
	}
	sess := newSession(sessionPath)
	if err := sess.load(); err != nil {
		t.Fatal(err)
	}

	target := filepath.Join(dir, "archive-20260101T000000Z.tar.gz")
	writeTarGz(t, target, []archiveEntry{{name: "session.jsonl", content: "not session records\n"}})
	if err := cmdLoad(context.Background(), nil, sess, newDisplay(), []string{filepath.Base(target)}); err == nil {
		t.Fatal("cmdLoad accepted a session file that does not parse")
	}
	if got, err := os.ReadFile(sessionPath); err != nil || string(got) != string(content) {
		t.Fatalf("session file = %q (err %v), want it untouched", got, err)
	}
	if len(sess.Items) != 1 {
		t.Fatalf("in-memory session changed: %+v", sess.Items)
	}
}

// TestCmdLoadRejectsUnsafeEntryNames keeps an entry from escaping the session
// directory.
func TestCmdLoadRejectsUnsafeEntryNames(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "archive-20260101T000000Z.tar.gz")
	writeTarGz(t, target, []archiveEntry{
		{name: "session.jsonl", content: `{"role":"user","content":"x"}` + "\n"},
		{name: "prepak-20260101T000000Z-../evil.jsonl", content: "x\n"},
	})
	sess := newSession(filepath.Join(dir, "session.jsonl"))
	if err := cmdLoad(context.Background(), nil, sess, newDisplay(), []string{filepath.Base(target)}); err == nil {
		t.Fatal("cmdLoad accepted an entry that escapes the session directory")
	}
	if _, err := os.Stat(filepath.Join(dir, "evil.jsonl")); !os.IsNotExist(err) {
		t.Fatal("a failed /load wrote outside the session directory")
	}
}

// TestCmdLoadRejectsArchiveWithoutSessionFile covers an archive that holds only
// metadata and compaction files.
func TestCmdLoadRejectsArchiveWithoutSessionFile(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "archive-20260101T000000Z.tar.gz")
	writeTarGz(t, target, []archiveEntry{
		{name: sessionNameArchiveEntry, content: "named\n"},
		{name: "prepak-20260101T000000Z-session.jsonl", content: "x\n"},
	})
	sess := newSession(filepath.Join(dir, "session.jsonl"))
	if err := cmdLoad(context.Background(), nil, sess, newDisplay(), []string{filepath.Base(target)}); err == nil {
		t.Fatal("cmdLoad accepted an archive with no session file")
	}
}

// TestCmdLoadRejectsWrongArgumentCount keeps the command's contract with the
// dispatcher.
func TestCmdLoadRejectsWrongArgumentCount(t *testing.T) {
	sess := newSession(filepath.Join(t.TempDir(), "session.jsonl"))
	for _, args := range [][]string{nil, {"a", "b"}} {
		if err := cmdLoad(context.Background(), nil, sess, newDisplay(), args); err == nil {
			t.Errorf("cmdLoad%v accepted, want an error", args)
		}
	}
}
