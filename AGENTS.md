

## Development aids

Render a frame to a PPM and exit (useful on headless machines):

```sh
MIAGENT_SCREENSHOT=/tmp/miagent.ppm ./build/miagent-desktop
magick /tmp/miagent.ppm /tmp/miagent.png
```

Submit one prompt immediately at launch (handy with a local mock endpoint):

```sh
MIAGENT_PROMPT='summarize this project' ./build/miagent-desktop
```

Print frame timings (first frames plus every 60th frame) to stderr:

```sh
MIAGENT_PROFILE=1 ./build/miagent-desktop
```

Run the MCP bridge smoke test (stdio + streamable HTTP, attachments, errors,
and session persistence):

```sh
./tests/mcp_test.sh
```

Run the Agent Skills smoke test (discovery, parsing, precedence, activation,
and the bundled `tgi-tools` skill):

```sh
./tests/skills_test.sh
```

`scripts/preview.py out.png [cols] [rows]` prints a coarse ASCII preview and
samples colors at normalized coordinates.


## Project Map

Keep this section up to date! If any of this information is outdated make sure to correct it. This is intended to be
helpful for finding what you want in the project, it is not intended to be an authoritative source of truth.

```
src/
  main.odin       GLFW window, OpenGL context, ImGui setup, font/emoji order, frame loop
  app.odin        app state, layout constants, per-project drawer lifecycle
  panels.odin     terminal rail and drawers
  projects.odin   per-project harness/view/shell state + projects pane
  filepicker.odin async portal picker child process + fallback path entry
  audio.odin      turn-end tone via dlopen'd ALSA + terminal-bell fallback
  gui_config.odin window metrics + known projects in gui.json
  portal.c       XDG Desktop Portal FileChooser D-Bus/GIO shim
  conversation.odin  transcript view state + conversation/composer rendering
  markdown.odin   small Markdown renderer (paragraphs, headings, code, lists, tables)
  terminal.odin   PTY <- libghostty-vt <- ImGui draw list; key/mouse encoding, selection, clipboard
  ghostty.odin    libghostty-vt bindings (terminal, render state, key + mouse encoders)
  imgui.odin      cimgui bindings
  theme_config.odin  built-in terminal palette/font + theme.json overrides
  theme.odin      derived UI palette + ImGui style
  ui.odin         draw-list helpers
  util.odin       Rect/color/UTF-8/OSC-7 helpers
  harness/        the reusable agent harness (no UI dependencies)
    harness.odin  public API, worker thread, event queue, agent loop, nugget dedupe
    config.odin   per-project dotenv map, prompts, paths, environment
    session.odin  CLI-compatible JSONL sessions, context sizing, nugget digests
    provider.odin Responses API request/SSE/reconstruction, /models
    tools.odin    TGI tool discovery, execution, attachment/nugget collection
    http.c        libcurl streaming + buffered GET shim
    archive.odin  tar.gz session archives, naming, and atomic file operations
    session_commands.odin  /new, /sessions, /load, /compact, /desc
    archive.c     zlib gzip compression/decompression
  cli/
    main.odin     CLI entry point: prompt/command dispatch, signals, event loop
    display.odin  terminal markdown renderers + live tool boxes, raw fallback
  termark/        terminal markdown formatter ported from the Go CLI
    render.odin   block scanner + inline/block ANSI renderer
    renderer.odin streaming Renderer (commit/tail model)
    screen.odin   cursor-protocol screen manager
    livebox.odin  live tool-call code box
    box.odin      code-box helpers, tab expansion, terminal sizing
    syntax.odin   compact monokai syntax highlighter
    ansi.odin     SGR, width measurement, ANSI-aware wrapping
  mcp/            MCP config, JSON-RPC, host, sessions, and IPC client
  host/main.odin  the detached background host binary
  mcptool/main.odin  the TGI-shaped MCP bridge binary
  pty.c           forkpty/resize/read/write shim
  bridge.c        ImGuiIO/style/font/varargs bridge
prompts/          shared system/compaction/session prompts (installed into the config dir)
tools/            bundled TGI tools: bash, deepseek-search, activate_skill (installed into the config dir)
skills/           bundled global Agent Skills; tgi-tools carries the TGI protocol reference (installed into the config dir)
assets/fonts/     bundled scalable monochrome emoji fallback + OFL license
assets/icons/     hicolor app icon tree: scalable SVG + rendered PNG sizes
.env.example      full dotenv reference, installed as the config .env when missing
theme.json.example  default terminal colors/font, installed for users to copy to theme.json
install.sh        dependency check, build, asset install, launchers, desktop entry, icons
uninstall.sh      remove only the launcher symlinks and installed icons; leaves the config directory
tests/            MCP bridge, activate_skill, and install smoke tests
scripts/
  bootstrap.sh    fetch + build pinned native dependencies
  preview.py      ASCII screenshot preview helper (dev aid)
```
