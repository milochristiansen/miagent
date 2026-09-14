
# MiAgent

MiAgent (My Agent, yes I know the name is stupid, I think its funny), is a simple CLI agent harness written in Go.

The current version is pretty minimal, but useful. Output is rendered to the terminal, with basic formatting, in color.
A basic lightly sandboxed `bash` tool is provided, and there is support for custom tools. You can write tools in
anything you like so long as it can read environment variables and standard in/out. There is some simple support for
session management.

A lot of the code is very "sloppy", straight out of the agent. Some of it was written with thought, care, and attention
by me personally. It depends on how interesting I found something vs how interesting I found the result. Long story
short, the quality is... Variable, but stuff seems to work mostly. Have fun, but don't use this for anything critical.


## Configuration directory

MiAgent reads its prompts, tools, and core environment file from a user-level configuration directory. By default it
is `$XDG_CONFIG_HOME/miagent`, or `~/.config/miagent` when `XDG_CONFIG_HOME` is unset. Set `MIAGENT_CONFIG_DIR` (in
the environment or in a project's `.miagent/.env`) to use a different directory instead. The resolved path is exported
to every tool the harness runs as `MIAGENT_CONFIG_DIR`, so a tool can find the installation without repeating the XDG
resolution.

To successfully run this agent, you need to create that directory, and copy, minimum, the `tools`, `docs`, and `prompts`
directories from this repository. It is suggested that you also copy the `.env.example` file, rename it to `.env`, and
edit it to taste. Make sure to set the model provider information!

```sh
config="${MIAGENT_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/miagent}"
mkdir -p "$config/prompts" "$config/tools" "$config/docs"

cp prompts/* "$config/prompts/" # agent prompts
cp tools/* "$config/tools/"     # executable tools
cp docs/* "$config/docs/"       # agent documentation
cp .env.example "$config/.env"  # endpoint, model, and limits
```


## Tool call display

On a terminal each tool call is drawn as a box with the call's arguments and its live output. `MIAGENT_TOOLCALL_SIZE`
caps how many lines of each section are shown; it defaults to `10`, and `0` shows everything. The output is a window
over the most recent lines, so it scrolls inside the box rather than scrolling the rest of the session away. A value
larger than the terminal is reduced to the terminal height, and the cap is ignored when output is not a terminal (so
a piped or redirected run still records every line).
