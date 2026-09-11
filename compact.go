// Context compaction for /compact, following Pi's approach
// (packages/coding-agent/src/core/compaction/compaction.ts): pick a cut point
// that keeps roughly the most recent keepRecentTokens, summarize everything
// before it with one model call, and replace the summarized items with the
// summary. The prompts are read from COMPACT-*.md in the prompts subdirectory
// of the configuration directory (see configDir and prompt.go); the session
// file is archived before being rewritten (see archive.go).
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	openai "github.com/sashabaranov/go-openai"
)

// Context sizing. The provider's own counts are the size that matters: a
// usage record says what it covers and how many tokens that took, so the
// conversation is measured between records (see tokenIndex), and those counts
// take precedence wherever they reach. What is left to the character
// heuristic is only what no record covers and how a measured span's tokens are
// spread over the items in it, because the cut point has to be chosen before
// the next request is made. Four characters per token is about right for prose
// and undercounts code or JSON, which tokenize denser.
const charsPerToken = 4

// toolResultSummaryChars caps one tool result in the serialized conversation,
// as Pi does. A summary needs the gist of a result, not the whole file it
// printed.
const toolResultSummaryChars = 2000

// estimateItemTokens estimates one item's tokens from its text length.
func estimateItemTokens(it StoredItem) int {
	var chars int
	switch it.Role {
	case "user", "assistant", "compaction":
		chars = len(it.Content)
	case "reasoning":
		if it.Reasoning != nil {
			for _, p := range it.Reasoning.Content {
				chars += len(p.Text)
			}
			for _, p := range it.Reasoning.Summary {
				chars += len(p.Text)
			}
		}
	case "function_call":
		chars = len(it.Name) + len(it.Arguments)
	case "function_call_output":
		chars = len(it.Output)
	}
	if chars == 0 {
		return 0
	}
	return (chars + charsPerToken - 1) / charsPerToken
}

// anchor is one provider measurement located in the conversation: the number
// of items it covers and the tokens it reported for them.
type anchor struct {
	items  int
	tokens int
}

// tokenIndex sizes a conversation in tokens, measured where the provider has
// measured it.
//
// A usage record covers every item up to its anchor, so the tokens between two
// anchors are what the difference between their counts says: exact, and free
// of the fixed overhead a request carries (its instructions and tool schemas,
// which no item accounts for). What precedes the first anchor is sized as that
// anchor less an estimate of the items after it, which keeps that same
// overhead out of it. Where the provider measured a span but not the items
// inside it, each item takes the share of the span's tokens that its text
// estimate has of the span's; past the newest anchor only the estimate is
// left.
//
// The index holds one session's items and stays valid for them as long as the
// session only appends, which is all it does before a compaction replaces it.
type tokenIndex struct {
	items    []StoredItem
	prefix   []int // prefix[i]: tokens of items[:i]
	floor    int   // largest count reported for a context with no location
	measured bool  // at least one record measured something
}

// newTokenIndex sizes items against the usage records of the same session.
func newTokenIndex(items []StoredItem, usages []Usage) *tokenIndex {
	est := make([]int, len(items)+1)
	for i, it := range items {
		est[i+1] = est[i] + estimateItemTokens(it)
	}
	anchors, floor := measurements(usages, len(items))

	x := &tokenIndex{
		items:    items,
		prefix:   make([]int, len(items)+1),
		floor:    floor,
		measured: len(anchors) > 0 || floor > 0,
	}
	// Each position is sized from the newest anchor at or before it and, when
	// a later measurement exists, the span the two of them bracket.
	a, v, next := 0, 0, 0
	if len(anchors) > 0 {
		a, v, next = anchors[0].items, anchors[0].tokens, 1
	}
	for i := range x.prefix {
		for next < len(anchors) && anchors[next].items <= i {
			a, v = anchors[next].items, anchors[next].tokens
			next++
		}
		if i >= a && next < len(anchors) {
			span, total := est[anchors[next].items]-est[a], anchors[next].tokens-v
			if span > 0 && total > 0 {
				x.prefix[i] = v + (est[i]-est[a])*total/span
				continue
			}
		}
		x.prefix[i] = v + est[i] - est[a]
	}
	return x
}

