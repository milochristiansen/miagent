// Archived sessions: /sessions lists the archives /new has written beside the
// session file, and /load replaces the current session with one of them. Both
// work on the archive files rather than on the session's conversation, and
// /load retires the session it replaces with /new first, so the conversation
// being left behind is archived rather than lost.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// newArchivePattern matches the archives /new writes in a session directory:
// newArchivePrefix followed by the timestamp archiveStampLayout writes, with
// the -N collision suffix uniquePath may add. The timestamp is captured so a
// listing can date an archive from its name alone.
var newArchivePattern = regexp.MustCompile(
	`^` + regexp.QuoteMeta(newArchivePrefix) + `(\d{8}T\d{6}Z)(?:-\d+)?` +
		regexp.QuoteMeta(archiveExt) + `$`)

// compactionArchiveName matches an entry /new packed from a compaction
// archive: the names archiveName builds, including the -N collision suffix
// uniquePath may add. It is not anchored to one session name, so /load
// recognizes a packed archive whatever the session was called when it was
// written.
var compactionArchiveName = regexp.MustCompile(
	`^\.?` + regexp.QuoteMeta(archivePrefix) + `\d{8}T\d{6}Z-`)

// archivedSession is one /new archive as /sessions lists it: the file's name,
// its path, when its name says it was written, and the description it holds
// (empty when it holds none).
type archivedSession struct {
	name        string
	path        string
	when        time.Time
	description string
}

// cmdSessions lists the session archives beside the session file, oldest
// first, dated by the timestamp each name carries and described by the
// session-name.md stored inside it when there is one. It reads the archives
// and writes nothing.
func cmdSessions(_ context.Context, _ *provider, sess *Session, d *display, args []string) error {
	if len(args) > 0 {
		return fmt.Errorf("takes no arguments")
	}
	dir, err := sessionArchiveDir(sess)
	if err != nil {
		return err
	}
	archives, err := listArchivedSessions(dir)
	if err != nil {
		return err
	}
	if len(archives) == 0 {
		d.info(fmt.Sprintf("no archived sessions in %s\n", dir))
		return nil
	}

	var b strings.Builder
	fmt.Fprintf(&b, "archived sessions in %s (%d):\n", dir, len(archives))
	for _, a := range archives {
		desc := oneLine(a.description)
		if desc == "" {
			desc = "(no description)"
		}
		fmt.Fprintf(&b, "  %s  %s  %s\n", a.when.UTC().Format("2006-01-02 15:04:05Z"), a.name, desc)
	}
	d.info(b.String())
	return nil
}

// listArchivedSessions returns the archives /new wrote in dir, oldest first.
// A missing directory is no archives rather than an error: a session that was
// never retired has no archive directory to read either.
func listArchivedSessions(dir string) ([]archivedSession, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var archives []archivedSession
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		m := newArchivePattern.FindStringSubmatch(entry.Name())
		if m == nil {
			continue
		}
		when, err := time.Parse(archiveStampLayout, m[1])
		if err != nil {
			// The pattern guarantees the shape, so this cannot happen; a
			// name that somehow got through is skipped rather than dated
			// wrongly.
			continue
		}
		a := archivedSession{name: entry.Name(), path: filepath.Join(dir, entry.Name()), when: when}
		if a.description, err = archiveDescription(a.path); err != nil {
			return nil, fmt.Errorf("reading %s: %w", a.name, err)
		}
		archives = append(archives, a)
	}
	sort.Slice(archives, func(i, j int) bool {
		if !archives[i].when.Equal(archives[j].when) {
			return archives[i].when.Before(archives[j].when)
		}
		return archives[i].name < archives[j].name
	})
	return archives, nil
}

// archiveDescription returns the session description an archive holds as
// sessionNameArchiveEntry, or "" when it holds none (a session archived
// without a user prompt to name). Only that entry is read; the session file
// and compaction archives beside it in the stream are skipped.
func archiveDescription(path string) (string, error) {
	desc, ok, err := readArchiveEntry(path, sessionNameArchiveEntry)
	if err != nil {
		return "", err
	}
	if !ok {
		return "", nil
	}
	return strings.TrimSpace(desc), nil
}

