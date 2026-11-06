// Entry point for the background MCP host.
package main

import "core:fmt"
import "core:os"
import "../mcp"

main :: proc() {
	args := os.args
	command := len(args) > 1 ? args[1] : ""
	switch command {
	case "", "--foreground", "run":
		os.exit(mcp.host_run())
	case "--help", "-h", "help":
		fmt.printfln(`miagent-mcp-host - background MCP server host for MiAgent

Usage:
  miagent-mcp-host                 run in the foreground (the bridge starts it detached)
  miagent-mcp-host --status        print the running host status
  miagent-mcp-host --stop          stop the running host and its MCP servers
  miagent-mcp-host --help          show this help

The host listens only on loopback and writes its endpoint to
$XDG_RUNTIME_DIR/miagent/mcp-host.json (or $XDG_CACHE_HOME/miagent).
Set MIAGENT_MCP_HOST_IDLE_SECONDS=0 to disable idle shutdown.`)
	case "--status", "status":
		status := mcp.host_status()
		defer mcp.host_status_destroy(&status)
		if !status.running {
			fmt.println("MCP host: not running")
			if len(status.error) > 0 do fmt.println("  ", status.error)
			return
		}
		fmt.printfln("MCP host: running (pid %d, uptime %ds, %d client(s), %d tool(s))", status.pid, status.uptime_seconds, status.clients, status.tool_count)
		for s in status.servers {
			line := fmt.aprintf("  %s [%s] %s, %d tool(s)%s", s.name, s.transport, s.state, s.tool_count, s.resources ? " + resources" : "")
			fmt.println(line)
			if len(s.error) > 0 do fmt.println("    error:", s.error)
			else if len(s.log_tail) > 0 do fmt.printfln("    log: %s", s.log_tail)
			delete(line)
		}
	case "--stop", "stop":
		if err := mcp.shutdown_host(); err != "" {
			fmt.eprintln("miagent-mcp-host:", err)
			os.exit(1)
		}
		fmt.println("MCP host stopped")
	case:
		fmt.eprintln("miagent-mcp-host: unknown argument", command)
		os.exit(2)
	}
}
