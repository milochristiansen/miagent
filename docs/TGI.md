
# Tools, TGI, and MiAgent

MiAgent supports tool calling via a protocol named Tool Gateway Interface, based on a simplified version of CGI, an
early interface protocol used to script web servers. TGI sends requests to the tool as JSON over standard input, and
takes results on standard output and standard error in whatever format the tool chooses to use. Like CGI, environment
variables are used to pass some other useful information that the call will need.


## Tool environment:

Alongside the process environment it inherits, every tool is run with:

* **`TGI_VERSION`** — the protocol version, currently `1`.
* **`TGI_METHOD`** — `SCHEMA` during discovery, `INVOKE` during a call.
* **`TGI_TOOL`** — during discovery the tool file's name, during a call the name
  the tool declared in its schema.
* **`MIAGENT_CONFIG_DIR`** — the resolved configuration directory (see below).
  It is always set, whether it was configured or defaulted, so a tool can find
  the installed prompts, tools, and `.env` without repeating the XDG
  resolution.


## Tool Discovery:

When MiAgent starts up, all tools are run with `TGI_METHOD` set to `SCHEMA`, `TGI_TOOL` set to the file name, and no
standard input provided. The tool is then expected to provide a JSON schema describing the tool in a format that the
harness will be able to read.

The following fields are supported:

* **`name`** (required, non-empty) — the function name the model will call. The file name is irrelevant; two files may
  declare the same function (see precedence below). The name should consist of letters, digits, underscores, and dashes,
  with no spaces.
* **`description`** — what the tool does and when to use it. This is the model's only instruction manual for the tool,
  so make it specific, including how to read failures.
* **`parameters`** — a [JSON Schema](https://json-schema.org/) object describing the arguments. It is forwarded to the
  model provider as-is; the harness does not validate it, and the provider is what enforces it. A tool that takes no
  arguments can omit this field.

If the tool exits with a non-zero code or a `name` is not provided, a warning will be printed and the tool skipped.

Tools are loaded from the following directories in lexical order.

1. `$MIAGENT_CONFIG_DIR/tools` — the installed base set (`$XDG_CONFIG_HOME/miagent/tools`, or
   `~/.config/miagent/tools`, by default).
2. `<working-directory>/.miagent/tools` — the project-local set.

If multiple tools use the same name, the last loaded tool wins.


## Tool Calls:

Once a list of tools is created, if the model attempts to execute a tool call the harness will look up the tool name in
its list and calls the program associated with the tool setting `TGI_METHOD` set to `INVOKE` and `TGI_TOOL` to the tool
name. Any arguments provided will be on standard input. It is then the job of the tool program to read standard input,
parse any arguments it needs, and write the results to standard output in whatever format it wants to provide. Standard
error is also captured, and it is suggested it be used for error output and the like.

A non-zero exit code is reported to the model along with the results, but the harness does not do any special handling
of non-zero returns.

The model will get the raw output from standard out, the raw output from standard error, and the tool return code.
Standard out and error will not be interleaved. The data the model receives will have the following form:

```json
{
    "exit_code": 0,
    "stdout": "",
    "stderr": ""
}
```

(you may need to take this into account when writing your tool description, but most likely not)

For obvious reasons, keep your writing under control. You don't want to balloon context for no reason.

The tool call with not finish until the tool itself exits, and the output pipes are closed. If long running children
are spawned that retain either of the output pipes, they could cause the tool call to hang.

If the harness receives an exit flavored signal while a tool is running (`SIGINT` or `SIGTERM`) it will send `SIGTERM`
to the tool, wait up to 5 seconds for it to exit, and then sends `SIGKILL` and closes the pipes. For a good user
experience, you should close gracefully as soon as you possibly can when getting a signal to do so.


## Installing Tools:

Generally it is recommended to install tools globally in `$MIAGENT_CONFIG_DIR/tools`, however when installing from
an agent where this path is not writeable tools should be installed to the local tools directory at `./.miagent/tools`


## Example Tool:

The following is a fairly simple shell script implementing a "wordcount" tool using `jq` and `wc`.

```sh
#!/bin/sh

case "$TGI_METHOD" in
  SCHEMA)
    cat <<'EOF'
{
  "name": "wordcount",
  "description": "Count the lines, words, and characters in the given text. On success, prints the counts on one line in that order. Exits 2 with a message in stderr when the 'text' argument is missing or the JSON is malformed.",
  "parameters": {
    "type": "object",
    "properties": {
      "text": {
        "type": "string",
        "description": "The text to measure."
      }
    },
    "required": ["text"]
  }
}
EOF
    ;;

  INVOKE)
    if ! command -v jq >/dev/null 2>&1; then
      echo "jq not found in PATH" >&2
      exit 127
    fi
    text=$(jq -r '.text // empty' 2>/dev/null) || {
      echo "could not parse arguments as JSON" >&2
      exit 2
    }
    if [ -z "$text" ]; then
      echo "missing or empty 'text' argument" >&2
      exit 2
    fi
    printf '%s' "$text" | wc
    ;;

  *)
    echo "wordcount: unknown TGI_METHOD '${TGI_METHOD}'" >&2
    exit 2
    ;;
esac
```
