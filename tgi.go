// TGI tool execution (see tools/): running tools as subprocesses with a
// minimal environment, capturing stdout and stderr as separate channels,
// and tracking the running tool process so a shutdown signal can be
// forwarded to it.
package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"
	"time"
)

// TGIResult is the outcome of a TGI tool invocation.
type TGIResult struct {
	Code   int    `json:"exit_code"` // Can be -1 if the tool didn't exit on its own.
	Stdout string `json:"stdout"`
	Stderr string `json:"stderr"`
	Err    error  `json:"call_err,omitzero"`
}

// toolCallTimeout bounds a single TGI tool call. It is applied fresh to every
// call, so a tool invoked twice in one turn gets the full limit both times. A
// call that reaches it is stopped the same way an interrupt stops one (see
// terminateTool) and the timeout is reported in the result.
const toolCallTimeout = 5 * time.Minute

// RunTGITool runs the given binary as a TGI tool and returns the result.
// teeOut and teeErr, when non-nil, additionally receive the tool's stdout
// and stderr live as it runs (used to stream output into the display's open
// tool box); they may be written from concurrent goroutines.
//
// The call is bounded by toolCallTimeout, fresh for each call, so a tool that
// hangs cannot hang the harness.
func RunTGITool(ctx context.Context, name, toolPath, method string, input io.Reader, teeOut, teeErr io.Writer) TGIResult {
	return runTGITool(ctx, toolCallTimeout, name, toolPath, method, input, teeOut, teeErr)
}

// runTGITool is RunTGITool with an explicit per-call limit, so tests can
// exercise the timeout without waiting out the real one. A limit of zero
// applies no timeout.
func runTGITool(ctx context.Context, limit time.Duration, name, toolPath, method string, input io.Reader, teeOut, teeErr io.Writer) TGIResult {
	if limit > 0 {
		// Layer the limit on the caller's context rather than replacing it:
		// a call ends on whichever comes first — the tool finishing, an
		// interrupt, or the limit expiring.
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, limit)
		defer cancel()
	}

	cmd := exec.Command(toolPath)

	cmd.Env = append(os.Environ(), []string{
		"TGI_VERSION=1",
		"TGI_METHOD=" + method,
		"TGI_TOOL=" + name,
	}...)
	if method == "INVOKE" {
		cmd.Stdin = input
	}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return TGIResult{Err: fmt.Errorf("stdout pipe: %v", err)}
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return TGIResult{Err: fmt.Errorf("stderr pipe: %v", err)}
	}
	if err := cmd.Start(); err != nil {
		return TGIResult{Err: fmt.Errorf("start: %v", err)}
	}

	// Output buffers (returned to the caller for the model) with optional
	// live tees into the display.
	var outBuf, errBuf bytes.Buffer
	outTarget := io.Writer(&outBuf)
	errTarget := io.Writer(&errBuf)
	if teeOut != nil {
		outTarget = io.MultiWriter(&outBuf, teeOut)
	}
	if teeErr != nil {
		errTarget = io.MultiWriter(&errBuf, teeErr)
	}

	var wg sync.WaitGroup
	wg.Add(2)
	done := make(chan bool) // Needed to clean up the shutdown listener.

	// Drain output pipes
	go func() {
		defer wg.Done()
		_, _ = io.Copy(outTarget, stdout)
	}()
	go func() {
		defer wg.Done()
		_, _ = io.Copy(errTarget, stderr)
	}()

	// Listen for a shutdown command or the per-call limit.
	var listener sync.WaitGroup
	listener.Add(1)
	go func() {
		defer listener.Done()
		select {
		case <-ctx.Done():
			terminateTool(cmd.Process, done, toolStopGrace, stdout, stderr)
		case <-done:
		}
	}()

	// Wait until output pipes are drained.
	wg.Wait()

	// Close out the command (also break down the shutdown listener)
	_ = cmd.Wait()
	close(done)
	listener.Wait()

	// A deadline means the per-call limit was what ended the call; an
	// interrupt cancels the derived context too, but with context.Canceled.
	// Say which it was where the display and the model will both see it, and
	// force the "didn't exit on its own" code even if the tool handled the
	// stop signal and exited zero.
	timedOut := errors.Is(ctx.Err(), context.DeadlineExceeded)
	if timedOut {
		note := fmt.Sprintf("tool call timed out after %s\n", limit)
		if errBuf.Len() > 0 && !bytes.HasSuffix(errBuf.Bytes(), []byte("\n")) {
			errBuf.WriteByte('\n')
		}
		errBuf.WriteString(note)
		if teeErr != nil {
			_, _ = io.WriteString(teeErr, note)
		}
	}

	code := cmd.ProcessState.ExitCode()
	if timedOut {
		code = -1
	}
	return TGIResult{
		Stdout: outBuf.String(),
		Stderr: errBuf.String(),
		Code:   code,
	}
}

// toolStopGrace is how long a tool is given to exit after it is asked to
// stop, before it is killed.
const toolStopGrace = 5 * time.Second

// terminateTool stops a running tool process, giving it grace to exit after
// it is asked to stop. Where the platform supports a graceful stop the tool
// is asked to exit with SIGTERM; where it does not (Windows) it is killed
// outright. A tool that ignores SIGTERM is killed once grace expires. done
// is closed once the process has been reaped, which bounds the wait to the
// tool's actual lifetime.
//
// A forced kill also closes the given pipes. Killing the tool does not
// necessarily close the write ends of its output pipes: children it spawned
// inherit them and can keep them open, which would leave the caller's drains
// blocked on them forever. Closing our read ends lets those drains finish;
// any child that survives is on its own.
func terminateTool(p *os.Process, done <-chan bool, grace time.Duration, pipes ...io.Closer) {
	err := requestStop(p)
	switch {
	case err == nil:
		timer := time.NewTimer(grace)
		defer timer.Stop()
		select {
		case <-done:
			return
		case <-timer.C:
			_ = p.Kill()
		}
	case errors.Is(err, os.ErrProcessDone):
		// The tool is already gone; its pipes will reach EOF on their own,
		// so leave them alone rather than risk dropping buffered output.
		return
	default:
		_ = p.Kill()
	}
	for _, c := range pipes {
		if c != nil {
			_ = c.Close()
		}
	}
}
