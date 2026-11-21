package main

import "base:runtime"
import "core:strings"
import "core:testing"
import "core:time"

// A status poll must reuse the long-lived worker. Creating a fresh thread for
// every poll leaves an 8 MB stack and an allocator arena behind each time,
// which is an unbounded idle leak.
@(test)
test_mcp_status_poller_reuses_worker_thread :: proc(t: ^testing.T) {
	// The status value is allocated on the poller thread and freed here. Both
	// use Odin's heap allocator in production, but under the test runner the
	// main thread's tracking allocator would see that hand-off as a bad free.
	// Run this test on the plain heap allocator instead.
	original_allocator := context.allocator
	context.allocator = runtime.default_context().allocator
	defer context.allocator = original_allocator

	app: App
	defer app_clear_mcp_status(&app)
	project := strings.clone("/tmp/miagent-poller-test")
	defer delete(project)
	app.mcp_status_project = strings.clone(project)
	defer mcp_status_poller_destroy(&app)

	if !testing.expect_value(t, mcp_status_poller_start(&app, project), true) do return
	first := app.mcp_poller.thread
	if !testing.expect(t, first != nil) do return

	if !wait_for_mcp_poll(&app) do return

	if !testing.expect_value(t, mcp_status_poller_start(&app, project), true) do return
	second := app.mcp_poller.thread
	if !testing.expect_value(t, second, first) {
		return
	}
	_ = wait_for_mcp_poll(&app)
}

wait_for_mcp_poll :: proc(app: ^App) -> bool {
	for _ in 0 ..< 300 {
		mcp_status_poller_poll(app)
		if !app.mcp_poller.running do return true
		time.sleep(10 * time.Millisecond)
	}
	return false
}
