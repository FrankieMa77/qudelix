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
- **Auto pre-gain** — works out how much the boosted bands need pulling back
  and offers the number, rather than moving it for you
- **Per-band mute** for an instant A/B of one band; the gain is kept
- **20 preset slots**, which you can name from the app — the name is stored on
  the 5K, so other software sees it too
- **Profiles** — pair an output device with a preset and be offered the switch
  when that output becomes active
- **Preset import** from a file, from the clipboard — paste the filter list
  as published sites print it — or from the
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
- **Stage** — a soundstage for headphones: width, crossfeed, dialogue lift and
  room, applied on the Mac (see below)
- **Level** — live output level, a 14-day listening history, and a signal path
  inspector showing what is altering the audio and what is passing it through
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
speaks to the 5K's control interface, so playback is unaffected. One feature
does alter the audio, and only while you switch it on: with the **Stage**
running, the Mac's audio is processed on its way to the output device (the
5K's own EQ still runs on the device, untouched). Two others listen to the
audio without altering it, and one of those is on by default — all three are
described under [The audio tap](#the-audio-tap).

## Install

Download the `.dmg` from [Releases](../../releases), drag the app to
Applications, and launch it.

macOS will refuse to open it the first time — the app is signed only ad-hoc, not
with a paid Apple Developer ID. To allow it, open **System Settings → Privacy &
Security**, scroll to Security, and click **Open Anyway**. (The old
right-click → Open trick no longer works on current macOS.)

If you would rather not trust a binary, build it yourself — see below.

Requires macOS 14 or later. Universal binary, Apple Silicon and Intel.

### Verify your download

Because the app is signed ad-hoc, macOS cannot tell you who built it, and the
"Open Anyway" click above is pure trust. The checksum published with every
release is what narrows that gap. Before opening the DMG:

```
shasum -a 256 ~/Downloads/Qudelix-1.3.0.dmg
```

Compare the result against the SHA-256 in the [latest release
notes](../../releases/latest). Or, if you also downloaded the `.dmg.sha256`
file, let `shasum` do the comparison:

```
cd ~/Downloads && shasum -a 256 -c Qudelix-1.3.0.dmg.sha256
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
what you will enjoy. The **Tune** tab offers two ways to settle it by ear.

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
4. At the end, **Keep** the result or **Save to…** a preset slot. **Discard**
   restores exactly what you had.

Both options are always matched for loudness and never labelled, so you cannot
simply prefer the louder one — which is what happens in most casual A/B tests.
Some pairs are deliberately identical, as a check on how reliable the session was.

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

Unlike everything else in this app, the Stage runs on the Mac, not on the 5K:
it processes what the Mac plays on its way to the output device, using a
system audio tap (macOS 14.2 or later, and the System Audio Recording
permission). The 5K keeps doing its own EQ on-device, so nothing is applied
twice. Settings are kept per output device.

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

Levels are digital signal level (dBFS), not sound pressure: the app cannot
know your headphones' sensitivity or the 5K's analog volume, so it reports
trends and durations honestly instead of pretending to be a dosimeter. Nothing
is recorded and nothing leaves the Mac.

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
  account, and never transmitted. Six of them live in
  `~/Library/Application Support/QudelixBar/`:

  | File | What is in it |
  |---|---|
  | `stage.json` | Soundstage settings per output device, the 14-day listening totals, and the Level, quality and per-app EQ toggles |
  | `profiles.json` | Your output-device-to-preset pairings |
  | `last-eq.json` | The last EQ curve seen on the device, one per EQ group, what produced it, and which device it came from |
  | `presets.json` | The preset library kept on this Mac, the headphone name you typed, and which app is assigned which curve |
  | `ai-research.json` | What the AI preset studio has researched, keyed by headphone name — the description it got back, and the measurement it was anchored to. Up to 64 headphones, no key material, nothing about you |
  | `diag.txt` | The last 200 lines of an engine heartbeat, for bug reports. It records which phase the studio is in — `ai=idle`, `ai=researching`, `ai=designing` — and never what was asked or answered |

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
