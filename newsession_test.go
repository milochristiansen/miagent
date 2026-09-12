package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// TestSessionArchivePattern covers which files /new considers part of a
// session: its own compaction archives and nothing else.
func TestSessionArchivePattern(t *testing.T) {
	cases := []struct {
		session string
		name    string
		want    bool
	}{
		// A dot-named session's archives carry the dot in front.
		{".session.jsonl", ".prepak-20260910T024512Z-session.jsonl", true},
		{".session.jsonl", ".prepak-20260910T024512Z-session-1.jsonl", true},
		{".session.jsonl", ".prepak-20260910T024512Z-session-10.jsonl", true},
		{".session.jsonl", "prepak-20260910T024512Z-session.jsonl", false}, // dot lost
		{".session.jsonl", ".prepak-20260910T024512Z-sessions.jsonl", false},
		{".session.jsonl", ".prepak-20260910T024512Z-session.jsonl.bak", false},
		{".session.jsonl", ".prepak-20260910T024512Z-.session.jsonl", false}, // the old naming
		{".session.jsonl", ".prepak-notatimestamp-session.jsonl", false},
		{".session.jsonl", "archive-20260910T024512Z.tar.gz", false}, // a /new archive
		{".session.jsonl", ".session.jsonl", false},                  // the session itself

		{"session.jsonl", "prepak-20260910T024512Z-session.jsonl", true},
		{"session.jsonl", "prepak-20260910T024512Z-session-2.jsonl", true},
		{"session.jsonl", "prepak-20260910T024512Z-session.jsonl.tmp", false},

		// One session's archives are not another's, and a name that merely
		// contains the subject does not match.
		{"chat.jsonl", "prepak-20260910T024512Z-chat.jsonl", true},
		{"chat.jsonl", "prepak-20260910T024512Z-session.jsonl", false},
		{"log", "prepak-20260910T024512Z-log", true},
		{"log", "prepak-20260910T024512Z-catalog", false},
	}
	for _, tc := range cases {
		got := sessionArchivePattern(tc.session).MatchString(tc.name)
		if got != tc.want {
			t.Errorf("sessionArchivePattern(%q).MatchString(%q) = %v, want %v",
				tc.session, tc.name, got, tc.want)
		}
	}
}

// TestArchiveSessionKeepsTheSessionFile covers what a compaction depends on:
// the archive is a copy, so the session file is still at its path while the
// compacted replacement is prepared and renamed over it. A move would leave the
// path empty for that interval, and a crash there would lose the session.
func TestArchiveSessionKeepsTheSessionFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "session.jsonl")
	content := []byte(`{"role":"user","content":"hi"}` + "\n")
	if err := os.WriteFile(path, content, 0o600); err != nil {
		t.Fatal(err)
	}

	archive, err := archiveSession(path)
	if err != nil {
		t.Fatalf("archiveSession: %v", err)
	}
	if filepath.Dir(archive) != dir {
		t.Fatalf("archive %q is not beside the session", archive)
	}
	if base := filepath.Base(archive); !strings.HasPrefix(base, archivePrefix) {
		t.Fatalf("archive %q does not carry the archive prefix", base)
	}

	got, err := os.ReadFile(archive)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, content) {
		t.Fatalf("archive = %q, want a copy of the session", got)
	}
	still, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("the session file is gone after archiving: %v", err)
	}
	if !bytes.Equal(still, content) {
		t.Fatalf("session file = %q, want it untouched", still)
	}
	if st, err := os.Stat(archive); err != nil {
		t.Fatal(err)
	} else if st.Mode().Perm() != 0o600 {
		t.Fatalf("archive mode = %v, want the session file's", st.Mode().Perm())
	}
}

