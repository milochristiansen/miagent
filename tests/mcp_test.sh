#!/bin/sh
# End-to-end smoke test for the MCP bridge. Requires python3 and a built
# build/miagent-mcp plus build/miagent-mcp-host (make builds both).
set -eu

cd "$(dirname "$0")/.."
BRIDGE="$PWD/build/miagent-mcp"
HOST="$PWD/build/miagent-mcp-host"
if [ ! -x "$BRIDGE" ] || [ ! -x "$HOST" ]; then
    echo "build the bridge first: make build/miagent-mcp build/miagent-mcp-host" >&2
    exit 1
fi

TMP=$(mktemp -d)
cleanup() {
    MIAGENT_MCP_RUNTIME_DIR="$TMP/runtime" env -u TGI_METHOD -u TGI_TOOL "$BRIDGE" host-stop >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

mkdir -p "$TMP/project/.miagent" "$TMP/config" "$TMP/runtime" "$TMP/images"
cat > "$TMP/project/.miagent/mcp.json" <<JSON
{
  "mcpServers": {
    "mock": {
      "command": "$PWD/tests/mock_mcp_server.py",
      "timeout": 10,
      "env": { "CONFIG_OVERRIDE": "fromconfig", "EXPANDED": "\${MOCK_SECRET}" }
    }
  }
}
JSON

export MIAGENT_CONFIG_DIR="$TMP/config"
export MIAGENT_MCP_RUNTIME_DIR="$TMP/runtime"
export MIAGENT_MCP_HOST="$HOST"
export MOCK_SECRET="supersecret"
unset TGI_METHOD TGI_TOOL TGI_ATTACHMENT_DIR 2>/dev/null || true

run_tgi() {
    method=$1
    tool=$2
    shift 2
    ( cd "$TMP/project" && TGI_METHOD="$method" TGI_TOOL="$tool" "$@" "$BRIDGE" )
}

echo "== schema"
SCHEMA=$(run_tgi SCHEMA mock)
echo "$SCHEMA" | grep -q 'mcp__mock__echo'
echo "$SCHEMA" | grep -q 'mcp__mock__picture'
echo "$SCHEMA" | grep -q 'mcp__mock__envcheck'
echo "$SCHEMA" | grep -q 'mcp__mock__resources_list'
echo "$SCHEMA" | grep -q 'mcp__mock__resources_read'
LINES=$(printf '%s\n' "$SCHEMA" | wc -l)
[ "$LINES" -ge 4 ]
echo "   $LINES tools"

echo "== invoke"
OUT=$(printf '{"text":"hello"}\n' | run_tgi INVOKE mcp__mock__echo)
[ "$OUT" = "echo: hello" ]

echo "== environment"
OUT=$(printf '{}\n' | run_tgi INVOKE mcp__mock__envcheck)
[ "$OUT" = "secret=supersecret override=fromconfig" ]

echo "== image"
printf '{}\n' | run_tgi INVOKE mcp__mock__picture env TGI_ATTACHMENT_DIR="$TMP/images" >/dev/null
[ -f "$TMP/images/01.png" ]

echo "== resources list"
LIST=$(printf '{}\n' | run_tgi INVOKE mcp__mock__resources_list)
echo "$LIST" | grep -q 'file:///notes/hello.txt'
echo "$LIST" | grep -q 'note://{id}'

echo "== resources read text"
READ=$(printf '{"uri":"file:///notes/hello.txt"}\n' | run_tgi INVOKE mcp__mock__resources_read)
echo "$READ" | grep -q 'hello from resource'

echo "== resources read JSON blob"
READ=$(printf '{"uri":"data://json"}\n' | run_tgi INVOKE mcp__mock__resources_read)
echo "$READ" | grep -q '"answer": 42'

echo "== resources read image"
mkdir -p "$TMP/resource-images"
printf '{"uri":"image://tiny"}\n' | run_tgi INVOKE mcp__mock__resources_read env TGI_ATTACHMENT_DIR="$TMP/resource-images" >/dev/null
[ -f "$TMP/resource-images/01.png" ]

echo "== tool error"
set +e
printf '{}\n' | run_tgi INVOKE mcp__mock__fail >/dev/null 2>"$TMP/fail.err"
CODE=$?
set -e
[ "$CODE" -ne 0 ]
grep -q 'reported an error' "$TMP/fail.err"

echo "== host status"
STATUS=$(env -u TGI_METHOD -u TGI_TOOL "$BRIDGE" status)
echo "$STATUS" | grep -q 'mock \[stdio\] ready'
echo "$STATUS" | grep -q '8 tool(s)'
echo "$STATUS" | grep -q 'resources'

echo "== host survives bridge invocations"
printf '{"text":"again"}\n' | run_tgi INVOKE mcp__mock__echo | grep -q 'echo: again'
FIRST=$(printf '{}\n' | run_tgi INVOKE mcp__mock__counter)
SECOND=$(printf '{}\n' | run_tgi INVOKE mcp__mock__counter)
[ "$FIRST" = "counter=1" ]
[ "$SECOND" = "counter=2" ]

echo "== bare command resolved from PATH"
# The host is already running with the original PATH, which does not include
# pathbin. The bridge sends its current environment with each request, so a
# bare command must resolve against that PATH rather than the host's stale one.
mkdir -p "$TMP/pathbin"
ln -sf "$PWD/tests/mock_mcp_server.py" "$TMP/pathbin/mock-mcp"
cat > "$TMP/project/.miagent/mcp.json" <<JSON
{
  "mcpServers": {
    "mock": {
      "command": "mock-mcp",
      "timeout": 10
    }
  }
}
JSON
set +e
BARE_SCHEMA=$(cd "$TMP/project" && PATH="$TMP/pathbin:$PATH" \
    TGI_METHOD=SCHEMA TGI_TOOL=mock "$BRIDGE" 2>"$TMP/bare.err")
BARE_CODE=$?
set -e
if [ "$BARE_CODE" -ne 0 ] || ! printf '%s\n' "$BARE_SCHEMA" | grep -q 'mcp__mock__echo'; then
    cat "$TMP/bare.err" >&2
    echo "bare command was not resolved from PATH" >&2
    exit 1
fi

echo "== streamable HTTP"
mkdir -p "$TMP/http_project/.miagent"
python3 "$PWD/tests/mock_mcp_http.py" "$TMP/http.port" &
HTTP_PID=$!
trap 'kill "$HTTP_PID" 2>/dev/null || true; cleanup' EXIT INT TERM
i=0
while [ ! -s "$TMP/http.port" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
done
HTTP_PORT=$(cat "$TMP/http.port")
cat > "$TMP/http_project/.miagent/mcp.json" <<JSON
{
  "mcpServers": {
    "remote": {
      "url": "http://127.0.0.1:$HTTP_PORT/mcp",
      "headers": { "Authorization": "Bearer \${MOCK_SECRET}" },
      "timeout": 10
    }
  }
}
JSON
run_http_tgi() {
    method=$1
    tool=$2
    shift 2
    ( cd "$TMP/http_project" && TGI_METHOD="$method" TGI_TOOL="$tool" "$@" "$BRIDGE" )
}
HTTPS_SCHEMA=$(run_http_tgi SCHEMA remote)
echo "$HTTPS_SCHEMA" | grep -q 'mcp__remote__remote_echo'
echo "$HTTPS_SCHEMA" | grep -q 'mcp__remote__resources_read'
OUT=$(printf '{"text":"hi"}\n' | run_http_tgi INVOKE mcp__remote__remote_echo)
[ "$OUT" = "http: hi" ]
HTTP_LIST=$(printf '{}\n' | run_http_tgi INVOKE mcp__remote__resources_list)
echo "$HTTP_LIST" | grep -q 'https://example.test/remote.txt'
HTTP_READ=$(printf '{"uri":"https://example.test/remote.txt"}\n' | run_http_tgi INVOKE mcp__remote__resources_read)
echo "$HTTP_READ" | grep -q 'remote resource body'
kill "$HTTP_PID" 2>/dev/null || true
HTTP_PID=""
trap cleanup EXIT INT TERM

echo "all MCP bridge checks passed"
