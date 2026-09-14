// Model reasoning configuration: the effort the harness asks the model for,
// and the effort levels it believes each model supports.
//
// The Responses API takes reasoning as an object ({"reasoning":{"effort":...}}).
// Not every endpoint accepts it, and the set of values an endpoint accepts is
// not standardized, so the harness passes a configured value through rather
// than validating it against a fixed list. A value it does not send cannot be
// wrong; a value it rejects would only turn a working endpoint into a broken
// one.
package main

import (
	"os"
	"strings"

	openai "github.com/sashabaranov/go-openai"
)

// reasoningEffortEnv names the environment variable that sets the effort for agent turns.
const reasoningEffortEnv = "OPENAI_REASONING_EFFORT"

// reasoningEfforts are the values the OpenAI Responses API documents, weakest
// first. They order a model's reported levels, and they are what the built-in
// table claims for a reasoning family that accepts effort control. The harness
// does not restrict the configured value to this set.
var reasoningEfforts = []string{"minimal", "low", "medium", "high"}

// reasoningOffValues are the configured values that mean "send no reasoning
// object at all": an unset variable, or an explicit request to turn the
// behavior off.
var reasoningOffValues = map[string]bool{
	"":        true,
	"none":    true,
	"off":     true,
	"default": true,
}

// reasoningFromEnv returns the reasoning object to send with a request, from
// OPENAI_REASONING_EFFORT. A nil result means no reasoning object is sent: the
// endpoint keeps its own default. Any value other than the off values is sent
// as the effort, because a proxy or a local server may accept levels the
// OpenAI API does not name.
func reasoningFromEnv() *openai.ResponseReasoning {
	effort := configuredReasoningEffort()
	if reasoningOffValues[effort] {
		return nil
	}
	return &openai.ResponseReasoning{Effort: effort}
}

// configuredReasoningEffort returns the configured value, trimmed and
// lower-cased, for display and for the request. It is empty when the variable
// is unset or set to blank.
func configuredReasoningEffort() string {
	return strings.ToLower(strings.TrimSpace(os.Getenv(reasoningEffortEnv)))
}

// reasoningCapability is a known model family and the effort levels it takes.
// An empty level list means the family does not accept a reasoning effort at
// all, which is different from a family the harness knows nothing about.
type reasoningCapability struct {
	match   string   // lower-case substring of a model id
	efforts []string // accepted efforts, weakest first; empty means none
}

// reasoningCapabilities is a best-effort table of what the harness believes
// about model families, most specific first. It is only a fallback: when the
// endpoint reports a model's levels itself (see decodeModel), that wins.
//
// The standard OpenAI-compatible /models response carries no capability data,
// so for most endpoints this table is the only source. It deliberately covers
// only the OpenAI reasoning families the harness can name with confidence and
// the OpenAI chat families that plainly take no effort; anything else is
// reported as unknown rather than guessed at.
var reasoningCapabilities = []reasoningCapability{
	// Chat variants of reasoning families that do not take an effort.
	{"gpt-5-chat", nil},

	// Reasoning families and the effort levels they accept.
	{"gpt-5", reasoningEfforts},
	{"o4", []string{"low", "medium", "high"}},
	// o3-pro and the deep-research variants reason, but do not let the
	// caller choose an effort; they must precede the plain "o3" match.
	{"o3-pro", nil},
	{"o3-deep-research", nil},
	{"o3", []string{"low", "medium", "high"}},
	{"o1", []string{"low", "medium", "high"}},

	// OpenAI chat and utility families that do not take an effort.
	{"gpt-4o", nil},
	{"gpt-4.1", nil},
	{"gpt-4", nil},
	{"gpt-3", nil},
	{"chatgpt", nil},
	{"embedding", nil},
	{"whisper", nil},
	{"tts", nil},
	{"dall-e", nil},
	{"moderation", nil},
}

// inferReasoningEfforts returns the effort levels the harness knows a model id
// accepts, and whether it knows anything at all. An empty, true result means a
// model known not to take a reasoning effort.
func inferReasoningEfforts(id string) ([]string, bool) {
	lower := strings.ToLower(id)
	for _, c := range reasoningCapabilities {
		if strings.Contains(lower, c.match) {
			return c.efforts, true
		}
	}
	return nil, false
}

// normalizeEfforts cleans up a list of effort names reported by an endpoint:
// trimmed, lower-cased, de-duplicated, and ordered with the documented levels
// first so two endpoints that report the same set read the same way.
func normalizeEfforts(in []string) []string {
	seen := make(map[string]bool, len(in))
	order := make([]string, 0, len(in))
	for _, e := range in {
		e = strings.ToLower(strings.TrimSpace(e))
		if e == "" || seen[e] {
			continue
		}
		seen[e] = true
		order = append(order, e)
	}
	var out []string
	for _, e := range reasoningEfforts {
		if seen[e] {
			out = append(out, e)
			delete(seen, e)
		}
	}
	// Keep any endpoint-specific levels, in the order reported.
	for _, e := range order {
		if seen[e] {
			out = append(out, e)
			delete(seen, e)
		}
	}
	return out
}
