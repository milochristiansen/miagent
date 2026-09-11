package main

import (
	"fmt"
	"io"
	"os"
	"strings"
	"sync"

	"golang.org/x/term"

	"github.com/milo/MiAgent/termark"
)

// dispClass identifies the kind of markdown content currently on screen.
type dispClass int

const (
	dispNone dispClass = iota
	dispReasoning
	dispOutput
)

// display owns the session's screen output. On a terminal it renders three
// content classes: reasoning as subdued markdown (termark's "reasoning"
// style), agent output as plain markdown, and tool calls as live code boxes
// whose stdout/stderr rows stream in interleaved while the tool runs. Only
// one termark renderer is active at a time because each owns the screen's
// tail repaint; a class switch finalizes the previous renderer. When stdout
// is not a terminal, content falls back to plain text: assistant output and
// live tool output on stdout, reasoning on stderr.
type display struct {
	render  bool // termark renderer available (stdout is a terminal)
	cur     *termark.Renderer
	class   dispClass
	sepNext bool // a content block just ended; separate the next block with a blank line
	rawText bool // raw mode: stdout has received content
	rawLast bool // raw mode: last stdout byte was '\n'
	errText bool // raw mode: stderr has received content (reasoning)
	errLast bool // raw mode: last stderr byte was '\n'

	box    *termark.LiveBox // open tool box (render mode)
	rawTee *rawTee          // open tool box (raw mode)
}

func newDisplay() *display { return &display{} }

// renderable reports whether termark renderers can be used, probing once if
// stdout turns out to be a terminal after all (e.g. the first content of a
// session is a tool box rather than markdown). The probe asks the terminal
// directly: constructing a renderer to test for one would emit the line
// Screen.Close writes, leaving a blank line before the first block.
func (d *display) renderable() bool {
	if d.render {
		return true
	}
	if !term.IsTerminal(int(os.Stdout.Fd())) {
		return false
	}
	d.render = true
	return true
}

// sep emits one empty line, separating an ended content block from the next.
// It is called only between blocks, never while a renderer is active.
func (d *display) sep() {
	if d.cur != nil {
		return
	}
	if d.render {
		fmt.Fprint(os.Stdout, "\r\n")
		d.rawLast = true
		return
	}
	if !d.rawText {
		return
	}
	if !d.rawLast {
		d.rawWrite("\n") // close a line the previous block left open
	}
	d.rawWrite("\n") // the blank line
}

// open activates a markdown renderer for class, closing any renderer for the
// other class first. Only one renderer is ever active because each owns the
// screen's tail repaint. A class switch finalizes the previous renderer and
// separates the two contexts with a blank line. If stdout is not a terminal,
// New fails and output continues in raw mode.
func (d *display) open(class dispClass) {
	if d.cur != nil && d.class == class {
		return
	}
	if d.cur != nil {
		d.close()
		d.sepNext = true
	}
	if d.sepNext {
		d.sep()
		d.sepNext = false
	}
	style := ""
	if class == dispReasoning {
		style = "reasoning"
	}
	r, err := termark.New(os.Stdout, termark.Options{Style: style})
	if err != nil {
		d.render = false
		return
	}
	d.render = true
	d.cur = r
	d.class = class
}

// close finalizes the active markdown renderer so the screen is settled and
// the terminal is free for other output (a code box, another renderer).
func (d *display) close() {
	if d.cur != nil {
		_ = d.cur.Close()
		d.cur = nil
	}
	d.class = dispNone
}

// endTurn finalizes the current markdown content. In raw mode it terminates
// a stdout line the model left open. Any following block (tool box, next
// turn's content) gets a blank-line separator.
func (d *display) endTurn() {
	d.endErrLine()
	if d.cur != nil {
		d.sepNext = true
		d.close()
		return
	}
	if d.rawText && !d.rawLast {
		d.rawWrite("\n")
	}
	d.sepNext = d.rawText
}

// rawWrite emits plain text to stdout and tracks line termination.
func (d *display) rawWrite(s string) {
	if s == "" {
		return
	}
	fmt.Fprint(os.Stdout, s)
	d.rawText = true
	d.rawLast = strings.HasSuffix(s, "\n")
}

