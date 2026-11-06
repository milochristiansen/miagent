ODIN ?= odin
CC   ?= cc
CXX  ?= g++

MIAGENT_CONFIG_DIR ?= $(HOME)/.config/miagent
GHOSTTY_COMMIT := $(shell cat scripts/ghostty-commit 2>/dev/null)
CIMGUI_CONFIG := wchar32-v1

BUILD := build
CIMGUI := third_party/cimgui
GHOSTTY := third_party/libghostty-vt

# Must match the options used to build libcimgui.a in scripts/bootstrap.sh.
CXXFLAGS := -O2 -fPIC -I$(CIMGUI)/include -DIMGUI_USE_WCHAR32
CFLAGS   := -O2 -fPIC -Wall -Wextra
CIMGUI_HEADERS := $(wildcard $(CIMGUI)/include/*.h)

# The folder picker uses the XDG desktop portal over GIO/D-Bus. Build without
# GIO if it is not installed; the UI then falls back to manual path entry.
GIO_OK := $(shell pkg-config --exists gio-2.0 2>/dev/null && echo yes)
ifeq ($(GIO_OK),yes)
GIO_CFLAGS := $(shell pkg-config --cflags gio-2.0)
GIO_LIBS   := $(shell pkg-config --libs gio-2.0)
else
GIO_CFLAGS := -DMIAGENT_NO_PORTAL
GIO_LIBS   :=
endif
PORTAL_CFLAGS := $(CFLAGS) $(GIO_CFLAGS)

LDFLAGS  := -lstdc++ -lm -lpthread -lutil -lGL -ldl -lcurl -lz $(GIO_LIBS)

SHIMS := $(BUILD)/bridge.o $(BUILD)/pty.o $(BUILD)/portal.o $(BUILD)/image.o
HARNESS_SHIMS := $(BUILD)/http.o $(BUILD)/archive.o
MCP_SHIMS := $(BUILD)/mcp_transport.o
LIBS  := $(CIMGUI)/lib/libcimgui.a $(GHOSTTY)/lib/libghostty-vt.a
ARCHIVE := $(BUILD)/libmiagent.a
HARNESS_LIB := $(BUILD)/libharness.a
MCP_LIB := $(BUILD)/libmcp.a
MCP_BRIDGE := $(BUILD)/miagent-mcp
MCP_HOST := $(BUILD)/miagent-mcp-host
CLI := $(BUILD)/miagent

PHONY := all run debug cli test test-install clean deps distclean install install-mcp uninstall
.PHONY: $(PHONY)

all: ensure-deps $(BUILD)/miagent-desktop $(CLI) $(MCP_BRIDGE) $(MCP_HOST)

# `make` can bootstrap itself on a fresh clone; `make deps` forces the script.
ensure-deps:
	@test -f $(CIMGUI)/lib/libcimgui.a -a -f $(GHOSTTY)/lib/libghostty-vt.a \
		-a "$$(cat $(CIMGUI)/.miagent-config 2>/dev/null)" = "$(CIMGUI_CONFIG)" \
		-a "$$(cat $(GHOSTTY)/.miagent-source 2>/dev/null)" = "$(GHOSTTY_COMMIT)" || { \
		echo "native dependencies missing or out of date, running scripts/bootstrap.sh"; \
		./scripts/bootstrap.sh; \
	}

$(BUILD)/miagent-desktop: $(ARCHIVE) $(HARNESS_LIB) $(MCP_LIB) $(wildcard src/*.odin) $(wildcard src/harness/*.odin) $(wildcard src/mcp/*.odin)
	$(ODIN) build src -out:$@ -extra-linker-flags:"$(LDFLAGS)"

debug: ensure-deps $(ARCHIVE) $(HARNESS_LIB) $(MCP_LIB) $(wildcard src/*.odin) $(wildcard src/harness/*.odin) $(wildcard src/mcp/*.odin)
	$(ODIN) build src -debug -out:$(BUILD)/miagent-desktop -extra-linker-flags:"$(LDFLAGS)"

$(CLI): $(HARNESS_LIB) $(wildcard src/cli/*.odin) $(wildcard src/termark/*.odin) $(wildcard src/harness/*.odin)
	$(ODIN) build src/cli -out:$@ -extra-linker-flags:"-lpthread -lcurl -lz"

cli: $(CLI)

$(BUILD)/bridge.o: src/bridge.c $(CIMGUI_HEADERS) | $(BUILD)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(BUILD)/pty.o: src/pty.c | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/portal.o: src/portal.c | $(BUILD)
	$(CC) $(PORTAL_CFLAGS) -c $< -o $@

$(BUILD)/image.o: src/image.c src/stb_image.h | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/http.o: src/harness/http.c | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/archive.o: src/harness/archive.c | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/mcp_transport.o: src/mcp/transport.c | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

# One merged archive keeps static link order from mattering on the Odin side.
$(ARCHIVE): $(SHIMS) $(LIBS)
	rm -rf $(BUILD)/obj
	mkdir -p $(BUILD)/obj
	cd $(BUILD)/obj && ar x ../../$(CIMGUI)/lib/libcimgui.a
	cd $(BUILD)/obj && ar x ../../$(GHOSTTY)/lib/libghostty-vt.a
	rm -f $@
	ar rcs $@ $(SHIMS) $(BUILD)/obj/*.o

$(HARNESS_LIB): $(HARNESS_SHIMS)
	rm -f $@
	ar rcs $@ $(HARNESS_SHIMS)

$(MCP_LIB): $(MCP_SHIMS)
	rm -f $@
	ar rcs $@ $(MCP_SHIMS)

$(MCP_BRIDGE): $(MCP_LIB) $(wildcard src/mcp/*.odin) $(wildcard src/mcptool/*.odin)
	$(ODIN) build src/mcptool -out:$@ -extra-linker-flags:"-lpthread -lcurl -lz"

$(MCP_HOST): $(MCP_LIB) $(wildcard src/mcp/*.odin) $(wildcard src/host/*.odin)
	$(ODIN) build src/host -out:$@ -extra-linker-flags:"-lpthread -lcurl -lz"

$(BUILD):
	mkdir -p $@

run: all
	./$(BUILD)/miagent-desktop

test: all test-install
	$(ODIN) test src/termark
	$(ODIN) test src/harness -extra-linker-flags:"-lcurl -lz"
	$(ODIN) test src -extra-linker-flags:"$(LDFLAGS)"
	./tests/skills_test.sh
	./tests/mcp_test.sh

test-install: all
	./tests/install_test.sh

deps:
	./scripts/bootstrap.sh

# Install the desktop app, CLI, MCP binaries, prompts, tools, and docs into the
# user configuration directory. Paths can be overridden with MIAGENT_CONFIG_DIR
# and MIAGENT_BIN_DIR; see ./install.sh --help.
install:
	./install.sh

# Remove only the launcher symlinks; the configuration directory is preserved.
uninstall:
	./uninstall.sh

# Optional: install the bridge where the CLI and desktop can discover it even
# when they are not run from the build directory.  The desktop also finds the
# binaries next to itself, so this is mainly for the MiAgent CLI.
install-mcp: $(MCP_BRIDGE) $(MCP_HOST)
	mkdir -p "$(MIAGENT_CONFIG_DIR)/bin" "$(MIAGENT_CONFIG_DIR)/tools"
	cp $(MCP_BRIDGE) $(MCP_HOST) "$(MIAGENT_CONFIG_DIR)/bin/"
	cp $(MCP_BRIDGE) "$(MIAGENT_CONFIG_DIR)/tools/miagent-mcp"

clean:
	rm -rf $(BUILD)

distclean: clean
	rm -rf .deps third_party
