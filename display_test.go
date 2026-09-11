package main

import (
	"io"
	"os"
	"testing"
)

// captureStderr runs f with os.Stderr redirected and returns what it wrote.
func captureStderr(t *testing.T, f func()) string {
	t.Helper()
	old := os.Stderr
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stderr = w
	defer func() { os.Stderr = old }()
	f()
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	out, err := io.ReadAll(r)
	if err != nil {
		t.Fatal(err)
	}
	return string(out)
}

// TestDisplayClosesReasoningLine covers the raw-mode line bookkeeping: reasoning
// goes to stderr while the display's line tracking covers stdout, so a
// reasoning block that does not end in a newline has to be closed by the
// display itself, or the next thing the terminal writes lands on its last line.
func TestDisplayClosesReasoningLine(t *testing.T) {
	var errOut string
	out := captureStdout(t, func() {
		errOut = captureStderr(t, func() {
			d := newDisplay()
			d.reasoning("thinking about it")
			d.output("the answer")
			d.endTurn()
		})
	})
	if errOut != "thinking about it\n" {
		t.Fatalf("stderr = %q, want the reasoning line terminated", errOut)
	}
	// The answer's own line is terminated too, and the two streams stay
	// separate: reasoning is not echoed onto stdout.
	if out != "the answer\n" {
		t.Fatalf("stdout = %q, want just the answer on its own line", out)
	}
}

// TestDisplayClosesReasoningLineWithoutAnswer covers the same contract for a
// turn that reasons and then calls a tool: the tool box's own output follows on
// the terminal, so the reasoning line has to be closed before it.
func TestDisplayClosesReasoningLineWithoutAnswer(t *testing.T) {
	var errOut string
	out := captureStdout(t, func() {
		errOut = captureStderr(t, func() {
			d := newDisplay()
			d.reasoning("checking the tree")
			d.toolStart("bash", `{"command":"ls"}`)
			_, _ = d.toolOut().Write([]byte("main.go\n"))
			_, _ = d.toolErr().Write([]byte("warning\n"))
			d.toolEnd(TGIResult{Code: 0, Stdout: "main.go\n", Stderr: "warning\n"})
		})
	})
	if errOut != "checking the tree\n" {
		t.Fatalf("stderr = %q, want the reasoning line terminated", errOut)
	}
	if want := "Tool: bash\n{\"command\":\"ls\"}\nOutput:\nmain.go\nwarning\n"; out != want {
		t.Fatalf("stdout = %q, want %q", out, want)
	}
}

// TestDisplayReasoningAlreadyTerminated covers the other half: a reasoning
// block that ends in a newline is not given a second one.
func TestDisplayReasoningAlreadyTerminated(t *testing.T) {
	var errOut string
	captureStdout(t, func() {
		errOut = captureStderr(t, func() {
			d := newDisplay()
			d.reasoning("done thinking\n")
			d.output("answer")
			d.endTurn()
		})
	})
	if errOut != "done thinking\n" {
		t.Fatalf("stderr = %q, want no extra newline", errOut)
	}
}

// TestDisplaySubduedLine covers the final note's placement: it goes directly
// after the last output line, without info's blank separator, and is plain
// when stdout is not a terminal (as in this test).
func TestDisplaySubduedLine(t *testing.T) {
	out := captureStdout(t, func() {
		d := newDisplay()
		d.output("the answer")
		d.endTurn()
		d.subdued("context: 13 tokens (maximum unknown; set MIAGENT_CONTEXT_LIMIT)")
	})
	want := "the answer\ncontext: 13 tokens (maximum unknown; set MIAGENT_CONTEXT_LIMIT)\n"
	if out != want {
		t.Fatalf("stdout = %q, want %q", out, want)
	}
}

// TestDisplaySubduedClosesOpenLine covers the other half: a note written
// without a prior endTurn must still start on its own line.
func TestDisplaySubduedClosesOpenLine(t *testing.T) {
	out := captureStdout(t, func() {
		d := newDisplay()
		d.output("the answer")
		d.subdued("context: note")
	})
	want := "the answer\ncontext: note\n"
	if out != want {
		t.Fatalf("stdout = %q, want %q", out, want)
	}
}
