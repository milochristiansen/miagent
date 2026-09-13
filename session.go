// Session persistence: a JSONL file holding the conversation as one
// replayable Responses input item per line, plus one usage record per model
// turn whose response reported token usage. Every line is a user/assistant/
// reasoning message, a function call, a function call output, a usage record,
// or the compaction record a /compact left behind, told apart by the presence
// of a "type" tag. A session file holds at most one compaction record: /compact
// rewrites the file rather than appending to it, so the record describes the
// compaction that produced the file it sits in. The format is unversioned and
// carries no header: an old file is not migrated, it simply fails to load.
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	openai "github.com/sashabaranov/go-openai"
)

// maxSessionLineBytes caps one session line. A tool result is stored as a
// single JSON line, so a session holding a large one would otherwise be
// rejected by bufio.Scanner's default 64 KiB token limit and fail to load.
const maxSessionLineBytes = 64 << 20

// StoredItem is one JSONL-serializable conversation item. It mirrors the
// Responses API input items a resumed session replays: message items
// (role user|assistant with text content), reasoning items (the provider's
// id for the model's thinking plus its text, replayed so the provider sees
// the context it produced), function_call items (call id, name, raw JSON
// arguments), and function_call_output items (call id and the tool result
// text). A compaction item (role compaction) is the summary that stands in
// for the items an earlier /compact replaced; it is always the first item.
type StoredItem struct {
	Role      string     `json:"role"` // user | assistant | reasoning | function_call | function_call_output | compaction
	Content   string     `json:"content,omitempty"`
	CallID    string     `json:"call_id,omitempty"`
	Name      string     `json:"name,omitempty"`
	Arguments string     `json:"arguments,omitempty"`
	Output    string     `json:"output,omitempty"`
	Reasoning *reasoning `json:"reasoning,omitempty"` // role=reasoning
}

// reasoning is the body of a reasoning item: the provider's id for it, its
// summary and content text parts, and any opaque encrypted content it
// returned. All of it is stored so a resumed session can hand the item back
// unchanged.
type reasoning struct {
	ID               string          `json:"id,omitempty"`
	Summary          []ReasoningPart `json:"summary,omitempty"`
	Content          []ReasoningPart `json:"content,omitempty"`
	EncryptedContent string          `json:"encrypted_content,omitempty"`
}

// ReasoningPart is one text part of a reasoning item.
type ReasoningPart struct {
	Type string `json:"type,omitempty"` // summary_text | reasoning_text
	Text string `json:"text"`
}

// replay returns the parts and the opaque content to send back for this
// reasoning item, or nil when the item holds no text a provider would accept.
//
// llama.cpp and compatible servers reject a reasoning item whose content
// array is missing or empty, so content text is what replayed items carry.
// A provider that reports its thinking as a summary only (OpenAI's reasoning
// summary mode, content empty) gets that summary text replayed as content;
// its encrypted content is left out there, because opaque content no longer
// matches parts we rewrote.
func (r *reasoning) replay() (parts []ReasoningPart, encrypted string) {
	if r == nil {
		return nil, ""
	}
	if hasReasoningText(r.Content) {
		return r.Content, r.EncryptedContent
	}
	if !hasReasoningText(r.Summary) {
		return nil, ""
	}
	parts = make([]ReasoningPart, len(r.Summary))
	for i, p := range r.Summary {
		parts[i] = ReasoningPart{Type: "reasoning_text", Text: p.Text}
	}
	return parts, ""
}

// hasReasoningText reports whether any part carries non-blank text.
func hasReasoningText(parts []ReasoningPart) bool {
	for _, p := range parts {
		if strings.TrimSpace(p.Text) != "" {
			return true
		}
	}
	return false
}

// itemRoles are the conversation item roles a session file may contain;
// anything else is rejected on load rather than silently dropped from the
// context.
var itemRoles = map[string]bool{
	"user":                 true,
	"assistant":            true,
	"reasoning":            true,
	"function_call":        true,
	"function_call_output": true,
	"compaction":           true,
}

// Usage is the token accounting one model turn reported, as stored in a
// session file. Counters the provider did not report stay zero.
type Usage struct {
	InputTokens     int `json:"input_tokens"`
	CachedTokens    int `json:"cached_tokens,omitempty"`
	OutputTokens    int `json:"output_tokens"`
	ReasoningTokens int `json:"reasoning_tokens,omitempty"`
	TotalTokens     int `json:"total_tokens,omitempty"`

	// AtItems locates the measurement in the conversation: the number of
	// items it covers, which is the items a request carried plus the reply
	// its output count covers. The next request's input count covers
	// everything appended since, so consecutive records measure the span
	// between them exactly; only items past the newest one have to be
	// estimated. Zero means unknown (a record written before this field
	// existed), which bounds the context from below but cannot be placed in
	// it.
	AtItems int `json:"at_items,omitempty"`
}

// usageLine is the on-disk form of a Usage record: the record type that tells
// it apart from a conversation item, followed by the counters.
type usageLine struct {
	Type string `json:"type"`
	Usage
}

