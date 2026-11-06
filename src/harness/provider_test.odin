package harness

import "core:encoding/json"
import "core:testing"

// A request body must be byte-stable from one turn to the next: providers
// cache on the exact token prefix, and the tool schemas sit at the front of it.
// The request is built from json.Value objects, whose map iteration order
// changes between allocations, so marshal_request has to impose an order.
@(test)
test_request_is_byte_stable_across_turns :: proc(t: ^testing.T) {
	schema := `{
		"type": "object",
		"properties": {
			"path":      {"type": "string",  "description": "path"},
			"pattern":   {"type": "string",  "description": "pattern"},
			"limit":     {"type": "integer", "description": "limit"},
			"recursive": {"type": "boolean", "description": "recurse"},
			"encoding":  {"type": "string",  "description": "encoding"},
			"context":   {"type": "integer", "description": "context"}
		},
		"required": ["path", "pattern"]
	}`
	params, perr := json.parse_string(schema)
	testing.expect(t, perr == nil, "schema must parse")
	defer json.destroy_value(params)

	tools := []Tool{{name = "probe", description = "probe tool", parameters = params}}
	prompt := "a prompt"

	// Each turn rebuilds the tools and the input items from the sources, which
	// allocates fresh json.Object maps.
	first_tools := build_tools(tools)
	defer {
		for v in first_tools do json.destroy_value(v)
		delete(first_tools)
	}
	first_input := build_input([]StoredItem{{role = "user", content = prompt}})
	defer {
		for v in first_input do json.destroy_value(v)
		delete(first_input)
	}
	first, first_err := marshal_request(Request {
		model = "probe-model",
		instructions = "instructions",
		input = first_input,
		tools = first_tools,
		stream = true,
	})
	testing.expect(t, first_err == nil, "request must marshal")
	defer delete(first)

	second_tools := build_tools(tools)
	defer {
		for v in second_tools do json.destroy_value(v)
		delete(second_tools)
	}
	second_input := build_input([]StoredItem{{role = "user", content = prompt}})
	defer {
		for v in second_input do json.destroy_value(v)
		delete(second_input)
	}
	second, second_err := marshal_request(Request {
		model = "probe-model",
		instructions = "instructions",
		input = second_input,
		tools = second_tools,
		stream = true,
	})
	testing.expect(t, second_err == nil, "request must marshal")
	defer delete(second)

	testing.expect_value(t, string(first), string(second))
}
