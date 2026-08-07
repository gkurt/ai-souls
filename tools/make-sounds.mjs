// Synthesizes the bundled sound bank from scratch — no samples, no
// third-party audio, nothing lifted from any game. Every voice here is
// a few oscillators and an envelope, which is also why the whole bank
// weighs less than a screenshot.
//
//   node tools/make-sounds.mjs          # writes assets/sounds/*.mp3
//   node tools/make-sounds.mjs --wav    # keep the intermediate WAVs too
//
// Requires ffmpeg on PATH for the mp3 encode. mp3 is the one format all
// three platform audio backends decode (Media Foundation on Windows,
// AVFoundation on macOS, GStreamer on Linux).

import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const RATE = 44100;
const here = dirname(fileURLToPath(import.meta.url));
const outDir = resolve(here, "..", "assets", "sounds");
const keepWav = process.argv.includes("--wav");

// ---------------------------------------------------------- primitives

const clamp = (x, lo, hi) => Math.max(lo, Math.min(hi, x));
const TAU = Math.PI * 2;

/** Exponential decay, 1 at t=0, `-60dB` at t=tau*~7. */
const decay = (t, tau) => Math.exp(-t / tau);

/** Attack/decay envelope with a smooth (not clicky) onset. */
function ad(t, attack, tau) {
  if (t < attack) {
    const x = t / attack;
    return x * x * (3 - 2 * x);
  }
  return decay(t - attack, tau);
}

/** A struck-bell voice: inharmonic partials, higher ones dying first. */
function bell(t, base, partials) {
  let sum = 0;
  for (const [ratio, gain, tau] of partials) {
    sum += gain * Math.sin(TAU * base * ratio * t) * decay(t, tau);
  }
  return sum;
}

/** Deterministic value noise, so two runs produce byte-identical files. */
function makeNoise(seed) {
  let state = seed >>> 0;
  return () => {
    state = (state * 1664525 + 1013904223) >>> 0;
    return (state / 0xffffffff) * 2 - 1;
  };
}

/** One-pole low-pass, for turning white noise into air. */
function makeLowpass(cutoff) {
  const a = 1 - Math.exp((-TAU * cutoff) / RATE);
  let z = 0;
  return (x) => {
    z += a * (x - z);
    return z;
  };
}

// -------------------------------------------------------------- voices

const voices = {
  // The death knell: a very low bell with a long inharmonic tail and a
  // second strike an octave up, slightly late, so it blooms.
  gong(t) {
    const first = bell(t, 58, [
      [1.0, 1.0, 1.9],
      [2.02, 0.5, 1.3],
      [2.76, 0.34, 0.9],
      [4.07, 0.2, 0.55],
      [5.4, 0.12, 0.34],
      [8.93, 0.06, 0.18],
    ]);
    const late = t < 0.09 ? 0 : 0.45 * bell(t - 0.09, 116, [
      [1.0, 0.7, 1.1],
      [2.71, 0.22, 0.4],
      [5.18, 0.1, 0.2],
    ]);
    // A breath of low noise under the strike gives it a room.
    const air = 0.09 * gongNoise() * decay(t, 0.5);
    return (first + late + air) * Math.min(1, t / 0.004);
  },

  // Victory: a slow choral swell on a minor triad plus its fifth above,
  // with a little detune between voices so it shimmers rather than
  // beating flat.
  choir(t) {
    const notes = [174.61, 207.65, 261.63, 349.23]; // F3 Ab3 C4 F4
    let sum = 0;
    for (let i = 0; i < notes.length; i += 1) {
      const f = notes[i];
      const vibrato = 1 + 0.0035 * Math.sin(TAU * (4.6 + i * 0.4) * t);
      const detune = 1 + (i % 2 === 0 ? 0.0016 : -0.0016);
      const gain = 0.34 / (1 + i * 0.35);
      // Two partials per voice: a body and a soft second harmonic.
      sum += gain * Math.sin(TAU * f * detune * vibrato * t);
      sum += gain * 0.3 * Math.sin(TAU * 2 * f * detune * t);
    }
    return sum * ad(t, 0.85, 1.35);
  },

  // A question wants attention, not drama: two clear bell tones a fifth
  // apart, the second a beat behind.
  chime(t) {
    const one = bell(t, 880, [
      [1.0, 0.8, 0.42],
      [2.76, 0.22, 0.16],
      [5.4, 0.08, 0.07],
    ]);
    const two = t < 0.13 ? 0 : bell(t - 0.13, 1318.5, [
      [1.0, 0.6, 0.38],
      [2.76, 0.16, 0.14],
    ]);
    return (one + two) * 0.8;
  },

  // A bonfire catching: filtered noise rushing up and settling, over a
  // warm low tone.
  ember(t) {
    // The rush starts bright and closes down as the flame settles.
    const cutoff = 400 + 2600 * Math.exp(-t / 0.28);
    const rush = emberFilter(emberNoise(), cutoff) * ad(t, 0.05, 0.42) * 0.5;
    const warm = 0.4 * Math.sin(TAU * 96 * t) * ad(t, 0.09, 0.6);
    const body = 0.18 * Math.sin(TAU * 192 * t) * ad(t, 0.12, 0.4);
    return rush + warm + body;
  },

  // Refusal: a short pitch-dropping thump with a click on the front.
  thud(t) {
    // Integral of the 108→38 Hz exponential glide, so the phase stays
    // continuous instead of stepping with the frequency.
    const phase = TAU * (38 * t + 108 * 0.16 * (1 - Math.exp(-t / 0.16)));
    const body = Math.sin(phase) * ad(t, 0.004, 0.22);
    const click = 0.25 * thudNoise() * decay(t, 0.012);
    return body * 0.9 + click;
  },
};