// endErrLine terminates a stderr line the stream left open. Raw mode sends
// reasoning to stderr while the stdout line tracking below covers only stdout,
// so without this a reasoning block that does not end in a newline runs into
// whatever the terminal writes next. It is a no-op in render mode, where
// reasoning goes through a renderer and never touches stderr.
func (d *display) endErrLine() {
	if !d.errText || d.errLast {
		return
	}
	fmt.Fprint(os.Stderr, "\n")
	d.errLast = true
}

// info writes a slash command's result: harness output rather than model
// output, so it bypasses the markdown renderers and goes straight to stdout,
// after any content block that preceded it.
func (d *display) info(s string) {
	d.endErrLine()
	if d.cur != nil {
		d.close()
		d.sepNext = true
	}
	if d.sepNext {
		d.sep()
		d.sepNext = false
	}
	d.rawWrite(s)
}

// output streams agent content (plain markdown).
func (d *display) output(s string) {
	d.endErrLine() // reasoning, if any, was on stderr
	d.open(dispOutput)
	if d.cur != nil {
		_, _ = d.cur.Write([]byte(s))
		return
	}
	d.rawWrite(s)
}

// reasoning streams chain-of-thought content (subdued markdown).
func (d *display) reasoning(s string) {
	d.open(dispReasoning)
	if d.cur != nil {
		_, _ = d.cur.Write([]byte(s))
		return
	}
	fmt.Fprint(os.Stderr, s)
	d.errText = true
	d.errLast = strings.HasSuffix(s, "\n")
}

// toolStart opens a tool call box: header border with the tool name, the
// pretty-printed arguments, then the output header border. After this, the
// tool's stdout and stderr stream into the open box (or straight to stdout
// in raw mode); finish with toolEnd. Runs with no markdown renderer active
// and separates itself from preceding content with a blank line.
func (d *display) toolStart(name, args string) {
	d.endErrLine()
	if d.cur != nil {
		d.close()
		d.sepNext = true
	}
	if d.sepNext {
		d.sep()
		d.sepNext = false
	}

	if d.renderable() {
		d.box = termark.NewLiveBox(os.Stdout)
		d.box.Header("tool: " + name)
		for _, l := range splitContent(args) {
			d.box.Row(l)
		}
		d.box.Header("output")
		return
	}

	d.rawTee = &rawTee{}
	d.rawWrite("Tool: " + name + "\n")
	if args != "" {
		d.rawWrite(strings.TrimSuffix(args, "\n") + "\n")
	}
	d.rawWrite("Output:\n")
}

// toolOut returns the writer the tool's stdout is teed into while it runs.
func (d *display) toolOut() io.Writer {
	if d.box != nil {
		return d.box.Out()
	}
	if d.rawTee != nil {
		return d.rawTee
	}
	return io.Discard
}

// toolErr returns the writer the tool's stderr is teed into while it runs.
func (d *display) toolErr() io.Writer {
	if d.box != nil {
		return d.box.Err()
	}
	if d.rawTee != nil {
		return d.rawTee
	}
	return io.Discard
}

// toolEnd closes the open tool box: commits any unterminated row, notes a
// non-zero exit, and draws the footer border. Any following block gets a
// blank-line separator.
func (d *display) toolEnd(res TGIResult) {
	if d.box != nil {
		d.box.End(res.Code)
		d.box = nil
		d.rawText = true
		d.rawLast = true
		d.sepNext = true
		return
	}
	if d.rawTee != nil {
		if !d.rawTee.nl() {
			d.rawWrite("\n")
		}
		d.rawTee = nil
		if res.Code != 0 {
			d.rawWrite(fmt.Sprintf("(exit %d)\n", res.Code))
		}
		d.sepNext = true
	}
}

// rawTee is the plain-text writer used when stdout is not a terminal: it
// serializes writes from the tool's two pipes (a mutex keeps their chunks
// from interleaving) and records whether the stream ended on a newline.
type rawTee struct {
	mu     sync.Mutex
	endsNL bool
}

func (t *rawTee) Write(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	t.mu.Lock()
	fmt.Fprint(os.Stdout, string(p))
	t.endsNL = p[len(p)-1] == '\n'
	t.mu.Unlock()
	return len(p), nil
}

func (t *rawTee) nl() bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.endsNL
}

// splitContent splits a captured stream into content lines for a code box,
// dropping only the artifact of a single trailing newline.
func splitContent(s string) []string {
	if s == "" {
		return nil
	}
	trimmed := strings.TrimSuffix(s, "\n")
	if trimmed == "" {
		return []string{""}
	}
	return strings.Split(trimmed, "\n")
}
