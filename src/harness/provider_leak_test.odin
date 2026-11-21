package harness

import "core:mem"
import "core:testing"

// The streaming accumulator rebuilds a growing string for reasoning blocks and
// function-call arguments. These tests assert that replacing those strings does
// not leak the previous value: a long stream must leave only the final item
// behind, not one allocation per delta.

feed_event :: proc(state: ^SSE_State, payload: string) {
	handle_stream_event(state, payload)
}

@(test)
test_reasoning_delta_replacement_does_not_leak :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	original_allocator := context.allocator
	context.allocator = mem.tracking_allocator(&track)

	a := turn_accum_init()
	state := SSE_State{turn = &a, emit_live = false}
	for _ in 0 ..< 1000 {
		feed_event(&state, `{"type":"response.reasoning_text.delta","item_id":"rs_1","content_index":0,"delta":"abcdefghij"}`)
	}
	expected := 1000 * len("abcdefghij")
	if len(a.reasoning_items) != 1 || a.reasoning_items[0].reasoning == nil {
		context.allocator = original_allocator
		mem.tracking_allocator_destroy(&track)
		testing.fail_now(t, "reasoning item was not accumulated")
	}
	reasoning := a.reasoning_items[0].reasoning.?
	if len(reasoning.content) != 1 || len(reasoning.content[0].text) != expected {
		context.allocator = original_allocator
		mem.tracking_allocator_destroy(&track)
		testing.fail_now(t, "reasoning text did not grow to the expected size")
	}
	turn_accum_destroy(&a)

	leaked := len(track.allocation_map)
	context.allocator = original_allocator
	mem.tracking_allocator_destroy(&track)
	if !testing.expectf(t, leaked == 0, "reasoning stream leaked %d allocations", leaked) do return
}

@(test)
test_function_arguments_replacement_does_not_leak :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	original_allocator := context.allocator
	context.allocator = mem.tracking_allocator(&track)

	a := turn_accum_init()
	state := SSE_State{turn = &a, emit_live = false}
	for _ in 0 ..< 1000 {
		feed_event(&state, `{"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"abcdefghij"}`)
	}
	expected := 1000 * len("abcdefghij")
	if len(a.fn_items) != 1 || len(a.fn_items[0].arguments) != expected {
		context.allocator = original_allocator
		mem.tracking_allocator_destroy(&track)
		testing.fail_now(t, "function arguments did not grow to the expected size")
	}
	turn_accum_destroy(&a)

	leaked := len(track.allocation_map)
	context.allocator = original_allocator
	mem.tracking_allocator_destroy(&track)
	if !testing.expectf(t, leaked == 0, "function-call argument stream leaked %d allocations", leaked) do return
}
