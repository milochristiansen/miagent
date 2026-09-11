// /new: retire the current session into an archive, so the next prompt starts
// a fresh conversation.
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// archiveExt is the extension of the archive /new writes.
const archiveExt = ".tar.gz"

// cmdNew packs the session file and every compaction archive of it into one
// archive, deletes those files, and leaves the session empty so the next
// prompt starts a new conversation.
//
// The archive is written and closed before anything is deleted, so the
// conversation exists in exactly one place at every moment: either as loose
// files or inside the archive. A failure before the deletions leaves the
// session untouched.
func cmdNew(_ context.Context, _ *provider, sess *Session, d *display, args []string) error {
	if len(args) > 0 {
		return fmt.Errorf("takes no arguments")
	}
	if sess.path == "" {
		return errors.New("no session file configured")
	}

	files, err := sessionPackFiles(sess.path)
	if err != nil {
		return err
	}
	if len(files.all()) == 0 {
		if files.empty {
			d.info(fmt.Sprintf("nothing to archive: %s holds no exchanges yet\n", sess.path))
			return nil
		}
		d.info(fmt.Sprintf("nothing to archive: no session file at %s\n", sess.path))
		return nil
	}

	stem := "archive-" + time.Now().UTC().Format("20060102T150405Z")
	target, err := uniquePath(filepath.Dir(sess.path), stem, archiveExt)
	if err != nil {
		return err
	}
	if err := packArchive(target, files.all()); err != nil {
		os.Remove(target) // never leave a half-written archive behind
		return err
	}

	if err := removeFiles(files.all()); err != nil {
		return fmt.Errorf("archived as %s, but removing the originals failed: %w", target, err)
	}
	sess.reset()

	size := int64(0)
	if st, err := os.Stat(target); err == nil {
		size = st.Size()
	}
	d.info(fmt.Sprintf("archived %d %s (%s) as %s\n",
		len(files.all()), plural(len(files.all()), "file", "files"), humanBytes(size), target))
	d.info("removed " + files.describe() + "; the next prompt starts a new session\n")
	return nil
}

// sessionFiles are the files /new packs: a session file and the compaction
// archives beside it.
type sessionFiles struct {
	path     string   // the session file, empty when it does not exist or holds nothing
	archives []string // its compaction archives, oldest first
	empty    bool     // a session file exists but holds no records
}

// all returns every file to pack, the session file first.
func (f sessionFiles) all() []string {
	var paths []string
	if f.path != "" {
		paths = append(paths, f.path)
	}
	return append(paths, f.archives...)
}

// describe names what was deleted, for the report /new prints.
func (f sessionFiles) describe() string {
	switch {
	case f.path == "" && len(f.archives) == 0:
		return "nothing"
	case len(f.archives) == 0:
		return f.path
	case f.path == "":
		return fmt.Sprintf("%d session %s",
			len(f.archives), plural(len(f.archives), "archive", "archives"))
	default:
		return fmt.Sprintf("%s and %d session %s",
			f.path, len(f.archives), plural(len(f.archives), "archive", "archives"))
	}
}

// sessionPackFiles collects what /new archives: the session file, when it
// exists and holds something, and every compaction archive of it in the same
// directory. Archives of other sessions in that directory are left alone, as
// are previous /new archives.
//
// A session file with no records in it is not packed: it holds no exchange to
// archive, and the writability check leaves one behind whenever a run fails
// before its first commit. It is reported as empty rather than as absent,
// because it is there.
func sessionPackFiles(path string) (sessionFiles, error) {
	var files sessionFiles
	dir := filepath.Dir(path)

	switch st, err := os.Stat(path); {
	case err == nil:
		if st.Size() == 0 {
			files.empty = true
		} else {
			files.path = path
		}
	case !os.IsNotExist(err):
		return files, err
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			// The directory is gone, so there is nothing to collect: a
			// missing explicit session path is reported by the caller.
			return files, nil
		}
		return files, err
	}
	pattern := sessionArchivePattern(filepath.Base(path))
	for _, entry := range entries {
		if entry.IsDir() || !pattern.MatchString(entry.Name()) {
			continue
		}
		files.archives = append(files.archives, filepath.Join(dir, entry.Name()))
	}
	// Names carry their timestamp, so sorting orders them oldest first.
	sort.Strings(files.archives)
	return files, nil
}

// sessionArchivePattern matches the compaction archives of one session file:
// the names archiveName builds for it, including the -N collision suffix that
// uniquePath inserts before the extension.
//
// For .session.jsonl it matches .prepak-20260910T024512Z-session.jsonl and
// .prepak-20260910T024512Z-session-1.jsonl; for chat.jsonl it matches
// prepak-20260910T024512Z-chat.jsonl. The pattern is anchored, so it cannot
// pick up another session's archives by accident.
func sessionArchivePattern(base string) *regexp.Regexp {
	hidden, rest := "", base
	if stripped, ok := strings.CutPrefix(base, "."); ok && stripped != "" {
		hidden, rest = ".", stripped
	}
	ext := filepath.Ext(rest)
	stem := strings.TrimSuffix(rest, ext)

	pattern := "^" + regexp.QuoteMeta(hidden+archivePrefix) + `\d{8}T\d{6}Z-` +
		regexp.QuoteMeta(stem) + `(-\d+)?` + regexp.QuoteMeta(ext) + "$"
	return regexp.MustCompile(pattern)
}

// humanBytes renders a byte count for the report /new prints.
func humanBytes(n int64) string {
	switch {
	case n < 1024:
		return fmt.Sprintf("%d B", n)
	case n < 1024*1024:
		return fmt.Sprintf("%.1f KB", float64(n)/1024)
	default:
		return fmt.Sprintf("%.1f MB", float64(n)/(1024*1024))
	}
}