// Per-voice noise sources and filters, created fresh for each render so
// output stays deterministic.
let gongNoise, emberNoise, emberFilter, thudNoise;

function resetVoiceState() {
  const g = makeNoise(0x5eed01);
  const gLow = makeLowpass(180);
  gongNoise = () => gLow(g());

  const e = makeNoise(0x5eed02);
  emberNoise = e;
  const filters = new Map();
  emberFilter = (x, cutoff) => {
    // Quantize the cutoff so we reuse a small set of filter states
    // instead of rebuilding one per sample.
    const bucket = Math.round(cutoff / 50) * 50;
    let f = filters.get(bucket);
    if (!f) {
      f = makeLowpass(bucket);
      filters.set(bucket, f);
    }
    return f(x);
  };

  const th = makeNoise(0x5eed03);
  const thLow = makeLowpass(2600);
  thudNoise = () => thLow(th());
}

// --------------------------------------------------------------- render

const lengths = { gong: 3.6, choir: 3.2, chime: 1.6, ember: 1.9, thud: 0.9 };

/** Render a voice to normalized mono float samples with a fade-out tail. */
function render(name) {
  resetVoiceState();
  const seconds = lengths[name];
  const count = Math.round(seconds * RATE);
  const voice = voices[name];
  const out = new Float64Array(count);

  let peak = 0;
  for (let i = 0; i < count; i += 1) {
    const t = i / RATE;
    const value = voice(t);
    out[i] = value;
    const magnitude = Math.abs(value);
    if (magnitude > peak) peak = magnitude;
  }

  // Normalize to -1.5 dBFS, then fade the last 60 ms so no file ends on
  // a discontinuity (mp3 encoders turn those into an audible tick).
  const gain = peak > 0 ? 0.84 / peak : 0;
  const fade = Math.round(0.06 * RATE);
  for (let i = 0; i < count; i += 1) {
    let value = out[i] * gain;
    const remaining = count - i;
    if (remaining < fade) value *= remaining / fade;
    out[i] = clamp(value, -1, 1);
  }
  return out;
}

function toWav(samples) {
  const bytes = samples.length * 2;
  const buffer = Buffer.alloc(44 + bytes);
  buffer.write("RIFF", 0, "ascii");
  buffer.writeUInt32LE(36 + bytes, 4);
  buffer.write("WAVE", 8, "ascii");
  buffer.write("fmt ", 12, "ascii");
  buffer.writeUInt32LE(16, 16); // PCM chunk size
  buffer.writeUInt16LE(1, 20); // PCM
  buffer.writeUInt16LE(1, 22); // mono
  buffer.writeUInt32LE(RATE, 24);
  buffer.writeUInt32LE(RATE * 2, 28); // byte rate
  buffer.writeUInt16LE(2, 32); // block align
  buffer.writeUInt16LE(16, 34); // bits per sample
  buffer.write("data", 36, "ascii");
  buffer.writeUInt32LE(bytes, 40);
  for (let i = 0; i < samples.length; i += 1) {
    buffer.writeInt16LE(Math.round(samples[i] * 32767), 44 + i * 2);
  }
  return buffer;
}

mkdirSync(outDir, { recursive: true });

for (const name of Object.keys(voices)) {
  const wavPath = join(outDir, `${name}.wav`);
  const mp3Path = join(outDir, `${name}.mp3`);
  writeFileSync(wavPath, toWav(render(name)));
  execFileSync(
    "ffmpeg",
    ["-y", "-loglevel", "error", "-i", wavPath, "-codec:a", "libmp3lame", "-b:a", "128k", mp3Path],
    { stdio: "inherit" },
  );
  if (!keepWav) rmSync(wavPath);
  console.log(`wrote ${mp3Path}`);
}
