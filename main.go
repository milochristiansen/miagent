// MiAgent: a minimal agent harness that drives the OpenAI Responses API with
// TGI tools (see tools/). It streams reasoning (subdued markdown), assistant
// output (plain markdown), and live tool output through termark on a
// terminal, falling back to plain text when stdout is not a terminal.
// Sessions are persisted as JSONL (see session.go).
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"

	openai "github.com/sashabaranov/go-openai"
)

// ToolDef holds a discovered tool's schema and executable path.
type ToolDef struct {
	Name       string
	ExecPath   string
	Definition openai.ResponseTool
}

// toolsDir is the name of the tool directory, in both places tools are read
// from: the configuration directory holds the base set, and the state
// directory may hold a project-local set that overrides it. The prompts (in a
// prompts subdirectory) and the core .env also live in the configuration
// directory (see configDir).
const (
	toolsDir = "tools"
	stateDir = ".miagent"
)

// toolsDirs returns the directories tools are discovered in, in precedence
// order: the configuration directory's base set first, then the project-local
// set under the state directory. A tool defined in both is taken from the
// later directory, so a project can override an installed tool without
// touching the installation.
func toolsDirs(stateDir string) ([]string, error) {
	config, err := configDir()
	if err != nil {
		return nil, err
	}
	return []string{filepath.Join(config, toolsDir), filepath.Join(stateDir, toolsDir)}, nil
}

// defaultSession is the session file used when MIAGENT_SESSION is unset.
var defaultSession = filepath.Join(stateDir, "session.jsonl")

var discoveredTools map[string]ToolDef

func fail(format string, err error) {
	fmt.Fprintf(os.Stderr, format+": %v\n", err)
	os.Exit(1)
}

func usage() {
	fmt.Fprintf(os.Stderr, "Usage: miagent prompt...\n"+
		"The prompt is the raw command line (space-joined)\n"+
		"If the first prompt character is a \"/\" it is treated as a harness command instead of a prompt.\n"+
		"Commands: (/help, /context, /models, /desc, /compact, /new, /sessions, /load).\n"+
		"Configuration is read from MIAGENT_CONFIG_DIR when set, otherwise\n"+
		"$XDG_CONFIG_HOME/miagent (~/.config/miagent by default).\n")
	os.Exit(2)
}

