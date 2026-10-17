
# MiAgent

MiAgent (My Agent, yes I know the name is stupid, I think its funny), is a simple CLI agent harness written in Go.

The current version is pretty minimal, but useful. Output is rendered to the terminal, with basic formatting, in color.
A basic lightly sandboxed `bash` tool is provided, and there is support for custom tools. You can write tools in
anything you like so long as it can read environment variables and standard in/out. There is some simple support for
session management.

A lot of the code is very "sloppy", straight out of the agent. Some of it was written with thought, care, and attention
by me personally. It depends on how interesting I found something vs how interesting I found the result. Long story
short, the quality is... Variable, but stuff seems to work mostly. Have fun, but don't use this for anything critical.

Aside from a `bash` tool, there is also a pair of tools for using the DeepSeek search and fetch APIs. This tool
automatically hides itself if you do not provide a DeepSeek API key, either separately or via using a DeepSeek model.


## Should I use this?

No.

This agent harness is made for me, and my tastes. You *may* use it, I even put a bit of effort into making it generic in
spots where I could have made it specific to my environment, but I recommend that you do not use this project.

Not because it won't work for you, but because you will likely enjoy the result a lot more if you *make your own!* It
isn't hard, and you will have a tool you understand well enough to tweak it any way you like and have exactly what you
want.

That said, feel free to try this out and steal any ideas you like from it for your own thing, or even use this as a base
to make your own thing. Or, *sigh*, I suppose you could just use this raw the way it is. It works pretty well and I like
it quite a lot, so I guess it will probably do just as well for you. But, really, make your own. It's fun.


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
