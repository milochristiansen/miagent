
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

MiAgent reads its prompts, tools, and core environment file from a user-level configuration directory:
`$XDG_CONFIG_HOME/miagent`, or `~/.config/miagent` when `XDG_CONFIG_HOME` is unset.

To successfully run this agent, you need to create that directory, and copy, minimum, the `tools`, `docs`, and `prompts`
directories from this repository. It is suggested that you also copy the `.env.example` file, rename it to `.env`, and
edit it to taste. Make sure to set the model provider information!

```sh
config="${XDG_CONFIG_HOME:-$HOME/.config}/miagent"
mkdir -p "$config/prompts" "$config/tools" "$config/docs"

cp prompts/* "$config/prompts/" # agent prompts
cp tools/* "$config/tools/"     # executable tools
cp docs/* "$config/docs/"       # agent documentation
cp .env.example "$config/.env"  # endpoint, model, and limits
```
