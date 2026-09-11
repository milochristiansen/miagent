package termark

import (
	"bytes"
	"strings"

	"github.com/alecthomas/chroma/v2/quick"
	"github.com/rivo/uniseg"
	"github.com/yuin/goldmark/ast"
	extast "github.com/yuin/goldmark/extension/ast"
	"github.com/yuin/goldmark/renderer"
	"github.com/yuin/goldmark/util"
)

// ANSI SGR sequences emitted by the renderer.
const (
	esc          = "\x1b"
	resetSGR     = esc + "[0m"
	boldSGR      = esc + "[1m"
	italicSGR    = esc + "[3m"
	underlineSGR = esc + "[4m"
	strikeSGR    = esc + "[9m"
)

func fgSGR(color string) string { return esc + "[38;5;" + color + "m" }
func bgSGR(color string) string { return esc + "[48;5;" + color + "m" }

// ansiRenderer is a goldmark NodeRenderer that renders markdown to styled ANSI
// text. It replaces glamour's ansi renderer, scoped to the markdown an LLM
// emits (headings, paragraphs, emphasis, code, links, lists, blockquotes, code
// blocks, rules, tables).
type ansiRenderer struct {
	style Style
	width int

	// cur accumulates the current block's inline content (styled); block
	// handlers wrap it and flush to w at their exit.
	cur bytes.Buffer

	// block context
	quoteDepth int         // number of enclosing blockquotes
	listStack  []listLevel // enclosing lists
	curBullet  string      // bullet for the current list item's first line

	// table rendering
	table *tableState
}

type listLevel struct {
	ordered bool
	counter int
}

// tableState buffers a table's cells so column widths can be computed before
// rendering. cells[0] is the header row.
type tableState struct {
	cells [][]string
}

func newANSIRenderer(style Style, W int) *ansiRenderer {
	return &ansiRenderer{style: style, width: W}
}

// RegisterFuncs implements renderer.NodeRenderer.
func (r *ansiRenderer) RegisterFuncs(reg renderer.NodeRendererFuncRegisterer) {
	reg.Register(ast.KindDocument, r.renderDocument)
	reg.Register(ast.KindHeading, r.renderHeading)
	reg.Register(ast.KindBlockquote, r.renderBlockquote)
	reg.Register(ast.KindList, r.renderList)
	reg.Register(ast.KindListItem, r.renderListItem)
	reg.Register(ast.KindParagraph, r.renderParagraph)
	reg.Register(ast.KindTextBlock, r.renderTextBlock)
	reg.Register(ast.KindFencedCodeBlock, r.renderCodeBlock)
	reg.Register(ast.KindCodeBlock, r.renderCodeBlock)
	reg.Register(ast.KindThematicBreak, r.renderThematicBreak)
	reg.Register(ast.KindText, r.renderText)
	reg.Register(ast.KindString, r.renderText)
	reg.Register(ast.KindEmphasis, r.renderEmphasis)
	reg.Register(ast.KindCodeSpan, r.renderCodeSpan)
	reg.Register(ast.KindLink, r.renderLink)
	reg.Register(ast.KindAutoLink, r.renderAutoLink)
	reg.Register(ast.KindImage, r.renderImage)
	reg.Register(ast.KindRawHTML, r.renderNothing)
	reg.Register(ast.KindHTMLBlock, r.renderNothing)
	reg.Register(extast.KindStrikethrough, r.renderStrikethrough)
	reg.Register(extast.KindTaskCheckBox, r.renderTaskCheckBox)
	reg.Register(extast.KindTable, r.renderTable)
	reg.Register(extast.KindTableHeader, r.renderTableHeader)
	reg.Register(extast.KindTableRow, r.renderTableRow)
	reg.Register(extast.KindTableCell, r.renderTableCell)
}

// renderNothing skips a node and its children.
func (r *ansiRenderer) renderNothing(w util.BufWriter, source []byte, n ast.Node, entering bool) (ast.WalkStatus, error) {
	return ast.WalkSkipChildren, nil
}

