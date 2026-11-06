
# MiAgent Desktop

MiAgent (My Agent, yes I know the name is stupid, I think its funny), is a simple GUI/CLI agent harness written mostly
in Odin.

This project is specifically designed to be simple almost to the point of being crude, while still being a powerful and
flexible agent harness. I use this harness pretty much exclusively with DeepSeek 4.1 Flash, and that model was used to
write the entire thing. This is my main agent, I use it for everything, every day. This is not some silly little project
cranked out for fun and thrown away. This was written to fit my needs, and I expect to continue refining it for some
time to come.

I wrote this version of the harness in an effort to get away from yet another pile of javascript. I wanted a nice GUI
with native shells in-app, and I did not want it to use a single web technology. I ended up choosing Dear ImGui and
libGhostty for reasons of simplicity and decided to have the whole thing written in Odin because I like it. Very deep
reasoning on my part, but it seems to have mostly worked out. Bring back native desktop apps.


## "Should I use this?"

No.

This agent harness is made for me, and my tastes. You *may* use it, I even put a bit of effort into making it generic in
spots where I could have made it specific to my environment, but I recommend that you do not use this project.

Not because it won't work for you, but because you will likely enjoy the result a lot more if you *make your own!* It
isn't hard, and you will have a tool you understand well enough to tweak it any way you like and have exactly what you
want.

That said, feel free to try this out and steal any ideas you like from it for your own thing, or even use this as a base
to make your own thing. Or, *sigh*, I suppose you could just use this raw the way it is. It works pretty well and I like
it quite a lot, so I guess it will probably do just as well for you. But, really, make your own. It's fun!


## Building

You will need a few things to be installed to build and run this project.

To start, you will need compilers for the main program and its dependencies:

* Odin dev-2026-08 or newer
* Zig 0.16.x
* A C compiler

You will also need the following libraries installed:

* GLFW 3 (libglfw3-dev)
* OpenGL development files (libgl1-mesa-dev or equivalent)
* libcurl development files (libcurl4-openssl-dev or equivalent)
* zlib development files (zlib1g-dev or equivalent)

The following are technically option, but you will want them too:

* GIO/GLib development files (libgio-2.0-dev, libglib2.0-dev) (needed for the file picker to work)
* pkg-config (used to verify dependencies)

Past that, you need a loooong list of standard tools any Linux system will probably have. I'm not gonna list it all
here, if you are running something weird sic an agent on the problem, annoying shit like this is what they are best at.

I wrote this to use Fira Code with powerline support as the font. Fira Code is the default, but the GUI can use another
family or explicit font files through `theme.json` (see Configuring below). Fira Code is a nice font and I like it, but
if you hate it I suppose I will understand.

For the `bash` tool to work, you will need to install Bubble Wrap (`bwrap`). If the `bash` tool doesn't work, you aren't
getting much of anything done. You will also need `bash` and `jq`, but you have those anyway right? The `bash` tool is a
shell script. If you want to make it a `zsh` tool for some reason, it will take you literally less than a minute to do
by hand.

Once you have what you think is everything you need, you can run `make all` to build all the core binaries. Assuming
that doesn't spew errors all over the place, run `make install` to copy the required files to `~/.config/miagent`,
install symlinks to the binaries in `~/.local/bin`, and add a .desktop file for the GUI as well as required icons.
You can run `make uninstall` to delete the symlinks, .desktop file, and icons, but the main install directory will be
left alone.

Once you have run the install, you should be able to run the GUI via `miagent-desktop` or the CLI via `miagent`. They
share settings, sessions, nearly everything really.


## Configuring

There should be a `.env` file in `~/.config/miagent/`. Edit this file to taste. Make sure to set model name, API key,
reasoning level, etc!

Some of the variables you can set here are for default tools, others are only relevant to the CLI. All variables in this
file are loaded into the harness environment, and passed along to tools and the like.

Technically, you can set any variable you want here, but any variable that already exists in the environment will
override the values in the `.env` file. You can also add a per-project `.env` file with exactly the same behavior in
the `.miagent` directory in the project. The variables in the project level file will override the global ones.

You can add an `AGENT.md` file in the global config directory that will be injected into every standard turn.

After the first time you run the GUI, it creates a `gui.json` file with some GUI specific settings in the global config
directory. Most of these are, IMHO, not very interesting. There is also a fully optional theme file, `theme.json` you
can edit to change fonts and colors. There is a somewhat minimal example file in the project root. Set `font_emoji` to
an explicit font path if you want a different emoji fallback.