// measurements picks the usage records that locate themselves in a
// conversation of n items, in the order they cover it, and the largest count
// among the records that do not.
func measurements(usages []Usage, n int) (anchors []anchor, floor int) {
	for _, u := range usages {
		tokens := u.InputTokens + u.OutputTokens
		if u.AtItems <= 0 {
			// No location: a record written before the field said what it
			// measured. It measured a prefix of this conversation all the
			// same, so it bounds the total from below.
			floor = max(floor, tokens)
			continue
		}
		if u.AtItems > n || tokens <= 0 {
			// Not a usable measurement: it covers items that are not here,
			// or counts nothing.
			continue
		}
		if len(anchors) > 0 && tokens <= anchors[len(anchors)-1].tokens {
			// A context only grows, so a count no larger than the one before
			// it cannot be placed after it.
			continue
		}
		anchors = append(anchors, anchor{items: u.AtItems, tokens: tokens})
	}
	return anchors, floor
}

// total returns the tokens of the whole conversation as a request for it would
// report them: the newest measurement, plus an estimate of the items added
// after it.
func (x *tokenIndex) total() int {
	return max(x.prefix[len(x.items)], x.floor)
}

// suffix returns the tokens of items[i:], which is what a summary would have
// to stand in for after a cut at i. A span holds no fixed request overhead, so
// unlike total this is the conversation's own size, tail end first.
func (x *tokenIndex) suffix(i int) int {
	return x.prefix[len(x.items)] - x.prefix[i]
}

// contextTokens reports the token size of the context the next request would
// carry, and whether a provider measurement backs it.
func (s *Session) contextTokens() (tokens int, measured bool) {
	x := newTokenIndex(s.Items, s.Usages)
	return x.total(), x.measured
}

// cutPoint is where a compaction splits the conversation.
type cutPoint struct {
	// firstKept is the index of the first item that survives as itself.
	firstKept int
	// turnStart is the index of the user item that opened the turn being
	// split, or -1 when the cut lands on a turn boundary.
	turnStart int
	// split reports whether the cut falls inside a turn, in which case the
	// turn's own prefix is summarized separately so the retained suffix
	// keeps enough context to be understood.
	split bool
}

// isCutPoint reports whether a compaction may begin at this item. A tool
// result must stay with the call that produced it, and reasoning must stay
// with the reply it belongs to, so neither can start the kept range; a
// function_call may, because its outputs follow it.
func isCutPoint(it StoredItem) bool {
	switch it.Role {
	case "user", "assistant", "function_call", "compaction":
		return true
	}
	return false
}

// isTurnStart reports whether an item opens a turn.
func isTurnStart(it StoredItem) bool {
	return it.Role == "user" || it.Role == "compaction"
}