func (r *ansiRenderer) renderDocument(w util.BufWriter, source []byte, n ast.Node, entering bool) (ast.WalkStatus, error) {
	return ast.WalkContinue, nil
}

// blockSeparator writes a blank line before a top-level block that follows
// another top-level block.
func (r *ansiRenderer) blockSeparator(w util.BufWriter, n ast.Node) {
	if n.Parent() != nil && n.Parent().Kind() == ast.KindDocument && n.PreviousSibling() != nil {
		w.WriteByte('\n')
	}
}

// currentPrefix returns the line prefix for the current block context
// (blockquote bars + list indentation) and its display width.
func (r *ansiRenderer) currentPrefix() (string, int) {
	var b strings.Builder
	for range r.quoteDepth {
		b.WriteString("│ ")
	}
	for range len(r.listStack) {
		b.WriteString("  ")
	}
	return b.String(), displayWidth(b.String())
}

// flush writes the accumulated inline content as a wrapped block. The bullet
// (if any) prefixes the first line; continuation lines are indented to match.
func (r *ansiRenderer) flush(w util.BufWriter) {
	text := r.cur.String()
	r.cur.Reset()
	bullet := r.curBullet
	r.curBullet = ""
	if strings.TrimSpace(scrub([]byte(text))) == "" {
		return // no visible content (e.g. an empty heading)
	}
	prefix, pw := r.currentPrefix()
	bw := displayWidth(bullet)
	first := prefix + bullet
	cont := prefix + strings.Repeat(" ", bw)
	avail := r.width - pw - bw
	if avail < 1 {
		avail = 1
	}
	chunks := wrapANSI(text, avail)
	for i, ch := range chunks {
		if i == 0 {
			w.WriteString(first)
		} else {
			w.WriteString(cont)
		}
		w.WriteString(ch)
		w.WriteByte('\n')
	}
}

// flushPending flushes any pending inline content (an item's text that is
// followed by a nested block) before a nested block begins.
func (r *ansiRenderer) flushPending(w util.BufWriter) {
	if r.cur.Len() > 0 {
		r.flush(w)
	}
}

func (r *ansiRenderer) renderHeading(w util.BufWriter, source []byte, n ast.Node, entering bool) (ast.WalkStatus, error) {
	if entering {
		if n.ChildCount() == 0 {
			r.cur.Reset() // bare "#" with no text yet
			return ast.WalkContinue, nil
		}
		r.blockSeparator(w, n)
		r.cur.Reset()
		h := n.(*ast.Heading)
		s := r.style
		if s.HeadingBold {
			r.cur.WriteString(boldSGR)
		}
		color := s.HeadingColor
		if h.Level == 1 && s.H1Color != "" {
			color = s.H1Color
		}
		if color != "" {
			r.cur.WriteString(fgSGR(color))
		}
		// Leading # markers so the heading level is visible.
		r.cur.WriteString(strings.Repeat("#", h.Level) + " ")
		return ast.WalkContinue, nil
	}
	r.cur.WriteString(resetSGR)
	r.flush(w)
	return ast.WalkContinue, nil
}

func (r *ansiRenderer) renderParagraph(w util.BufWriter, source []byte, n ast.Node, entering bool) (ast.WalkStatus, error) {
	if entering {
		r.blockSeparator(w, n)
		r.cur.Reset()
		return ast.WalkContinue, nil
	}
	r.flush(w)
	return ast.WalkContinue, nil
}

func (r *ansiRenderer) renderTextBlock(w util.BufWriter, source []byte, n ast.Node, entering bool) (ast.WalkStatus, error) {
	return ast.WalkContinue, nil
}

func (r *ansiRenderer) renderBlockquote(w util.BufWriter, source []byte, n ast.Node, entering bool) (ast.WalkStatus, error) {
	if entering {
		r.blockSeparator(w, n)
		r.flushPending(w)
		r.quoteDepth++
		return ast.WalkContinue, nil
	}
	r.quoteDepth--
	return ast.WalkContinue, nil
}

