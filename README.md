# Qudelix for macOS

A native macOS menu bar app for configuring the **Qudelix 5K** DAC/amp, over USB
or Bluetooth.

[![Download](https://img.shields.io/github/v/release/FrankieMa77/qudelix?label=download&style=flat-square)](https://github.com/FrankieMa77/qudelix/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/FrankieMa77/qudelix/total?style=flat-square)](https://github.com/FrankieMa77/qudelix/releases)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?style=flat-square&logo=apple)](https://github.com/FrankieMa77/qudelix/releases/latest)
[![Universal](https://img.shields.io/badge/binary-Apple%20Silicon%20%2B%20Intel-blue?style=flat-square)](https://github.com/FrankieMa77/qudelix/releases/latest)
[![MIT](https://img.shields.io/badge/licence-MIT-green?style=flat-square)](LICENSE)

Unofficial, and not affiliated with or endorsed by Qudelix, Inc.

Qudelix ship a browser-based configuration app. On macOS it is unreliable —
Chrome's WebHID goes through the same system call that, if a report is framed
even one byte wrong, makes the 5K stop responding and drop off the USB bus. This
app talks to the device directly through IOKit instead, and gets the framing
right.

---

## Screenshots

| Equalizer | Presets | Import |
|---|---|---|
| ![Equalizer](docs/screenshots/equalizer.png) | ![Presets](docs/screenshots/presets.png) | ![Import](docs/screenshots/import.png) |

| Tune | Stage | Level |
|---|---|---|
| ![Tune](docs/screenshots/tune.png) | ![Stage](docs/screenshots/stage.png) | ![Level](docs/screenshots/level.png) |

## Features

- **Live device status** — battery, charging, firmware, sample rate, input source
- **Battery in the menu bar** — a bolt while charging, the level once it runs
  low, and notifications at 20% and 10% (see below)
- **Volume** control with mute
- **Sample rate** — set the rate macOS runs the 5K at, change which rates the
  device offers, or let the app match the rate to what you're playing (see below)
- **10-band parametric EQ** editor: filter type, frequency, gain, Q, plus pre-gain
- **20-band mode** — switch between 10 and 20 bands from the EQ pane; the app
  also follows a switch made anywhere else
- **Live response curve** showing the combined filter shape, and — after an
  import the device could not take exactly — the requested shape behind it, so
  you can see where the two part company
- **Curve editing** — drag a band's dot to shape it, click one to open an
  inspector for its filter type, gain and Q under the graph, double-click to
  clear it; undo and redo throughout
- **Auto pre-gain** — works out how much the boosted bands need pulling back
  and offers the number, rather than moving it for you
- **Per-band mute** for an instant A/B of one band; the gain is kept
- **20 preset slots**, which you can name from the app — the name is stored on
  the 5K, so other software sees it too
- **Preset library** on the Mac, beside the twenty slots on the device — as
  many curves as you like, global or bound to one output, applied through the
  same gated path as an import
- **Headphones field** — name the pair on the end of the 5K, and when the
  AutoEq project has measured that model a fitted correction is offered once
- **Per-app EQ** — give a single app a curve of its own from the library,
  applied on the Mac before the audio reaches the 5K, so a podcast player can
  run a speech-shaped preset while music keeps the device's curve (see below)
- **Profiles** — pair an output device with a preset and be offered the switch
  when that output becomes active
- **Preset import** from a file, from the clipboard — paste the filter list
  as published sites print it — from a file dropped onto the menu bar icon,
  or from the
  [AutoEq](https://github.com/jaakkopasanen/AutoEq) database (6,000+ headphones),
  fitted live to a target curve of your choosing with bass and tilt adjustment
- **AI preset studio** — design a preset for the headphones you named, with an
  AI provider of your choosing on your own API key. It researches the model
  once and caches what it learned, then designs one of fifteen kinds of preset
  and shows it as a draft you can audition on the 5K, keep in the library, or
  write into a device slot. Folded away by default and silent until you press
  **Generate**; the key lives in the Keychain and nowhere else. **Correction**
  needs no provider at all when the AutoEq project has measured your model.
  See [Privacy](#privacy) for exactly what is contacted and what is sent
- **Device settings** — channel trim, volume limit and the DAC reconstruction
  filter, all stored on the 5K itself
- **Export** your EQ in the standard parametric format
- **Update check** in the About panel — on request only, never in the background
- **Tune** — find the EQ you actually prefer, by ear (see below)
- **Stage** — a soundstage for headphones: width, crossfeed by band, balance,
  dialogue lift and room, with a true-peak limiter, loudness compensation,
  dynamic bass and convolution with an impulse response of your own, all
  applied on the Mac (see below)
- **Level** — live output level, an estimate of the level at the ear, a 14-day
  listening history, and a signal path inspector showing what is altering the
  audio and what is passing it through
- **Call and microphone awareness** — the Mac-side engine steps aside while
  the headset is on a call, and a guard tells you when an app grabs the
  headset's microphone and drops the Bluetooth link to the voice codec, or
  puts the default input back for you
- **Stream quality detection** — measures whether what's playing looks lossy
  or lossless (any player: it doesn't ask apps, it analyzes the audio), and
  can auto-match the USB rate: lossless → 44.1 kHz bit-perfect, lossy → your
  chosen rate. It is on by default, and listening is how it works: see
  [The audio tap](#the-audio-tap). Both parts can be switched off. When it has
  measured a cutoff,
  an import can also be told to stop correcting there, rather than spending
  filters and headroom on frequencies the source has already discarded
- **Diagnostics panel** logging every packet exchanged with the device

Works over **USB or Bluetooth**. USB is used whenever the 5K is plugged in;
otherwise the app controls the device over Bluetooth LE. Either way it only
speaks to the 5K's control interface, so playback is unaffected. Two features
do alter the audio, and only while you switch them on: with the **Stage**
running, or an app assigned under **Per-app EQ**, the Mac's audio is processed
on its way to the output device (the 5K's own EQ still runs on the device,
untouched). Two others listen to the audio without altering it, and one of
those is on by default — all four are described under
[The audio tap](#the-audio-tap).

## Install

Download the `.dmg` from [Releases](../../releases), drag the app to
Applications, and launch it.

macOS will refuse to open it the first time — the app is signed only ad-hoc, not
with a paid Apple Developer ID. To allow it, open **System Settings → Privacy &
Security**, scroll to Security, and click **Open Anyway**. (The old
right-click → Open trick no longer works on current macOS.)

If you would rather not trust a binary, build it yourself — see below.

Requires macOS 14 or later. Universal binary, Apple Silicon and Intel.

### Linux

A command-line version for Ubuntu 22.04 and later, `qudelix`, controls the
5K over USB (and, best-effort, Bluetooth LE) without the graphical app. It
ships as a `.deb` built from this repository; install and usage notes are in
[linux/README.md](linux/README.md).

### Verify your download

Because the app is signed ad-hoc, macOS cannot tell you who built it, and the
"Open Anyway" click above is pure trust. The checksum published with every
release is what narrows that gap. Before opening the DMG:

```
shasum -a 256 ~/Downloads/Qudelix-1.4.0.dmg
```

Compare the result against the SHA-256 in the [latest release
notes](../../releases/latest). Or, if you also downloaded the `.dmg.sha256`
file, let `shasum` do the comparison:

```
cd ~/Downloads && shasum -a 256 -c Qudelix-1.4.0.dmg.sha256
```

That should print `OK`. If the hashes differ, or the check fails, do not open
the file.

Be clear about what this does and does not buy you: it catches a corrupted
download or an asset replaced after publication, and it lets you confirm two
people downloaded the same bytes. It is not a substitute for notarization, and
it assumes the release page you read the hash from is itself genuine. Building
from source sidesteps all of it.

## Supported devices

The original **Qudelix 5K** on firmware 3.x, in either 10-band or 20-band EQ
mode.

The app identifies the device during its connection handshake, and if it finds
something it does not implement it says so and writes nothing, rather than
silently doing the wrong thing:

| Case | Why |
|---|---|
| 5K Plus, T71, Aura Vita | different EQ command set |
| Firmware 2.x | Qudelix changed the command format in firmware 3 |
| Firmware 1.x | too old; the official app refuses these too |

## Tune

EQ is personal, and reading a frequency-response graph tells you very little about
what you will enjoy. The **Tune** tab offers four ways to settle it by ear. Every
pair you hear is matched for loudness on its magnitude response across the
range where music lives, so the louder option never wins by being louder.

![Tune](docs/screenshots/tune.png)

### Compare

Blind A/B. Play music you know well, and the app presents two EQ settings; you
pick whichever sounds better. It narrows down from there, over roughly twenty
comparisons, and ends with a curve you can keep or save to a preset.

1. Start playing music at a comfortable volume, and leave the volume alone.
2. Open **Tune → Compare → Start**.
3. Use **Switch** to flip between A and B as often as you like, then **Prefer A**
   or **Prefer B**. If they genuinely sound the same, say so — that answer is
   used, not discarded.
4. At the end, **Keep** the result or **Save to slot…**. **Discard**
   restores exactly what you had.

Both options are always matched for loudness and never labelled, so you cannot
simply prefer the louder one — which is what happens in most casual A/B tests.
Some pairs are deliberately identical, as a check on how reliable the session was.
If you named a winner on most of those, the session says so and refuses to
write a result.

### Shape

A shorter route to a curve: bass, then presence, then overall tilt, one axis at
a time, three rounds each, halving the step. Three controls settle in twelve
comparisons where the full Compare takes about twenty, and you are never asked
about tilt while the bass is still moving underneath it.

Each axis is fitted to your live band centres, so what you hear during the
session is exactly the curve **Keep** will write — not an approximation of it.
When the pre-gain headroom cannot carry the full ranges with matched levels,
the ranges shrink until it can, and the intro says what fraction is being
explored. Three axes landing within what anyone can reliably hear is reported
as a real answer: leave it alone.

### Blind check

Does the EQ you already have survive not knowing which side is which? Five
trials, sides randomised, your curve against a flat one — a flat *curve*,
never the enable switch, because switching the EQ off takes the pre-gain with
it and turns the whole thing into a test of which side is louder. Four of five
is the line for saying which way you leant; anything less is reported as the
difference not surviving blinding, with all three counts shown. It writes
nothing whatever the answer.

### Tones

Plays faint tones at ten frequencies and finds the quietest level you can hear at
each, then compares that with typical hearing.

1. Set a comfortable volume, and sit somewhere quiet.
2. Open **Tune → Tones → Start**.
3. Press **I hear it** (or the space bar) the moment you hear anything, however
   faint. Roughly one presentation in five is silent on purpose.
4. If the result shows a real difference across the range, **Apply** writes a
   correction. If it does not, the app says so and leaves your EQ alone.

Tones stay quiet throughout, and the EQ is switched off while measuring so the
measurement is of you and your headphones rather than of your EQ settings.

Two honest caveats. Without laboratory calibration this measures your ears and
your headphones together, so it is specific to that pairing and is **not** a
hearing test in any medical sense — if you are worried about your hearing, see an
audiologist. And for most people with ordinary hearing the answer is "nothing to
correct", which the app will tell you plainly rather than inventing a curve.

## Sample rate

macOS runs a USB DAC at **one fixed rate** and resamples everything else to it.
Unlike iOS it never switches that rate to match what you're playing, so a 5K
parked at 96 kHz plays every 44.1 kHz album through a resampler. The row under
the volume slider fixes that without a trip to Audio MIDI Setup.

![Sample rate row](docs/screenshots/equalizer.png)

**Pick a rate.** 44.1 / 48 / 88.2 / 96 kHz, applied instantly. Match it to what
you listen to — most music is 44.1 kHz, most video 48 kHz — and the system stops
resampling.

**Change what the 5K offers.** The device decides which rates it advertises to
the Mac, and it can be pinned to a single one; if yours is, macOS has nothing
else to offer and the picker will show only that rate. The label at the end of
the row says which rates the device is currently offering and changes it. The
5K restarts its USB connection to re-enumerate, so audio drops for a second or
two and the app reconnects on its own.

**Or let it follow the music.** With **Auto rate** ticked, the app measures
what's playing and matches the rate to it: lossless → 44.1 kHz, lossy → the rate
you last chose yourself, content that genuinely extends beyond the 44.1 family →
96 kHz. It only acts on a verdict that has held for ten seconds, leaves at least
45 seconds between changes, and never switches while the Soundstage is on
(that path resamples anyway). The row narrates every state in plain words —
"listening to what's playing…", "lossless — set 44.1 kHz automatically",
"lossy — keeping your rate" — so nothing happens silently. Untick it and the
rate stays exactly where you put it.

How the detection decides is described under [Level](#level); the short version
is that it measures the audio rather than asking the player, so it works with
Spotify, Apple Music, a local file or a browser tab alike.

## Battery

The 5K reports its charge over both USB and Bluetooth, and the app surfaces it
in three places so you don't have to open anything to know.

**In the menu bar.** A bolt appears next to the icon while charging. Once the
charge drops to 20% the icon is joined by the level itself, so a glance at the
corner of the screen is enough. Hovering shows charge, the active preset and
which link is carrying the connection.

**In the popover.** The header pill shows the percentage, orange at 20% and red
at 10%, with the state spelled out in the line underneath.

**As notifications.** Standard macOS notifications at 20% and 10%, and one when
charging starts. Each fires once per episode — they won't nag if the reading
hovers around a threshold, and they survive a brief Bluetooth dropout without
re-announcing the same low battery. macOS asks for notification permission the
first time one actually fires, not at launch.

## Stage

Headphones put the band inside your head. The **Stage** tab spreads it back
out: mid/side width with a brilliance shelf on the sides, an interaural
crossfeed (each ear hears a delayed, darkened copy of the other channel — the
cue that moves sound out of the skull), a mid-only dialogue lift, and sparse
early reflections with a short diffuse tail. Presets for **Music**, **Movie**
and **Theater**, plus geometry controls — Distance, Span, Center, Size — and a
**Night** mode that evens out movie dynamics without touching dialogue.

![Stage](docs/screenshots/stage.png)

Crossfeed can be trimmed by band — below 800 Hz, where it anchors the image;
between 800 Hz and 4 kHz; and above 4 kHz, where it mostly dulls the treble —
and a **Balance** pair corrects a headphone whose two sides have drifted, in
level and in time. Four further stages sit behind the geometry, each off by
default and each explained on the pane:

- **Loudness** — an equal-loudness contour, sized from how far the estimated
  level at the ear sits below a reference, so quiet listening keeps its bass.
  It follows a thirty-second average of the listening level rather than this
  second's chorus.
- **Dynamic bass** — the 5K applies its curve after the Mac, so a bass boost
  is a promise the driver has to keep. This stage measures what the device's
  own curve will do to the low band and eases the loudest passages before
  they reach it; quiet passages keep the whole boost.
- **Impulse response** — run a WAV, AIFF or CAF impulse response of your own
  over the output, with a Mix slider: a headphone correction, a measured room,
  a reverb. Up to two seconds long, with no added latency at any length; a
  response the output's buffer size cannot afford is refused with the two
  ways out named.
- **True-peak limiter** — the stage ends by holding the output under
  −1 dBTP, estimating the peaks between samples that a DAC or a lossy encoder
  redraws. The soft clipper shapes; the limiter guarantees.

The order is fixed: room, crossfeed and balance; convolution; loudness
shelves; dynamic bass; soft clipper; true-peak limiter. The Level pane shows
what the last three are doing each second.

Unlike everything else in this app, the Stage runs on the Mac, not on the 5K:
it processes what the Mac plays on its way to the output device, using a
system audio tap (macOS 14.2 or later, and the System Audio Recording
permission). The 5K keeps doing its own EQ on-device, so nothing is applied
twice. Settings are kept per output device.

When the 5K is on a call over Bluetooth, or a call app is holding the headset
microphone, the engine steps out of the audio path and comes back when the
call ends, rather than fighting the link while it renegotiates. Separately, a
**microphone guard** watches for anything making the headset's microphone the
Mac's default input — which is what drops the link to the 16 kHz voice codec
and makes everything sound thin. It can stay off, ask with a banner, or put
the default input back on the built-in microphone for you; two reverts of the
same device in two minutes and it stops fighting you.

Switching the Stage off takes the processing back out of the audio path
immediately. It does not necessarily close the tap, because two other features
share it — see [The audio tap](#the-audio-tap).

Honesty notes, because this feature category is full of overpromising: it
works on the stereo mix — it widens and rooms what is already there. Surround
content stays downmixed, nothing tracks your head, and mono content (most
YouTube speech) gives Width and Crossfeed nothing to work with — the pane
tells you when that is what's playing rather than letting you hunt for a
difference that cannot exist.

## Level

Live output level, time listened, and how much of it was loud — today and for
the previous week, kept 14 days. Useful for the "why are my ears tired"
conversation with yourself. Metering rides the Stage engine when it runs, or a
listen-only tap (nothing inserted into the audio path) when you switch **Track
listening levels** on by itself.

The meter itself is digital signal level (dBFS). Beside it sits one number
about the world rather than the signal: an **estimate of the level at the
ear**, built from a K-weighted measurement of what is playing, the
attenuation the 5K itself reports (or the output device's volume when the 5K
is not the anchor), and a population figure for the headphone that a
per-output calibration slider lets you shift. Two of the three are measured
and the third is an assumption, which is why the pane never prints the number
without the word "estimate", never prints a decimal, and says what it rests
on. Nothing is recorded and nothing leaves the Mac.

### Is this actually lossless?

The same pane can tell you whether what's playing came from a lossy or a
lossless source. It doesn't ask the player — no music app exposes that to other
apps — it measures the audio, which is why it works the same for Spotify, Apple
Music, a local file or a browser tab.

Lossy encoders discard the top of the spectrum, and where they stop is
characteristic: around 16 kHz at low bitrates, around 20 kHz at 320 kbps, while
lossless material carries energy to the edge of its sample rate. The verdict
appears in plain words with the frequency it measured, and it feeds the
automatic rate matching described under [Sample rate](#sample-rate).

It is evidence, not proof, and the wording says which:

- A lossless file made **from** a lossy source keeps the original's cutoff and
  is reported as lossy. That is the correct answer about the audio, even though
  the file is technically lossless.
- Warm or old masters roll off on their own before any codec would cut them.
  The app reports "rolls off naturally — can't judge" rather than accusing them,
  and casts no vote on the rate.
- Quiet or dark passages carry no treble to judge at all, and say so.

**Detect stream quality** is on by default, and it is one of the three
switches that keep a system audio tap open. Untick it and the detector stops;
what that leaves running is set out below.

## Per-app EQ

The 5K applies one curve to everything it is sent. Under **Presets → Per-app
EQ** you can give a single app a second curve of its own, applied on the Mac
before the audio ever reaches the device — so a podcast player can run a
speech-shaped preset while music keeps the curve on the 5K, with no switching
by hand.

The section lists whatever is playing right now, plus anything you have already
assigned. Pick a preset from your library for a row, or leave it on **Default**,
which means no Mac-side curve at all. Up to eight apps can be assigned at once.
Any library preset can be used here, whichever of the device's two EQ banks it
was saved for: this chain runs on the Mac and has its own band count, so it is
never stretched to fit.

Two things follow from where it runs. It stacks: an app's curve is applied
first, and the 5K's own EQ still runs afterwards on the result. And it has to
be heard to work, so switching it on with an app assigned inserts the engine
into the audio path (the same path the Stage uses) even with the Stage itself
off. Switch it off, or leave nothing assigned, and the engine goes back to
whatever the other switches asked for.

## The audio tap

Four things in this app work on the Mac's own audio rather than on the 5K:
the Stage, per-app EQ, the listening-level meter, and stream-quality detection.
All of them are fed by one mechanism — a macOS process tap, created **global**,
which captures the output of every process on the machine except this app
(excluded so it cannot hear itself). It needs macOS 14.2 or later, and macOS
asks once for the System Audio Recording permission.

With apps assigned there is one further tap per assigned app, covering just
that app's processes, and the global one then excludes them so nothing is heard
twice. A per-app tap that cannot be created is skipped rather than fatal: its
app simply keeps playing through the global tap with no curve of its own.

**Stream-quality detection is on by default, so the tap is created at launch**
unless you turn it off. That is also when the permission is asked for — at
first launch, rather than the first time you open the Stage. The audio is
analysed a block at a time in memory and written nowhere; what survives a
block is a verdict and a cutoff frequency.

Four switches decide whether a tap exists at all:

| Switch | Where | Default | Effect |
|---|---|---|---|
| **Stage** | Stage tab | off | processes the audio on its way out |
| **Per-app EQ** | Presets tab | **on**, idle until an app is assigned | processes the audio on its way out |
| **Track listening levels** | Level tab | off | listens only |
| **Detect stream quality** | Level tab | **on** | listens only |

With all four off, the whole engine is torn down, taps included, and the app
goes back to being a pure remote control for the 5K.

## Build from source

```sh
git clone https://github.com/FrankieMa77/qudelix.git
cd qudelix/QudelixBar
./build-app.sh              # current architecture, fast
./build-app.sh --universal  # arm64 + x86_64
./make-dmg.sh               # universal build, packaged as a DMG
```

Swift 5.9+ and the Xcode command line tools are all that is required; there are
no third-party dependencies.

## Privacy

- Three hosts are contacted, each only when you ask. `raw.githubusercontent.com`
  and `autoeq.app` are reached when you open the Import pane, to fetch the
  headphone list and the correction you pick. `api.github.com` is reached only
  when you press **Check** in the About panel, to read the latest release
  number. Nothing is contacted at launch, and there is no background or
  scheduled check — the update check runs once, when you press it, and
  downloads nothing.
- **The AI preset studio adds a fourth destination, and only if you use it.**
  It contacts exactly one host, the provider you picked in its own menu: one of
  `api.mistral.ai`, `api.openai.com`, `api.anthropic.com` or `openrouter.ai`,
  and never any of the others. It is reached only while you are pressing
  **Generate** — choosing a provider, typing a model name, saving a key,
  picking a preset kind or writing a note sends nothing anywhere. Requests go
  over HTTPS to that one pinned host, refuse every redirect, and run one at a
  time with no retry.
- What leaves the machine on a Generate is: the headphone name you typed in the
  Library field, the preset kind you chose, the note you typed (capped at 200
  characters), and — when the AutoEq project has measured that headphone — the
  stored correction as a list of filter lines this app formats itself from the
  numbers it parsed. Nothing else. Not your EQ curve, not your presets, not
  your device, not your output names, and no identifier of any kind. It is your
  own account at that provider, on your own key, and their privacy policy is
  the one that then applies to the request.
- The API key lives only in the macOS Keychain, one item per provider under the
  service name `com.qudelixbar.app.ai`. It is never written to a state file, a
  log, an error message, or back into the pane — the studio asks the Keychain
  whether a key *exists* to enable its button, and only the request builder ever
  asks for the bytes, which go into one HTTP header and nowhere else. **Forget
  key** removes the item.
- No telemetry, analytics, or crash reporting, and nothing is ever uploaded.
- The Stage and Level features process audio in memory and write none of it
  anywhere, ever. What they open, when, and how to close it is set out under
  [The audio tap](#the-audio-tap).
- The microphone guard reads which device macOS has as its default input, and
  in **Fix automatically** mode sets that default to the built-in microphone —
  it never opens a microphone, records nothing, and does nothing else.
- Everything the app keeps is a local file, readable only by your user
  account, and never transmitted. They live in
  `~/Library/Application Support/QudelixBar/`:

  | File | What is in it |
  |---|---|
  | `stage.json` | Soundstage settings per output device, the 14-day listening totals, and the Level, quality and per-app EQ toggles |
  | `profiles.json` | Your output-device-to-preset pairings |
  | `last-eq.json` | The last EQ curve seen on the device, one per EQ group, what produced it, and which device it came from |
  | `presets.json` | The preset library kept on this Mac, the headphone name you typed, and which app is assigned which curve |
  | `ai-research.json` | What the AI preset studio has researched, keyed by headphone name — the description it got back, and the measurement it was anchored to. Up to 64 headphones, no key material, nothing about you |
  | `diag.txt` | The last 200 lines of an engine heartbeat, for bug reports. It records which phase the studio is in — `ai=idle`, `ai=researching`, `ai=designing` — and never what was asked or answered |
  | `impulses/` | The app's own copies of the impulse responses you picked for the Soundstage, named by a scrubbed base name and eight hex digits of the content hash. Copies no output's settings still reference are swept whenever a response is installed or removed |

  If one of the five JSON files ever fails to load, it is not overwritten:
  the app copies it aside as `<name>.recovered`, carries on with defaults, and
  leaves the copy for you.
- Outside that folder, `~/Library/Logs/QudelixBar.log` holds device packet
  traces, and rolls over to `QudelixBar.log.1` at 2 MB — so there are normally
  two of it. Since it records raw packet hex it includes the 5K's own Bluetooth
  address and any preset names stored on it. Separately, macOS keeps the app's
  preferences in `~/Library/Preferences/com.qudelixbar.app.plist`; the app puts
  two things there — which Bluetooth peripheral it has adopted, as the per-Mac
  identifier CoreBluetooth issues rather than the device's address, and the AI
  provider and model name chosen in the studio. Never a key.
- Several of those identify hardware, and are worth a glance before you attach
  one to a bug report. The packet log and `diag.txt` carry the names of your
  audio output devices. `stage.json` and `profiles.json` go further: they are
  keyed by CoreAudio device UIDs, and a UID is generally built from a Bluetooth
  device's MAC address or a USB DAC's serial number.
- Bluetooth scanning never records the names of nearby devices, only a count of
  how many were ignored. USB enumeration is narrower but not silent: the 5K's
  Bluetooth chip vendor is a common one, so the app can meet another device
  that shares the vendor ID and exposes a vendor-defined HID interface, and the
  log names that device in the line where it declines to talk to it.
- Only EQ, volume, and preset settings are written to the device — the same
  things the official app writes. Firmware is never touched.

## Developer tools

`Sources/qxusb` and `Sources/qxprobe` are diagnostic CLIs, not part of the app.
They can destabilise a device if misused — `qxusb --noid` deliberately
reproduces a USB bus-drop failure, and `qxprobe` sends Bluetooth GAIA commands.
Read the source before running them.

## Known limitations

- Only the user (headphone) EQ group is exposed, not the speaker group.
- Preset slots show generic names until you name them. Names are limited by
  bytes rather than characters, so a name in Japanese or emoji runs out of
  room sooner than its length suggests.
- Crossfeed is shown but cannot be changed here — it lives inside the preset
  the device stores, and writing it means rewriting that preset.
- A muted band comes back after an app restart as a bypassed band rather than
  a muted one. The gain is safe on the device and the row reads "Off"; the
  unmute button is what's missing.
- Profiles match the *output device*, not your headphones. Two pairs sharing
  one adapter look like the same output — and some cheap adapters report an
  identical identity to every other unit of their model.
- Only firmware 3.x is supported; see the table above for what happens on
  anything else.
- No auto-update mechanism. The About panel will tell you when a newer release
  exists, but downloading and installing it is manual.

## Changelog

### 1.4.0 — 2026-09-06

Equalizer

- **Band inspector.** Click a band's dot to select it; a panel under the graph
  carries its filter type, gain and a logarithmic Q slider. Double-click a
  band to clear it. A readout badge in the graph's corner follows the drag,
  then the pointer, then the selection.
- **Flatten and Reset are two buttons.** Flatten zeroes the gains and leaves
  every centre, filter type and Q alone; Reset restores the factory layout
  for the current mode. Each is one undo step.
- **Update** writes the curve back into the slot it was loaded from, without a
  trip through the Save menu.
- The curve and its markers dim when the equalizer is switched off, as the
  band table already did.
- The gain controls stay on an empty or muted band row.

Presets and corrections

- **A preset library on the Mac**, beside the twenty slots on the device,
  holding as many curves as you care to make. A preset is global or bound to
  one output device, records which EQ bank it was made for, and applies
  through the same gated, clamped, single-undo path as an import. It lives in
  `presets.json`, read and written with the same care as the other state
  files.
- **Headphones field.** Name the pair on the end of the 5K. When the AutoEq
  project has measured that model, a fitted correction is offered once, as a
  banner and as a line under the field, with the alternative measurements in
  a menu. A name is looked up once, and only when it changes.
- **AI preset studio.** Design a preset for the named headphones with an AI
  provider of your choosing, on your own key: fifteen kinds, from Correction
  and the published targets to Clarity, Warmth and a V-shape. The draft can
  be auditioned on the 5K, kept in the library or written into a slot. Silent
  until you press **Generate**; the key lives in the Keychain and nowhere
  else; Correction needs no provider at all when a measurement exists. The
  [Privacy](#privacy) section lists exactly what leaves the machine.
- **Per-app EQ.** Give a single app a second curve of its own from the
  library, applied on the Mac before the audio reaches the 5K: a podcast
  player on a speech-shaped preset while music keeps the curve on the device,
  with no switching by hand. Up to eight apps, each on any library preset or
  Default. The section lists what is playing right now, and it inserts the
  Mac-side engine only while something is assigned.
- **Drop a preset file onto the menu bar icon** to import it.
- The Presets pane is one scrolling page. Device slots and the library are
  disclosures that remember whether you left them open, the slot list names
  the active slot in its header, and the pane stays reachable with the 5K
  away so the library, assignments and profiles can be tidied offline.
  Deleting a library preset and overwriting a named slot both ask first.
  One vocabulary throughout: a **slot** lives on the device, the **library**
  lives on the Mac; **Load** and **Apply** bring a curve live, **Save to
  slot…** and **Save to library…** put it away.
- The parser now reads files the way they are actually published:
  tab-separated, lower case, pass filters without a gain, shelves without a
  Q, a preamble without its colon. When a file carries more filters than the
  device has bands, the ones doing the most work are kept rather than the
  first twenty, and everything a file asked for and did not get is now said
  rather than dropped in silence.
- Fits are cached on the values the sliders actually take, so re-fitting a
  shape tried a moment ago costs nothing, and the cache keeps the whole
  result — the clipping warning and the predicted rating included.

Stage

- **Crossfeed by band.** Three trims scale the crossfeed amount below 800 Hz,
  between 800 Hz and 4 kHz, and above 4 kHz. Trims at 100% are a genuine
  no-op, sample for sample.
- **Balance.** Level, ±3 dB split between the sides so the loudness holds, and
  time, up to 0.5 ms, to correct a pair whose two sides have drifted. Applied
  last, just before the clipper.
- **True-peak limiter.** The stage now ends in a limiter that holds the output
  under −1 dBTP by estimating the peaks between samples. Off by default. It
  runs after the soft clipper, so the last thing to touch the audio is the
  one stage that can state a ceiling and keep it.
- **Loudness compensation.** An equal-loudness contour sized from how far the
  estimated level at the ear sits below a reference, so quiet listening keeps
  its bass. It follows a thirty-second average of the listening level, and
  glides to each new setting rather than stepping. Off by default.
- **Dynamic bass.** The 5K applies its curve after the Mac, so a bass boost is
  a promise the driver has to keep. This stage measures what the device's own
  curve will do to the low band and eases the loudest passages before they
  get there; quiet passages keep the whole boost. Off by default.
- **Impulse response.** Run a WAV, AIFF or CAF impulse response of your own
  over the Mac's output, with a Mix slider, per output device. Up to two
  seconds, with no added latency at any length; a response the output's
  buffer size cannot afford is refused with the two ways out named.
- The chain order is fixed: room, crossfeed and balance; convolution; loudness
  shelves; dynamic bass; soft clipper; true-peak limiter.
- **Call awareness.** When the 5K is on a call over Bluetooth, or a call app
  is holding the headset microphone, the Mac-side engine steps out of the way
  and comes back when the call ends. The automatic rate switcher never
  renegotiates under a call, and the stream verdict measured before the call
  is dropped rather than left voting.
- **Microphone guard.** When an app makes the headset's microphone the Mac's
  default input and the Bluetooth link collapses to the voice codec, the app
  says so, or puts the default input back on the built-in microphone for you.
  Off, Ask or Fix. Two reverts of the same device in two minutes and it backs
  off; a Mac with no built-in microphone degrades to asking.

Level

- **Estimated level at the ear.** One number about the world rather than the
  signal, built from the K-weighted loudness of what is playing, the
  attenuation the 5K itself reports, and a population figure for the
  headphone that a per-output calibration slider lets you shift. Always
  marked as an estimate, never printed with a decimal, and the pane says what
  it rests on.
- The live row shows what the limiter, the loudness shelf and the bass guard
  are doing this second, and the signal path names each stage only while it
  is actually in the audio path.

Tune

- **Shape.** Bass, then presence, then tilt, one axis at a time, three rounds
  each: twelve comparisons instead of twenty. What you hear is exactly the
  curve **Keep** writes. When the pre-gain headroom cannot carry the full
  ranges with matched levels, the ranges shrink until it can, and the intro
  says by how much.
- **Blind check.** Five trials of your curve against a flat one, sides
  randomised and levels matched. It writes nothing whatever the answer.
- **Proper level matching.** Pairs are matched on the mean magnitude response
  from 100 Hz to 8 kHz rather than on the mean of the band gains, so a bass
  shelf no longer reads as a large change and a treble tilt as a small one.
  The louder side is trimmed down to the quieter, so matching never makes a
  session louder than the pre-gain already judged safe.
- A by-ear session earns a verdict before anything acts on it. Too many
  presses on the silent checks, readings too far apart, or too few of them
  refuse the result and show the counts the refusal turned on, on the Tones
  side and the Compare side alike.
- A Compare session survives closing the popover.

The app

- **A new shell.** The app owns its status item and popover, so clicking the
  icon no longer leaves a view graph behind each time, and the per-second
  meter values republish only while the popover is on screen.
- **A drawn menu bar icon**: headphones in a circle, with EQ bypass, the
  Soundstage, the stream verdict, battery and a call composed as marks on it.
- **Install with a double-click.** The disk image carries an installer that
  copies the app, clears the download flag and launches it, so Gatekeeper
  asks once, for the installer, and never again for the app.
- The footer shows the version and the source revision it was built from.
- The release build refuses to package a binary that is not universal.

Fixes

- Dynamic bass measured the low band after the loudness shelf had already
  raised it, so with both on it undid part of the shelf on loud passages. It
  now measures before the shelf.
- Night mode resumed from an envelope minutes old when switched back on, so
  it could open several decibels too quiet or too loud. It now starts fresh on
  every engage.
- The first block after a rate change or an engine start could overrun the
  realtime deadline at small buffers because eight delay rings were zeroed
  element by element, twice. They are cleared in one block store, once.
- A library preset with one unreadable band was dropped whole and erased on
  the next save. One bad band now costs one band. A presets file that exists
  but cannot be read is left alone instead of being replaced by an empty
  library, and the AI research cache survives one malformed entry.
- Ending a by-ear session after switching the device between its 10- and
  20-band banks wrote the old bank's curve into the new one. The restore is
  refused across a bank switch.
- Writing an AI draft to a slot could store the previous curve under the new
  name, because the slot save overtook the coalesced band writes. Pending
  writes are flushed first.
- Undo now restores the equalizer's on/off switch as well as the curve.
- Bluetooth discovery no longer runs while the 5K is connected over USB.
- The heartbeat file is appended a line at a time instead of being rewritten
  every fifteen seconds, and it no longer records the name of an impulse
  response file.
- Nothing is contacted at launch: a saved headphone name is looked up only
  after the popover has been opened once.
- Dragging a band, hovering the curve, or a device poll that changed nothing
  no longer redraws the whole popover; the response curve is computed several
  times faster and the correction search runs on a keystroke rather than on
  every redraw.
- The audio tap consumed the wrong input buffer when the output device had
  inputs of its own, so a headset or dock microphone was mixed into what the
  Soundstage wrote back out and metered as the listening level. The tap's
  buffer is now taken from the end of the list.
- A tone test could renegotiate the USB rate under itself. Detection sits the
  session out while the pipeline is muted, and a frozen window is never
  re-judged as new evidence.
- Hi-res content was downsampled to 44.1 kHz on outputs that stop at 48 kHz.
  Auto-rate now takes the highest rate at or above 88.2 kHz the output
  offers, and holds where there is none.
- Outputs that appear a few seconds after login are enumerated again three
  seconds in, so their saved Soundstage settings no longer look lost.
- Preset and device names are no longer parsed as Markdown in the profile
  prompt, the microphone banner, or the footer.
- A pane that outgrows its region is clipped at its edge instead of drawing
  over the footer.
- Imported files go through the hardened reader: no symlink is followed, no
  FIFO can wedge the load, and a short read is a failed read rather than a
  truncated document parked as recovered.
- Two bands sitting on the same frequency can no longer be dragged through
  each other.
- The microphone guard's alerts, the battery alerts and every other
  notification share one delivery path with fixed identifiers, so a battery dipping in and out of
  "low" replaces its warning instead of stacking a column of them.

### 1.3.0 — 2026-09-05

Equalizer

- **Drag the curve to shape it.** Move a band's dot vertically for gain and
  horizontally for frequency; hold Option for Q and Shift for fine steps.
  Hovering shows which band a drag would take. Everything goes through the
  same gated, clamped path as the sliders.
- **Undo and redo** for EQ edits, with Cmd-Z and Cmd-Shift-Z and buttons beside
  Flatten. A drag or an import is one step, not a hundred.
- **Auto pre-gain.** The editor works out how much attenuation the summed curve
  needs to avoid clipping in the 5K's own DSP and offers the number. It never
  moves a value you set yourself.
- **Per-band mute** for an instant A/B of one band. The gain is kept and
  restored exactly, and a mute is never committed to the device's flash.
- **The requested curve, shown.** When an import asks for more than the device
  can hold, the requested shape is drawn as a dashed ghost behind the live
  curve with the gap shaded and the worst point labelled.
- Pre-gain is now written to both stored channels. Previously only the first
  was written, which could leave a left/right level imbalance invisible from
  the app.

Presets and corrections

- **Name preset slots** from the app. The name is stored on the 5K, so other
  software sees it. Saving an imported correction into a slot names the slot
  after it, unless the curve has since been edited.
- **Fit to a target of your choice** when importing from AutoEq, with bass and
  tilt adjustment on the same fit. Targets are grouped by form factor. The fit
  is asked to stay within the device's limits, so nothing is clamped on
  arrival; the published preset is still offered as-is.
- **Predicted preference rating** for over-ear and on-ear corrections, from the
  published AES model, scored on the error that survives the bands this device
  can actually run. In-ear gets no score: those coefficients could not be
  verified from a primary source.
- **Import from the clipboard.** Paste a filter list as published sites print
  it.
- **Bandwidth-aware fitting.** When stream-quality detection has measured where
  the source stops, an import can be told to stop correcting there.
- **Profiles.** Pair an output device with a preset and be offered the switch
  when that output becomes active. It always asks the first time; mark an
  output automatic once you trust it.
- The EQ snapshot used to repair a device is now kept per EQ group, tagged with
  the device it came from, and never restored onto a different device. A
  damaged snapshot is parked rather than overwritten.

The device itself

- **Device settings** drawer: channel trim, a volume ceiling, the DAC
  reconstruction filter, power and battery-care state. Crossfeed is shown but
  not settable.
- The parser now reads the codec, output jack, gain, mute, charger and
  low-battery fields it used to skip. The low-battery alert takes the device's
  own flag as a trigger, and the header can say "plugged in, not charging"
  when battery care is on rather than implying a fault.

Everything else

- **Signal path inspector** in the Level pane: five rows from source to output
  saying what alters the audio and what passes it through.
- **About panel** with the version and the exact source revision, and an
  update check that runs only when you press it.
- Accessibility names for every icon-only control.
- Copy and Reveal buttons on the diagnostics log.
- The README and privacy section now list every file the app writes and state
  that a system-wide audio tap is created at launch by default, with the three
  switches that govern it.

Fixes

- Bluetooth stopped retrying a switched-off device every 18 seconds for the
  whole session. It backs off to once a minute and logs it once.
- The by-ear tuner read headroom off the largest single band rather than the
  summed response, so it under-read on exactly the curves with the least
  headroom. Tune results derived on top of an import are worth re-running.
- The by-ear macros and the tone-test correction were applied by band index,
  so in 20-band mode they landed on the wrong frequencies. Both now map by
  frequency.
- A/B trials were being written to flash and pushed into undo one band at a
  time. A trial now reaches neither.
- Quitting with the 5K unplugged could save a flat curve as the last EQ and
  write it over the real one on the next connect. Snapshots now require a
  device that has been read.
- Device reports stopped arriving during any slider drag and landed in a burst
  afterwards, defeating the echo windows. The HID source now runs in common
  run-loop modes.
- Recording of the listening history now follows its switch alone. It used to
  accumulate whenever the engine ran for stream detection.
- Auto-rate refuses to renegotiate the 5K from audio that was going to a
  different output device.
- A tone test that measured nothing at a frequency says so instead of reporting
  typical hearing and writing a "+0 dB" correction through the gap.
- The Compare session's reliability check no longer flags a listener who
  correctly answered "same" on identical pairs.
- The Stage soft clipper is anti-aliased.
- Hardened runtime on the bundle. The audio-recording permission is asked once
  more on first launch of this version because the grant is keyed to the
  signature.
- Two audit rounds of crash, resource and input-validation fixes: NaN and
  non-finite sample rates, unbounded loops on hostile buffer descriptions,
  throttled logs, bounded caches, state files that refuse anything but a
  regular file.

### 1.2.0 — 2026-08-06

- Stage: a soundstage for headphones, applied on the Mac.
- Level: live output level and a 14-day listening history.
- Stream quality detection, with optional automatic sample-rate matching.
- USB sample rate control, including the rates the device offers the host.
- Battery indication in the menu bar, with low and charging alerts.
- Switch between 10-band and 20-band EQ from the app.
- EQ settings persist across device restarts.

### 1.1.0 — 2026-08-03

- Control over Bluetooth LE as well as USB.
- Tune tab: blind A/B comparison and tone thresholds, by ear.
- Fixed the EQ mode being misread on connect.

### 1.0.1 — 2026-08-02

- Hardened device, log and network handling; release checksums published.

### 1.0.0 — 2026-08-02

- First release: USB control, live status, volume, 10-band parametric EQ,
  20 preset slots, AutoEq import, diagnostics.

## Feedback and contributions

Bug reports, ideas, and pull requests are all welcome — open an
[issue](../../issues) or a PR.

Especially useful right now:

- **Firmware other than 3.1.8**, or any 5K that behaves oddly — the diagnostics
  panel and `~/Library/Logs/QudelixBar.log` capture everything needed.
- **Intel Macs.** The binary is universal but has only been run on Apple Silicon.

## Licence

[MIT](LICENSE). Use it, build it, fork it; no warranty is given.

## Credits

- [devicePEQ](https://github.com/jeromeof/devicePEQ) — prior open-source work on
  the Qudelix HID protocol
- [AutoEq](https://github.com/jaakkopasanen/AutoEq) by Jaakko Pasanen — the
  headphone correction database