// findCutPoint chooses where to split, keeping roughly keepRecentTokens of the
// most recent conversation. It walks backwards until the items from an item to
// the end cover the budget, then cuts at the first valid cut point at or after
// that item. Sizes come from the index, so where usage records back them the
// walk follows what the provider measured rather than what the text suggests.
//
// When the budget is consumed by items that cannot start the kept range (a
// huge tool output trailing the session, say), no valid cut point exists at or
// after it; Pi leaves the cut at the start and reports nothing to compact,
// which makes such a session uncompactable, so this instead falls back to the
// last valid cut point. That may keep less than the budget; it never keeps
// more.
//
// A cut landing inside a turn reports that turn's start so the caller can
// summarize the turn's prefix separately.
func (x *tokenIndex) findCutPoint(keepRecent int) cutPoint {
	var cutPoints []int
	for i, it := range x.items {
		if isCutPoint(it) {
			cutPoints = append(cutPoints, i)
		}
	}
	if len(cutPoints) == 0 {
		// Nothing can start a kept range: the conversation is all reasoning
		// and tool results. Leave it alone rather than split a pair.
		return cutPoint{firstKept: 0, turnStart: -1}
	}

	// Default: keep everything, unless the budget pushes the cut later.
	cutIndex := cutPoints[0]
	for i := len(x.items) - 1; i >= 0; i-- {
		if x.suffix(i) < keepRecent {
			continue
		}
		cutIndex = cutPoints[len(cutPoints)-1]
		for _, c := range cutPoints {
			if c >= i {
				cutIndex = c
				break
			}
		}
		break
	}

	// Reasoning immediately before the cut belongs to the reply that follows
	// it, so step back to keep the two together: a kept range must not open
	// with a reply whose thinking was summarized away.
	for cutIndex > 0 && x.items[cutIndex-1].Role == "reasoning" {
		cutIndex--
	}

	cut := cutPoint{firstKept: cutIndex, turnStart: -1}
	if isTurnStart(x.items[cutIndex]) {
		return cut
	}
	// Mid-turn cut: the kept range starts with a reply or a tool call, so
	// the turn's opening request has to be summarized alongside the history.
	for i := cutIndex; i >= 0; i-- {
		if isTurnStart(x.items[i]) {
			cut.turnStart = i
			cut.split = true
			break
		}
	}
	return cut
}

// serializeConversation renders items as text for the summarization request.
// The conversation is presented as text rather than as messages so the model
// summarizes it instead of continuing it (Pi does the same). A leading
// compaction item is not part of the text: it is returned as the previous
// summary, which drives the update prompt.
func serializeConversation(items []StoredItem) (text string, previousSummary string) {
	var parts []string
	for _, it := range items {
		switch it.Role {
		case "compaction":
			previousSummary = it.Content
		case "user":
			if it.Content != "" {
				parts = append(parts, "[User]: "+it.Content)
			}
		case "assistant":
			if it.Content != "" {
				parts = append(parts, "[Assistant]: "+it.Content)
			}
		case "reasoning":
			if it.Reasoning == nil {
				continue
			}
			var text strings.Builder
			for _, p := range it.Reasoning.Content {
				text.WriteString(p.Text)
			}
			for _, p := range it.Reasoning.Summary {
				text.WriteString(p.Text)
			}
			if s := strings.TrimSpace(text.String()); s != "" {
				parts = append(parts, "[Assistant thinking]: "+s)
			}
		case "function_call":
			parts = append(parts, "[Assistant tool calls]: "+formatToolCall(it))
		case "function_call_output":
			if it.Output != "" {
				parts = append(parts, "[Tool result]: "+truncateForSummary(it.Output, toolResultSummaryChars))
			}
		}
	}
	return strings.Join(parts, "\n\n"), previousSummary
}