func main() {
	// The prompt is the whole, unparsed command line: argv[1:] joined with
	// spaces. No argument parsing.
	if len(os.Args) < 2 {
		usage()
	}
	prompt := strings.Join(os.Args[1:], " ")

	// Signal listener: a signal cancels the context (interrupting any
	// in-flight model stream or tool) and the main loop exits gracefully.
	ctx, cancel := context.WithCancel(context.Background())
	sigCh := make(chan os.Signal, 2)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(sigCh)
	go func() {
		<-sigCh
		cancel()
	}()

	// Configure the run: the local .env first (it may point
	// MIAGENT_CONFIG_DIR at another installation), then the resolved
	// configuration directory, then the core .env (see loadConfig).
	if err := loadConfig(stateDir); err != nil {
		fail("loading configuration", err)
	}

	apiKey := os.Getenv("OPENAI_API_KEY")
	baseURL := os.Getenv("OPENAI_BASE_URL")
	sessionFile := os.Getenv("MIAGENT_SESSION")
	model := os.Getenv("OPENAI_MODEL")

	// Load the conversation and the usage recorded so far from the session
	// file: the MIAGENT_SESSION path when set, otherwise the state
	// directory's session.jsonl, whose directory is created on demand. A
	// missing explicitly-named session is a fresh session; a missing default
	// one is the ordinary first run.
	//
	// The state directory is the harness's own and is created on demand; a
	// directory named by MIAGENT_SESSION belongs to whoever named it, so a
	// wrong path there is reported rather than repaired.
	outPath := sessionFile
	if outPath == "" {
		outPath = defaultSession
		if err := os.MkdirAll(filepath.Dir(outPath), 0o755); err != nil {
			fail("creating "+filepath.Dir(outPath), err)
		}
	}
	sess := newSession(outPath)
	if _, err := os.Stat(outPath); err == nil {
		if err := sess.load(); err != nil {
			fail("loading session", err)
		}
	} else if errors.Is(err, os.ErrNotExist) {
		if sessionFile != "" {
			fmt.Fprintf(os.Stderr, "session %s not found; starting a new session\n", sessionFile)
		}
	} else {
		fail("loading session", err)
	}

	interrupted := func() {
		fmt.Fprintf(os.Stderr, "interrupted by signal; session saved up to the last complete exchange\n")
		os.Exit(3)
	}

	// The session's screen: termark renderers on a terminal, plain text
	// otherwise (see display.go). A malformed tool-call display size is
	// reported now, before any output, rather than partway through a run.
	disp := newDisplay()
	if disp.toolSizeErr != nil {
		fail("loading configuration", disp.toolSizeErr)
	}

	// The provider is needed by commands that call the model (/compact
	// summarizes through it and /new names the session through it) as well
	// as by the agent loop below, so it is built before dispatch.
	// Constructing it does no I/O; a command that actually calls the model
	// declares that with needModel.
	cfg := openai.DefaultConfig(apiKey)
	if baseURL != "" {
		cfg.BaseURL = baseURL
	}
	// The reasoning level is read here, once, and carried by the provider so
	// every agent turn sends the same one. A malformed value is not rejected:
	// the endpoint decides which levels it accepts, and a proxy may take ones
	// the OpenAI API does not name. /models reports what it is set to.
	prov := &provider{
		client:          openai.NewClientWithConfig(cfg),
		model:           model,
		baseURL:         baseURL,
		apiKey:          apiKey,
		reasoning:       reasoningFromEnv(),
		reasoningEffort: configuredReasoningEffort(),
	}

	// A slash-prefixed prompt is a harness command: it runs here, before any
	// exchange starts, and never enters the conversation.
	if name, args, ok := parseCommand(prompt); ok {
		cmd, ok := findCommand(name)
		if !ok {
			unknownCommand(name)
		}
		if cmd.needModel && model == "" {
			fmt.Fprintf(os.Stderr, "Error: /%s needs a model (set OPENAI_MODEL)\n", cmd.name)
			os.Exit(1)
		}
		if err := cmd.run(ctx, prov, sess, disp, args); err != nil {
			fail("command /"+cmd.name, err)
		}
		return
	}

	// Everything past this point talks to the provider.
	if model == "" {
		fmt.Fprintf(os.Stderr, "Error: model not specified (set OPENAI_MODEL)\n")
		os.Exit(1)
	}

	// An exchange is recorded in the session file, which makes this the first
	// point at which creating an empty one is harmless: the conversation below
	// fills it. The commands above do not write it — /context only reads, and
	// /new retires the file — so the check is not run for them, and the file it
	// creates here is one a session that runs a turn would have created anyway.
	// Failing now rather than at the commit that follows the model's answer is
	// the point: an unsaveable session is worth saying before it costs a turn.
	if err := checkSessionWritable(outPath); err != nil {
		fail("session file", err)
	}

	// Discover tools via TGI SCHEMA calls.
	discoveredTools = make(map[string]ToolDef)
	tools := discoverTools(ctx)

	// Load the instructions sent with every request: the system prompt from
	// the configuration directory's prompts/SYSTEM.md, then the optional AGENTS.md
	// files, which have lower priority (they add to it rather than replace
	// it). Read once here, like
	// the system prompt and unlike the compaction prompts, which /compact
	// reads on demand. Nothing of this reaches the session.
	instructions, err := sessionInstructions(stateDir)
	if err != nil {
		fail("loading instructions", err)
	}

	// This exchange starts with the user's prompt.
	sess.Items = append(sess.Items, StoredItem{Role: "user", Content: prompt})

	for {
		// Shutdown may have been requested between exchanges.
		select {
		case <-ctx.Done():
			interrupted()
		default:
		}

		// Run one model turn: stream the response through the display,
		// and return the items it produced (assistant message, function
		// calls) plus the usage the provider reported, for persistence.
		turnItems, turnUsage, final, err := runModelTurn(ctx, prov, instructions, sess.Items, tools, disp)
		if err != nil {
			if ctx.Err() != nil {
				interrupted()
			}
			fail("response", err)
		}
		sess.Items = append(sess.Items, turnItems...)
		if turnUsage != nil {
			// Locate the measurement: the input tokens covered the items
			// this request carried and the output tokens covered the reply
			// it produced, so together they size the conversation up to
			// here. Items appended later — the tool results of this turn
			// below, or the next one — are not in either count, and get
			// estimated on top until the request that carries them reports
			// its own usage.
			turnUsage.AtItems = len(sess.Items)
			sess.Usages = append(sess.Usages, *turnUsage)
		}

		if final {
			// Final answer: the exchange is complete. Persist it, then leave
			// a subdued context-size note just below the answer. A bad
			// MIAGENT_CONTEXT_LIMIT must not turn a completed turn into a
			// failure, so an unformattable note is omitted rather than fatal.
			if err := sess.commit(); err != nil {
				fail("saving session", err)
			}
			if line, err := contextLine(sess); err == nil {
				// A BEL rides the note so it lands at the end of the turn
				// in both render and raw mode, alerting a reader who has
				// looked away that the answer is ready.
				disp.subdued(line + "\a")
			}
			return
		}

		// Execute the function calls the model made. Each call opens a
		// live tool box whose output section streams stdout/stderr
		// interleaved while the tool runs; the result is fed back as a
		// function_call_output item.
		for _, it := range turnItems {
			if it.Role != "function_call" {
				continue
			}
			prettyArgs := tryIndentJSONishText(it.Arguments)
			disp.toolStart(it.Name, prettyArgs)

			res, envelope := executeTool(ctx, it.Name, it.Arguments, disp.toolOut(), disp.toolErr())
			disp.toolEnd(res)

			sess.Items = append(sess.Items, StoredItem{
				Role:   "function_call_output",
				CallID: it.CallID,
				Output: envelope,
			})
		}

		// The tool round is complete: persist it, then let the model
		// respond to the results.
		if err := sess.commit(); err != nil {
			fail("saving session", err)
		}
	}
}

