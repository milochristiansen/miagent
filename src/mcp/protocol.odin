package mcp

import "core:encoding/json"
import "core:fmt"
import "core:strings"

JSONRPC_VERSION :: "2.0"
PROTOCOL_VERSION :: "2025-06-18"
CLIENT_NAME :: "miagent-mcp-host"
CLIENT_VERSION :: "1.0.0"

// Tool_Kind distinguishes real MCP tools from the two synthetic tools that
// adapt MCP resources to TGI.
Tool_Kind :: enum {
	Mcp_Tool,
	Resources_List,
	Resources_Read,
}

// Advertised_Tool is the normalized tools/list entry the host returns to the
// bridge and the UI.
Advertised_Tool :: struct {
	server:        string,
	name:          string,
	function_name: string,
	title:         string,
	description:   string,
	parameters:    json.Value,
	kind:          Tool_Kind,
}

advertised_tool_destroy :: proc(t: ^Advertised_Tool) {
	delete(t.server)
	delete(t.name)
	delete(t.function_name)
	delete(t.title)
	delete(t.description)
	json.destroy_value(t.parameters)
	t^ = {}
}

advertised_tools_destroy :: proc(tools: ^[]Advertised_Tool) {
	for &t in tools^ do advertised_tool_destroy(&t)
	delete(tools^)
	tools^ = nil
}

Rpc_Error :: struct {
	code:    int        `json:"code"`,
	message: string     `json:"message"`,
	data:    json.Value `json:"data,omitempty"`,
}

Rpc_Request :: struct {
	jsonrpc: string     `json:"jsonrpc"`,
	id:      Maybe(int) `json:"id,omitempty"`,
	method:  string     `json:"method"`,
	params:  json.Value `json:"params,omitempty"`,
}

Rpc_Notification :: struct {
	jsonrpc: string     `json:"jsonrpc"`,
	method:  string     `json:"method"`,
	params:  json.Value `json:"params,omitempty"`,
}

Rpc_Response :: struct {
	jsonrpc: string     `json:"jsonrpc"`,
	id:      json.Value `json:"id"`,
	result:  json.Value `json:"result,omitempty"`,
	error:   Rpc_Error  `json:"error,omitempty"`,
}

Rpc_Incoming :: struct {
	jsonrpc: string     `json:"jsonrpc"`,
	id:      json.Value `json:"id"`,
	method:  string     `json:"method"`,
	params:  json.Value `json:"params"`,
	result:  json.Value `json:"result"`,
	error:   Rpc_Error  `json:"error"`,
}

jsonrpc_request :: proc(id: int, method: string, params: json.Value) -> string {
	o := make(json.Object)
	o[strings.clone("jsonrpc")] = json.String(strings.clone(JSONRPC_VERSION))
	o[strings.clone("id")] = json.Integer(id)
	o[strings.clone("method")] = json.String(strings.clone(method))
	if params != nil do o[strings.clone("params")] = json.clone_value(params)
	data, err := json.marshal(o)
	json.destroy_value(o)
	if err != nil do return ""
	return string(data)
}

jsonrpc_notification :: proc(method: string, params: json.Value) -> string {
	o := make(json.Object)
	o[strings.clone("jsonrpc")] = json.String(strings.clone(JSONRPC_VERSION))
	o[strings.clone("method")] = json.String(strings.clone(method))
	if params != nil do o[strings.clone("params")] = json.clone_value(params)
	data, err := json.marshal(o)
	json.destroy_value(o)
	if err != nil do return ""
	return string(data)
}

jsonrpc_error_response :: proc(id: json.Value, code: int, message: string) -> string {
	o := make(json.Object)
	o[strings.clone("jsonrpc")] = json.String(strings.clone(JSONRPC_VERSION))
	o[strings.clone("id")] = json.clone_value(id)
	e := make(json.Object)
	e[strings.clone("code")] = json.Integer(code)
	e[strings.clone("message")] = json.String(strings.clone(message))
	o[strings.clone("error")] = e
	data, err := json.marshal(o)
	json.destroy_value(o)
	if err != nil do return ""
	return string(data)
}

jsonrpc_result_response :: proc(id: json.Value, result: json.Value) -> string {
	o := make(json.Object)
	o[strings.clone("jsonrpc")] = json.String(strings.clone(JSONRPC_VERSION))
	o[strings.clone("id")] = json.clone_value(id)
	o[strings.clone("result")] = json.clone_value(result)
	data, err := json.marshal(o)
	json.destroy_value(o)
	if err != nil do return ""
	return string(data)
}

jget :: proc(o: json.Object, key: string) -> json.Value {
	if v, ok := o[key]; ok do return v
	return nil
}

jstr :: proc(v: json.Value) -> string {
	#partial switch x in v {
	case json.String: return string(x)
	case: return ""
	}
}

jint :: proc(v: json.Value) -> int {
	#partial switch x in v {
	case json.Integer: return int(x)
	case json.Float: return int(x)
	case: return 0
	}
}

jbool :: proc(v: json.Value) -> bool {
	#partial switch x in v {
	case json.Boolean: return bool(x)
	case: return false
	}
}

jobj :: proc(v: json.Value) -> (json.Object, bool) {
	#partial switch x in v {
	case json.Object: return x, true
	case: return nil, false
	}
}

is_null :: proc(v: json.Value) -> bool {
	#partial switch _ in v {
	case json.Null: return true
	case: return false
	}
}

jarr :: proc(v: json.Value) -> (json.Array, bool) {
	#partial switch x in v {
	case json.Array: return x, true
	case: return nil, false
	}
}

obj_set :: proc(o: ^json.Object, key: string, value: json.Value) {
	o[strings.clone(key)] = value
}

str_value :: proc(s: string) -> json.Value { return json.String(strings.clone(s)) }
int_value :: proc(n: int) -> json.Value { return json.Integer(n) }
bool_value :: proc(b: bool) -> json.Value { return json.Boolean(b) }

id_string :: proc(v: json.Value) -> string {
	#partial switch x in v {
	case json.Integer: return fmt.aprintf("%d", int(x))
	case json.String: return string(x)
	case json.Float: return fmt.aprintf("%g", f64(x))
	case: return ""
	}
}

id_int :: proc(v: json.Value) -> (int, bool) {
	#partial switch x in v {
	case json.Integer: return int(x), true
	case json.Float: return int(x), true
	case json.String:
		s := strings.trim_space(string(x))
		n := 0
		if len(s) == 0 do return 0, false
		for ch in s {
			if ch < '0' || ch > '9' do return 0, false
			n = n * 10 + int(ch - '0')
		}
		return n, true
	case: return 0, false
	}
}