// TestSessionPackFilesSkipsEmptySession covers the session file the
// writability check leaves behind when a run fails before its first commit: it
// holds no exchange, so /new has nothing to pack, nothing to remove, and says
// so instead of reporting a file that is sitting right there as missing.
func TestSessionPackFilesSkipsEmptySession(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "session.jsonl")
	if err := os.WriteFile(path, nil, 0o644); err != nil {
		t.Fatal(err)
	}

	files, err := sessionPackFiles(path)
	if err != nil {
		t.Fatal(err)
	}
	if files.path != "" {
		t.Fatalf("session path = %q, want an empty session not packed", files.path)
	}
	if !files.empty {
		t.Fatal("empty = false, want the empty session reported")
	}
	if len(files.all()) != 0 {
		t.Fatalf("all() = %v, want nothing to pack", files.all())
	}

	// /new reports it as empty and leaves it alone.
	var out string
	out = captureStdout(t, func() {
		if err := cmdNew(context.Background(), nil, newSession(path), newDisplay(), nil); err != nil {
			t.Fatalf("cmdNew: %v", err)
		}
	})
	if !strings.Contains(out, "nothing to archive: "+path+" holds no exchanges yet") {
		t.Fatalf("output = %q, want the empty session reported", out)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("the empty session file was removed: %v", err)
	}
	if entries, err := os.ReadDir(dir); err != nil {
		t.Fatal(err)
	} else if len(entries) != 1 {
		t.Fatalf("/new left %d entries, want just the empty session", len(entries))
	}
}

