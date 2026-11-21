package harness

import "core:fmt"
import "core:testing"
import "core:time"

// Non-turn work items still need an end event so the CLI stops waiting and the
// GUI clears its live state, but they must not be reported as agent turns:
// that distinction is what keeps the desktop app's turn-end tone quiet after a
// slash command or a prompt rejected before the model runs.
event_ends :: proc(h: ^Harness) -> (turn_ends, action_ends: int) {
	for ev in h.events {
		#partial switch ev.kind {
		case .Turn_End:
			turn_ends += 1
		case .Action_End:
			action_ends += 1
		case:
		}
	}
	return
}

@(test)
test_slash_command_ends_with_action_end :: proc(t: ^testing.T) {
	h := Harness{}
	defer {
		for &ev in h.events do event_destroy(&ev)
		delete(h.events)
	}

	h_run_prompt(&h, "/help")

	turn_ends, action_ends := event_ends(&h)
	testing.expect_value(t, action_ends, 1)
	testing.expect_value(t, turn_ends, 0)
}

@(test)
test_rejected_prompt_ends_with_action_end :: proc(t: ^testing.T) {
	h := Harness{}
	defer {
		for &ev in h.events do event_destroy(&ev)
		delete(h.events)
	}

	// An empty harness has no model configured, so the prompt is rejected
	// before a user item or model request is ever produced.
	h_run_prompt(&h, "hello")

	turn_ends, action_ends := event_ends(&h)
	testing.expect_value(t, action_ends, 1)
	testing.expect_value(t, turn_ends, 0)
}

// `/close` is `/new` plus a request for a tabbed consumer to drop the session
// tab. The CLI ignores Session_Close; the desktop app uses it after the archive
// has completed (or when there was nothing to archive).
@(test)
test_close_command_requests_tab_close :: proc(t: ^testing.T) {
	dir := fmt.aprintf("/tmp/miagent-close-command-%d", time.to_unix_nanoseconds(time.now()))
	defer delete(dir)
	session_path := fmt.aprintf("%s/session.jsonl", dir)
	defer delete(session_path)

	h := Harness{}
	h.session = session_init(session_path)
	defer session_destroy(&h.session)
	defer {
		for &ev in h.events do event_destroy(&ev)
		delete(h.events)
	}

	h_run_prompt(&h, "/close")

	close_requests := 0
	for ev in h.events {
		#partial switch ev.kind {
		case .Session_Close:
			close_requests += 1
		case:
		}
	}
	turn_ends, action_ends := event_ends(&h)
	testing.expect_value(t, close_requests, 1)
	testing.expect_value(t, action_ends, 1)
	testing.expect_value(t, turn_ends, 0)
}
