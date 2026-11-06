// The CLI's screen output: reasoning and assistant markdown through termark,
// plus live tool-call code boxes. This mirrors the Go CLI's display.go.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "../termark"

Disp_Class :: enum {
	None,
	Reasoning,
	Output,
}

SUBDUED_PREFIX :: "\x1b[3m\x1b[38;5;244m"
SUBDUED_SUFFIX :: "\x1b[0m"

Display :: struct {
	render: bool,
	cur:    ^termark.Renderer,
	class:  Disp_Class,

	sep_next: bool,
	raw_text: bool,
	raw_last: bool,
	err_text: bool,
	err_last: bool,

	box:             termark.Live_Box,
	box_open:        bool,
	raw_tool_active: bool,

	tool_size: int,
	width:     int,
	height:    int,
}

new_display :: proc(tool_size: int) -> Display {
	w, h, ok := termark.Terminal_Size()
	if !ok {
		w = 80
		h = 0
	}
	return Display{
		tool_size = tool_size,
		width = w,
		height = h,
	}
}

display_destroy :: proc(d: ^Display) {
	if d.cur != nil {
		termark.Renderer_Close(d.cur)
		termark.Renderer_Destroy(d.cur)
		d.cur = nil
	}
	if d.box_open {
		termark.Live_Box_Destroy(&d.box)
		d.box_open = false
	}
}

renderable :: proc(d: ^Display) -> bool {
	if d.render do return true
	if !termark.Stdout_Is_Tty() do return false
	d.render = true
	return true
}

raw_write :: proc(d: ^Display, s: string) {
	if len(s) == 0 do return
	fmt.print(s)
	d.raw_text = true
	d.raw_last = strings.has_suffix(s, "\n")
}

display_sep :: proc(d: ^Display) {
	if d.cur != nil do return
	if d.render {
		fmt.print("\r\n")
		d.raw_last = true
		return
	}
	if !d.raw_text do return
	if !d.raw_last do raw_write(d, "\n")
	raw_write(d, "\n")
}

display_open :: proc(d: ^Display, class: Disp_Class) {
	if d.cur != nil && d.class == class do return
	if d.cur != nil {
		display_close(d)
		d.sep_next = true
	}
	if d.sep_next {
		display_sep(d)
		d.sep_next = false
	}
	style := ""
	if class == .Reasoning do style = "reasoning"
	r, err := termark.New_Renderer(os.to_writer(os.stdout), style, 0)
	if err != "" {
		d.render = false
		return
	}
	d.render = true
	d.cur = r
	d.class = class
}

display_close :: proc(d: ^Display) {
	if d.cur != nil {
		termark.Renderer_Close(d.cur)
		termark.Renderer_Destroy(d.cur)
		d.cur = nil
	}
	d.class = .None
}

end_err_line :: proc(d: ^Display) {
	if !d.err_text || d.err_last do return
	fmt.eprint("\n")
	d.err_last = true
}

display_end_turn :: proc(d: ^Display) {
	end_err_line(d)
	if d.cur != nil {
		d.sep_next = true
		display_close(d)
		return
	}
	if d.raw_text && !d.raw_last do raw_write(d, "\n")
	d.sep_next = d.raw_text
}

display_info :: proc(d: ^Display, s: string) {
	end_err_line(d)
	if d.cur != nil {
		display_close(d)
		d.sep_next = true
	}
	if d.sep_next {
		display_sep(d)
		d.sep_next = false
	}
	raw_write(d, s)
}

display_subdued :: proc(d: ^Display, s: string) {
	text := strings.trim_suffix(s, "\n")
	end_err_line(d)
	if d.cur != nil do display_close(d)
	if d.raw_text && !d.raw_last do raw_write(d, "\n")
	if renderable(d) {
		fmt.print(SUBDUED_PREFIX)
		fmt.print(text)
		fmt.print(SUBDUED_SUFFIX)
		fmt.print("\r\n")
		d.raw_text = true
		d.raw_last = true
		d.sep_next = false
		return
	}
	raw_write(d, text)
	raw_write(d, "\n")
	d.sep_next = false
}

display_output :: proc(d: ^Display, s: string) {
	end_err_line(d)
	display_open(d, .Output)
	if d.cur != nil {
		termark.Renderer_Write(d.cur, s)
		return
	}
	raw_write(d, s)
}

display_reasoning :: proc(d: ^Display, s: string) {
	display_open(d, .Reasoning)
	if d.cur != nil {
		termark.Renderer_Write(d.cur, s)
		return
	}
	fmt.eprint(s)
	d.err_text = true
	d.err_last = strings.has_suffix(s, "\n")
}

split_content :: proc(s: string) -> []string {
	if len(s) == 0 do return nil
	trimmed := strings.trim_suffix(s, "\n")
	if len(trimmed) == 0 {
		out := make([]string, 1)
		return out
	}
	return strings.split(trimmed, "\n")
}

toolcall_input_lines :: proc(args: string, limit: int) -> (lines: []string, elided: int) {
	all := split_content(args)
	if limit <= 0 || len(all) <= limit do return all, 0
	return all[:limit], len(all) - limit
}

display_tool_start :: proc(d: ^Display, name, args: string) {
	end_err_line(d)
	if d.cur != nil {
		display_close(d)
		d.sep_next = true
	}
	if d.sep_next {
		display_sep(d)
		d.sep_next = false
	}

	if renderable(d) {
		w, h, ok := termark.Terminal_Size()
		if !ok {
			w = d.width
			h = d.height
		}
		if w > 0 do d.width = w
		if h > 0 do d.height = h
		d.box = termark.New_Live_Box(os.to_writer(os.stdout), d.width, d.height, d.tool_size)
		d.box_open = true
		input, elided := toolcall_input_lines(args, d.box.Limit)
		termark.Live_Box_Header(&d.box, strings.concatenate({"tool: ", name}, context.temp_allocator), elided)
		for line in input do termark.Live_Box_Row(&d.box, line)
		termark.Live_Box_Output_Header(&d.box, "output")
		return
	}

	d.raw_tool_active = true
	raw_write(d, strings.concatenate({"Tool: ", name, "\n"}, context.temp_allocator))
	if len(args) > 0 {
		raw_write(d, strings.trim_suffix(args, "\n"))
		raw_write(d, "\n")
	}
	raw_write(d, "Output:\n")
}

display_tool_out :: proc(d: ^Display, stderr: bool, text: string) {
	if d.box_open {
		if stderr {
			termark.Live_Box_Err(&d.box, text)
		} else {
			termark.Live_Box_Out(&d.box, text)
		}
		return
	}
	if d.raw_tool_active do raw_write(d, text)
}

display_tool_end :: proc(d: ^Display, code: int) {
	if d.box_open {
		termark.Live_Box_End(&d.box, code)
		termark.Live_Box_Destroy(&d.box)
		d.box_open = false
		d.raw_text = true
		d.raw_last = true
		d.sep_next = true
		return
	}
	if d.raw_tool_active {
		if !d.raw_last do raw_write(d, "\n")
		d.raw_tool_active = false
		if code != 0 do raw_write(d, fmt.tprintf("(exit %d)\n", code))
		d.sep_next = true
	}
}