func (r *ansiRenderer) renderList(w util.BufWriter, source []byte, n ast.Node, entering bool) (ast.WalkStatus, error) {
	if entering {
		r.blockSeparator(w, n)
		r.flushPending(w)
		l := n.(*ast.List)
		r.listStack = append(r.listStack, listLevel{ordered: l.IsOrdered(), counter: l.Start})
		return ast.WalkContinue, nil
	}
	r.listStack = r.listStack[:len(r.listStack)-1]
	return ast.WalkContinue, nil
}

func (r *ansiRenderer) renderListItem(w util.BufWriter, source []byte, n ast.Node, entering bool) (ast.WalkStatus, error) {
	if entering {
		r.flushPending(w)
		r.cur.Reset()
		level := &r.listStack[len(r.listStack)-1]
		if level.ordered {
			r.curBullet = itoa(level.counter) + ". "
			level.counter++
		} else {
			r.curBullet = "• "
		}
		return ast.WalkContinue, nil
	}
	r.flush(w)
	return ast.WalkContinue, nil
}

func (r *ansiRenderer) renderText(w util.BufWriter, source []byte, n ast.Node, entering bool) (ast.WalkStatus, error) {
	if !entering {
		return ast.WalkContinue, nil
	}
	prefix := r.textStylePrefix(n)
	if prefix != "" {
		r.cur.WriteString(prefix)
	}
	switch t := n.(type) {
	case *ast.Text:
		r.cur.Write(t.Segment.Value(source))
		// A line break inside a block is content: goldmark leaves the newline
		// out of the segment, so a break the renderer ignores silently glues
		// the words on either side together (model prose arrives hard-wrapped
		// at ~80 columns, so this is the common case). A soft break — the
		// newline that only wraps a line of one paragraph — renders as a space,
		// as CommonMark prescribes; a hard break keeps its own line. A break
		// with nothing after it in the block is not a break at all, and is
		// dropped rather than left as a trailing empty line.
		if t.NextSibling() != nil {
			switch {
			case t.SoftLineBreak():
				r.cur.WriteByte(' ')
			case t.HardLineBreak():
				r.cur.WriteByte('\n')
			}
		}
	case *ast.String:
		r.cur.Write(t.Value)
	}
	if prefix != "" {
		r.cur.WriteString(resetSGR)
	}
	return ast.WalkContinue, nil
}

// textStylePrefix returns the SGR prefix for a body-text run, or "" when
// body text is unstyled (TextColor unset, the default modes). In subdued
// modes body text gets TextColor/TextItalic, except where a nearer inline
// wrapper already opens its own styling at its boundary (headings, strong,
// strikethrough, code spans, links) or where the wrapper's own styling must
// win (*emphasis* in the reasoning mode is upright grey, not italic).
func (r *ansiRenderer) textStylePrefix(n ast.Node) string {
	if r.style.TextColor == "" {
		return ""
	}
	for p := n.Parent(); p != nil; p = p.Parent() {
		switch p.Kind() {
		case ast.KindEmphasis:
			if p.(*ast.Emphasis).Level == 1 {
				return fgSGR(r.style.TextColor) // upright, subdued
			}
			return "" // **strong** is styled at its boundary
		case ast.KindHeading, ast.KindCodeSpan, ast.KindLink,
			ast.KindAutoLink, ast.KindImage, extast.KindStrikethrough:
			return "" // these open their own SGR at their boundaries
		}
		if p.Kind() == ast.KindDocument {
			break
		}
	}
	pre := ""
	if r.style.TextItalic {
		pre += italicSGR
	}
	return pre + fgSGR(r.style.TextColor)
}

