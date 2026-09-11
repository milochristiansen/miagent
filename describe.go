// /desc: a short, plain-language description of the work in a session,
// produced by the model from the user prompts and assistant answers alone.
package main

import (
	"context"
	"fmt"
	"strings"
)

// describePromptName is the prompt file /desc reads from the prompts
// subdirectory of the configuration directory, alongside SYSTEM.md and
// COMPACT-*.md (see prompt.go).
const describePromptName = "DESCRIPTION.md"

// describeMaxTokens bounds the model's reply. A description is one or two
// sentences, so the budget is small; it caps the reply rather than requiring it
// to fill the budget, and with no reasoning object there is nothing else to
// spend it on.
const describeMaxTokens = 512

// loadDescribePrompt reads DESCRIPTION.md from the prompts subdirectory of the
// configuration directory. Like the compaction prompts it is read on demand,
// when /desc runs, so the wording can change without a restart or a rebuild.
func loadDescribePrompt() (string, error) {
	path, err := promptPath(describePromptName)
	if err != nil {
		return "", err
	}
	return loadPrompt(path)
}

// describeConversation renders a session's user prompts and assistant answers
// as text, in order, for the description request. Reasoning and tool traffic
// are left out: the work is what was asked and what was answered, not how. A
// compaction summary is included, because the earlier prompts and answers it
// replaced are no longer in the session and the work it stands in for would
// otherwise go undescribed.
func describeConversation(items []StoredItem) string {
	var parts []string
	for _, it := range items {
		switch it.Role {
		case "compaction":
			if s := strings.TrimSpace(it.Content); s != "" {
				parts = append(parts, "Summary of earlier work: "+s)
			}
		case "user":
			if s := strings.TrimSpace(it.Content); s != "" {
				parts = append(parts, "User: "+s)
			}
		case "assistant":
			if s := strings.TrimSpace(it.Content); s != "" {
				parts = append(parts, "Assistant: "+s)
			}
		}
	}
	return strings.Join(parts, "\n\n")
}

// describeInput frames the reduced conversation so the model reads it as
// material to describe rather than a conversation to continue.
func describeInput(conversation string) string {
	return "<conversation>\n" + conversation + "\n</conversation>"
}

// cmdDescribe reports a short description of the work done in the session. The
// conversation is reduced to the user prompts and assistant answers and sent
// with DESCRIPTION.md, read from the configuration directory's prompts
// subdirectory; the model's reply is the command's output. The session is only
// read, never written.
func cmdDescribe(ctx context.Context, prov *provider, sess *Session, d *display, args []string) error {
	if len(args) > 0 {
		return fmt.Errorf("takes no arguments")
	}
	conversation := describeConversation(sess.Items)
	if conversation == "" {
		d.info("nothing to describe: the session has no prompts or answers yet\n")
		return nil
	}
	prompt, err := loadDescribePrompt()
	if err != nil {
		return err
	}
	text, _, err := prov.summarize(ctx, prompt, describeInput(conversation), describeMaxTokens)
	if err != nil {
		return err
	}
	// The description is model markdown, so it goes through the renderer
	// rather than the plain harness-output path. endTurn finalizes the block
	// and, when stdout is not a terminal, terminates the line.
	d.output(text)
	d.endTurn()
	return nil
}
