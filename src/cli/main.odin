// miagent: the shared-harness command-line agent. The prompt is the whole,
// unparsed command line (argv[1:] joined with spaces). A prompt beginning with
// "/" is a harness command. This is the CLI counterpart to miagent-desktop.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"
import "../harness"

signal_cancelled: i32
signal_count: i32

cli_signal_handler :: proc "c" (sig: posix.Signal) {
	previous := sync.atomic_add(&signal_count, 1)
	sync.atomic_store(&signal_cancelled, 1)
	if previous >= 1 {
		// The first signal asked the run to stop; a second one is the reader
		// insisting. Restore the default action and re-raise, so a blocked
		// write or a tool the harness cannot interrupt still ends the process.
		act: posix.sigaction_t
		posix.sigaction(sig, &act, nil)
		posix.kill(posix.getpid(), sig)
	}
}

install_signal_handlers :: proc() {
	act: posix.sigaction_t
	act.sa_handler = cli_signal_handler
	act.sa_flags = {}
	posix.sigaction(posix.Signal(posix.SIGINT), &act, nil)
	posix.sigaction(posix.Signal(posix.SIGTERM), &act, nil)
}

usage :: proc() {
	fmt.eprint("Usage: miagent prompt...\n" +
		"The prompt is the raw command line (space-joined)\n" +
		"If the first prompt character is a \"/\" it is treated as a harness command instead of a prompt.\n" +
		"Commands: (/help, /context, /models, /desc, /compact, /new, /sessions, /load).\n" +
		"Configuration is read from MIAGENT_CONFIG_DIR when set, otherwise\n" +
		"$XDG_CONFIG_HOME/miagent (~/.config/miagent by default).\n")
	os.exit(2)
}

Command_Info :: struct {
	name:       string,
	summary:    string,
	need_model: bool,
}

command_table := [?]Command_Info{
	{"help", "list all slash commands", false},
	{"context", "context size and maximum for this session", false},
	{"models", "list the endpoint's models and their supported reasoning levels", false},
	{"desc", "describe the work done in this session in a sentence or two", true},
	{"compact", "replace older conversation with a summary, archiving the session", true},
	{"new", "archive the session and its compaction archives under a generated name, then start fresh", true},
	{"sessions", "list archived sessions by date, with the description each holds", false},
	{"load", "archive this session, then replace it with the named archived session", true},
}

find_command :: proc(name: string) -> (Command_Info, bool) {
	for c in command_table do if c.name == name do return c, true
	return Command_Info{}, false
}

command_lines :: proc() -> []string {
	lines := make([]string, len(command_table))
	for c, i in command_table {
		lines[i] = fmt.aprintf("  /%s\t%s", c.name, c.summary)
	}
	return lines
}