func (r *ansiRenderer) renderEmphasis(w util.BufWriter, source []byte, n ast.Node, entering bool) (ast.WalkStatus, error) {
	e := n.(*ast.Emphasis)
	italic := e.Level == 1 && r.style.EmphItalic
	bold := e.Level >= 2 && r.style.StrongBold
	if entering {
		if italic {
			r.cur.WriteString(italicSGR)
		}
		if bold {
			r.cur.WriteString(boldSGR)
		}
	} else if italic || bold {
		r.cur.WriteString(resetSGR)
	}
	return ast.WalkContinue, nil
}

func (r *ansiRenderer) renderStrikethrough(w util.BufWriter, source []byte, n ast.Node, entering bool) (ast.WalkStatus, error) {
	if !r.style.StrikeThrough {
		return ast.WalkContinue, nil
	}
	if entering {
		r.cur.WriteString(strikeSGR)
	} else {
		r.cur.WriteString(resetSGR)
	}
	return ast.WalkContinue, nil
}

func (r *ansiRenderer) renderCodeSpan(w util.BufWriter, source []byte, n ast.Node, entering bool) (ast.WalkStatus, error) {
	if r.style.CodeColor == "" {
		return ast.WalkContinue, nil
	}
	if entering {
		r.cur.WriteString(fgSGR(r.style.CodeColor))
	} else {
		r.cur.WriteString(resetSGR)
	}
	return ast.WalkContinue, nil
}

func (r *ansiRenderer) renderLink(w util.BufWriter, source []byte, n ast.Node, entering bool) (ast.WalkStatus, error) {
	s := r.style
	styled := s.LinkColor != "" || s.LinkUnderline
	if entering {
		if s.LinkColor != "" {
			r.cur.WriteString(fgSGR(s.LinkColor))
		}
		if s.LinkUnderline {
			r.cur.WriteString(underlineSGR)
		}
		return ast.WalkContinue, nil
	}
	if styled {
		r.cur.WriteString(resetSGR)
	}
	if dest := n.(*ast.Link).Destination; len(dest) > 0 {
		r.cur.WriteString(" (" + string(dest) + ")")
	}
	return ast.WalkContinue, nil
}

// renderAutoLink renders a bare URL/email (no separate text), so the URL is
// the visible label and needs no parenthesized repeat.
func (r *ansiRenderer) renderAutoLink(w util.BufWriter, source []byte, n ast.Node, entering bool) (ast.WalkStatus, error) {
	if !entering {
		return ast.WalkContinue, nil
	}
	s := r.style
	if s.LinkColor != "" {
		r.cur.WriteString(fgSGR(s.LinkColor))
	}
	if s.LinkUnderline {
		r.cur.WriteString(underlineSGR)
	}
	r.cur.Write(n.(*ast.AutoLink).Label(source))
	if s.LinkColor != "" || s.LinkUnderline {
		r.cur.WriteString(resetSGR)
	}
	return ast.WalkContinue, nil
}

// renderImage renders an image as its alt text with the destination beside it,
// the way renderLink renders a link: a terminal cannot show the image, and the
// URL is the only part of it the reader can act on, so it is not dropped.
func (r *ansiRenderer) renderImage(w util.BufWriter, source []byte, n ast.Node, entering bool) (ast.WalkStatus, error) {
	if entering {
		r.cur.WriteString("[")
		return ast.WalkContinue, nil
	}
	r.cur.WriteString("]")
	if dest := n.(*ast.Image).Destination; len(dest) > 0 {
		r.cur.WriteString(" (" + string(dest) + ")")
	}
	return ast.WalkContinue, nil
}

func (r *ansiRenderer) renderTaskCheckBox(w util.BufWriter, source []byte, n ast.Node, entering bool) (ast.WalkStatus, error) {
	if entering {
		cb := n.(*extast.TaskCheckBox)
		if cb.IsChecked {
			r.cur.WriteString("[x] ")
		} else {
			r.cur.WriteString("[ ] ")
		}
	}
	return ast.WalkContinue, nil
}

