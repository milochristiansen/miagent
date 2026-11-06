# harness

The reusable agent harness behind MiAgent Desktop and its command-line client.
It has no UI dependencies and is the shared core of the desktop app (`src/`) and
the CLI (`src/cli/`).

## Public surface

- `harness_init(*Harness) -> string` — load configuration for the current
  directory, the session, prompts, and tools, then start the worker thread. The
  returned string is a startup warning/error (empty on success); non-fatal notes
  are available from `harness_startup_notes`.
- `harness_init_project(*Harness, project_dir) -> string` — the same, rooted at
  an explicit project directory. Tools run with that directory as their working
  directory, and relative session paths resolve beneath it. At the start of each
  later turn the worker reloads dotenv/config, instructions, and tool discovery;
  the active session path is preserved so configuration changes do not switch
  conversations.
- `harness_init_project_session(*Harness, project_dir, session_path) -> string`
  — the same, with an explicit session file. The GUI uses one harness per
  conversation tab; an empty `session_path` keeps the default
  `MIAGENT_SESSION` / `.miagent/session.jsonl` behavior.
- `harness_destroy(*Harness)` — stop the worker and free everything.
- `harness_submit(*Harness, prompt) -> bool` — queue a prompt.
- `harness_load_archive(*Harness, archive_path) -> bool` — queue the same
  action as `/load` for an already-resolved archive path. This accepts paths
  containing spaces and is what the desktop preview button uses.
- `harness_cancel(*Harness)` / `harness_is_running(*Harness)`.
- `harness_poll_event(*Harness, *Event) -> bool` — drain the structured event
  queue. Every returned event owns its strings; call `event_destroy`.
- `harness_history(*Harness) -> []StoredItem` — deep copy of the loaded session
  for initial display. Free with `harness_free_items`.
- `harness_read_session_items(path) -> ([]StoredItem, string)` and
  `harness_read_archive_items(path) -> ([]StoredItem, string)` — read-only
  conversation loading for previews, without touching a live harness.
- `harness_context(*Harness) -> Context_Info` — cached token/context state.
- `harness_snapshot(*Harness) -> Harness_Snapshot` — deep-copied debug view:
  resolved configuration, prompt documents, session nuggets, discovered tools,
  recent and total usage, and the last/current turn's prompt, status, tool
  calls, request sizes, and response usage. Destroy it with
  `harness_snapshot_destroy`.
- `harness_model`, `harness_session_path`, `harness_project_dir`,
  `harness_tool_count`, `harness_startup_notes`. String getters return owned
  copies, because configuration can be replaced between turns.
- `config_dir_path()` — the installation configuration directory, without
  loading dotenv files.

Slash command support includes `/help`, `/context`, `/models`, `/new`,
`/sessions`, `/load`, `/compact`, and `/desc`. Session commands match the CLI's
gzip/tar archive names, `session-name.md` entries, compaction prompts, and
`prepak-` archives. `/models` reads the endpoint's `/models` document through
the buffered libcurl shim and annotates each model with the reasoning levels
the endpoint reports or the harness's model-family table knows.

Events cover user prompts, assistant/reasoning deltas and ends, tool
start/output/end, context updates, notes, errors, and turn completion.

When MCP configuration is present (`$MIAGENT_CONFIG_DIR/mcp.json` or
`<project>/.miagent/mcp.json`), discovery also runs the `miagent-mcp` bridge as
a TGI tool. It declares every MCP tool under an `mcp__server__tool` name, so MCP
and ordinary TGI tools share one tools array. Resource-capable servers also get
generic `mcp__server__resources_list` and `mcp__server__resources_read` tools.
The bridge talks to a detached background host; see `docs/MCP.md`. `harness_mcp_configured` and
`harness_has_mcp_tools` let a UI decide whether to show MCP status.

## Compatibility

Request bodies are marshalled with sorted object keys (`marshal_request`).
The API caches on an exact token prefix and flattens the tool schemas ahead
of the conversation, so a request whose maps re-emit in a different order
each turn misses the cache from its first token. Sorting also matches the Go
CLI, whose tool definitions are marshalled from Go maps.

The per-turn config/prompt/tool reload is cache-neutral when nothing changed:
the conversation input comes from the untouched session, instructions are
rebuilt from the same files, ordinary tools are discovered in sorted directory
order, MCP tools are sorted by server and tool name, and the request marshaler
sorts every object key. The reload regression test compares the encoded request
body across two no-op reloads.

The package reads the same `MIAGENT_CONFIG_DIR`, `.env`, prompts, and TGI tools
as the Go CLI, and reads/writes the CLI's JSONL session format (including
reasoning, function calls, generic tool attachments, nugget items, usage, and
compaction records). Model
calls use the OpenAI Responses API with the same request shape and SSE event
handling as the CLI. Dotenv values are kept per `Harness` (rather than written
into the process environment), so multiple project harnesses can run in one
process with their own configuration and child-process environments.

`http.c` is the one native shim. Build it into `build/libharness.a`, which
`provider.odin` links against:

```sh
cc -O2 -fPIC -Wall -Wextra -c src/harness/http.c -o build/http.o
ar rcs build/libharness.a build/http.o
```

The final link also needs `-lcurl -lz`.