// TestSessionPackFiles covers the collection step: the session file, its
// compaction archives, and nothing else in the directory.
func TestSessionPackFiles(t *testing.T) {
	dir := t.TempDir()
	write := func(name string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(dir, name), []byte(name), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// A dot-named session with two compaction archives, plus files that
	// must not be packed: another session's archive, a previous /new
	// archive, and an unrelated file.
	for _, name := range []string{
		".session.jsonl",
		".prepak-20260101T000000Z-session.jsonl",
		".prepak-20260102T000000Z-session.jsonl",
		".prepak-20260102T000000Z-session-1.jsonl",
		".prepak-20260101T000000Z-other.jsonl",
		"archive-20260103T000000Z.tar.gz",
		"notes.txt",
	} {
		write(name)
	}

	files, err := sessionPackFiles(filepath.Join(dir, ".session.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	if files.path != filepath.Join(dir, ".session.jsonl") {
		t.Fatalf("session path = %q", files.path)
	}
	var got []string
	for _, p := range files.archives {
		got = append(got, filepath.Base(p))
	}
	want := []string{
		".prepak-20260101T000000Z-session.jsonl",
		".prepak-20260102T000000Z-session-1.jsonl",
		".prepak-20260102T000000Z-session.jsonl",
	}
	sort.Strings(want)
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("archives = %v, want %v", got, want)
	}
	// Names sort by their timestamp, so the order is deterministic (and the
	// earliest archive leads) even though a collision suffix sorts oddly.
	if !strings.Contains(filepath.Base(files.archives[0]), "20260101T000000Z") {
		t.Fatalf("archives = %v, want the earliest first", got)
	}
	if all := files.all(); len(all) != 4 || all[0] != files.path {
		t.Fatalf("all() = %v, want the session file first then its archives", all)
	}
}

// TestCmdNewEndToEnd covers /new: the session file and its compaction
// archives end up inside one archive, the originals are gone, the session is
// empty afterwards, and a later exchange writes a fresh session file.
func TestCmdNewEndToEnd(t *testing.T) {
	dir := t.TempDir()
	t.Chdir(dir)

	// The naming prompt and a stub endpoint that returns a fixed name, so
	// /new stores a session-name.md alongside the packed files.
	prompts := promptsFixture(t)
	if err := os.WriteFile(filepath.Join(prompts, sessionNamePromptName), []byte("Name this session.\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"status":"completed","output":[{"type":"message","role":"assistant",` +
			`"content":[{"type":"output_text","text":"Adding session naming to /new"}]}]}`))
	}))
	t.Cleanup(srv.Close)
	prov := &provider{client: newTestClient(srv.URL), model: "stub"}

	// A session with a conversation and two compaction archives, one of
	// them from another session (which must survive).
	sessionPath := filepath.Join(dir, stateDir, "session.jsonl")
	if err := os.MkdirAll(filepath.Dir(sessionPath), 0o755); err != nil {
		t.Fatal(err)
	}
	s := newSession(sessionPath)
	s.Items = []StoredItem{
		{Role: "user", Content: "hello"},
		{Role: "assistant", Content: "hi"},
	}
	s.Usages = []Usage{{InputTokens: 10, OutputTokens: 2, AtItems: 1}}
	if err := s.commit(); err != nil {
		t.Fatal(err)
	}
	prepak1 := filepath.Join(dir, stateDir, "prepak-20260101T000000Z-session.jsonl")
	prepak2 := filepath.Join(dir, stateDir, "prepak-20260102T000000Z-session.jsonl")
	other := filepath.Join(dir, stateDir, "prepak-20260101T000000Z-other.jsonl")
	for _, p := range []string{prepak1, prepak2, other} {
		if err := os.WriteFile(p, []byte("archived: "+filepath.Base(p)+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	wantContents := map[string]string{}
	for _, p := range []string{sessionPath, prepak1, prepak2} {
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		wantContents[filepath.Base(p)] = string(b)
	}

	out := captureStdout(t, func() {
		if err := cmdNew(context.Background(), prov, s, newDisplay(), nil); err != nil {
			t.Fatalf("cmdNew: %v", err)
		}
	})
	if !strings.Contains(out, "archived 3 files") || !strings.Contains(out, "next prompt starts a new session") {
		t.Fatalf("output = %q", out)
	}

	// The originals are gone, the other session's archive is untouched.
	for _, p := range []string{sessionPath, prepak1, prepak2} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Fatalf("%s still exists after /new", filepath.Base(p))
		}
	}
	if _, err := os.Stat(other); err != nil {
		t.Fatalf("another session's archive was removed: %v", err)
	}

	// Exactly one archive, holding the session and both of its archives
	// byte for byte.
	archives, err := filepath.Glob(filepath.Join(dir, stateDir, "archive-*.tar.gz"))
	if err != nil || len(archives) != 1 {
		t.Fatalf("archives = %v (err %v), want exactly one", archives, err)
	}
	got := readTarGz(t, archives[0])
	// The packed files plus the generated session-name.md entry.
	if len(got) != len(wantContents)+1 {
		t.Fatalf("archive holds %d files (%v), want %d", len(got), keys(got), len(wantContents)+1)
	}
	for name, want := range wantContents {
		if got[name] != want {
			t.Fatalf("archive entry %s = %q, want %q", name, got[name], want)
		}
	}
	if got[sessionNameArchiveEntry] != "Adding session naming to /new\n" {
		t.Fatalf("archive entry %s = %q, want the generated name", sessionNameArchiveEntry, got[sessionNameArchiveEntry])
	}

	// The session in memory is empty.
	if len(s.Items) != 0 || len(s.Usages) != 0 || s.Compacted || s.Carried != (Usage{}) {
		t.Fatalf("session not reset: %d items, %d usages, compacted=%v", len(s.Items), len(s.Usages), s.Compacted)
	}

	// A second /new now has no session file to pack, and says so rather than
	// writing an empty archive.
	out = captureStdout(t, func() {
		if err := cmdNew(context.Background(), nil, s, newDisplay(), nil); err != nil {
			t.Fatalf("second cmdNew: %v", err)
		}
	})
	if !strings.Contains(out, "nothing to archive") {
		t.Fatalf("second /new output = %q, want nothing to archive", out)
	}
	if archives, _ := filepath.Glob(filepath.Join(dir, stateDir, "archive-*.tar.gz")); len(archives) != 1 {
		t.Fatalf("second /new wrote an archive: %v", archives)
	}

	// A new exchange starts a new session file, holding only that exchange.
	s.Items = append(s.Items, StoredItem{Role: "user", Content: "fresh start"})
	if err := s.commit(); err != nil {
		t.Fatalf("commit after /new: %v", err)
	}
	fresh, err := os.ReadFile(sessionPath)
	if err != nil {
		t.Fatalf("the session file was not recreated: %v", err)
	}
	if want := `{"role":"user","content":"fresh start"}` + "\n"; string(fresh) != want {
		t.Fatalf("new session file = %q, want just the new exchange %q", fresh, want)
	}
}