func (r *ansiRenderer) renderThematicBreak(w util.BufWriter, source []byte, n ast.Node, entering bool) (ast.WalkStatus, error) {
	if !entering {
		return ast.WalkContinue, nil
	}
	r.blockSeparator(w, n)
	if r.style.RuleColor != "" {
		w.WriteString(fgSGR(r.style.RuleColor))
	}
	w.WriteString(strings.Repeat("─", r.width))
	w.WriteString(resetSGR)
	w.WriteByte('\n')
	return ast.WalkContinue, nil
}

// renderCodeBlock renders a fenced or indented code block: the header border
// (carrying the fence's info string, when it has one), the body — syntax
// highlighted when a language is known, plain otherwise — and the footer
// border.
func (r *ansiRenderer) renderCodeBlock(w util.BufWriter, source []byte, n ast.Node, entering bool) (ast.WalkStatus, error) {
	if !entering {
		return ast.WalkContinue, nil
	}
	r.blockSeparator(w, n)

	// An indented code block has no info string, so only a fenced one names a
	// language; both carry their content as lines.
	var lang string
	if fenced, ok := n.(*ast.FencedCodeBlock); ok {
		lang = string(fenced.Language(source))
	}
	var code bytes.Buffer
	lines := n.Lines()
	for i := 0; i < lines.Len(); i++ {
		seg := lines.At(i)
		code.Write(seg.Value(source))
	}
	// An opening fence with no content yet renders nothing (anchorless).
	if strings.TrimSpace(code.String()) == "" {
		return ast.WalkContinue, nil
	}

	// Header (language, if any) and footer borders span the full width.
	r.writeCodeBorder(w, codeHeader(lang, r.width))

	if lang != "" {
		var hl bytes.Buffer
		if err := quick.Highlight(&hl, code.String(), lang, "terminal256", "monokai"); err == nil {
			r.writeCodeContent(w, hl.String(), false)
			r.writeCodeBorder(w, codeFooter(r.width))
			return ast.WalkContinue, nil
		}
	}

	r.writeCodeContent(w, code.String(), true)
	r.writeCodeBorder(w, codeFooter(r.width))
	return ast.WalkContinue, nil
}

// codeBlockBGSeq returns the code-block background SGR ("" if unset).
func (r *ansiRenderer) codeBlockBGSeq() string {
	if r.style.CodeBlockBG == "" {
		return ""
	}
	return bgSGR(r.style.CodeBlockBG)
}

// writeCodeBorder writes a header/footer border line, styled with the code
// block foreground and background.
func (r *ansiRenderer) writeCodeBorder(w util.BufWriter, s string) {
	if bg := r.codeBlockBGSeq(); bg != "" {
		w.WriteString(bg)
	}
	if r.style.CodeBlockColor != "" {
		w.WriteString(fgSGR(r.style.CodeBlockColor))
	}
	w.WriteString(s)
	w.WriteString(resetSGR)
	w.WriteByte('\n')
}

// writeCodeContent writes the code body, applying the code-block background to
// each line (re-applied after each SGR reset) and filling each line to full
// width via EL — no literal trailing spaces, so copy/paste is preserved. Tabs
// are expanded to tab stops, because a terminal moves over the cells a tab
// crosses without painting them, which would break the background of
// tab-indented code.
// plain indicates the content is unstyled (apply the code-block foreground).
func (r *ansiRenderer) writeCodeContent(w util.BufWriter, content string, plain bool) {
	lines := strings.Split(content, "\n")
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1] // drop the trailing-newline artifact
	}
	bg := r.codeBlockBGSeq()
	for _, line := range lines {
		line, _ = expandTabs(line, 0)
		if bg != "" {
			w.WriteString(bg)
			if plain && r.style.CodeBlockColor != "" {
				w.WriteString(fgSGR(r.style.CodeBlockColor))
			}
			w.WriteString(strings.ReplaceAll(line, resetSGR, resetSGR+bg))
			w.WriteString("\x1b[K")
		} else if plain && r.style.CodeBlockColor != "" {
			w.WriteString(fgSGR(r.style.CodeBlockColor))
			w.WriteString(line)
			w.WriteString(resetSGR)
		} else {
			w.WriteString(line)
		}
		w.WriteByte('\n')
	}
}

