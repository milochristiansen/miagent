// Archiving for /compact: the session file is copied aside as its own loadable
// archive before it is replaced, so the full pre-compaction conversation
// survives the rewrite and the session path is never left empty.
package main

import (
	"archive/tar"
	"compress/gzip"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// archivePrefix marks an archived session file.
const archivePrefix = "prepak-"

// archiveName returns the archive file name for a session file's base name and
// timestamp.
//
// A dot-named session keeps its dot at the front: `.session.jsonl` becomes
// `.prepak-20260910T024512Z-session.jsonl`, not
// `prepak-20260910T024512Z-.session.jsonl`. The archive stays as hidden as the
// session it came from (dotfiles are skipped by ls and by default globs), and
// the name does not carry a stray "-." in the middle.
func archiveName(base string, ts time.Time) string {
	stamp := ts.UTC().Format("20060102T150405Z")
	if rest, ok := strings.CutPrefix(base, "."); ok && rest != "" {
		return "." + archivePrefix + stamp + "-" + rest
	}
	return archivePrefix + stamp + "-" + base
}

// uniquePath returns a path in dir for stem+ext that does not exist yet,
// inserting -1, -2, … after the stem. It never returns a path that would
// overwrite an existing file.
func uniquePath(dir, stem, ext string) (string, error) {
	for i := 0; ; i++ {
		candidate := stem + ext
		if i > 0 {
			candidate = fmt.Sprintf("%s-%d%s", stem, i, ext)
		}
		path := filepath.Join(dir, candidate)
		_, err := os.Lstat(path)
		if os.IsNotExist(err) {
			return path, nil
		}
		if err != nil {
			return "", err
		}
		if i > 1000 {
			return "", fmt.Errorf("cannot find a free name for %s%s in %s", stem, ext, dir)
		}
	}
}

// archiveSession copies the session file aside as an archive and returns the
// path of the copy. It copies rather than moves, because the session path must
// stay occupied until the compacted replacement is renamed over it: a move
// would leave a window in which a crash (or a power loss) leaves no session at
// the configured path at all, and the next run would silently start fresh. A
// copy is also what makes the rollback trivial — a failure after this point
// discards the copy, and the session file was never touched.
//
// The copy is created exclusively, so an existing file is never overwritten,
// and it keeps the session file's permissions.
func archiveSession(path string) (string, error) {
	name := archiveName(filepath.Base(path), time.Now())
	ext := filepath.Ext(name)
	target, err := uniquePath(filepath.Dir(path), strings.TrimSuffix(name, ext), ext)
	if err != nil {
		return "", err
	}
	if err := copyFile(path, target); err != nil {
		_ = os.Remove(target)
		return "", err
	}
	return target, nil
}

// copyFile copies src to dst, creating dst exclusively and keeping src's
// permissions. The copy is fsynced before it is reported as written, so an
// archive that exists holds the whole session even across a crash.
func copyFile(src, dst string) (err error) {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	mode := os.FileMode(0644)
	if st, err := in.Stat(); err == nil {
		mode = st.Mode().Perm()
	}
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	defer func() {
		if cerr := out.Close(); cerr != nil && err == nil {
			err = cerr
		}
	}()

	if _, err = io.Copy(out, in); err != nil {
		return err
	}
	return out.Sync()
}

// discardArchive removes an archive copy written for a compaction that did not
// happen. Failing to remove it is not worth reporting: the session file is
// intact either way, and a leftover copy is inert.
func discardArchive(path string) {
	_ = os.Remove(path)
}

// archiveEntry is content stored in an archive with no file behind it, written
// after the files passed to packArchive. /new uses one for the generated
// session-name.md, which must live inside the archive rather than beside it.
type archiveEntry struct {
	name    string
	content string
}

// packArchive writes files and extra in-memory entries into a gzip-compressed
// tar archive at path, storing each under its base name. All the files must
// share a directory, which the callers guarantee: they are one session file and
// its compaction archives.
//
// The archive is created exclusively, so an existing file is never overwritten;
// on failure the caller removes whatever was written.
func packArchive(path string, files []string, entries []archiveEntry) (err error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}
	defer func() {
		if cerr := f.Close(); cerr != nil && err == nil {
			err = cerr
		}
	}()

	gz := gzip.NewWriter(f)
	tw := tar.NewWriter(gz)
	for _, src := range files {
		if err = addToArchive(tw, src); err != nil {
			return err
		}
	}
	for _, e := range entries {
		if err = addContentToArchive(tw, e.name, e.content); err != nil {
			return err
		}
	}
	// Close the layers in order: each writes its trailer through the one
	// below it.
	if err = tw.Close(); err != nil {
		return err
	}
	if err = gz.Close(); err != nil {
		return err
	}
	return f.Sync()
}

