// Styles for the terminal markdown renderer. These mirror the presets in the
// Go CLI's termark package: the default is "dark"; "reasoning" is the subdued
// grey/italic treatment used for chain-of-thought text.
package termark

import "core:fmt"

STYLE_DARK :: "dark"
STYLE_LIGHT :: "light"
STYLE_ASCII :: "ascii"
STYLE_REASONING :: "reasoning"

Style :: struct {
	// TextColor styles plain body text; "" leaves it unstyled. TextItalic
	// italicizes plain body text (the reasoning preset).
	text_color:   string,
	text_italic:  bool,

	heading_color: string,
	heading_bold:  bool,

	h1_color: string,
	h1_bold:  bool,

	emph_italic:    bool,
	strong_bold:    bool,
	strike_through: bool,

	code_color: string,

	link_color:     string,
	link_underline: bool,

	blockquote_color: string,
	rule_color:       string,
	code_block_color: string,
	code_block_bg:    string,
}

dark_style :: proc() -> Style {
	return Style{
		heading_color = "39", heading_bold = true,
		h1_color = "228", h1_bold = true,
		emph_italic = true, strong_bold = true, strike_through = true,
		code_color = "203",
		link_color = "35", link_underline = true,
		blockquote_color = "39", rule_color = "240",
		code_block_color = "244", code_block_bg = "233",
	}
}

light_style :: proc() -> Style {
	return Style{
		heading_color = "0", heading_bold = true,
		h1_color = "0", h1_bold = true,
		emph_italic = true, strong_bold = true, strike_through = true,
		code_color = "196",
		link_color = "27", link_underline = true,
		blockquote_color = "0", rule_color = "244",
		code_block_color = "252", code_block_bg = "233",
	}
}

ascii_style :: proc() -> Style {
	return Style{
		heading_color = "0", heading_bold = true,
		h1_color = "0", h1_bold = true,
		emph_italic = false, strong_bold = false, strike_through = false,
		code_color = "",
		link_color = "4", link_underline = true,
		blockquote_color = "0", rule_color = "0", code_block_color = "0",
	}
}

// reasoning_style is the subdued mode for chain-of-thought: body text is
// italic and grey, *emphasis* renders upright and grey, and every other
// construct keeps the dark preset's formatting.
reasoning_style :: proc() -> Style {
	s := dark_style()
	s.text_color = "244"
	s.text_italic = true
	s.emph_italic = false
	return s
}

resolve_style_name :: proc(name: string) -> (Style, string) {
	switch name {
	case "", "dark":
		return dark_style(), ""
	case "light":
		return light_style(), ""
	case "ascii":
		return ascii_style(), ""
	case "reasoning":
		return reasoning_style(), ""
	}
	return Style{}, fmt.aprintf("termark: unknown style %q", name)
}
