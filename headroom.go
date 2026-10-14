// Context headroom: refusing to start a turn when the session is close to the
// model's context window. A request made with almost no room left is the one a
// provider is most likely to cut off mid-answer, so the harness stops before
// making it and points the reader at /compact instead.
package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

// contextLimitEnv names the environment variable holding the model's context
// window in tokens. It is the same value /context reports fullness against.
const contextLimitEnv = "MIAGENT_CONTEXT_LIMIT"

// contextHeadroomEnv names the environment variable that sets how much of the
// context window must remain free before a turn may start, as a percentage of
// the window.
const contextHeadroomEnv = "MIAGENT_CONTEXT_HEADROOM"

// defaultContextHeadroom is the percentage of the window that must remain free
// when MIAGENT_CONTEXT_HEADROOM is unset. A tenth of the window is enough room
// for a tool result and a reply without the request running out of context.
const defaultContextHeadroom = 10

// contextHeadroomFromEnv reads MIAGENT_CONTEXT_HEADROOM. An unset or blank
// variable is the default; a whole number from 0 to 100 is the percentage of
// the context window to keep free, and 0 disables the check. A malformed value
// is an error rather than a silent fallback, so a typo does not quietly remove
// the guard.
func contextHeadroomFromEnv() (int, error) {
	v := strings.TrimSpace(os.Getenv(contextHeadroomEnv))
	if v == "" {
		return defaultContextHeadroom, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 0 || n > 100 {
		return 0, fmt.Errorf("%s must be a percentage between 0 and 100 (got %q)", contextHeadroomEnv, v)
	}
	return n, nil
}

// contextRefusal decides whether a turn may start. It returns a note to print
// and true when the session has less than headroom percent of the configured
// context window left, and ("", false) when a turn may proceed.
//
// Without MIAGENT_CONTEXT_LIMIT there is nothing to compare against, and a
// headroom of 0 disables the check outright. The size is the one the next
// request would carry (see Session.contextTokens), so the newly typed prompt
// is already counted; a session whose size has never been measured is judged
// by the estimate the same way /context reports it.
func contextRefusal(s *Session, headroom int) (string, bool, error) {
	if headroom <= 0 || len(s.Items) == 0 {
		return "", false, nil
	}
	limit, err := envTokenLimit(contextLimitEnv)
	if err != nil {
		return "", false, err
	}
	if limit == 0 {
		return "", false, nil
	}

	used, measured := s.contextTokens()
	remaining := int64(limit) - int64(used)
	if remaining*100 >= int64(limit)*int64(headroom) {
		return "", false, nil
	}
	if remaining < 0 {
		remaining = 0
	}
	return fmt.Sprintf("context: %s / %s tokens%s, only %.1f%% left (below the %d%% headroom to start a turn); run /compact to summarize the conversation, then send the prompt again",
		commas(used), commas(limit), estimateNote(measured),
		100*float64(remaining)/float64(limit), headroom), true, nil
}
