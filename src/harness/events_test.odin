package harness

import "core:testing"

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
