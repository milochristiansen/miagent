// Turn-end audio alert.
//
// The desktop app has no audio dependency of its own: this file generates a
// short three-note arpeggio and hands it to ALSA through dlopen'd symbols.
// libasound is present on essentially every Linux desktop (directly, or
// through the PipeWire/PulseAudio ALSA plugins), but it is not a link-time
// requirement.
// When it cannot be loaded or no PCM can be opened, the alert falls back to
// the terminal bell, matching the CLI's turn-end BEL.
package main

import "core:dynlib"
import "core:fmt"
import "core:math"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

AUDIO_RATE :: 44100
AUDIO_LATENCY_US :: 100000
AUDIO_MIN_INTERVAL :: 150 * time.Millisecond
AUDIO_BELL_MIN_INTERVAL :: 120 * time.Millisecond
AUDIO_BELL_MS :: 70
AUDIO_BELL_HZ :: 920.0

// A quick rising A-major arpeggio: A5, C#6, E6. The last note is held a
// little longer so the alert resolves instead of stopping abruptly.
AUDIO_NOTE_HZ := [?]f32{880.0, 1108.73, 1318.51}
AUDIO_NOTE_MS := [?]int{55, 55, 90}
AUDIO_ATTACK_MS :: 4

// Peak amplitude of the arpeggio, as a fraction of full scale. The harmonic
// sum peaks at 1.2x the fundamental, so 0.6 leaves a little under 3 dB of
// headroom below clipping while making the alert clearly audible over
// music and video.
AUDIO_GAIN :: 0.60

// ALSA constants used by snd_pcm_set_params. They are stable ABI values from
// alsa/pcm.h; keeping the literals here avoids requiring ALSA headers at build
// time as well as the library at link time.
SND_PCM_STREAM_PLAYBACK :: i32(0)
SND_PCM_FORMAT_S16_LE :: i32(2)
SND_PCM_ACCESS_RW_INTERLEAVED :: i32(3)

Alsa_Pcm :: struct {}

// The field names are matched against exported ALSA symbols after stripping
// the "snd_" prefix by dynlib.initialize_symbols.
Alsa_Symbols :: struct {
	__handle:       dynlib.Library,
	pcm_open:       proc "c" (pcm: ^^Alsa_Pcm, name: cstring, stream: i32, mode: i32) -> i32,
	pcm_set_params: proc "c" (pcm: ^Alsa_Pcm, format: i32, access: i32, channels: u32, rate: u32, soft_resample: i32, latency: u32) -> i32,
	pcm_writei:     proc "c" (pcm: ^Alsa_Pcm, buffer: rawptr, size: uint) -> i64,
	pcm_drain:      proc "c" (pcm: ^Alsa_Pcm) -> i32,
	pcm_close:      proc "c" (pcm: ^Alsa_Pcm) -> i32,
	pcm_recover:    proc "c" (pcm: ^Alsa_Pcm, err: i32, silent: i32) -> i32,
}

Audio :: struct {
	ready:     bool,
	symbols:   Alsa_Symbols,
	mutex:     sync.Mutex,
	last_play: time.Tick,
	last_bell: time.Tick,
}

g_audio: Audio

// audio_alert_init loads the ALSA entry points once. Failure is not fatal:
// audio_alert_play then just rings the terminal bell.
audio_alert_init :: proc() {
	if g_audio.ready do return

	symbols: Alsa_Symbols
	_, ok := dynlib.initialize_symbols(&symbols, "libasound.so.2", "snd_")
	if !ok || symbols.pcm_open == nil || symbols.pcm_set_params == nil ||
	   symbols.pcm_writei == nil || symbols.pcm_drain == nil ||
	   symbols.pcm_close == nil || symbols.pcm_recover == nil {
		if symbols.__handle != nil do dynlib.unload_library(symbols.__handle)
		return
	}
	g_audio.symbols = symbols
	g_audio.ready = true
}

// audio_alert_play starts the alert on a worker thread: opening a PCM and
// waiting for the short buffer to drain can take tens of milliseconds, which
// must not stall the frame loop. Repeated turn ends in quick succession share
// one tone.
audio_alert_play :: proc() {
	if !g_audio.ready {
		audio_bell()
		return
	}

	sync.mutex_lock(&g_audio.mutex)
	now := time.tick_now()
	if g_audio.last_play._nsec != 0 && time.tick_since(g_audio.last_play) < AUDIO_MIN_INTERVAL {
		sync.mutex_unlock(&g_audio.mutex)
		return
	}
	g_audio.last_play = now
	sync.mutex_unlock(&g_audio.mutex)

	if thread.create_and_start(audio_alert_worker, priority = .Low, self_cleanup = true, name = "miagent-audio") == nil {
		// Thread creation is the only part that can fail synchronously; fall
		// back rather than dropping the alert silently.
		audio_bell()
	}
}