// runModelTurn streams one model response for the given conversation and
// returns the items it produced, plus whether the turn was final (no
// function calls to run). Assistant text and reasoning are routed through
// the display as they arrive, and any answer the stream did not carry as
// deltas is echoed once the response completes. instructions is the request's
// full instruction text: the system prompt plus whatever AGENTS.md
// contributed.
func runModelTurn(
	ctx context.Context,
	prov *provider,
	instructions string,
	conversation []StoredItem,
	tools []openai.ResponseTool,
	d *display,
) (items []StoredItem, usage *Usage, final bool, err error) {
	defer d.endTurn()

	stream, err := prov.client.CreateResponseStream(ctx, openai.CreateResponseRequest{
		Model:        prov.model,
		Instructions: instructions,
		Input:        itemsToInput(conversation),
		Tools:        tools,
		Reasoning:    prov.reasoning,
	})
	if err != nil {
		return nil, nil, false, err
	}
	defer stream.Close()

	// Accumulators used both to echo text live and as a fallback source
	// of the response items if response.completed omits them.
	var (
		completed bool
		finalResp openai.CreateResponseResponse
		msgText   strings.Builder
		fnCalls   []StoredItem       // function calls in stream order
		fnByID    = map[string]int{} // item id -> index into fnCalls
		rsItems   []StoredItem       // reasoning items in stream order
		rsByID    = map[string]int{} // item id -> index into rsItems
	)
	addFn := func(id string) int {
		if idx, ok := fnByID[id]; ok {
			return idx
		}
		fnByID[id] = len(fnCalls)
		fnCalls = append(fnCalls, StoredItem{Role: "function_call", CallID: id})
		return len(fnCalls) - 1
	}
	// addReasoningText appends a reasoning delta to the part at partIndex of
	// the item with the given id, registering the item on first sight. It
	// re-resolves the item through its slice index rather than holding a
	// pointer, because appending another item reallocates the slice.
	addReasoningText := func(id string, summary bool, partIndex int, delta string) {
		if id == "" || delta == "" {
			return
		}
		idx, ok := rsByID[id]
		if !ok {
			idx = len(rsItems)
			rsByID[id] = idx
			rsItems = append(rsItems, StoredItem{Role: "reasoning", Reasoning: &reasoning{ID: id}})
		}
		r := rsItems[idx].Reasoning
		parts := &r.Content
		partType := "reasoning_text"
		if summary {
			parts, partType = &r.Summary, "summary_text"
		}
		for len(*parts) <= partIndex {
			*parts = append(*parts, ReasoningPart{Type: partType})
		}
		(*parts)[partIndex].Text += delta
	}

	for {
		ev, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, nil, false, err
		}

		switch ev.Type {
		case openai.ResponseStreamEventReasoningTextDelta:
			if ev.Delta != "" {
				d.reasoning(ev.Delta)
				addReasoningText(ev.ItemID, false, ev.ContentIndex, ev.Delta)
			}

		case openai.ResponseStreamEventReasoningSummaryTextDelta:
			if ev.Delta != "" {
				d.reasoning(ev.Delta)
				addReasoningText(ev.ItemID, true, ev.SummaryIndex, ev.Delta)
			}

		case openai.ResponseStreamEventOutputTextDelta:
			msgText.WriteString(ev.Delta)
			d.output(ev.Delta)

		case openai.ResponseStreamEventFunctionArgumentsDelta:
			// Record the arguments fragment, keyed by the item id shared
			// with the call's output_item.added event.
			if ev.ItemID != "" {
				fnCalls[addFn(ev.ItemID)].Arguments += ev.Delta
			}

		case openai.ResponseStreamEventOutputItemAdded:
			it := ev.Item
			if it != nil && it.Type == "function_call" {
				idx := addFn(it.ID)
				if it.Name != "" {
					fnCalls[idx].Name = it.Name
				}
				if it.CallID != "" {
					fnCalls[idx].CallID = it.CallID
				}
			}

		case openai.ResponseStreamEventCompleted:
			if ev.Response != nil {
				completed = true
				finalResp = *ev.Response
			}

		case openai.ResponseStreamEventFailed:
			msg := "response failed"
			if ev.Response != nil && ev.Response.Error != nil && ev.Response.Error.Message != "" {
				msg = ev.Response.Error.Message
			}
			return nil, nil, false, errors.New(msg)

		case openai.ResponseStreamEventIncomplete:
			msg := "response incomplete"
			if ev.Response != nil && ev.Response.Error != nil && ev.Response.Error.Message != "" {
				msg += ": " + ev.Response.Error.Message
			}
			return nil, nil, false, errors.New(msg)

		case openai.ResponseStreamEventError:
			msg := ev.Message
			if msg == "" && ev.Error != nil {
				msg = ev.Error.Message
			}
			if msg == "" {
				msg = "unknown stream error"
			}
			return nil, nil, false, errors.New(msg)
		}
	}
	if !completed {
		return nil, nil, false, errors.New("stream ended before response.completed")
	}

	// Prefer the canonical items carried by response.completed; fall back
	// to the items reconstructed from stream events, in the order the model
	// produced them: reasoning, then its answer, then its function calls.
	if len(finalResp.Output) > 0 {
		items = responseItems(finalResp.Output)
	} else {
		items = make([]StoredItem, 0, len(rsItems)+1+len(fnCalls))
		items = append(items, rsItems...)
		if msgText.Len() > 0 {
			items = append(items, StoredItem{Role: "assistant", Content: msgText.String()})
		}
		// Function call names arrive in output_item.added; the arguments
		// deltas fill them in. Calls whose item events never arrived are
		// dropped here rather than replayed nameless.
		for _, call := range fnCalls {
			if call.Name != "" {
				items = append(items, call)
			}
		}
	}

	// Echo of the response is done; line termination is handled by the
	// display (renderer Close / raw-mode endTurn).

	// The display only ever sees deltas, so a provider that reports the
	// message text in response.completed without streaming it (or streams only
	// part of it) would leave the turn blank on screen. Echo whatever the
	// display has not seen, before the turn's line is terminated.
	if answer := assistantText(items); answer != "" {
		if rest := streamedRemainder(msgText.String(), answer); rest != "" {
			d.output(rest)
		}
	}

	// A final turn produced no function calls.
	final = true
	for _, it := range items {
		if it.Role == "function_call" {
			final = false
			break
		}
	}
	return items, usageOf(finalResp.Usage), final, nil
}