A bundled monochrome Noto Emoji font supplies emoji glyphs when the regular text fonts do not have them. Noto Color
Emoji itself is a bitmap font with a single fixed 109px strike, which ImGui's rasterizer cannot scale down to UI sizes,
so its colorful glyphs are not used here. A scalable color emoji font would require switching the rasterizer to
FreeType.


## Tools and Prompts

A harness is largely defined by its tools and prompts. The main driving principle of this project is simplicity, and
that drove the choices made here.

This agent harness ships with four tool packages:

* A lightly sandboxed `bash` tool.
* Web search and fetch tools based on DeepSeek's API.
* An MCP bridge tool set for accessing MCP servers.
* An `activate_skill` tool for Agent Skills.

There is no read tool. There is no write tool. There is no edit tool. This is by design, sorta. When I made my first
agent harness, I gave it a `bash` tool and told myself that I would add more tools as I needed them, fully expecting to
write file management tools pretty much right away. However, it just never was an issue. It turns out that, for DeepSeek
at least, it does a really good job of reading, writing, and editing files purely in `bash`. If I take the time to
scroll back through the tool calls there is a lot of `sed` and inline minimal Python scripts to do targeted reads and
edits. Everything just works great. Sometimes I can hardly believe how well it works.

Beyond the tools, the system prompt was lifted pretty much directly from DeepSeek Harness's minimal mode, with some
added bits to keep the agent from navel gazing its own session and stuff. The compaction prompts are largely lifted from
Pi Agent. The summary prompts were written by the agent writing that feature, and lightly edited by me.


## Skills

MiAgent's skill support is completely standard, as defined at [agentskills.io](https://agentskills.io/).

There is one included default skill: `tgi-tools`, a simple instruction manual for writing TGI tools for use with this
agent.


## License

MiAgent is released under the MIT License. See [LICENSE](LICENSE) for the full text.

It bundles, links, or derives from the third-party work listed below. The copyright lines are reproduced here because
they have to travel with redistributions; for every entry licensed MIT, the permission notice is the one in `LICENSE`.


### Bundled source and data

| Component | Where | License | Copyright |
| --- | --- | --- | --- |
| stb_image v2.28 | `src/stb_image.h` | Public domain, or MIT at your option | Copyright (c) 2017 Sean Barrett |
| Noto Emoji Regular | `assets/fonts/` | SIL OFL 1.1, see `assets/fonts/OFL.txt` | Copyright 2013 Google LLC |

`NotoEmoji-Regular.ttf` is a modified copy of Google's Noto Emoji: it is instantiated at weight 400 and subset to the
symbol and emoji ranges. It remains under the OFL rather than the MIT License, and `OFL.txt` ships beside it.


### Statically linked libraries

| Component | License | Copyright |
| --- | --- | --- |
| libghostty-vt (Ghostty) | MIT | Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors |
| cimgui | MIT | Copyright (c) 2015 Stephan Dilly |
| Dear ImGui, via cimgui | MIT | Copyright (c) 2014-2026 Omar Cornut |
| Odin runtime and core library | zlib | Copyright (c) 2016-2025 Ginger Bill |

These are fetched and built by `scripts/bootstrap.sh` and live in `third_party/`, which is generated and not tracked by
git. The script copies the upstream license files there, but the notices above are the ones to keep with binary
distributions.


### Prompt text derived from other agents

| Component | License | Copyright | Used for |
| --- | --- | --- | --- |
| DeepSeek Harness | MIT | Copyright (c) 2026 DeepSeek | `prompts/SYSTEM.md` follows its minimal-mode system prompt |
| Pi | MIT | Copyright (c) 2025 Mario Zechner | `prompts/COMPACT-*.md` follow its compaction prompts |

Upstream projects: [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) and
[earendil-works/pi](https://github.com/earendil-works/pi).


### System and build-time dependencies

The GUI links against libraries provided by the system: GLFW (zlib/libpng), OpenGL, libcurl (curl license), zlib (zlib
license), GLib/GIO (LGPL-2.1-or-later), and ALSA (LGPL-2.1-or-later, loaded with `dlopen`). None of their code is
redistributed in this repository or in its binaries. The same holds for build and runtime tooling: the Odin compiler
(zlib), Zig (MIT), GCC/G++ (GPLv3 with the runtime exception), Bubblewrap (LGPL-2.0-or-later), `jq` (MIT), and `bash`
(GPLv3).

Fira Code is the default UI font family name, but it is not bundled or installed by this project. Users who install it
do so under the SIL Open Font License 1.1.


### Redistributing binaries

If you ship a compiled build, include `LICENSE`, this section (or a copy of each notice above), and
`assets/fonts/OFL.txt` alongside the binaries.
