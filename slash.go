// Slash commands: a prompt that starts with "/" is a harness command, handled
// before the provider is called and never entering the conversation. Commands
// act on the loaded session and report through the display's plain-text path,
// because their output is harness output rather than model output.
package main

import (
	"context"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
)

// command is one slash command. needModel marks a command that calls the model
// itself: the harness checks for a configured OPENAI_MODEL before running one.
// It is not set for commands that only reach the endpoint (/models) or touch
// nothing beyond the session (/context, /new).
type command struct {
	name      string // as typed, without the leading slash
	summary   string // one line, listed when a command is not found
	needModel bool
	run       func(ctx context.Context, prov *provider, sess *Session, d *display, args []string) error
}

// commands lists the slash commands in listing order.
var commands = []command{
	{
		name:    "context",
		summary: "context size and maximum for this session",
		run:     cmdContext,
	},
	{
		name:    "models",
		summary: "list the endpoint's models and their reasoning levels",
		run:     cmdModels,
	},
	{
		name:      "compact",
		summary:   "replace older conversation with a summary, archiving the session",
		needModel: true,
		run:       cmdCompact,
	},
	{
		name:    "new",
		summary: "archive the session and its compaction archives, then start fresh",
		run:     cmdNew,
	},
}

// cmdCompact replaces the session's older conversation with a summary of it,
// archiving the pre-compaction session file. See provider.compact.
func cmdCompact(ctx context.Context, prov *provider, sess *Session, d *display, args []string) error {
	if len(args) > 0 {
		return fmt.Errorf("takes no arguments")
	}
	return prov.compact(ctx, sess, d)
}

// parseCommand splits a prompt into a slash command: the name without its
// leading slash, plus the whitespace-separated arguments that follow it. It
// reports whether the prompt is a command at all; a prompt that does not
// start with "/" is an ordinary prompt for the model.
func parseCommand(prompt string) (name string, args []string, ok bool) {
	if !strings.HasPrefix(prompt, "/") {
		return "", nil, false
	}
	fields := strings.Fields(prompt)
	return strings.TrimPrefix(fields[0], "/"), fields[1:], true
}

// findCommand looks up a command by name.
func findCommand(name string) (command, bool) {
	for _, c := range commands {
		if c.name == name {
			return c, true
		}
	}
	return command{}, false
}

// unknownCommand reports an unrecognized slash command and exits, listing the
// commands that exist.
func unknownCommand(name string) {
	fmt.Fprintf(os.Stderr, "unknown command /%s\navailable commands:\n", name)
	for _, c := range commands {
		fmt.Fprintf(os.Stderr, "  /%s\t%s\n", c.name, c.summary)
	}
	os.Exit(2)
}

// cmdContext reports how full the session's context is.
//
// The size is what the next request would carry: the newest usage the provider
// reported, plus an estimate of any items that record does not cover (see
// Session.contextTokens). A number without a measurement behind it — a session
// that has not called the model yet, or one just rewritten by /compact — is
// labelled estimated. The maximum is the model's context window from
// MIAGENT_CONTEXT_LIMIT (tokens); without it the size is reported alone.
func cmdContext(_ context.Context, _ *provider, sess *Session, d *display, args []string) error {
	if len(args) > 0 {
		return fmt.Errorf("takes no arguments")
	}
	line, err := contextLine(sess)
	if err != nil {
		return err
	}
	d.info(line + "\n")
	return nil
}

// contextLine formats the context-size line /context prints and a normal run
// prints just before it exits. The line has no trailing newline; callers add
// whatever terminator their output path requires.
func contextLine(sess *Session) (string, error) {
	if len(sess.Items) == 0 {
		return "context: unknown (the session is empty)", nil
	}

	used, measured := sess.contextTokens()
	note := ""
	switch {
	case !measured && sess.Compacted:
		note = ", estimated; unmeasured since compaction"
	case !measured:
		note = ", estimated; no model turn has reported usage yet"
	}
	limit, err := envTokenLimit("MIAGENT_CONTEXT_LIMIT")
	if err != nil {
		return "", err
	}
	if limit == 0 {
		return fmt.Sprintf("context: %s tokens%s (maximum unknown; set MIAGENT_CONTEXT_LIMIT)",
			commas(used), note), nil
	}
	return fmt.Sprintf("context: %s / %s tokens (%.1f%%%s)",
		commas(used), commas(limit), 100*float64(used)/float64(limit), note), nil
}

// cmdModels lists the models the configured endpoint offers, with the
// reasoning efforts each is known to accept, and names the model and effort
// the harness is currently set to.
//
// The standard OpenAI-compatible /models response says nothing about
// reasoning, so a level a model reports itself (some routers add one) is used
// when present and the harness's own model-family table otherwise; a model
// neither source covers is reported as unknown rather than guessed at. The
// command talks to the endpoint but needs no model of its own, so it runs
// before OPENAI_MODEL is required and can be used to choose one.
func cmdModels(ctx context.Context, prov *provider, _ *Session, d *display, args []string) error {
	if len(args) > 0 {
		return fmt.Errorf("takes no arguments")
	}
	models, err := prov.listModels(ctx)
	if err != nil {
		return err
	}
	sort.Slice(models, func(i, j int) bool { return models[i].ID < models[j].ID })

	var b strings.Builder
	fmt.Fprintf(&b, "models at %s (%d):\n", endpointLabel(prov.baseURL), len(models))
	if len(models) == 0 {
		b.WriteString("  (none)\n")
	}
	width := 0
	for _, m := range models {
		if n := len(m.ID); n > width {
			width = n
		}
	}
	for _, m := range models {
		marker := "  "
		if prov.model != "" && m.ID == prov.model {
			marker = "* "
		}
		fmt.Fprintf(&b, "%s%-*s  %s\n", marker, width, m.ID, reasoningSummary(m))
	}
	switch {
	case prov.model == "":
		b.WriteString("no model configured; set OPENAI_MODEL\n")
	case prov.reasoningEffort != "":
		fmt.Fprintf(&b, "configured: %s, reasoning effort %q (%s)\n", prov.model, prov.reasoningEffort, reasoningEffortEnv)
	default:
		fmt.Fprintf(&b, "configured: %s, reasoning effort default\n", prov.model)
	}
	d.info(b.String())
	return nil
}

// envTokenLimit reads a token count from the named environment variable.
// Unset or empty is 0 (unknown); a set value must be a positive integer.
func envTokenLimit(name string) (int, error) {
	v := strings.TrimSpace(os.Getenv(name))
	if v == "" {
		return 0, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 {
		return 0, fmt.Errorf("%s must be a positive integer (got %q)", name, v)
	}
	return n, nil
}

// plural picks the singular or plural form for a count.
func plural(n int, singular, plural string) string {
	if n == 1 {
		return singular
	}
	return plural
}

// commas renders a token count with ',' thousands separators.
func commas(n int) string {
	s := strconv.Itoa(n)
	if len(s) <= 3 {
		return s
	}
	var b strings.Builder
	head := len(s) % 3
	b.WriteString(s[:head])
	for i := head; i < len(s); i += 3 {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(s[i : i+3])
	}
	return b.String()
}