// assistantText returns the assistant message text carried by items, which is
// what a reader of the turn expects to see whatever produced it.
func assistantText(items []StoredItem) string {
	var text strings.Builder
	for _, it := range items {
		if it.Role == "assistant" {
			text.WriteString(it.Content)
		}
	}
	return text.String()
}

// streamedRemainder returns the part of the answer the display has not seen:
// the whole of it when nothing was streamed, the tail when what was streamed
// is a prefix of it, and nothing when the two disagree — text that is not an
// extension of what is already on screen would otherwise be printed twice.
func streamedRemainder(streamed, answer string) string {
	switch {
	case streamed == "":
		return answer
	case streamed == answer:
		return ""
	case strings.HasPrefix(answer, streamed):
		return answer[len(streamed):]
	default:
		return ""
	}
}

// responseItems extracts the persistence-worthy items (assistant message
// text, the model's reasoning, and completed function calls) from a
// response's output list. Reasoning is kept so a resumed session replays the
// context the provider produced; items that carry no text and no opaque
// content are dropped as noise.
func responseItems(output []any) []StoredItem {
	var items []StoredItem
	for _, raw := range output {
		b, err := json.Marshal(raw)
		if err != nil {
			continue
		}
		var it struct {
			Type             string          `json:"type"`
			Role             string          `json:"role"`
			ID               string          `json:"id"`
			CallID           string          `json:"call_id"`
			Name             string          `json:"name"`
			Arguments        string          `json:"arguments"`
			EncryptedContent string          `json:"encrypted_content"`
			Summary          []ReasoningPart `json:"summary"`
			Content          []ReasoningPart `json:"content"`
		}
		if err := json.Unmarshal(b, &it); err != nil {
			continue
		}
		switch it.Type {
		case "message":
			if it.Role != "assistant" {
				continue
			}
			var sb strings.Builder
			for _, c := range it.Content {
				if c.Type == "output_text" {
					sb.WriteString(c.Text)
				}
			}
			if sb.Len() > 0 {
				items = append(items, StoredItem{Role: "assistant", Content: sb.String()})
			}
		case "reasoning":
			if !hasReasoningText(it.Content) && !hasReasoningText(it.Summary) && it.EncryptedContent == "" {
				continue
			}
			items = append(items, StoredItem{
				Role: "reasoning",
				Reasoning: &reasoning{
					ID:               it.ID,
					Summary:          it.Summary,
					Content:          it.Content,
					EncryptedContent: it.EncryptedContent,
				},
			})
		case "function_call":
			if it.CallID == "" || it.Name == "" {
				continue
			}
			items = append(items, StoredItem{
				Role:      "function_call",
				CallID:    it.CallID,
				Name:      it.Name,
				Arguments: it.Arguments,
			})
		}
	}
	return items
}

