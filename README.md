# Ladder

A polyphonic Minimoog-inspired software synthesizer for macOS, built entirely on
Apple's built-in frameworks — no third-party dependencies.

![](docs/screenshot.png)

## Sound engine

- 16 voices, velocity-sensitive with an adjustable velocity curve, full sustain-pedal support
- 3 oscillators per voice (triangle / saw / square / 25% pulse, PolyBLEP anti-aliased),
  octave range 32'–2', detune, plus a noise source and per-oscillator analog drift
- Moog ladder lowpass filter (Huovilainen model, per-stage tanh, 2x oversampled)
  with resonance, key tracking, velocity-to-cutoff, and its own ADSR contour
- Dual ADSR envelopes (filter + amp)
- 2 LFOs (sine / tri / square / sample-and-hold) routable to pitch, filter, or amp,
  free-running or scaled by the mod wheel
- Master FX: 3-band Pultec-style EQ, cross-fed stereo delay with tape-style time
  smoothing, Freeverb reverb, soft-clip output stage

## Architecture

- **CoreAudio / AVAudioSourceNode** render callback at a 128-frame hardware buffer
  (~4 ms output latency)
- **CoreMIDI** input via the MIDI 2.0 UMP API (16-bit velocity where available, hot-plug)
- Real-time safe throughout: MIDI and parameter changes reach the audio thread
  through lock-free SPSC ring buffers and atomics — no locks or allocation in the
  render path
- **SwiftUI** front end with custom knob controls, a play-mode patch bank, and a
  live FFT waterfall (Accelerate/vDSP)
- Presets are plain JSON in `~/Library/Application Support/Ladder/Presets/`

## Building

Requires Xcode (full install, not just Command Line Tools).

```sh
swift run -c release          # run directly
Scripts/package.sh            # build dist/Ladder.app
```

Plug in a USB MIDI keyboard and play — sources are picked up automatically,
including hot-plug.