// addContentToArchive appends in-memory content to a tar archive under name.
// The header is built directly, so the entry needs no file on disk to describe
// it; the mode matches the files the archives normally hold.
func addContentToArchive(tw *tar.Writer, name, content string) error {
	hdr := &tar.Header{
		Name:    name,
		Mode:    0o644,
		Size:    int64(len(content)),
		ModTime: time.Now(),
	}
	if err := tw.WriteHeader(hdr); err != nil {
		return err
	}
	_, err := io.WriteString(tw, content)
	return err
}

// addToArchive appends one file to a tar archive under its base name.
func addToArchive(tw *tar.Writer, path string) error {
	st, err := os.Stat(path)
	if err != nil {
		return err
	}
	hdr, err := tar.FileInfoHeader(st, "")
	if err != nil {
		return err
	}
	hdr.Name = filepath.Base(path)
	if err := tw.WriteHeader(hdr); err != nil {
		return err
	}
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = io.Copy(tw, f)
	return err
}

// removeFiles deletes every path, reporting all the failures it hit rather
// than stopping at the first: a partially removed set is what the caller has
// to describe to the user.
func removeFiles(paths []string) error {
	var failed []string
	for _, path := range paths {
		if err := os.Remove(path); err != nil {
			failed = append(failed, fmt.Sprintf("%s: %v", path, err))
		}
	}
	if len(failed) > 0 {
		return errors.New(strings.Join(failed, "; "))
	}
	return nil
}

// writeSessionFile replaces the session file's contents atomically: the
// content is written to a temporary file in the same directory and fsynced,
// then renamed over the session path, so a reader either sees the old file or
// the new one and never a partial write. The temporary file is removed on any
// failure, and the result keeps the session file's existing permissions (a
// temp file is created 0600, which would otherwise tighten them).
func writeSessionFile(path string, content []byte) error {
	dir := filepath.Dir(path)
	mode := os.FileMode(0644)
	if st, err := os.Stat(path); err == nil {
		mode = st.Mode().Perm()
	}

	tmp, err := os.CreateTemp(dir, filepath.Base(path)+".tmp*")
	if err != nil {
		return err
	}
	defer func() {
		if tmp != nil {
			tmp.Close()
			os.Remove(tmp.Name())
		}
	}()

	if _, err := tmp.Write(content); err != nil {
		return err
	}
	if err := tmp.Chmod(mode); err != nil {
		return err
	}
	if err := tmp.Sync(); err != nil {
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	name := tmp.Name()
	tmp = nil

	if err := os.Rename(name, path); err != nil {
		os.Remove(name)
		return err
	}
	// Make the rename itself durable. A directory that cannot be synced (some
	// network filesystems) still holds the new file, and the replacement did
	// happen, so a failure here is not something the caller can act on.
	_ = syncDir(dir)
	return nil
}

// syncDir fsyncs a directory, so a rename into it survives a crash. A directory
// that does not support it reports an error the caller decides how to treat.
func syncDir(dir string) error {
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}
