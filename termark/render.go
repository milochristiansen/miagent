package termark

import (
	"bytes"
	"strings"

	"github.com/rivo/uniseg"
	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/ast"
	"github.com/yuin/goldmark/extension"
	"github.com/yuin/goldmark/parser"
	"github.com/yuin/goldmark/renderer"
	"github.com/yuin/goldmark/text"
	"github.com/yuin/goldmark/util"
)

// Line is one rendered screen line: its exact ANSI bytes (SGR included) and its
// display width in cells (SGR-scrubbed, grapheme-correct).
type Line struct {
	Bytes []byte // exact render bytes for this line, SGR included
	Width int    // display cells (SGR-scrubbed)
}

// newGoldmark builds a goldmark instance (GFM) using our ANSI renderer.
func newGoldmark(style Style, W int) goldmark.Markdown {
	md := goldmark.New(
		goldmark.WithExtensions(extension.GFM),
		goldmark.WithParserOptions(parser.WithAutoHeadingID()),
	)
	ar := newANSIRenderer(style, W)
	md.SetRenderer(renderer.NewRenderer(
		renderer.WithNodeRenderers(util.Prioritized(ar, 1000)),
	))
	return md
}

// fragmentRenderer renders markdown fragments to Lines.
type fragmentRenderer struct {
	md    goldmark.Markdown
	style Style
	W     int
}

func newFragmentRenderer(style Style, W int) *fragmentRenderer {
	return &fragmentRenderer{md: newGoldmark(style, W), style: style, W: W}
}

// render renders b as a standalone document and splits the output into Lines.
//
// b is copied first: goldmark's segment values append into the byte slice they
// are given (a code block's last line carries ForceNewline, which goldmark
// implements as append(value, '\n')), so a slice with spare capacity lets the
// parse write into memory the caller still owns. The renderer's buffer always
// has spare capacity — it grows by append, and it is handed over trimmed of a
// trailing incomplete rune — so the copy is what keeps a parse from corrupting
// the input it is streaming.
func (fr *fragmentRenderer) render(b []byte) []Line {
	var out bytes.Buffer
	if err := fr.md.Convert(bytes.Clone(b), &out); err != nil {
		return nil
	}
	return splitLines(out.Bytes())
}

// splitLines splits rendered ANSI bytes on '\n' into Lines. A trailing empty
// segment (a trailing newline artifact) is dropped.
func splitLines(b []byte) []Line {
	segs := bytes.Split(b, []byte{'\n'})
	lines := make([]Line, 0, len(segs))
	for i, seg := range segs {
		if i == len(segs)-1 && len(seg) == 0 {
			continue // trailing-newline artifact
		}
		lines = append(lines, Line{Bytes: seg, Width: uniseg.StringWidth(scrub(seg))})
	}
	return lines
}

// scrub removes ANSI escape sequences, returning the visible text.
func scrub(b []byte) string { return string(stripANSI(b)) }

// stripANSI removes ANSI escape sequences (CSI, OSC, and single-char ESC
// sequences), returning the visible bytes.
func stripANSI(b []byte) []byte {
	var out []byte
	for i := 0; i < len(b); {
		if b[i] != 0x1b {
			out = append(out, b[i])
			i++
			continue
		}
		if i+1 >= len(b) {
			break
		}
		switch b[i+1] {
		case '[': // CSI: ESC [ params/intermediate final(0x40-0x7e)
			i += 2
			for i < len(b) && (b[i] < 0x40 || b[i] > 0x7e) {
				i++
			}
			if i < len(b) {
				i++
			}
		case ']': // OSC: ESC ] ... (BEL or ESC \)
			i += 2
			for i < len(b) {
				if b[i] == 0x07 {
					i++
					break
				}
				if b[i] == 0x1b && i+1 < len(b) && b[i+1] == '\\' {
					i += 2
					break
				}
				i++
			}
		default: // ESC + optional intermediates + final
			i += 2
			for i < len(b) && b[i] < 0x40 {
				i++
			}
			if i < len(b) {
				i++
			}
		}
	}
	return out
}

// blockRange is a top-level block's [Start, End) byte offsets.
type blockRange struct {
	Start int
	End   int
}