// codeHeader builds the header border: "─ lang ───…" (or a plain rule when no
// language is known), spanning width cells.
func codeHeader(lang string, width int) string {
	if lang == "" {
		return strings.Repeat("─", width)
	}
	label := "─ " + lang + " "
	if lw := displayWidth(label); lw < width {
		return label + strings.Repeat("─", width-lw)
	}
	return label
}

// codeFooter builds the footer border: a plain rule spanning width cells.
func codeFooter(width int) string {
	return strings.Repeat("─", width)
}

func (r *ansiRenderer) renderTable(w util.BufWriter, source []byte, n ast.Node, entering bool) (ast.WalkStatus, error) {
	if entering {
		r.blockSeparator(w, n)
		r.table = &tableState{}
		return ast.WalkContinue, nil
	}
	r.renderTableCells(w)
	r.table = nil
	return ast.WalkContinue, nil
}

func (r *ansiRenderer) renderTableHeader(w util.BufWriter, source []byte, n ast.Node, entering bool) (ast.WalkStatus, error) {
	if entering {
		r.table.cells = append(r.table.cells, []string{})
	}
	return ast.WalkContinue, nil
}

func (r *ansiRenderer) renderTableRow(w util.BufWriter, source []byte, n ast.Node, entering bool) (ast.WalkStatus, error) {
	if entering {
		r.table.cells = append(r.table.cells, []string{})
	}
	return ast.WalkContinue, nil
}

func (r *ansiRenderer) renderTableCell(w util.BufWriter, source []byte, n ast.Node, entering bool) (ast.WalkStatus, error) {
	if entering {
		r.cur.Reset()
		return ast.WalkContinue, nil
	}
	cell := r.cur.String()
	r.cur.Reset()
	last := len(r.table.cells) - 1
	r.table.cells[last] = append(r.table.cells[last], cell)
	return ast.WalkContinue, nil
}

// renderTableCells writes the buffered table as a boxed grid with aligned
// columns, box-drawing borders, and a separator line under the header row.
// Column widths are fitted to the renderer's width so the table never exceeds
// it; cell contents that no longer fit their column are hard-wrapped, growing
// a row to several physical lines rather than overflowing the box.
func (r *ansiRenderer) renderTableCells(w util.BufWriter) {
	cells := r.table.cells
	if len(cells) == 0 {
		return
	}
	ncols := 0
	for _, row := range cells {
		if len(row) > ncols {
			ncols = len(row)
		}
	}
	natural := make([]int, ncols)
	for _, row := range cells {
		for i, c := range row {
			if cw := displayWidth(scrub([]byte(c))); cw > natural[i] {
				natural[i] = cw
			}
		}
	}
	// A column slot costs its content width plus two spaces and a separator;
	// the table also has one leading and one trailing border cell.
	overhead := 3*ncols + 1
	widths := fitTableWidths(natural, r.width-overhead)

	// Wrap each cell to its column width, one physical line per wrapped piece.
	type wrapped struct {
		lines []string
	}
	grid := make([][]wrapped, len(cells))
	for ri, row := range cells {
		grid[ri] = make([]wrapped, ncols)
		for ci := 0; ci < ncols; ci++ {
			if ci >= len(row) {
				grid[ri][ci].lines = []string{""}
				continue
			}
			text := row[ci]
			if displayWidth(scrub([]byte(text))) <= widths[ci] {
				grid[ri][ci].lines = []string{text}
			} else {
				grid[ri][ci].lines = wrapTableText(text, widths[ci])
			}
		}
	}

	// border builds a horizontal border line joining column slots (each
	// width+2 cells) with the given corner/tee/end characters.
	border := func(left, mid, right string) string {
		var b strings.Builder
		b.WriteString(left)
		for ci := 0; ci < ncols; ci++ {
			b.WriteString(strings.Repeat("─", widths[ci]+2))
			if ci < ncols-1 {
				b.WriteString(mid)
			}
		}
		b.WriteString(right)
		return b.String()
	}

	// rowLines writes one table row: each of the row's physical lines carries
	// the full column grid, so wrapped cells keep their column separators.
	rowLines := func(ri int) {
		height := 1
		for ci := 0; ci < ncols; ci++ {
			if h := len(grid[ri][ci].lines); h > height {
				height = h
			}
		}
		for k := 0; k < height; k++ {
			w.WriteString("│")
			for ci := 0; ci < ncols; ci++ {
				var seg string
				if k < len(grid[ri][ci].lines) {
					seg = grid[ri][ci].lines[k]
				}
				w.WriteByte(' ')
				w.WriteString(padCell(seg, widths[ci]))
				w.WriteByte(' ')
				w.WriteString("│")
			}
			w.WriteByte('\n')
		}
	}

	w.WriteString(border("┌", "┬", "┐"))
	w.WriteByte('\n')
	for ri := range cells {
		rowLines(ri)
		if ri == 0 {
			w.WriteString(border("├", "┼", "┤"))
			w.WriteByte('\n')
		}
	}
	w.WriteString(border("└", "┴", "┘"))
	w.WriteByte('\n')
}