// discoverTools scans the tool directories and runs TGI discovery on every
// executable it finds there. Directories are scanned in precedence order (see
// toolsDirs): a tool whose name is already known is replaced by the later
// definition, so the tool list carries each name once, in its surviving
// version.
//
// A missing directory is not an error: a project that defines no tools of its
// own, and an installation that has not had any installed, are both ordinary.
func discoverTools(ctx context.Context) []openai.ResponseTool {
	dirs, err := toolsDirs(stateDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Warning: tool discovery skipped: %v\n", err)
		return nil
	}

	var tools []openai.ResponseTool
	index := map[string]int{} // tool name -> position in tools
	for _, dir := range dirs {
		entries, err := os.ReadDir(dir)
		if err != nil {
			if !os.IsNotExist(err) {
				fmt.Fprintf(os.Stderr, "Warning: reading %s: %v\n", dir, err)
			}
			continue
		}
		for _, entry := range entries {
			if entry.IsDir() {
				continue
			}
			execPath := filepath.Join(dir, entry.Name())
			info, err := os.Stat(execPath)
			if err != nil || info.Mode()&0111 == 0 {
				continue
			}

			def, err := fetchToolMeta(ctx, execPath)
			if err != nil {
				fmt.Fprintf(os.Stderr, "Warning: tool %q in %s: %v\n", entry.Name(), dir, err)
				continue
			}

			discoveredTools[def.Name] = *def
			if i, ok := index[def.Name]; ok {
				// Overridden: keep one entry, carrying the winner.
				tools[i] = def.Definition
				continue
			}
			index[def.Name] = len(tools)
			tools = append(tools, def.Definition)
		}
	}
	return tools
}