// topLevelBlocks parses b and returns the top-level blocks' byte ranges, in
// document order. A block's range is [lineStart(minContentStart),
// lineEnd(maxContentStop)], including leading markers (a heading's "#", a
// list's "-") and spanning all content lines.
//
// Like render, b is copied before it reaches goldmark, which appends into the
// slices it is given; the offsets returned index the copy, and are offsets
// into b as well because the copy is byte-identical.
func (fr *fragmentRenderer) topLevelBlocks(b []byte) []blockRange {
	b = bytes.Clone(b)
	docNode := fr.md.Parser().Parse(text.NewReader(b))
	var blocks []blockRange
	tb := thematicBreakLines(b)
	tbIdx := 0
	_ = ast.Walk(docNode, func(n ast.Node, entering bool) (ast.WalkStatus, error) {
		if !entering || n.Parent() != docNode {
			return ast.WalkContinue, nil
		}
		start, stop := contentMinMax(n)
		if start < 0 {
			// A thematic break carries no content lines; locate its line via a
			// source scan (the i-th thematic-break node maps to the i-th
			// thematic-break line).
			if n.Kind() == ast.KindThematicBreak && tbIdx < len(tb) {
				start, stop = tb[tbIdx][0], tb[tbIdx][1]
				tbIdx++
				blocks = append(blocks, blockRange{start, stop})
			}
			return ast.WalkContinue, nil
		}
		start = lineStart(b, start)
		if n.Kind() == ast.KindFencedCodeBlock && start > 0 {
			// A fenced block's content starts one line after the opening
			// fence; step back to the opening fence line.
			start = lineStart(b, start-1)
		}
		blocks = append(blocks, blockRange{start, lineEnd(b, stop)})
		return ast.WalkContinue, nil
	})
	return blocks
}

// contentMinMax returns the minimum content Start and maximum content Stop
// across the node's subtree (a block's own Lines() plus its descendants').
func contentMinMax(n ast.Node) (minStart, maxStop int) {
	minStart, maxStop = -1, -1
	var visit func(n ast.Node)
	visit = func(n ast.Node) {
		if n.Type() == ast.TypeBlock {
			lines := n.Lines()
			for i := 0; i < lines.Len(); i++ {
				s, e := lines.At(i).Start, lines.At(i).Stop
				if minStart < 0 || s < minStart {
					minStart = s
				}
				if maxStop < 0 || e > maxStop {
					maxStop = e
				}
			}
		}
		for c := n.FirstChild(); c != nil; c = c.NextSibling() {
			visit(c)
		}
	}
	visit(n)
	return minStart, maxStop
}

// lineStart returns the byte offset of the start of the line containing byte
// offset s (the position after the preceding newline, or 0).
func lineStart(b []byte, s int) int {
	for i := s - 1; i >= 0; i-- {
		if b[i] == '\n' {
			return i + 1
		}
	}
	return 0
}

// lineEnd returns the byte offset just past the end of the line containing the
// byte just before e (e is an exclusive stop).
func lineEnd(b []byte, e int) int {
	for i := e; i < len(b); i++ {
		if b[i] == '\n' {
			return i + 1
		}
	}
	return len(b)
}

// precedingBlankStart returns the start of the run of blank (newline-only)
// lines immediately before offset. If the byte before offset is not a newline
// (or offset is 0), offset is returned. The committed part ends here: the
// blank separator between blocks belongs to the tail, not the cache.
func precedingBlankStart(b []byte, offset int) int {
	i := offset
	for i > 0 && b[i-1] == '\n' {
		if lineStart(b, i-1) != i-1 {
			break
		}
		i--
	}
	return i
}

// thematicBreakLines returns the [start, end) byte ranges (each range includes
// the trailing newline) of the thematic-break lines in b, in document order.
func thematicBreakLines(b []byte) [][2]int {
	type line struct{ start, end int } // [start, end): content, end before newline
	var lines []line
	i := 0
	for i < len(b) {
		start := i
		for i < len(b) && b[i] != '\n' {
			i++
		}
		lines = append(lines, line{start, i})
		if i >= len(b) {
			break
		}
		i++ // skip the newline
	}
	var out [][2]int
	for idx, ln := range lines {
		if !isRuleLine(b[ln.start:ln.end]) {
			continue
		}
		if idx > 0 && strings.TrimSpace(string(b[lines[idx-1].start:lines[idx-1].end])) != "" {
			continue // setext heading underline, not a thematic break
		}
		end := ln.end
		if end < len(b) {
			end++ // include the trailing newline
		}
		out = append(out, [2]int{ln.start, end})
	}
	return out
}

// isRuleLine reports whether line is a thematic-break rule: at most three
// leading spaces, then three or more of a single character ('-', '*' or '_'),
// then only trailing whitespace.
func isRuleLine(line []byte) bool {
	k := 0
	for k < len(line) && line[k] == ' ' {
		k++
	}
	if k > 3 || k+3 > len(line) {
		return false
	}
	c := line[k]
	if c != '-' && c != '*' && c != '_' {
		return false
	}
	j := k
	for j < len(line) && line[j] == c {
		j++
	}
	if j-k < 3 {
		return false
	}
	for j < len(line) {
		if line[j] != ' ' && line[j] != '\t' {
			return false
		}
	}
	return true
}

// streamingModel simulates feeding b byte-by-byte through the tail finder and
// returns the final screen lines (committed ++ tail). It is the streaming
// invariant: equal to render(b) for any b.
func (fr *fragmentRenderer) streamingModel(b []byte) []Line {
	tf := newTailFinder(fr)
	var tail []Line
	for i := 0; i <= len(b); i++ {
		_, tail = tf.tick(b[:i])
	}
	return append(append([]Line{}, tf.cache...), tail...)
}