// add returns the counter-wise sum of two usage records. AtItems is not a
// counter and does not sum: an aggregate measurement has no single anchor.
func (u Usage) add(o Usage) Usage {
	return Usage{
		InputTokens:     u.InputTokens + o.InputTokens,
		CachedTokens:    u.CachedTokens + o.CachedTokens,
		OutputTokens:    u.OutputTokens + o.OutputTokens,
		ReasoningTokens: u.ReasoningTokens + o.ReasoningTokens,
		TotalTokens:     u.TotalTokens + o.TotalTokens,
	}
}

// usageOf converts the provider's usage report for one turn into a session
// record, or nil when the response carried no usage at all.
func usageOf(u *openai.ResponseUsage) *Usage {
	if u == nil {
		return nil
	}
	rec := &Usage{
		InputTokens:  u.InputTokens,
		OutputTokens: u.OutputTokens,
		TotalTokens:  u.TotalTokens,
	}
	if d := u.InputTokensDetails; d != nil {
		rec.CachedTokens = d.CachedTokens
	}
	if d := u.OutputTokensDetails; d != nil {
		rec.ReasoningTokens = d.ReasoningTokens
	}
	return rec
}

// functionCallItem is the Responses API input item for a completed
// function call (the SDK exposes no typed struct for it).
type functionCallItem struct {
	Type      string `json:"type"`
	CallID    string `json:"call_id"`
	Name      string `json:"name"`
	Arguments string `json:"arguments"`
	Status    string `json:"status"`
}

// reasoningInputItem is the Responses API input item for reasoning the model
// produced earlier (the SDK exposes no typed struct for it).
type reasoningInputItem struct {
	Type             string          `json:"type"`
	ID               string          `json:"id,omitempty"`
	Summary          []ReasoningPart `json:"summary"`
	Content          []ReasoningPart `json:"content"`
	EncryptedContent string          `json:"encrypted_content,omitempty"`
}

// The wrapper that presents a compaction summary back to the model. It is the
// wire format for replaying a summary rather than a prompt, so it is a
// constant here and not a configurable file (Pi keeps it in code too):
// resumed sessions must keep replaying exactly what earlier ones did.
const (
	compactionPrefix = "The conversation history before this point was compacted into the following summary:\n\n<summary>\n"
	compactionSuffix = "\n</summary>"
)

// compactionRecord is the session-file record describing the compaction that
// produced the file it sits in: where the pre-compaction session was archived,
// when, the context size before and after, and the usage to carry forward —
// every usage record of the archived conversation plus that of the
// summarization call itself, so cost reporting survives the rewrite.
type compactionRecord struct {
	Type         string `json:"type"` // "compaction"
	Archived     string `json:"archived"`
	Created      string `json:"created"`
	TokensBefore int    `json:"tokens_before"`
	TokensAfter  int    `json:"tokens_after"`
	Usage        Usage  `json:"usage"`
}

// itemsToInput converts stored items into Responses API input items.
func itemsToInput(items []StoredItem) []any {
	in := make([]any, 0, len(items))
	for _, it := range items {
		switch it.Role {
		case "user":
			in = append(in, openai.ResponseInputMessage{
				Type:    "message",
				Role:    "user",
				Content: []openai.ResponseInputText{{Type: "input_text", Text: it.Content}},
			})
		case "compaction":
			in = append(in, openai.ResponseInputMessage{
				Type:    "message",
				Role:    "user",
				Content: []openai.ResponseInputText{{Type: "input_text", Text: compactionPrefix + it.Content + compactionSuffix}},
			})
		case "assistant":
			in = append(in, openai.ResponseInputMessage{
				Type:    "message",
				Role:    "assistant",
				Content: []openai.ResponseInputText{{Type: "output_text", Text: it.Content}},
			})
		case "reasoning":
			parts, encrypted := it.Reasoning.replay()
			if parts == nil {
				// The provider reported no text for this item (only an id,
				// or opaque content on its own); there is nothing a request
				// may carry, and providers reject an empty content array.
				continue
			}
			summary := it.Reasoning.Summary
			if summary == nil {
				summary = []ReasoningPart{}
			}
			in = append(in, reasoningInputItem{
				Type:             "reasoning",
				ID:               it.Reasoning.ID,
				Summary:          summary,
				Content:          parts,
				EncryptedContent: encrypted,
			})
		case "function_call":
			in = append(in, functionCallItem{
				Type:      "function_call",
				CallID:    it.CallID,
				Name:      it.Name,
				Arguments: it.Arguments,
				Status:    "completed",
			})
		case "function_call_output":
			in = append(in, openai.ResponseFunctionCallOutput{
				Type:   "function_call_output",
				CallID: it.CallID,
				Output: it.Output,
			})
		}
	}
	return in
}