help_text :: proc() -> string {
	b := strings.builder_make()
	strings.write_string(&b, "Enter your prompt on the command line raw or quoted (all segments are space joined). The following slash (/) commands exist:\n")
	for line in command_lines() {
		strings.write_string(&b, line)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

unknown_command :: proc(name: string) {
	fmt.eprintf("unknown command /%s\navailable commands:\n", name)
	for line in command_lines() do fmt.eprintln(line)
	os.exit(2)
}

commas :: proc(n: int) -> string {
	s := fmt.aprintf("%d", n)
	if len(s) <= 3 do return s
	b := strings.builder_make()
	head := len(s) % 3
	if head == 0 do head = 3
	strings.write_string(&b, s[:head])
	for i := head; i < len(s); i += 3 {
		strings.write_byte(&b, ',')
		strings.write_string(&b, s[i:i + 3])
	}
	delete(s)
	return strings.to_string(b)
}

context_line :: proc(h: ^harness.Harness) -> string {
	info := harness.harness_context(h)
	if info.items == 0 do return "context: unknown (the session is empty)"
	note := ""
	if !info.measured {
		if harness.harness_session_compacted(h) {
			note = ", estimated; unmeasured since compaction"
		} else {
			note = ", estimated; no model turn has reported usage yet"
		}
	}
	if info.limit == 0 {
		return fmt.aprintf("context: %s tokens%s (maximum unknown; set MIAGENT_CONTEXT_LIMIT)",
			commas(info.tokens), note)
	}
	return fmt.aprintf("context: %s / %s tokens (%.1f%%%s)",
		commas(info.tokens), commas(info.limit),
		100.0 * f64(info.tokens) / f64(info.limit), note)
}

main :: proc() {
	args := os.args
	if len(args) < 2 do usage()
	prompt := strings.join(args[1:], " ")
	defer delete(prompt)

	install_signal_handlers()

	h: harness.Harness
	if err := harness.harness_init(&h); err != "" {
		fmt.eprintln("loading configuration:", err)
		os.exit(1)
	}
	defer harness.harness_destroy(&h)

	notes := harness.harness_startup_notes(&h)
	defer delete(notes)
	model := harness.harness_model(&h)
	defer delete(model)
	if len(notes) > 0 {
		for line in strings.split(notes, "\n") {
			trimmed := strings.trim_space(line)
			if len(trimmed) == 0 do continue
			// The harness keeps these as startup notes so a GUI can show
			// them; the CLI reports them only when a prompt actually needs
			// the model, exactly as the Go CLI does.
			if trimmed == "OPENAI_MODEL is not set; the agent cannot run until it is configured" do continue
			if trimmed == "OPENAI_API_KEY is not set" do continue
			fmt.eprintln("Warning:", line)
		}
	}

	// Command-line validation happens here, before the harness runs: unknown
	// commands are a usage error (exit 2), and a command that calls the model
	// without one configured is a run error (exit 1).
	is_command := strings.has_prefix(prompt, "/")
	command_name := ""
	if is_command {
		fields := strings.fields(prompt)
		if len(fields) > 0 do command_name = fields[0][1:]
		cmd, found := find_command(command_name)
		if !found do unknown_command(command_name)
		if cmd.need_model && len(model) == 0 {
			fmt.eprintf("Error: /%s needs a model (set OPENAI_MODEL)\n", cmd.name)
			os.exit(1)
		}
		if command_name == "help" {
			if len(fields) > 1 {
				fmt.eprintln("command /help: takes no arguments")
				os.exit(1)
			}
			fmt.print(help_text())
			return
		}
		if command_name == "context" {
			if len(fields) > 1 {
				fmt.eprintln("command /context: takes no arguments")
				os.exit(1)
			}
			fmt.print(context_line(&h))
			fmt.print("\n")
			return
		}
	}

	if !is_command && len(model) == 0 {
		fmt.eprintln("Error: model not specified (set OPENAI_MODEL)")
		os.exit(1)
	}

	tool_size := harness.harness_tool_call_size(&h)
	disp := new_display(tool_size)
	defer display_destroy(&disp)

	if !harness.harness_submit(&h, prompt) {
		fmt.eprintln("could not queue prompt")
		os.exit(1)
	}

	done := false
	had_error := false
	cancel_sent := false

	for !done {
		if sync.atomic_load(&signal_cancelled) != 0 && !cancel_sent {
			harness.harness_cancel(&h)
			cancel_sent = true
		}

		ev: harness.Event
		if harness.harness_poll_event(&h, &ev) {
			switch ev.kind {
			case .Note:
				// A headroom refusal is an early exit, not a note on a
				// completed turn: the Go CLI reports it and exits 1.
				if strings.has_prefix(ev.text, "context:") && strings.contains(ev.text, "headroom to start a turn") {
					had_error = true
				}
				if strings.has_prefix(ev.text, "attached ") && strings.contains(ev.text, " to the tool result") {
					// The attachment annotation belongs to the tool result just
					// closed, so it is subdued and does not get the blank
					// separator command output receives.
					display_subdued(&disp, ev.text)
					display_end_turn(&disp)
				} else {
					text := ev.text
					if !strings.has_suffix(text, "\n") do text = strings.concatenate({text, "\n"}, context.temp_allocator)
					display_info(&disp, text)
				}
			case .Error:
				had_error = true
				display_end_turn(&disp)
				if is_command {
					fmt.eprintf("command /%s: %s\n", command_name, ev.text)
				} else {
					fmt.eprintf("response: %s\n", ev.text)
				}
			case .Reasoning_Delta:
				display_reasoning(&disp, ev.text)
			case .Assistant_Delta:
				display_output(&disp, ev.text)
			case .Tool_Start:
				display_tool_start(&disp, ev.name, ev.text)
			case .Tool_Output:
				display_tool_out(&disp, ev.stream == .Stderr, ev.text)
			case .Tool_End:
				display_tool_end(&disp, ev.code)
			case .Turn_End, .Action_End:
				display_end_turn(&disp)
				done = true
			case .Context, .User, .Assistant_Start, .Assistant_Replace, .Assistant_End, .Reasoning_Start, .Reasoning_Discard, .Reasoning_End, .Session_Changed:
				// The CLI does not echo the prompt and has no separate UI
				// state for these events.
			}
			harness.event_destroy(&ev)
		} else {
			time.sleep(1 * time.Millisecond)
		}
	}

	if sync.atomic_load(&signal_cancelled) != 0 {
		fmt.eprintln("interrupted by signal; session saved (a turn may be incomplete)")
		os.exit(3)
	}

	if had_error do os.exit(1)

	// A completed ordinary turn leaves the usual subdued context-size note,
	// with a BEL so a reader looking away knows the answer is ready.
	if !is_command {
		line := context_line(&h)
		display_subdued(&disp, strings.concatenate({line, "\a"}, context.temp_allocator))
	}
}