// cmdLoad replaces the current session with an archived one. The session being
// replaced is retired with /new first, exactly as /new alone would do, and the
// chosen archive is then unpacked into its place: its session file is written
// at the configured session path, its compaction archives are restored beside
// it, and the in-memory session is reloaded from the result.
//
// The archive is read and checked before anything is retired, so a missing or
// malformed one leaves the current session untouched.
func cmdLoad(ctx context.Context, prov *provider, sess *Session, d *display, args []string) error {
	if len(args) != 1 {
		return fmt.Errorf("takes one session (an archive name or path)")
	}
	dir, err := sessionArchiveDir(sess)
	if err != nil {
		return err
	}
	target, err := resolveArchivePath(dir, args[0])
	if err != nil {
		return err
	}
	entries, err := readArchive(target)
	if err != nil {
		return fmt.Errorf("reading %s: %w", target, err)
	}
	sessionFile, extra, sessionName, err := splitArchive(entries)
	if err != nil {
		return fmt.Errorf("reading %s: %w", target, err)
	}
	if err := checkArchiveNames(extra); err != nil {
		return fmt.Errorf("reading %s: %w", target, err)
	}
	// A session file that cannot be parsed must not be adopted: the current
	// session is still in place, so this is the point to refuse.
	var probe Session
	if err := probe.loadFrom(strings.NewReader(sessionFile)); err != nil {
		return fmt.Errorf("reading %s (%s): %w", target, sessionName, err)
	}

	// Retire the session being replaced, exactly as /new would: a conversation
	// being left behind is archived, not discarded.
	if err := cmdNew(ctx, prov, sess, d, nil); err != nil {
		return err
	}

	// Restore the compaction archives first and the session file last, so the
	// session path is written only once everything it sits beside is in
	// place, and a crash mid-load leaves an empty session rather than one
	// whose history is half-restored.
	for _, e := range extra {
		if err := writeRestoredFile(filepath.Join(dir, e.name), e.content); err != nil {
			return fmt.Errorf("restoring %s: %w", e.name, err)
		}
	}
	if err := writeSessionFile(sess.path, []byte(sessionFile)); err != nil {
		return fmt.Errorf("writing %s: %w", sess.path, err)
	}
	if err := sess.load(); err != nil {
		return fmt.Errorf("loading %s: %w", sess.path, err)
	}

	d.info(fmt.Sprintf("loaded %s (%d %s); the next prompt continues it\n",
		target, len(sess.Items), plural(len(sess.Items), "item", "items")))
	return nil
}

// splitArchive separates the entries of a session archive into the session
// file's content, the compaction archives to restore beside it, and the name
// of the session file. /new packs exactly one session file, so a second is a
// malformed archive rather than something to choose between.
func splitArchive(entries []archiveEntry) (sessionFile string, extra []archiveEntry, sessionName string, err error) {
	for _, e := range entries {
		switch {
		case e.name == sessionNameArchiveEntry:
			// Archive metadata, not a file to restore.
		case compactionArchiveName.MatchString(e.name):
			extra = append(extra, e)
		case sessionName == "":
			sessionName, sessionFile = e.name, e.content
		default:
			return "", nil, "", fmt.Errorf("holds more than one session file (%q and %q)", sessionName, e.name)
		}
	}
	if sessionName == "" {
		return "", nil, "", errors.New("holds no session file")
	}
	return sessionFile, extra, sessionName, nil
}

// checkArchiveNames rejects entries that cannot be written beside the session
// file: an empty name, a name with a directory component, or an absolute path.
// /new stores base names, so a safely packed archive never trips this; it
// keeps a hand-made or damaged archive from writing anywhere else.
func checkArchiveNames(entries []archiveEntry) error {
	for _, e := range entries {
		if e.name == "" || e.name == "." || e.name == ".." ||
			filepath.IsAbs(e.name) || e.name != filepath.Base(e.name) {
			return fmt.Errorf("unsafe entry name %q", e.name)
		}
	}
	return nil
}

// resolveArchivePath turns a /load argument into a file path. A name without a
// directory is looked for beside the session file, where /new writes its
// archives and where /sessions names them; a path with a directory, or an
// absolute one, is used as given, relative to the working directory.
func resolveArchivePath(dir, arg string) (string, error) {
	if arg == "" {
		return "", errors.New("empty session name")
	}
	var candidates []string
	switch {
	case filepath.IsAbs(arg):
		candidates = append(candidates, arg)
	case filepath.Dir(arg) == ".":
		candidates = append(candidates, filepath.Join(dir, arg))
	default:
		// Prefer the session directory, then the working directory: /sessions
		// prints bare names, but an explicit relative path is the caller's.
		candidates = append(candidates, filepath.Join(dir, arg), arg)
	}
	for _, c := range candidates {
		if st, err := os.Stat(c); err == nil && !st.IsDir() {
			return c, nil
		}
	}
	if len(candidates) == 1 {
		return "", fmt.Errorf("no session archive at %s", candidates[0])
	}
	return "", fmt.Errorf("no session archive %q (tried %s)", arg, strings.Join(candidates, ", "))
}

// sessionArchiveDir is the directory /new writes a session's archives in: the
// directory of the session file.
func sessionArchiveDir(sess *Session) (string, error) {
	if sess == nil || sess.path == "" {
		return "", errors.New("no session file configured")
	}
	return filepath.Dir(sess.path), nil
}

// writeRestoredFile creates path exclusively with content and fsyncs it, so a
// restored file that exists holds all of it even across a crash. An existing
// file is never overwritten: /new has just packed and removed this session's
// loose files, so a survivor is something this load did not put there.
func writeRestoredFile(path, content string) (err error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer func() {
		if cerr := f.Close(); cerr != nil && err == nil {
			err = cerr
		}
		if err != nil {
			_ = os.Remove(path)
		}
	}()
	if _, err = io.WriteString(f, content); err != nil {
		return err
	}
	return f.Sync()
}

// oneLine collapses whitespace in s to single spaces, so a description that
// arrived with newlines still prints as the one line /sessions lists.
func oneLine(s string) string {
	return strings.Join(strings.Fields(s), " ")
}
