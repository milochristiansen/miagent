package termark

import (
	"errors"
	"io"
	"os"
	"sync"
	"time"
	"unicode/utf8"

	"golang.org/x/term"
)

// ErrClosed is returned by Write/Flush/Close after Close.
var ErrClosed = errors.New("termark: renderer is closed")

// ErrNotTTY is returned by New when w is not a terminal.
var ErrNotTTY = errors.New("termark: output is not a TTY")

// Options configures a Renderer.
type Options struct {
	// Style is a style name ("dark" default, "light", "ascii") or, via
	// WithStyleConfig, a raw Style.
	Style string

	// Width is the wrap width in cells. 0 = auto, from the TTY (re-polled
	// each tick).
	Width int

	// Coalesce is the minimum interval between ticks under sustained input.
	// Default 16ms. When the writer is idle (no tick since the previous
	// batch), ticks run immediately in the Write call's goroutine, so
	// characters from a slow stream appear the moment they arrive.
	Coalesce time.Duration

	// styleConfig, when non-nil, overrides Style with a raw config.
	styleConfig *Style
}

// WithStyleConfig returns a copy of o configured with the raw style config.
func (o Options) WithStyleConfig(cfg Style) Options {
	o.styleConfig = &cfg
	return o
}

func (o Options) resolveStyle() (Style, error) {
	if o.styleConfig != nil {
		return *o.styleConfig, nil
	}
	return resolveStyleName(o.Style)
}

// Renderer streams markdown to a TTY, rendering as input arrives.
type Renderer struct {
	mu sync.Mutex
	f  *os.File

	fr     *fragmentRenderer
	tf     *tailFinder
	screen *Screen

	buf []byte // append-only input buffer (guarded by mu)

	width int // wrap width (auto if 0)
	autoW bool

	coalesce time.Duration

	closed bool

	tickCh chan struct{} // tick signal (buffered, non-blocking send)
	done   chan struct{} // shutdown signal for the tick goroutine
}

// New creates a renderer writing to w. w must be a TTY (an *os.File whose fd
// is a terminal); non-TTY output is an error.
func New(w io.Writer, opts Options) (*Renderer, error) {
	f, ok := w.(*os.File)
	if !ok {
		return nil, ErrNotTTY
	}
	if !term.IsTerminal(int(f.Fd())) {
		return nil, ErrNotTTY
	}

	cfg, err := opts.resolveStyle()
	if err != nil {
		return nil, err
	}

	W, _, err := term.GetSize(int(f.Fd()))
	if err != nil {
		W = 80
	}
	autoW := opts.Width == 0
	if !autoW {
		W = opts.Width
	}

	coalesce := opts.Coalesce
	if coalesce == 0 {
		coalesce = 16 * time.Millisecond
	}

	fr := newFragmentRenderer(cfg, W)

	r := &Renderer{
		f:        f,
		fr:       fr,
		tf:       newTailFinder(fr),
		width:    W,
		autoW:    autoW,
		coalesce: coalesce,
	}
	r.screen = NewScreen(W, f)

	r.tickCh = make(chan struct{}, 1)
	r.done = make(chan struct{})
	go r.tickLoop()
	return r, nil
}

// Write implements io.Writer: appends markdown bytes and schedules a tick. It
// never blocks: the tick runs on the background goroutine, coalesced to the
// Coalesce floor under sustained input.
func (r *Renderer) Write(p []byte) (int, error) {
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return 0, ErrClosed
	}
	r.buf = append(r.buf, p...)
	r.mu.Unlock()

	// Non-blocking signal to the tick goroutine.
	select {
	case r.tickCh <- struct{}{}:
	default:
	}
	return len(p), nil
}

// Flush runs a pending tick synchronously and returns after emission.
func (r *Renderer) Flush() error {
	if err := r.checkClosed(); err != nil {
		return err
	}
	r.tick()
	return nil
}

// Close emits the final tick plus the document-level suffix and releases state.
func (r *Renderer) Close() error {
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return nil
	}
	r.closed = true
	r.mu.Unlock()

	close(r.done) // stop the tick goroutine

	r.tick() // final tick
	r.mu.Lock()
	r.screen.Close()
	r.mu.Unlock()
	return nil
}

func (r *Renderer) checkClosed() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return ErrClosed
	}
	return nil
}

// tickLoop runs ticks on a background goroutine, coalescing them to the
// Coalesce floor under sustained input.
func (r *Renderer) tickLoop() {
	for {
		select {
		case <-r.done:
			return
		case <-r.tickCh:
			r.tick()
			// Coalesce: drain a pending signal, then wait the floor so a
			// flood of writes produces ~1/Coalesce ticks per second.
			select {
			case <-r.tickCh:
			default:
			}
			select {
			case <-r.done:
				return
			case <-time.After(r.coalesce):
			}
		}
	}
}

// tick runs one tick (re-poll the terminal size, re-render the tail, emit the
// diff) under r.mu.
func (r *Renderer) tick() {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.autoW {
		if W, _, err := term.GetSize(int(r.f.Fd())); err == nil {
			if W != r.width {
				r.reconfigure(W)
				r.width = W
				r.screen.Resize(W)
			}
		}
	}

	// UTF-8 tail safety: a trailing incomplete rune is not-yet-arrived; hold it
	// back from the parse so no rune is ever rendered half-formed.
	complete := trimIncompleteRune(r.buf)
	newCommitted, tail := r.tf.tick(complete)
	if len(newCommitted) > 0 {
		r.screen.CommitAndUpdate(newCommitted, tail)
	} else {
		r.screen.UpdateTail(tail)
	}
}

// trimIncompleteRune drops a trailing incomplete UTF-8 rune, if any, so the
// tail finder parses only complete runes.
func trimIncompleteRune(b []byte) []byte {
	if len(b) == 0 || b[len(b)-1] < utf8.RuneSelf {
		return b
	}
	start := len(b) - 1
	for start > 0 && b[start]&0xC0 == 0x80 {
		start--
	}
	if r, size := utf8.DecodeRune(b[start:]); r == utf8.RuneError && size == 1 {
		return b[:start]
	}
	return b
}

// reconfigure re-wraps the tail renderer for a new width (committed lines keep
// their old wrap; they are frozen on screen/scrollback — §3.5.6).
func (r *Renderer) reconfigure(W int) {
	r.fr = newFragmentRenderer(r.fr.style, W)
	r.tf.fr = r.fr
}
