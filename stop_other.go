//go:build !unix

package main

import (
	"errors"
	"os"
)

// requestStop reports that this platform has no graceful stop signal, so
// the tool has to be killed.
func requestStop(*os.Process) error {
	return errors.New("graceful stop not supported")
}