// TestCmdNewLeavesFilesOnFailure covers the promise that /new never deletes
// what it could not archive: an unreadable file fails the pack with every
// original still in place and no partial archive behind.
func TestCmdNewLeavesFilesOnFailure(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("file permissions do not bind root")
	}
	dir := t.TempDir()
	sessionPath := filepath.Join(dir, "session.jsonl")
	if err := os.WriteFile(sessionPath, []byte("conversation\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	// A prepak file the process cannot read: the pack must fail.
	unreadable := filepath.Join(dir, "prepak-20260101T000000Z-session.jsonl")
	if err := os.WriteFile(unreadable, []byte("archived\n"), 0o000); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(unreadable, 0o644)

	s := newSession(sessionPath)
	if err := cmdNew(context.Background(), nil, s, newDisplay(), nil); err == nil {
		t.Fatal("cmdNew succeeded with an unreadable file")
	}

	for _, p := range []string{sessionPath, unreadable} {
		if _, err := os.Stat(p); err != nil {
			t.Fatalf("%s was removed despite the failure: %v", filepath.Base(p), err)
		}
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), archiveExt) {
			t.Fatalf("a failed /new left %s behind", e.Name())
		}
	}
}

// TestConfigDir covers the config directory resolution: XDG_CONFIG_HOME when it
// holds an absolute path, and ~/.config otherwise — the XDG rule being that an
// empty or relative value is ignored rather than resolved against the working
// directory.
func TestConfigDir(t *testing.T) {
	t.Run("absolute XDG_CONFIG_HOME", func(t *testing.T) {
		dir := t.TempDir()
		t.Setenv("XDG_CONFIG_HOME", dir)
		got, err := configDir()
		if err != nil {
			t.Fatalf("configDir: %v", err)
		}
		if want := filepath.Join(dir, configName); got != want {
			t.Fatalf("configDir = %q, want %q", got, want)
		}
	})

	t.Run("unset falls back to ~/.config", func(t *testing.T) {
		t.Setenv("XDG_CONFIG_HOME", "")
		home := t.TempDir()
		t.Setenv("HOME", home)
		got, err := configDir()
		if err != nil {
			t.Fatalf("configDir: %v", err)
		}
		if want := filepath.Join(home, ".config", configName); got != want {
			t.Fatalf("configDir = %q, want %q", got, want)
		}
	})

	t.Run("relative is ignored", func(t *testing.T) {
		t.Setenv("XDG_CONFIG_HOME", "relative/path")
		home := t.TempDir()
		t.Setenv("HOME", home)
		got, err := configDir()
		if err != nil {
			t.Fatalf("configDir: %v", err)
		}
		if want := filepath.Join(home, ".config", configName); got != want {
			t.Fatalf("configDir = %q, want the default, not a working-directory path", got)
		}
	})
}

// TestLoadEnv covers the environment precedence: the state directory's .env
// overrides the core one in the configuration directory, and an exported
// variable overrides both.
func TestLoadEnv(t *testing.T) {
	root := t.TempDir()
	t.Chdir(root)
	config := configFixture(t)
	if err := os.Mkdir(stateDir, 0o755); err != nil {
		t.Fatal(err)
	}
	write := func(path, content string) {
		t.Helper()
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write(filepath.Join(config, ".env"), "MIAGENT_TEST_A=core\nMIAGENT_TEST_B=core\n")
	write(filepath.Join(stateDir, ".env"), "MIAGENT_TEST_B=state\nMIAGENT_TEST_C=state\n")

	// Set and unset only what this test touches.
	t.Setenv("MIAGENT_TEST_A", "")
	os.Unsetenv("MIAGENT_TEST_A")
	os.Unsetenv("MIAGENT_TEST_B")
	os.Unsetenv("MIAGENT_TEST_C")
	t.Cleanup(func() {
		os.Unsetenv("MIAGENT_TEST_A")
		os.Unsetenv("MIAGENT_TEST_B")
		os.Unsetenv("MIAGENT_TEST_C")
	})

	if err := loadEnv(stateDir); err != nil {
		t.Fatalf("loadEnv: %v", err)
	}
	if got := os.Getenv("MIAGENT_TEST_A"); got != "core" {
		t.Fatalf("A = %q, want the configuration directory's value", got)
	}
	if got := os.Getenv("MIAGENT_TEST_B"); got != "state" {
		t.Fatalf("B = %q, want the state directory to override the core file", got)
	}
	if got := os.Getenv("MIAGENT_TEST_C"); got != "state" {
		t.Fatalf("C = %q, want the state directory's own value", got)
	}

	// An exported variable wins over both files.
	if err := os.Setenv("MIAGENT_TEST_B", "exported"); err != nil {
		t.Fatal(err)
	}
	if err := loadEnv(stateDir); err != nil {
		t.Fatalf("loadEnv: %v", err)
	}
	if got := os.Getenv("MIAGENT_TEST_B"); got != "exported" {
		t.Fatalf("B = %q, want the exported value to survive", got)
	}

	// Missing files are fine; a malformed one is reported, naming the file.
	if err := os.Remove(filepath.Join(config, ".env")); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(stateDir, ".env")); err != nil {
		t.Fatal(err)
	}
	if err := loadEnv(stateDir); err != nil {
		t.Fatalf("loadEnv with no env files: %v", err)
	}
	write(filepath.Join(stateDir, ".env"), "this line has no assignment\n")
	err := loadEnv(stateDir)
	if err == nil {
		t.Fatal("loadEnv accepted a malformed .env")
	}
	if !strings.Contains(err.Error(), filepath.Join(stateDir, ".env")) {
		t.Fatalf("error = %v, want it to name the file", err)
	}
}

