// Naming for /new: the first few user prompts of a session are given to the
// model with the SESSION-NAME.md prompt, and the reply is stored inside the
// archive /new writes as session-name.md. A later command can read that entry
// back to list an old session under a short name.
package main

import (
	"context"
	"strings"
)

// sessionNamePromptName is the prompt file /new reads from the prompts
// subdirectory of the configuration directory, alongside SYSTEM.md,
// COMPACT-*.md, and DESCRIPTION.md (see prompt.go).
const sessionNamePromptName = "SESSION-NAME.md"

// sessionNameArchiveEntry is the name under which the generated session name is
// stored inside the archive /new writes. A later command reads it back to name
// an old session.
const sessionNameArchiveEntry = "session-name.md"

// sessionNameMaxTokens bounds the model's reply. A name is one short sentence,
// so the budget is small; it caps the reply rather than requiring the model to
// fill it, and with no reasoning object there is nothing else to spend it on.
const sessionNameMaxTokens = 256

// sessionNamePromptLimit is how many of the session's first user prompts are
// sent. The opening prompts say what the session set out to do, which is what
// the name is for; describing the rest of the work is /desc's job.
const sessionNamePromptLimit = 3

// loadSessionNamePrompt reads the session-name prompt from the prompts
// subdirectory of the configuration directory. Like the description and
// compaction prompts it is read on demand, when /new runs, so the wording can
// change without a restart or a rebuild.
func loadSessionNamePrompt() (string, error) {
	path, err := promptPath(sessionNamePromptName)
	if err != nil {
		return "", err
	}
	return loadPrompt(path)
}

// sessionNameConversation renders the first few user prompts of a session as
// text for the naming request. Only the user side is included: no assistant
// answers, reasoning, or tool traffic, and no compaction summary, which is not
// a prompt the user wrote.
func sessionNameConversation(items []StoredItem) string {
	var parts []string
	for _, it := range items {
		if len(parts) == sessionNamePromptLimit {
			break
		}
		if it.Role != "user" {
			continue
		}
		if s := strings.TrimSpace(it.Content); s != "" {
			parts = append(parts, "User: "+s)
		}
	}
	return strings.Join(parts, "\n\n")
}

// sessionNameInput frames the reduced prompts so the model reads them as
// material to name rather than a conversation to continue.
func sessionNameInput(conversation string) string {
	return "<conversation>\n" + conversation + "\n</conversation>"
}

// sessionName returns the short name to store in a /new archive, or "" when
// the session holds no user prompt to name. It reads SESSION-NAME.md from the
// prompts subdirectory and sends the first few user prompts; the model's reply
// is the name.
func sessionName(ctx context.Context, prov *provider, items []StoredItem) (string, error) {
	conversation := sessionNameConversation(items)
	if conversation == "" {
		return "", nil
	}
	prompt, err := loadSessionNamePrompt()
	if err != nil {
		return "", err
	}
	text, _, err := prov.summarize(ctx, prompt, sessionNameInput(conversation), sessionNameMaxTokens)
	if err != nil {
		return "", err
	}
	return text, nil
}
