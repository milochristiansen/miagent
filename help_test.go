package main

import (
	"context"
	"strings"
	"testing"
)

// TestHelpText covers the blurb: the harness's prompt guidance, every command,
// and none of the suggestion to run /help that the guidance itself came from.
func TestHelpText(t *testing.T) {
	text := helpText()
	if !strings.Contains(text, "Enter your prompt on the command line raw or quoted (all segments are space joined).") {
		t.Fatalf("helpText() = %q, want the prompt guidance", text)
	}
	for _, suggestion := range []string{"run `miagent /help`", "run miagent /help", "run /help"} {
		if strings.Contains(text, suggestion) {
			t.Fatalf("helpText() still suggests running /help (%q):\n%s", suggestion, text)
		}
	}
	for _, c := range commandTable() {
		if !strings.Contains(text, "/"+c.name) {
			t.Fatalf("helpText() does not list /%s:\n%s", c.name, text)
		}
	}
}

// TestCmdHelp checks that the command prints exactly that text, so the two
// cannot diverge.
func TestCmdHelp(t *testing.T) {
	var out string
	var err error
	out = captureStdout(t, func() {
		err = cmdHelp(context.Background(), nil, nil, newDisplay(), nil)
	})
	if err != nil {
		t.Fatalf("cmdHelp: %v", err)
	}
	if out != helpText() {
		t.Fatalf("stdout = %q, want helpText()", out)
	}
}

// TestCmdHelpRejectsArguments keeps the command's contract with the dispatcher.
func TestCmdHelpRejectsArguments(t *testing.T) {
	if err := cmdHelp(context.Background(), nil, nil, newDisplay(), []string{"x"}); err == nil {
		t.Fatal("cmdHelp accepted an argument, want an error")
	}
}

// TestHelpIsRegistered covers the command being reachable at all, and listed
// with the others.
func TestHelpIsRegistered(t *testing.T) {
	if _, ok := findCommand("help"); !ok {
		t.Fatal("/help is not registered")
	}
	if !strings.Contains(helpText(), "/help") {
		t.Fatal("help text does not list /help")
	}
}
