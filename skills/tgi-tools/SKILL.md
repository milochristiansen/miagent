---
name: tgi-tools
description: Write, install, and debug MiAgent TGI tools. Use when the user asks to add or change an agent tool, or when tool discovery or invocation fails.
---

# Writing MiAgent TGI Tools

TGI (Tool Gateway Interface) is how MiAgent discovers and calls tools. A tool is an executable file. MiAgent runs it
with `TGI_METHOD=SCHEMA` to discover it and `TGI_METHOD=INVOKE` to call it.

## The two modes

A tool must handle both values of `TGI_METHOD`:

- **`SCHEMA`** — no stdin. Print one JSON object per line, each with a `name`, a `description`, and optional
  `parameters` (a JSON Schema object). A single executable may declare several tools; the call sets `TGI_TOOL` to the
  declared name so the program can tell them apart. If the process exits non-zero or a schema is malformed, MiAgent
  skips the whole file with a warning.
- **`INVOKE`** — read one JSON object from stdin. Write the result to stdout and diagnostics to stderr. A non-zero exit
  code is reported to the model along with the output, so use it for failures.

The description is the model's only manual for the tool: say what it does, when to use it, and how to interpret
failures.

## Install

Put executables in `$MIAGENT_CONFIG_DIR/tools` to install them globally, or in `<project>/.miagent/tools` for a
project-local tool. When two tools declare the same name, the later loaded one wins (project tools load after global
ones). Restart MiAgent or let the next turn's discovery pick up the new file.

## Returning files and hard context

During `INVOKE`, `$TGI_ATTACHMENT_DIR` is an empty per-call directory. Write return files at its top level. Write text
under `$TGI_ATTACHMENT_DIR/nuggets/` to add hard context that `/compact` will not summarize. Name ordered files with a
zero-padded prefix (`01.png`, `02.png`, ...). Keep each file under 32 MiB and the whole call under 48 MiB and 600 files.
The directory is removed after the call, so do not use it for anything else.

## Rules of thumb

- Keep stdout clean: the harness wraps it as `{"exit_code":...,"stdout":...,"stderr":...}`.
- Close child processes and their pipes before exiting; calls time out after five minutes and are terminated on
  `SIGINT`/`SIGTERM`.
- Do not require an installed library if a small shell or standard-library script will do.

## Reference

Read `references/TGI.md` (in this skill directory) for the complete protocol, including attachment classification,
nugget reinjection, discovery precedence, signal handling, and a worked `wordcount` example.
