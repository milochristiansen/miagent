//go:build unix

package main

import (
	"os"
	"syscall"
)

// requestStop asks the tool to exit with SIGTERM. Platforms without a
// graceful stop signal report an error so the caller kills it instead.
func requestStop(p *os.Process) error {
	return p.Signal(syscall.SIGTERM)
}
