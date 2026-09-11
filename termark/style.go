package termark

import "fmt"

// Style configures the ANSI styling applied by the renderer. Color fields are
// ANSI 256-color codes as decimal strings ("" = terminal default). Presets for
// "dark", "light", "ascii", and "reasoning" are provided; the default is
// "dark".
type Style struct {
	// TextColor styles plain body text (no markdown emphasis or other
	// inline wrapper). "" leaves body text unstyled. TextItalic makes
	// plain body text italic. These exist for the subdued "reasoning"
	// preset: body text renders italic and grey, while *emphasis* (which
	// in that preset has EmphItalic off) renders upright and grey.
	TextColor  string
	TextItalic bool

	HeadingColor string // heading text foreground
	HeadingBold  bool

	H1Color string // level-1 heading foreground
	H1Bold  bool

	EmphItalic    bool // *emphasis* renders italic
	StrongBold    bool // **strong** renders bold
	StrikeThrough bool // ~~strikethrough~~ renders struck

	CodeColor string // inline code foreground

	LinkColor     string // link text foreground
	LinkUnderline bool

	BlockquoteColor string // blockquote bar/text foreground
	RuleColor       string // thematic-break foreground
	CodeBlockColor  string // fenced code block foreground
	CodeBlockBG     string // fenced code block background
}

func darkStyle() Style {
	return Style{
		HeadingColor: "39", HeadingBold: true,
		H1Color: "228", H1Bold: true,
		EmphItalic: true, StrongBold: true, StrikeThrough: true,
		CodeColor: "203",
		LinkColor: "35", LinkUnderline: true,
		BlockquoteColor: "39", RuleColor: "240", CodeBlockColor: "244", CodeBlockBG: "233",
	}
}

func lightStyle() Style {
	return Style{
		HeadingColor: "0", HeadingBold: true,
		H1Color: "0", H1Bold: true,
		EmphItalic: true, StrongBold: true, StrikeThrough: true,
		CodeColor: "196",
		LinkColor: "27", LinkUnderline: true,
		BlockquoteColor: "0", RuleColor: "244", CodeBlockColor: "252", CodeBlockBG: "233",
	}
}

func asciiStyle() Style {
	return Style{
		HeadingColor: "0", HeadingBold: true,
		H1Color: "0", H1Bold: true,
		EmphItalic: false, StrongBold: false, StrikeThrough: false,
		CodeColor: "",
		LinkColor: "4", LinkUnderline: true,
		BlockquoteColor: "0", RuleColor: "0", CodeBlockColor: "0",
	}
}

// reasoningStyle is the subdued mode for chain-of-thought: body text is
// italic and grey, *emphasis* renders upright and grey (EmphItalic off, the
// upright body color comes from the text-run styling), and every other
// construct keeps the dark preset's formatting.
func reasoningStyle() Style {
	s := darkStyle()
	s.TextColor = "244"
	s.TextItalic = true
	s.EmphItalic = false
	return s
}

// resolveStyleName returns the Style for a preset name, defaulting to "dark"
// when name is empty. Supported names: "dark", "light", "ascii", "reasoning".
func resolveStyleName(name string) (Style, error) {
	switch name {
	case "", "dark":
		return darkStyle(), nil
	case "light":
		return lightStyle(), nil
	case "ascii":
		return asciiStyle(), nil
	case "reasoning":
		return reasoningStyle(), nil
	}
	return Style{}, fmt.Errorf("termark: unknown style %q", name)
}