// audio_bell_play is the terminal BEL sound. It is deliberately distinct from
// the turn-end arpeggio and is rate-limited so `printf '\a\a\a'` cannot turn
// into a stream of PCM opens.
audio_bell_play :: proc() {
	if !g_audio.ready {
		audio_bell()
		return
	}

	sync.mutex_lock(&g_audio.mutex)
	now := time.tick_now()
	if g_audio.last_bell._nsec != 0 && time.tick_since(g_audio.last_bell) < AUDIO_BELL_MIN_INTERVAL {
		sync.mutex_unlock(&g_audio.mutex)
		return
	}
	g_audio.last_bell = now
	sync.mutex_unlock(&g_audio.mutex)

	if thread.create_and_start(audio_bell_worker, priority = .Low, self_cleanup = true, name = "miagent-bell") == nil {
		audio_bell()
	}
}

audio_bell_worker :: proc() {
	if !audio_play_bell_tone() do audio_bell()
}

audio_play_bell_tone :: proc() -> bool {
	s := g_audio.symbols
	pcm: ^Alsa_Pcm
	if s.pcm_open(&pcm, cstring("default"), SND_PCM_STREAM_PLAYBACK, 0) < 0 do return false
	defer _ = s.pcm_close(pcm)

	if s.pcm_set_params(pcm, SND_PCM_FORMAT_S16_LE, SND_PCM_ACCESS_RW_INTERLEAVED,
	                    1, AUDIO_RATE, 1, AUDIO_LATENCY_US) < 0 {
		return false
	}

	samples := audio_bell_samples()
	defer delete(samples)
	total := uint(len(samples))
	written: uint = 0
	for written < total {
		frames := s.pcm_writei(pcm, rawptr(&samples[written]), total - written)
		if frames < 0 {
			if s.pcm_recover(pcm, i32(frames), 1) < 0 do return false
			continue
		}
		if frames == 0 do return false
		written += uint(frames)
	}
	_ = s.pcm_drain(pcm)
	return true
}

audio_bell_samples :: proc() -> []i16 {
	n := AUDIO_RATE * AUDIO_BELL_MS / 1000
	buf := make([]i16, n)
	attack := max(AUDIO_RATE * 2 / 1000, 1)
	for i in 0 ..< n {
		t := f32(i) / f32(AUDIO_RATE)
		life := f32(i) / f32(n)
		env := min(f32(1.0), f32(i) / f32(attack)) * (1.0 - life) * (1.0 - life)
		wave := math.sin(2.0 * math.PI * AUDIO_BELL_HZ * t) +
		        0.12 * math.sin(4.0 * math.PI * AUDIO_BELL_HZ * t)
		buf[i] = i16(wave * env * AUDIO_GAIN * 32767.0)
	}
	return buf
}

audio_alert_worker :: proc() {
	playback_ok := audio_play_tone()
	if !playback_ok do audio_bell()
}

audio_play_tone :: proc() -> bool {
	s := g_audio.symbols
	pcm: ^Alsa_Pcm
	if s.pcm_open(&pcm, cstring("default"), SND_PCM_STREAM_PLAYBACK, 0) < 0 do return false
	defer _ = s.pcm_close(pcm)

	if s.pcm_set_params(pcm, SND_PCM_FORMAT_S16_LE, SND_PCM_ACCESS_RW_INTERLEAVED,
	                    1, AUDIO_RATE, 1, AUDIO_LATENCY_US) < 0 {
		return false
	}

	samples := audio_tone_samples()
	defer delete(samples)

	total := uint(len(samples))
	written: uint = 0
	for written < total {
		frames := s.pcm_writei(pcm, rawptr(&samples[written]), total - written)
		if frames < 0 {
			if s.pcm_recover(pcm, i32(frames), 1) < 0 do return false
			continue
		}
		if frames == 0 do return false
		written += uint(frames)
	}
	_ = s.pcm_drain(pcm)
	return true
}

// audio_tone_samples builds a mono 16-bit arpeggio. Each note has a fast
// attack and a quadratic decay to zero, so consecutive notes join without
// clicks. Two low harmonics give the sine a soft bell-like edge while keeping
// the sound short and unobtrusive.
audio_tone_samples :: proc() -> []i16 {
	total := 0
	for ms in AUDIO_NOTE_MS do total += AUDIO_RATE * ms / 1000

	buf := make([]i16, total)
	attack := AUDIO_RATE * AUDIO_ATTACK_MS / 1000
	offset := 0
	for hz, note in AUDIO_NOTE_HZ {
		n := AUDIO_RATE * AUDIO_NOTE_MS[note] / 1000
		for i in 0 ..< n {
			t := f32(i) / f32(AUDIO_RATE)
			life := f32(i) / f32(n)
			env := min(f32(1.0), f32(i) / f32(attack)) * (1.0 - life) * (1.0 - life)
			wave := math.sin(2.0 * math.PI * hz * t) +
			        0.15 * math.sin(4.0 * math.PI * hz * t) +
			        0.05 * math.sin(6.0 * math.PI * hz * t)
			buf[offset + i] = i16(wave * env * AUDIO_GAIN * 32767.0)
		}
		offset += n
	}
	return buf
}

// audio_bell is the last-resort alert. Writing to /dev/tty reaches the user's
// terminal even when stdout/stderr were redirected; without a controlling
// terminal, BEL on stderr is harmless.
audio_bell :: proc() {
	if tty, err := os.open("/dev/tty", {.Write}); err == nil {
		_, _ = os.write_string(tty, "\a")
		_ = os.close(tty)
		return
	}
	fmt.eprint("\a")
}
