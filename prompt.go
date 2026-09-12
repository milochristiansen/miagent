// Prompt files: the harness's prompts are editable text, not compiled-in
// strings. They live in a prompts subdirectory of the configuration directory
// (see configDir) as SYSTEM.md, COMPACT-*.md, DESCRIPTION.md, and
// SESSION-NAME.md, so one installation serves every project and a prompt can
// be changed without a rebuild. SYSTEM.md and the optional AGENTS.md files are
// read once at startup, because every turn needs them; the COMPACT-*.md files,
// DESCRIPTION.md, and SESSION-NAME.md are read on demand, when /compact, /desc,
// and /new run.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// agentsFile names the per-project instruction file. It is read like the
// prompts in the configuration directory's prompts subdirectory, two
// differences aside: it is optional, and it belongs to the project rather than
// to the installation, so it is looked for in the working directory and the
// state directory.
const agentsFile = "AGENTS.md"

// promptsDir is the name of the configuration directory's prompt
// subdirectory, which holds SYSTEM.md, COMPACT-*.md, DESCRIPTION.md, and
// SESSION-NAME.md.
const promptsDir = "prompts"

// promptPath returns the path of the named prompt file in the configuration
// directory's prompts subdirectory.
func promptPath(name string) (string, error) {
	config, err := configDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(config, promptsDir, name), nil
}

// loadPrompt reads one required prompt file. Surrounding whitespace is
// trimmed: a text file ends in a newline, and neither the model nor a cache
// key cares for it, so trimming keeps the prompt sent equal to the text
// written. A file that is missing, unreadable, or blank is an error — no
// caller can proceed without a prompt — and the error distinguishes the three,
// so a missing SYSTEM.md does not read as an empty one.
func loadPrompt(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	text := strings.TrimSpace(string(b))
	if text == "" {
		return "", fmt.Errorf("%s is empty", path)
	}
	return text, nil
}

// readOptionalPrompt reads one optional file with the same trimming as
// loadPrompt, but a missing file is not an error: it contributes nothing.
// Anything else that goes wrong (unreadable, a directory in its place) still
// is, because silently dropping instructions the user wrote is worse than
// refusing to start.
func readOptionalPrompt(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", err
	}
	return strings.TrimSpace(string(b)), nil
}

// loadAgents returns the AGENTS.md instructions for the working directory: the
// current directory's file first, then the state directory's, concatenated in
// that order with a blank line between them. Either or both may be absent, and
// an absent or blank file contributes nothing.
func loadAgents(stateDir string) (string, error) {
	var sections []string
	for _, path := range []string{agentsFile, filepath.Join(stateDir, agentsFile)} {
		text, err := readOptionalPrompt(path)
		if err != nil {
			return "", err
		}
		if text != "" {
			sections = append(sections, text)
		}
	}
	return strings.Join(sections, "\n\n"), nil
}

// sessionInstructions builds the instructions sent with every request of a
// session: the system prompt, then the AGENTS.md files. It is read once, at
// startup, unlike the compaction prompts.
//
// The agent files are appended, which is what gives them lower priority than
// the system prompt: they add to it rather than replace it, and the system
// prompt holds the earlier (and so governing) position. The result is passed
// to the provider as instructions and nowhere else: project instructions are
// context for the model, not part of the conversation, so they are never
// written to the session file and never replayed from it.
func sessionInstructions(stateDir string) (string, error) {
	systemPath, err := promptPath("SYSTEM.md")
	if err != nil {
		return "", err
	}
	system, err := loadPrompt(systemPath)
	if err != nil {
		return "", err
	}
	agents, err := loadAgents(stateDir)
	if err != nil {
		return "", err
	}
	if agents == "" {
		return system, nil
	}
	return system + "\n\n" + agents, nil
}