// fitTableWidths shrinks natural column widths to fit avail content cells
// (terminal width minus table overhead). The widest columns are reduced first,
// down to a per-column floor (3, then 2, then 1); if even one cell per column
// overflows, the natural widths are returned rather than mangled.
func fitTableWidths(natural []int, avail int) []int {
	widths := append([]int(nil), natural...)
	sum := func() int {
		total := 0
		for _, w := range widths {
			total += w
		}
		return total
	}
	if sum() <= avail {
		return widths
	}
	for floor := 3; floor >= 1; floor-- {
		for {
			if sum() <= avail {
				return widths
			}
			// Reduce the widest column still above the floor.
			bi := -1
			for i, w := range widths {
				if w > floor && (bi < 0 || w > widths[bi]) {
					bi = i
				}
			}
			if bi < 0 {
				break
			}
			widths[bi]--
		}
	}
	return widths
}

// wrapTableText wraps styled cell text to the given display width. Words
// longer than the width are hard-split (never split a wide rune); ANSI SGR
// state is carried across line breaks. A cell with no visible text yields one
// empty line.
func wrapTableText(s string, width int) []string {
	if width < 1 {
		width = 1
	}
	var lines []string
	var line strings.Builder
	col := 0
	active := ""
	needSpace := false

	startLine := func() {
		if active != "" {
			line.WriteString(esc + "[" + active + "m")
		}
	}
	endLine := func() {
		if active != "" {
			line.WriteString(resetSGR)
		}
		lines = append(lines, line.String())
		line.Reset()
		col = 0
		needSpace = false
		startLine()
	}

	i := 0
	for i < len(s) {
		c := s[i]
		if c == 0x1b {
			if needSpace && col > 0 {
				line.WriteByte(' ')
				col++
				needSpace = false
			}
			j := csiEnd(s, i)
			line.WriteString(s[i:j])
			active = applySGR(active, s[i:j])
			i = j
			continue
		}
		if c == ' ' {
			needSpace = true
			i++
			continue
		}
		j := i
		for j < len(s) && s[j] != ' ' && s[j] != 0x1b {
			j++
		}
		word := s[i:j]
		i = j
		if needSpace && col > 0 {
			if col+1+displayWidth(word) <= width {
				line.WriteByte(' ')
				col++
			} else {
				endLine() // the space would not fit; drop it and start a fresh line
			}
		} else if col > 0 && col+displayWidth(word) > width {
			endLine()
		}
		needSpace = false
		for _, piece := range splitCells(word, width) {
			pw := displayWidth(piece)
			if col > 0 && col+pw > width {
				endLine()
			}
			line.WriteString(piece)
			col += pw
		}
	}
	if col > 0 || line.Len() > 0 {
		endLine()
	}
	if len(lines) == 0 {
		return []string{""}
	}
	return lines
}

