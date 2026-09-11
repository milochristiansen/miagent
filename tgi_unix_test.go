//go:build unix

package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// waitForFile blocks until path exists, failing the test if it does not
// appear within a few seconds.
func waitForFile(t *testing.T, path string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(path); err == nil {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("%s did not appear", path)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// startSlowTool writes a tool that installs the given trap, signals that it
// is running by creating ready, then loops until it is stopped. It returns a
// function that cancels the tool's context and yields its result.
func startSlowTool(t *testing.T, dir, ready, trap string) func() TGIResult {
	t.Helper()
	tool := filepath.Join(dir, "slow")
	script := fmt.Sprintf("#!/bin/sh\n%s\n: > %q\nwhile :; do sleep 0.05; done\n", trap, ready)
	if err := os.WriteFile(tool, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)

	ch := make(chan TGIResult, 1)
	go func() {
		ch <- RunTGITool(ctx, "slow", tool, "INVOKE", strings.NewReader("{}"), nil, nil)
	}()

	waitForFile(t, ready)

	return func() TGIResult {
		cancel()
		select {
		case r := <-ch:
			return r
		case <-time.After(toolStopGrace + 5*time.Second):
			t.Fatal("tool did not shut down")
			return TGIResult{}
		}
	}
}

// TestRunTGIToolStopsGracefully covers early shutdown: on a platform with a
// graceful stop signal the tool is asked to exit with SIGTERM and given a
// chance to handle it, rather than being killed outright.
func TestRunTGIToolStopsGracefully(t *testing.T) {
	dir := t.TempDir()
	stop := startSlowTool(t, dir, filepath.Join(dir, "ready"), "trap 'exit 42' TERM")

	res := stop()
	if res.Err != nil {
		t.Fatalf("running the tool: %v", res.Err)
	}
	if res.Code != 42 {
		t.Fatalf("tool exited %d, want 42 (SIGTERM handled, not killed)", res.Code)
	}
}

// TestTerminateToolKillsAfterGrace covers the escalation: a process that
// ignores SIGTERM is waited on for the grace period and then killed.
func TestTerminateToolKillsAfterGrace(t *testing.T) {
	dir := t.TempDir()
	ready := filepath.Join(dir, "ready")
	tool := filepath.Join(dir, "ignore-term")
	script := fmt.Sprintf("#!/bin/sh\ntrap '' TERM\n: > %q\nwhile :; do sleep 1; done\n", ready)
	if err := os.WriteFile(tool, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}

	cmd := exec.Command(tool)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	waitForFile(t, ready)

	done := make(chan bool)
	go func() {
		_ = cmd.Wait()
		close(done)
	}()

	const grace = 200 * time.Millisecond
	start := time.Now()
	terminateTool(cmd.Process, done, grace)

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("process did not die")
	}
	if code := cmd.ProcessState.ExitCode(); code != -1 {
		t.Fatalf("process exited %d, want -1 (killed)", code)
	}
	if elapsed := time.Since(start); elapsed < grace {
		t.Fatalf("process exited after %v, want it to survive the %v grace period", elapsed, grace)
	} else if elapsed > 2*time.Second {
		t.Fatalf("process took %v to die, want it killed after the grace period", elapsed)
	}
}

// killPID kills the process whose pid is written to pidfile, if any.
func killPID(pidfile string) {
	b, err := os.ReadFile(pidfile)
	if err != nil {
		return
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil {
		return
	}
	if p, err := os.FindProcess(pid); err == nil {
		_ = p.Kill()
	}
}

// TestTerminateToolClosesPipesAfterKill covers the escaped-child case: a
// tool that spawns a child inheriting its output pipes and then ignores
// SIGTERM. Killing the tool does not close those pipes, so the drains would
// block on them forever unless terminateTool closes our read ends.
func TestTerminateToolClosesPipesAfterKill(t *testing.T) {
	dir := t.TempDir()
	ready := filepath.Join(dir, "ready")
	pidfile := filepath.Join(dir, "child.pid")
	tool := filepath.Join(dir, "leaky")
	script := fmt.Sprintf("#!/bin/sh\nsleep 30 &\necho $! > %q\ntrap '' TERM\n: > %q\nwhile :; do sleep 1; done\n",
		pidfile, ready)
	if err := os.WriteFile(tool, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { killPID(pidfile) })

	cmd := exec.Command(tool)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		_, _ = io.Copy(io.Discard, stdout)
	}()
	go func() {
		defer wg.Done()
		_, _ = io.Copy(io.Discard, stderr)
	}()

	waitForFile(t, ready)

	// The tool ignores SIGTERM, so this escalates to SIGKILL and must then
	// close the pipe read ends to unblock the drains.
	terminateTool(cmd.Process, make(chan bool), 200*time.Millisecond, stdout, stderr)

	drained := make(chan struct{})
	go func() {
		wg.Wait()
		close(drained)
	}()
	select {
	case <-drained:
	case <-time.After(3 * time.Second):
		t.Fatal("output drains stayed blocked after the tool was killed")
	}
	_ = cmd.Wait()
}