// Session is a session file's contents: the conversation items replayed to
// the provider, one usage record per model turn that reported usage, and the
// persistence state needed to append both as the session grows. A compacted
// session also carries what its rewrite would otherwise have lost: the usage
// of the turns that were summarized.
type Session struct {
	Items  []StoredItem
	Usages []Usage

	// Carried is usage the session accumulated before its last compaction:
	// the archived conversation's turns plus the summarization call, as
	// recorded in the compaction record. Usages only ever holds turns
	// measured since, so the session's whole usage is Carried plus Usages
	// (see Session.total); it is written back into the next compaction's
	// record, keeping the session's token history complete across any number
	// of rewrites.
	Carried Usage
	// Compacted reports whether the session was produced by a compaction,
	// which is why its context has no measurement yet.
	Compacted bool

	path            string // session file; created on the first commit
	committed       int    // items already written to path
	committedUsages int    // usage records already written to path
}

// newSession returns a session persisted at path.
func newSession(path string) *Session { return &Session{path: path} }

// load reads the session file into s and marks everything read as committed.
// A missing or empty file leaves s empty; anything else must be a record this
// build understands.
func (s *Session) load() error {
	f, err := os.Open(s.path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	defer f.Close()
	return s.loadFrom(f)
}

// loadFrom reads session records from r into s and marks everything read as
// committed. load uses it on the session file; a command adopting a session
// file uses it to recognize a bad one before it replaces the current session.
// A missing file is load's concern, not loadFrom's.
func (s *Session) loadFrom(r io.Reader) error {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), maxSessionLineBytes)
	compaction := false
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		// The "type" tag is absent on conversation items and names the
		// record on everything else.
		var tag struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal([]byte(line), &tag); err != nil {
			return fmt.Errorf("bad session line: %w", err)
		}
		switch tag.Type {
		case "":
			var it StoredItem
			if err := json.Unmarshal([]byte(line), &it); err != nil {
				return fmt.Errorf("bad session line: %w", err)
			}
			if !itemRoles[it.Role] {
				return fmt.Errorf("bad session line: unknown item role %q", it.Role)
			}
			s.Items = append(s.Items, it)
		case "usage":
			var u Usage
			if err := json.Unmarshal([]byte(line), &u); err != nil {
				return fmt.Errorf("bad session line: %w", err)
			}
			s.Usages = append(s.Usages, u)
		case "compaction":
			if compaction {
				return errors.New("bad session line: a session file holds at most one compaction record")
			}
			var rec compactionRecord
			if err := json.Unmarshal([]byte(line), &rec); err != nil {
				return fmt.Errorf("bad session line: %w", err)
			}
			if rec.Archived == "" {
				return errors.New(`bad session line: compaction record has no "archived" field`)
			}
			compaction = true
			s.Carried = rec.Usage
			s.Compacted = true
		default:
			return fmt.Errorf("bad session line: unknown record type %q", tag.Type)
		}
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	s.committed = len(s.Items)
	s.committedUsages = len(s.Usages)
	return nil
}

// commit appends the items and usage records added since the last commit to
// the session file, creating the file if needed. An exchange is committed only
// when it is complete: either a final answer or a finished tool round, so an
// interruption never leaves a partial exchange (e.g. function calls without
// their outputs) on disk.
func (s *Session) commit() error {
	items := s.Items[s.committed:]
	usages := s.Usages[s.committedUsages:]
	if len(items) == 0 && len(usages) == 0 {
		return nil
	}
	if err := appendSession(s.path, items, usages); err != nil {
		return err
	}
	s.committed = len(s.Items)
	s.committedUsages = len(s.Usages)
	return nil
}

// reset empties the session: its conversation, its usage, and the persistence
// state, so the next exchange starts from nothing. It is what /new leaves
// behind after the session file has been archived and deleted — the in-memory
// state has to match, or the next commit would write records for a session
// that no longer exists on disk.
func (s *Session) reset() {
	s.Items = nil
	s.Usages = nil
	s.Carried = Usage{}
	s.Compacted = false
	s.committed = 0
	s.committedUsages = 0
}

// total returns the session's complete usage: what earlier turns carried
// through the last compaction plus every turn measured since.
func (s *Session) total() Usage {
	total := s.Carried
	for _, u := range s.Usages {
		total = total.add(u)
	}
	return total
}

// checkSessionWritable verifies that the session file can be written, so a
// session that cannot be saved says so before an exchange runs rather than
// after one has. It creates the file when it does not exist, because proving
// the path accepts one is the whole point; that leaves a session with no
// records behind, which is an ordinary state — every session starts empty, and
// the loader and /new both read it as a session with nothing in it. The
// directory is not created: the default state directory is the harness's own
// and the first run makes it, while a path named by MIAGENT_SESSION belongs to
// whoever named it, and a wrong one there is theirs to fix.
func checkSessionWritable(path string) error {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	return f.Close()
}

// appendSession appends conversation items and usage records to the session
// file, creating it if needed. Each record is written as one JSON line; the
// file carries no header, so an empty file and a missing one are the same
// thing.
func appendSession(path string, items []StoredItem, usages []Usage) error {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}
	defer f.Close()

	enc := json.NewEncoder(f)
	for _, it := range items {
		if err := enc.Encode(it); err != nil {
			return err
		}
	}
	for _, u := range usages {
		if err := enc.Encode(usageLine{Type: "usage", Usage: u}); err != nil {
			return err
		}
	}
	return nil
}
