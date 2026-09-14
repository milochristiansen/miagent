// Tool-call display configuration: how much of a tool call's arguments and
// output the live box shows.
//
// On a terminal a tool call is drawn as a code box that updates in place. Its
// two sections — the pretty-printed arguments and the tool's streamed output —
// are each capped at MIAGENT_TOOLCALL_SIZE lines so that a tool which prints a
// thousand lines cannot push the rest of the session off the screen. The
// output is a window over the last lines to arrive, so it scrolls within the
// box rather than scrolling the terminal. The cap is reduced to the terminal
// height when that is smaller, because a box taller than the screen cannot be
// redrawn in place.
//
// A size of 0 is the escape hatch: it disables the cap and lets the box grow
// without bound, exactly as it did before the option existed. Output that is
// not a terminal is never capped: a log wants every line.
package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

// toolcallSizeEnv names the environment variable that caps tool-call lines.
const toolcallSizeEnv = "MIAGENT_TOOLCALL_SIZE"

// defaultToolcallSize is the per-section cap when the variable is unset. It is
// ten so that the arguments, the output, and the box's three border rows fit on
// the common 24-row terminal with a row to spare for a non-zero exit note.
const defaultToolcallSize = 10

// toolcallSizeFromEnv reads MIAGENT_TOOLCALL_SIZE. An unset or blank variable
// is the default; "0" means no cap; any other value must be a non-negative
// integer. A malformed value is an error rather than a silent fallback, so a
// typo does not quietly change what a run shows.
func toolcallSizeFromEnv() (int, error) {
	v := strings.TrimSpace(os.Getenv(toolcallSizeEnv))
	if v == "" {
		return defaultToolcallSize, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 0 {
		return 0, fmt.Errorf("%s must be a non-negative integer (got %q)", toolcallSizeEnv, v)
	}
	return n, nil
}

// toolcallInputLines returns the argument rows a tool box shows: the
// pretty-printed arguments, capped to limit rows (0 means all). When rows are
// dropped the last row is a "… (N more lines)" note, so the reader can tell the
// call was truncated; the note replaces the last content row rather than adding
// one, which keeps the returned window at exactly limit rows.
func toolcallInputLines(args string, limit int) []string {
	lines := splitContent(args)
	if limit <= 0 || len(lines) <= limit {
		return lines
	}
	if limit == 1 {
		// No room for both a line and a note: the first line is the most use.
		return lines[:1]
	}
	note := fmt.Sprintf("… (%d more lines)", len(lines)-(limit-1))
	return append(lines[:limit-1:limit-1], note)
}
