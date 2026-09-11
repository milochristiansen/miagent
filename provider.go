// The model endpoint the harness talks to and the model list it offers. The
// agent loop and /compact build a provider for their model calls; /models uses
// it to ask the endpoint what it has and how each model reasons.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"

	openai "github.com/sashabaranov/go-openai"
)

// defaultBaseURL mirrors the go-openai default, so a model list can name the
// endpoint even when OPENAI_BASE_URL is unset. Only the label comes from it;
// the SDK client keeps its own copy of the default.
const defaultBaseURL = "https://api.openai.com/v1"

// maxModelsBytes caps the model-list response the harness will read, so a
// hostile or broken endpoint cannot exhaust memory.
const maxModelsBytes = 8 << 20

// provider is the model endpoint a command talks to: the configured client and
// the model name. The agent loop builds one too; /compact needs it because
// summarization is itself a model call.
type provider struct {
	client *openai.Client
	model  string

	// baseURL and apiKey are the explicit OPENAI_BASE_URL and OPENAI_API_KEY
	// values, kept so /models can query the endpoint directly and read the
	// capability fields the SDK's typed Model drops. baseURL is empty when the
	// SDK default is in use, and the SDK path is used then.
	baseURL string
	apiKey  string

	// reasoning is the reasoning configuration sent with agent turns (nil when
	// none is configured), and reasoningEffort its configured value, for
	// display by /models.
	reasoning       *openai.ResponseReasoning
	reasoningEffort string
}

// modelInfo is one model an endpoint offers, plus what the harness believes
// about the reasoning efforts it accepts.
type modelInfo struct {
	ID      string
	Efforts []string // accepted efforts, weakest first; empty means none
	Known   bool     // whether anything is known about the model's reasoning
}

// endpointLabel names the endpoint for display: the configured base URL, or the
// SDK default when none was set.
func endpointLabel(baseURL string) string {
	if strings.TrimSpace(baseURL) == "" {
		return defaultBaseURL
	}
	return strings.TrimRight(baseURL, "/")
}

// modelsURL is the model-list URL for a base URL, falling back to the SDK
// default when none was configured.
func modelsURL(baseURL string) string {
	base := strings.TrimSpace(baseURL)
	if base == "" {
		base = defaultBaseURL
	}
	return strings.TrimRight(base, "/") + "/models"
}

// listModels returns every model the endpoint offers, each annotated with the
// reasoning efforts it is known to accept.
//
// When the harness knows the endpoint's base URL it reads the model list
// itself, so it can also pick up capability metadata the SDK's typed model
// drops; otherwise it goes through the SDK. A failure of the direct read falls
// back to the SDK, which reports a consistent error for the same endpoint.
func (p *provider) listModels(ctx context.Context) ([]modelInfo, error) {
	if p.baseURL != "" {
		if models, err := p.fetchModels(ctx); err == nil {
			return models, nil
		}
	}

	list, err := p.client.ListModels(ctx)
	if err != nil {
		return nil, err
	}
	models := make([]modelInfo, 0, len(list.Models))
	for _, m := range list.Models {
		models = append(models, annotateModel(m.ID, nil))
	}
	return models, nil
}

// fetchModels reads the endpoint's /models document directly, keeping any
// reasoning capability fields alongside each model id.
func (p *provider) fetchModels(ctx context.Context) ([]modelInfo, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, modelsURL(p.baseURL), nil)
	if err != nil {
		return nil, err
	}
	if p.apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+p.apiKey)
	}
	req.Header.Set("Accept", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		detail, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		msg := strings.TrimSpace(string(detail))
		if msg == "" {
			return nil, fmt.Errorf("model list: %s", resp.Status)
		}
		return nil, fmt.Errorf("model list: %s: %s", resp.Status, msg)
	}

	var body struct {
		Data []json.RawMessage `json:"data"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, maxModelsBytes)).Decode(&body); err != nil {
		return nil, fmt.Errorf("model list: %w", err)
	}

	models := make([]modelInfo, 0, len(body.Data))
	for _, raw := range body.Data {
		if m, ok := decodeModel(raw); ok {
			models = append(models, m)
		}
	}
	return models, nil
}

// rawModel is the part of a model object the harness reads: the id, and the
// capability fields routers sometimes add. The standard OpenAI shape carries
// none of the latter.
type rawModel struct {
	ID                       string   `json:"id"`
	ReasoningEfforts         []string `json:"reasoning_efforts"`
	SupportedReasoningLevels []string `json:"supported_reasoning_levels"`
	Reasoning                *struct {
		SupportedEfforts []string `json:"supported_efforts"`
		Efforts          []string `json:"efforts"`
		SupportedEffort  string   `json:"supported_effort"`
	} `json:"reasoning"`
}

// reportedEfforts returns the effort levels the model object names, if any,
// preferring the richer list fields over a single value.
func (m rawModel) reportedEfforts() []string {
	if m.Reasoning != nil {
		if len(m.Reasoning.SupportedEfforts) > 0 {
			return m.Reasoning.SupportedEfforts
		}
		if len(m.Reasoning.Efforts) > 0 {
			return m.Reasoning.Efforts
		}
		if m.Reasoning.SupportedEffort != "" {
			return []string{m.Reasoning.SupportedEffort}
		}
	}
	if len(m.ReasoningEfforts) > 0 {
		return m.ReasoningEfforts
	}
	return m.SupportedReasoningLevels
}

// decodeModel reads one model object. A model without an id is skipped rather
// than reported as a blank row.
func decodeModel(raw json.RawMessage) (modelInfo, bool) {
	var m rawModel
	if err := json.Unmarshal(raw, &m); err != nil {
		return modelInfo{}, false
	}
	if strings.TrimSpace(m.ID) == "" {
		return modelInfo{}, false
	}
	return annotateModel(m.ID, m.reportedEfforts()), true
}

// annotateModel pairs a model id with its reasoning levels: levels the endpoint
// reported when it gave any, otherwise what the harness knows about the model
// family. A model neither source covers stays unknown.
func annotateModel(id string, reported []string) modelInfo {
	m := modelInfo{ID: id}
	if efforts := normalizeEfforts(reported); len(efforts) > 0 {
		m.Efforts = efforts
		m.Known = true
		return m
	}
	if efforts, known := inferReasoningEfforts(id); known {
		m.Efforts = efforts
		m.Known = true
	}
	return m
}

// reasoningSummary renders one model's reasoning levels for /models.
func reasoningSummary(m modelInfo) string {
	switch {
	case !m.Known:
		return "reasoning: unknown"
	case len(m.Efforts) == 0:
		return "reasoning: none"
	default:
		return "reasoning: " + strings.Join(m.Efforts, ", ")
	}
}