// TestSessionFilesDescribe covers the sentence /new reports after deleting:
// which files it names, for each combination of session file and archives.
func TestSessionFilesDescribe(t *testing.T) {
	cases := []struct {
		files sessionFiles
		want  string
	}{
		{sessionFiles{}, "nothing"},
		{sessionFiles{path: "s.jsonl"}, "s.jsonl"},
		{sessionFiles{archives: []string{"a"}}, "1 session archive"},
		{sessionFiles{archives: []string{"a", "b"}}, "2 session archives"},
		{sessionFiles{path: "s.jsonl", archives: []string{"a"}}, "s.jsonl and 1 session archive"},
		{sessionFiles{path: "s.jsonl", archives: []string{"a", "b"}}, "s.jsonl and 2 session archives"},
	}
	for _, tc := range cases {
		if got := tc.files.describe(); got != tc.want {
			t.Errorf("describe() = %q, want %q", got, tc.want)
		}
	}
}

// TestCmdNewArchivesOnly covers the state left when a session file is gone but
// its compaction archives remain: /new still packs what is there. The session
// has no in-memory prompt to name, so no model call is needed.
func TestCmdNewArchivesOnly(t *testing.T) {
	dir := t.TempDir()
	sessionPath := filepath.Join(dir, "session.jsonl")
	prepak := filepath.Join(dir, "prepak-20260101T000000Z-session.jsonl")
	if err := os.WriteFile(prepak, []byte("archived\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	s := newSession(sessionPath)
	out := captureStdout(t, func() {
		if err := cmdNew(context.Background(), nil, s, newDisplay(), nil); err != nil {
			t.Fatalf("cmdNew: %v", err)
		}
	})
	if !strings.Contains(out, "archived 1 file") || !strings.Contains(out, "removed 1 session archive") {
		t.Fatalf("output = %q", out)
	}
	if _, err := os.Stat(prepak); !os.IsNotExist(err) {
		t.Fatal("the archive was not removed")
	}
	archives, err := filepath.Glob(filepath.Join(dir, "archive-*.tar.gz"))
	if err != nil || len(archives) != 1 {
		t.Fatalf("archives = %v (err %v), want exactly one", archives, err)
	}
	if got := readTarGz(t, archives[0]); got["prepak-20260101T000000Z-session.jsonl"] != "archived\n" {
		t.Fatalf("archive contents = %v", got)
	}
}

// TestHumanBytes covers the sizes /new reports.
func TestHumanBytes(t *testing.T) {
	cases := map[int64]string{
		0:           "0 B",
		512:         "512 B",
		2048:        "2.0 KB",
		5 << 20:     "5.0 MB",
		3 << 30:     "3072.0 MB",
		1024 * 1024: "1.0 MB",
		1024 * 1023: "1023.0 KB",
	}
	for n, want := range cases {
		if got := humanBytes(n); got != want {
			t.Errorf("humanBytes(%d) = %q, want %q", n, got, want)
		}
	}
}

// readTarGz returns the contents of a gzip-compressed tar archive, keyed by
// entry name.
func readTarGz(t *testing.T, path string) map[string]string {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		t.Fatal(err)
	}
	defer gz.Close()

	out := map[string]string{}
	tr := tar.NewReader(gz)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		b, err := io.ReadAll(tr)
		if err != nil {
			t.Fatal(err)
		}
		out[hdr.Name] = string(b)
	}
	return out
}

func keys(m map[string]string) []string {
	var out []string
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