// formatToolCall renders a stored function call as name(key=value, …), the
// shape Pi uses. Arguments are the raw JSON string the model produced, so a
// value that will not decode is passed through as it was written.
func formatToolCall(it StoredItem) string {
	raw := strings.TrimSpace(it.Arguments)
	if raw == "" {
		return it.Name + "()"
	}
	var args map[string]any
	if err := json.Unmarshal([]byte(raw), &args); err != nil {
		return it.Name + "(" + raw + ")"
	}
	keys := make([]string, 0, len(args))
	for k := range args {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	pairs := make([]string, 0, len(keys))
	for _, k := range keys {
		value, err := json.Marshal(args[k])
		if err != nil {
			continue
		}
		pairs = append(pairs, fmt.Sprintf("%s=%s", k, value))
	}
	return it.Name + "(" + strings.Join(pairs, ", ") + ")"
}

// truncateForSummary caps text for a summarization prompt, marking how much
// was dropped so the model knows the result was longer. The cap counts bytes
// (it is a size budget), but the cut lands on a rune boundary and the dropped
// count is in runes: half a character would reach the model as a replacement
// character, misreporting the text it is summarizing.
func truncateForSummary(text string, maxChars int) string {
	if len(text) <= maxChars {
		return text
	}
	cut := maxChars
	for cut > 0 && !utf8.RuneStart(text[cut]) {
		cut--
	}
	return fmt.Sprintf("%s\n\n[... %d more characters truncated]", text[:cut], utf8.RuneCountInString(text[cut:]))
}

// compactPrompts holds the four prompts a compaction may send, read from
// COMPACT-*.md in the prompts subdirectory of the configuration directory
// (see prompt.go).
type compactPrompts struct {
	System     string // system prompt of the summarization request
	Initial    string // summary format, when there is no previous summary
	Update     string // merge rules, when updating an existing summary
	TurnPrefix string // summary of a split turn's prefix
}

// loadCompactPrompts reads the four prompt files from the prompts
// subdirectory of the configuration directory. All four are read even though a
// given run uses at most two of them: which two depends on the cut point,
// which is not known until the conversation is measured, so requiring all four
// keeps the failure deterministic and ahead of any provider call.
func loadCompactPrompts() (*compactPrompts, error) {
	p := &compactPrompts{}
	for _, f := range []struct {
		dst  *string
		name string
	}{
		{&p.System, "COMPACT-SYSTEM.md"},
		{&p.Initial, "COMPACT-INITIAL.md"},
		{&p.Update, "COMPACT-UPDATE.md"},
		{&p.TurnPrefix, "COMPACT-PREFIX.md"},
	} {
		path, err := promptPath(f.name)
		if err != nil {
			return nil, err
		}
		text, err := loadPrompt(path)
		if err != nil {
			return nil, err
		}
		*f.dst = text
	}
	return p, nil
}

// compactSettings come from the environment; both are token counts.
type compactSettings struct {
	keepRecent int // roughly how much of the recent conversation to keep
	reserve    int // budget the summary may use, as a share of it
}

// defaults, matching Pi's DEFAULT_COMPACTION_SETTINGS.
const (
	defaultKeepRecent = 20000
	defaultReserve    = 16384
)

func compactSettingsFromEnv() (compactSettings, error) {
	keep, err := envTokenLimit("MIAGENT_KEEP_RECENT_TOKENS")
	if err != nil {
		return compactSettings{}, err
	}
	reserve, err := envTokenLimit("MIAGENT_RESERVE_TOKENS")
	if err != nil {
		return compactSettings{}, err
	}
	if keep == 0 {
		keep = defaultKeepRecent
	}
	if reserve == 0 {
		reserve = defaultReserve
	}
	return compactSettings{keepRecent: keep, reserve: reserve}, nil
}

// summarize runs one summarization call and returns its text and usage. The
// conversation is presented inside the prompt as text, with the system prompt
// telling the model to summarize rather than continue it.
//
// The configured reasoning effort is deliberately not sent: reasoning tokens
// count against MaxOutputTokens, so a high effort could spend the summary's
// whole budget thinking and return no text. Summarization does not need it.
func (p *provider) summarize(ctx context.Context, system, prompt string, maxTokens int) (string, Usage, error) {
	resp, err := p.client.CreateResponse(ctx, openai.CreateResponseRequest{
		Model:           p.model,
		Instructions:    system,
		Input:           []any{promptMessage("user", "input_text", prompt)},
		MaxOutputTokens: maxTokens,
	})
	if err != nil {
		return "", Usage{}, err
	}
	if resp.Status != "" && resp.Status != openai.ResponseStatusCompleted {
		msg := string(resp.Status)
		if resp.Error != nil && resp.Error.Message != "" {
			msg = resp.Error.Message
		}
		return "", Usage{}, fmt.Errorf("summarization response %s", msg)
	}
	text := strings.TrimSpace(resp.GetOutputText())
	if text == "" {
		return "", Usage{}, errors.New("summarization returned no text")
	}
	var usage Usage
	if u := usageOf(resp.Usage); u != nil {
		usage = *u
	}
	return text, usage, nil
}

// promptMessage builds one text message input item.
func promptMessage(role, contentType, text string) openai.ResponseInputMessage {
	return openai.ResponseInputMessage{
		Type:    "message",
		Role:    role,
		Content: []openai.ResponseInputText{{Type: contentType, Text: text}},
	}
}

// summarizationPrompt builds the user message for a summarization call: the
// conversation, the previous summary when there is one, and the prompt that
// says what to produce. Its shape follows Pi's.
func summarizationPrompt(base string, conversation, previousSummary string) string {
	var b strings.Builder
	b.WriteString("<conversation>\n")
	b.WriteString(conversation)
	b.WriteString("\n</conversation>\n\n")
	if previousSummary != "" {
		b.WriteString("<previous-summary>\n")
		b.WriteString(previousSummary)
		b.WriteString("\n</previous-summary>\n\n")
	}
	b.WriteString(base)
	return b.String()
}

// compactionPlan is what a compaction will do, decided before any provider
// call: which text is summarized, which items survive as themselves, and the
// sized conversation it was cut from.
type compactionPlan struct {
	historyText string // the conversation before the split turn
	prefixText  string // the split turn's opening, when the cut split one
	firstKept   int    // index of the first surviving item; also the number of items replaced by the summary
	previous    string // summary being replaced, when there is one
	size        *tokenIndex
}

// planCompaction decides the cut and what falls on each side of it. A nil plan
// means there is nothing to compact.
func planCompaction(s *Session, keepRecent int) (*compactionPlan, error) {
	if len(s.Items) == 0 {
		return nil, nil
	}
	size := newTokenIndex(s.Items, s.Usages)
	cut := size.findCutPoint(keepRecent)
	if cut.firstKept <= 0 {
		// Everything is already within the retained tail: no history to
		// summarize.
		return nil, nil
	}

	historyEnd := cut.firstKept
	if cut.split {
		historyEnd = cut.turnStart
	}

	plan := &compactionPlan{firstKept: cut.firstKept, size: size}
	plan.historyText, _ = serializeConversation(s.Items[:historyEnd])
	if cut.split {
		plan.prefixText, _ = serializeConversation(s.Items[cut.turnStart:cut.firstKept])
	}
	// The summary being replaced is the first item of the summarized region,
	// which may fall in the history or, when the cut split the very turn the
	// summary opens, inside the prefix.
	plan.previous = previousSummary(s.Items[:cut.firstKept])

	// Nothing to summarize means nothing to do: this is what makes /compact
	// idempotent, since after a compaction the only thing before the kept
	// range is the summary being replaced, and re-summarizing a summary
	// would archive the session again for no gain.
	if plan.historyText == "" && plan.prefixText == "" {
		return nil, nil
	}
	if err := validateKept(s.Items[cut.firstKept:]); err != nil {
		return nil, err
	}
	return plan, nil
}

// previousSummary returns the summary a compaction would update: the summary
// of an earlier compaction, when the history about to be summarized contains
// one.
func previousSummary(items []StoredItem) string {
	for _, it := range items {
		if it.Role == "compaction" {
			return it.Content
		}
	}
	return ""
}

// validateKept checks that the items surviving a compaction stand on their own.
// A tool result without its call, or thinking without its reply, would be a
// context the provider may reject or misread, so a compaction that would
// produce one fails instead.
func validateKept(kept []StoredItem) error {
	calls := make(map[string]bool, len(kept))
	for _, it := range kept {
		if it.Role == "function_call" {
			calls[it.CallID] = true
		}
	}
	for i, it := range kept {
		switch it.Role {
		case "function_call_output":
			if !calls[it.CallID] {
				return fmt.Errorf("internal error: tool result %q would be kept without its call", it.CallID)
			}
		case "reasoning":
			// Thinking belongs to the reply it precedes.
			if i+1 < len(kept) && (kept[i+1].Role == "assistant" || kept[i+1].Role == "function_call") {
				continue
			}
			if i+1 < len(kept) && kept[i+1].Role == "reasoning" {
				continue
			}
			return errors.New("internal error: thinking would be kept without the reply it belongs to")
		}
	}
	return nil
}

// compactedSessionBytes renders a compacted session file: the compaction
// record, the summary item, then the kept items.
func compactedSessionBytes(rec compactionRecord, items []StoredItem) ([]byte, error) {
	buf := &bytes.Buffer{}
	enc := json.NewEncoder(buf)
	if err := enc.Encode(rec); err != nil {
		return nil, err
	}
	for _, it := range items {
		if err := enc.Encode(it); err != nil {
			return nil, err
		}
	}
	return buf.Bytes(), nil
}

// compact replaces the session's older conversation with a summary of it.
//
// Order matters: the session file is checked, the prompts are read, then the
// cut is decided and validated, then the model is asked to summarize, and only
// when a complete replacement session exists is it swapped in (see
// archiveSession and writeSessionFile). A failure at any earlier step leaves
// the session exactly as it was, and the pre-compaction session survives as
// its own archive.
func (p *provider) compact(ctx context.Context, s *Session, d *display) error {
	if s.path == "" {
		return errors.New("no session file to compact")
	}
	// A session that has not been written yet has nothing to summarize. That
	// is the same state as a conversation under the retention budget, and it
	// is reported the same way: a first-time project running /compact is not
	// an error, and a missing file is not something the user can fix beyond
	// the prompt they have not sent yet.
	if _, err := os.Stat(s.path); err != nil {
		if os.IsNotExist(err) {
			d.info(fmt.Sprintf("nothing to compact: no session file at %s\n", s.path))
			return nil
		}
		return fmt.Errorf("session file: %w", err)
	}

	prompts, err := loadCompactPrompts()
	if err != nil {
		return err
	}
	settings, err := compactSettingsFromEnv()
	if err != nil {
		return err
	}

	plan, err := planCompaction(s, settings.keepRecent)
	if err != nil {
		return err
	}
	if plan == nil {
		// Nothing to compact means the conversation itself is under the
		// budget, so it is the conversation's size that belongs here, not
		// what a request for it would report.
		size := newTokenIndex(s.Items, s.Usages)
		d.info(fmt.Sprintf("nothing to compact: the conversation (%s tokens%s) is already within the retention budget (%s tokens)\n",
			commas(size.suffix(0)), estimateNote(size.measured), commas(settings.keepRecent)))
		return nil
	}
	d.info(fmt.Sprintf("compacting: replacing %d %s with a summary (%s tokens%s)…\n",
		plan.firstKept, plural(plan.firstKept, "item", "items"),
		commas(plan.size.total()), estimateNote(plan.size.measured)))

	carried := s.total()
	summary, usage, err := p.summarizePlan(ctx, prompts, plan, settings)
	if err != nil {
		return err
	}
	carried = carried.add(usage)

	summaryItem := StoredItem{Role: "compaction", Content: summary}
	kept := s.Items[plan.firstKept:]
	items := make([]StoredItem, 0, len(kept)+1)
	items = append(items, summaryItem)
	items = append(items, kept...)

	// What the compaction leaves behind, in the terms /context will report the
	// new session in: the tail it keeps, measured where the provider measured
	// it and free of the fixed overhead a request carries, plus the summary,
	// which no request has carried yet and only the heuristic can size.
	after := estimateItemTokens(summaryItem) + plan.size.suffix(plan.firstKept)
	archived := filepath.Base(s.path)
	rec := compactionRecord{
		Type:         "compaction",
		Archived:     archived, // replaced below with the real name if it moved
		Created:      time.Now().UTC().Format(time.RFC3339),
		TokensBefore: plan.size.total(),
		TokensAfter:  after,
		Usage:        carried,
	}
	content, err := compactedSessionBytes(rec, items)
	if err != nil {
		return err
	}

	// The archive name is decided before the record is written, so the file
	// names the archive it actually sits next to. The archive is a copy: the
	// session file stays in place until the replacement is renamed over it,
	// so no crash can leave the session path empty (see archiveSession).
	archive, err := archiveSession(s.path)
	if err != nil {
		return err
	}
	rec.Archived = filepath.Base(archive)
	if content, err = compactedSessionBytes(rec, items); err != nil {
		discardArchive(archive)
		return err
	}
	if err := writeSessionFile(s.path, content); err != nil {
		// The session file is untouched, so the archive is a redundant copy
		// of it: remove it rather than leave a stray that the next /new or
		// /compact would pack as if it were a real compaction.
		discardArchive(archive)
		return err
	}

	// The file on disk already holds all of this, so nothing is pending.
	s.Items = items
	s.Usages = nil
	s.Carried = carried
	s.Compacted = true
	s.committed = len(items)
	s.committedUsages = 0

	d.info(fmt.Sprintf("compacted %s -> %s tokens (%s); replaced %d %s, kept %d as they were\n",
		commas(plan.size.total()), commas(after), afterNote(plan.size.measured),
		plan.firstKept, plural(plan.firstKept, "item", "items"), len(kept)))
	d.info(fmt.Sprintf("archived as %s\n", archive))
	return nil
}

// summarizePlan produces the replacement summary: the history's summary, the
// split turn's prefix summary when the cut fell inside a turn, or both merged.
//
// A history that is only the summary being replaced is carried forward rather
// than sent again: it is already the summary, and its job in the merge is done
// by the <previous-summary> block.
func (p *provider) summarizePlan(ctx context.Context, prompts *compactPrompts, plan *compactionPlan, settings compactSettings) (string, Usage, error) {
	historyMax := settings.reserve * 8 / 10
	prefixMax := settings.reserve / 2

	history, usage, err := p.historySummary(ctx, prompts, plan, historyMax)
	if err != nil {
		return "", Usage{}, err
	}
	if plan.prefixText == "" {
		return history, usage, nil
	}

	// A split turn: the prefix is summarized on its own terms so the kept
	// suffix can be understood, and the two summaries are joined.
	prefixPrompt := summarizationPrompt(prompts.TurnPrefix, plan.prefixText, "")
	prefix, prefixUsage, err := p.summarize(ctx, prompts.System, prefixPrompt, prefixMax)
	if err != nil {
		return "", Usage{}, err
	}
	return history + "\n\n---\n\n**Turn Context (split turn):**\n\n" + prefix, usage.add(prefixUsage), nil
}

// historySummary summarizes everything before the split turn, returning the
// previous summary unchanged when there is nothing new to fold into it.
func (p *provider) historySummary(ctx context.Context, prompts *compactPrompts, plan *compactionPlan, maxTokens int) (string, Usage, error) {
	switch {
	case plan.historyText != "":
		return p.summarize(ctx, prompts.System, plan.prompt(prompts), maxTokens)
	case plan.previous != "":
		return plan.previous, Usage{}, nil
	default:
		return "No prior history.", Usage{}, nil
	}
}

// prompt builds the summarization prompt: the update rules when a previous
// summary is being merged, the initial format otherwise.
func (plan *compactionPlan) prompt(prompts *compactPrompts) string {
	base := prompts.Initial
	if plan.previous != "" {
		base = prompts.Update
	}
	return summarizationPrompt(base, plan.historyText, plan.previous)
}

// estimateNote labels a token count as measured or estimated.
func estimateNote(measured bool) string {
	if measured {
		return ""
	}
	return ", estimated"
}

// afterNote describes the size a compaction leaves behind: the tail it keeps
// is measured when the conversation was, while the summary is text no request
// has carried yet, so it is always estimated.
func afterNote(measured bool) string {
	if measured {
		return "kept tail measured, summary estimated"
	}
	return "estimated"
}