// splitCells splits a space-free run into display-cell pieces of at most
// width cells, never splitting a wide (double-cell) rune.
func splitCells(s string, width int) []string {
	if width < 1 {
		width = 1
	}
	var pieces []string
	var b strings.Builder
	cw := 0
	for _, r := range s {
		rw := displayWidth(string(r))
		if cw > 0 && cw+rw > width {
			pieces = append(pieces, b.String())
			b.Reset()
			cw = 0
		}
		b.WriteRune(r)
		cw += rw
	}
	if cw > 0 {
		pieces = append(pieces, b.String())
	}
	if len(pieces) == 0 {
		return []string{""}
	}
	return pieces
}

func padCell(s string, width int) string {
	if w := displayWidth(scrub([]byte(s))); w < width {
		return s + strings.Repeat(" ", width-w)
	}
	return s
}

// ---- helpers ----

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}

func displayWidth(s string) int { return uniseg.StringWidth(s) }

// csiEnd returns the index just past the CSI sequence starting at s[i]
// (s[i] == 0x1b). Returns i+1 if malformed.
func csiEnd(s string, i int) int {
	j := i + 2 // skip ESC [
	for j < len(s) {
		c := s[j]
		if (c >= '0' && c <= '9') || c == ';' {
			j++
			continue
		}
		if c == 'm' {
			return j + 1
		}
		return i + 1
	}
	return i + 1
}

// applySGR updates the active SGR parameter list given one SGR sequence.
func applySGR(active, seq string) string {
	params := seq[2 : len(seq)-1] // strip ESC[ and m
	for _, p := range strings.Split(params, ";") {
		if p == "0" {
			return ""
		}
	}
	if active == "" {
		return params
	}
	return active + ";" + params
}

// wrapANSI wraps a styled string into content lines of at most width visible
// cells, breaking at word boundaries. SGR state is preserved across breaks:
// each continuation line re-opens the active style. No prefixes are applied.
func wrapANSI(s string, width int) []string {
	if width < 1 {
		width = 1
	}
	var lines []string
	var line strings.Builder
	col := 0
	active := ""

	emit := func() {
		if active != "" {
			line.WriteString(resetSGR)
		}
		lines = append(lines, line.String())
		line.Reset()
		if active != "" {
			line.WriteString(esc + "[" + active + "m")
		}
		col = 0
	}

	i := 0
	needSpace := false
	for i < len(s) {
		c := s[i]
		if c == 0x1b {
			// Resolve a pending space before the SGR so the space lands in the
			// right (unstyled) position.
			if needSpace && col > 0 {
				line.WriteByte(' ')
				col++
				needSpace = false
			}
			j := csiEnd(s, i)
			line.WriteString(s[i:j])
			active = applySGR(active, s[i:j])
			i = j
			continue
		}
		if c == ' ' {
			needSpace = true
			for i < len(s) && s[i] == ' ' {
				i++
			}
			continue
		}
		if c == '\n' {
			// A hard break: end the line here, whatever its width. A pending
			// space is dropped, as it is at any other line end.
			if col > 0 || line.Len() > 0 {
				emit()
			}
			needSpace = false
			i++
			continue
		}
		j := i
		for j < len(s) && s[j] != ' ' && s[j] != '\n' && s[j] != 0x1b {
			j++
		}
		word := s[i:j]
		ww := displayWidth(word)
		add := ww
		if needSpace {
			add++
		}
		if col+add > width && col > 0 {
			emit()
			line.WriteString(word)
			col = ww
		} else {
			if needSpace && col > 0 {
				line.WriteByte(' ')
			}
			line.WriteString(word)
			col += add
		}
		needSpace = false
		i = j
	}

	if col > 0 || line.Len() > 0 || len(lines) == 0 {
		if active != "" {
			line.WriteString(resetSGR)
		}
		lines = append(lines, line.String())
	}
	return lines
}