// fetchToolMeta runs the tool with TGI_METHOD=SCHEMA and parses the
// JSON tool definition from its stdout.
func fetchToolMeta(ctx context.Context, execPath string) (*ToolDef, error) {
	r := RunTGITool(ctx, filepath.Base(execPath), execPath, "SCHEMA", nil, nil, nil)
	if r.Err != nil {
		return nil, r.Err
	}
	if r.Code != 0 {
		detail := strings.TrimSpace(r.Stderr)
		if detail == "" {
			return nil, fmt.Errorf("tool exited %d", r.Code)
		}
		return nil, fmt.Errorf("tool exited %d: %s", r.Code, detail)
	}

	var meta struct {
		Name        string                 `json:"name"`
		Description string                 `json:"description"`
		Parameters  map[string]interface{} `json:"parameters"`
	}
	if err := json.Unmarshal([]byte(r.Stdout), &meta); err != nil {
		return nil, fmt.Errorf("bad JSON: %w", err)
	}
	if meta.Name == "" {
		return nil, fmt.Errorf("missing 'name' field")
	}

	def := openai.NewResponseFunctionTool(openai.FunctionDefinition{
		Name:        meta.Name,
		Description: meta.Description,
		Parameters:  meta.Parameters,
	})

	return &ToolDef{
		Name:       meta.Name,
		ExecPath:   execPath,
		Definition: def,
	}, nil
}

// executeTool runs a discovered TGI tool with the given JSON arguments,
// teeing its stdout and stderr live into teeOut/teeErr (the display's open
// tool box), and returns the tool's result plus the JSON envelope of it that
// is fed back to the model.
func executeTool(ctx context.Context, name string, args string, teeOut, teeErr io.Writer) (TGIResult, string) {
	tool, ok := discoveredTools[name]
	if !ok {
		return toolFailure(teeErr, fmt.Sprintf("unknown tool: %s", name))
	}
	if ctx.Err() != nil {
		return toolFailure(teeErr, "not executed: interrupted by signal")
	}

	r := RunTGITool(ctx, tool.Name, tool.ExecPath, "INVOKE", strings.NewReader(args), teeOut, teeErr)
	if r.Err != nil {
		// The tool failed to run at all (no process).
		return toolFailure(teeErr, fmt.Sprintf("tool invocation failed: %v", r.Err))
	}

	buf := &bytes.Buffer{}
	enc := json.NewEncoder(buf)
	enc.SetIndent("", "    ")
	if err := enc.Encode(r); err != nil {
		return toolFailure(teeErr, err.Error())
	}
	return r, buf.String()
}

// toolFailure builds a synthetic tool result carrying a plain error message,
// used when a tool cannot run or the harness cannot encode its result. The
// message is also streamed into the open tool box (as stderr) when a tee is
// available.
func toolFailure(teeErr io.Writer, msg string) (TGIResult, string) {
	if teeErr != nil {
		_, _ = teeErr.Write([]byte(msg + "\n"))
	}
	res := TGIResult{Code: -1, Stderr: msg}
	buf := &bytes.Buffer{}
	enc := json.NewEncoder(buf)
	enc.SetIndent("", "    ")
	_ = enc.Encode(res) // never fails for this value
	return res, buf.String()
}

// tryIndentJSONishText attempts to reindent the given string as if it was JSON, returning the trimmed text if it is not JSON.
func tryIndentJSONishText(s string) string {
	trimmed := strings.TrimSpace(s)
	if trimmed == "" {
		return ""
	}
	var buf bytes.Buffer
	if err := json.Indent(&buf, []byte(trimmed), "", "    "); err != nil {
		return trimmed
	}
	return buf.String()
}
