// TGI tool execution (see tools/): running tools as subprocesses with a
// minimal environment, capturing stdout and stderr as separate channels,
// and tracking the running tool process so a shutdown signal can be
// forwarded to it.
package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"
)

// TGIResult is the outcome of a TGI tool invocation.
type TGIResult struct {
	Code   int    `json:"exit_code"` // Can be -1 if the tool didn't exit on its own.
	Stdout string `json:"stdout"`
	Stderr string `json:"stderr"`
	Err    error  `json:"call_err,omitzero"`
}

// RunTGITool runs the given binary as a TGI tool and returns the result.
// teeOut and teeErr, when non-nil, additionally receive the tool's stdout
// and stderr live as it runs (used to stream output into the display's open
// tool box); they may be written from concurrent goroutines.
func RunTGITool(ctx context.Context, name, toolPath, method string, input io.Reader, teeOut, teeErr io.Writer) TGIResult {
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

	// Listen for shutdown command.
	go func() {
		select {
		case <-ctx.Done():
			cmd.Process.Signal(os.Kill)
		case <-done:
		}
	}()

	// Wait until output pipes are drained.
	wg.Wait()

	// Close out the command (also break down the shutdown listener)
	_ = cmd.Wait()
	close(done)

	return TGIResult{
		Stdout: outBuf.String(),
		Stderr: errBuf.String(),
		Code:   cmd.ProcessState.ExitCode(),
	}
}
