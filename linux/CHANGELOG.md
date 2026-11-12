# Qudelix for Linux: changelog

## Version numbers

Linux now has its own version line, starting at 0.7.0. It follows the Mac app's 1.6.3, so
nothing here is a downgrade: the Debian packages carry an epoch (`1:0.7.0`) and apt upgrades
an installed 1.6.x normally. AUR packagers need `epoch=1` in their PKGBUILDs.

Linux releases are tagged `linux-v<version>` and titled "Qudelix for Linux". Mac releases keep
the `v<version>` tags and the Mac changelog in the main README.

## 0.7.1

Bluetooth control works now. In 0.7.0 the 5K's control link never came up over Bluetooth.

- Qudelix opens the 5K's Bluetooth LE control link itself. It works with any BlueZ version,
  including the one in Ubuntu, and needs no experimental BlueZ settings.
- The 5K accepts a new control link only for a few seconds after it is switched on, and again
  shortly after a previous control link ends. Qudelix waits for that in the background and
  connects within about a second. If the 5K is already on and nothing connects, switch it off,
  wait two minutes and switch it on again.
- Qudelix no longer asks BlueZ to connect the 5K or to scan for it, so waiting for the control
  link can no longer push your Bluetooth audio over to the headset (call) profile.
- `qudelix probe` says whether this machine can open a Bluetooth LE control link.

## 0.7.0

New in the app:

- A sidebar with the Device, EQ, Presets, Library, Tune, Stage and Level pages. It folds into
  a list on narrow windows.
- Stage: soundstage processing for what you play. It works through a temporary "Qudelix Stage"
  output that is removed when you turn Stage off or quit. Needs PipeWire.
- Level: output level meters and stream quality, plus Auto-match USB rate, which sets the sample
  rate of the whole audio graph (every app) to what the 5K runs at while it is on. Needs PipeWire.
- Auto-fit and Auto-trim: the EQ follows a reference curve or trims itself against the
  measured balance.
- Tune: Compare, Shape, Blind, Trim and Tones sessions for tuning the EQ by ear. The tones need
  PipeWire.
- EQ page: the requested curve is drawn over the result, headroom is shown with a "Set x dB"
  button, Update and Save to slot, and a 10-band or 20-band switch.
- Load from file on the EQ and Presets pages.
- Loading the slot that is already active now says what happened.

Safety:

- When Stage stops, for any reason (turned off, failed, output changed, quit, logout or a crash),
  your output gets the volume you were hearing through Stage, and its mute, before it becomes the
  default again, so the sound never jumps louder.
- Stage turns itself off, puts your output back and says why if it goes silent, if its two audio
  paths run at different rates, or if it cannot save its recovery record. A failed restore of
  your default output is reported.
- Auto-match clears a sample rate it left behind after a crash, and says when another program
  has fixed the rate.
- The app opens at once and connects to the audio server in the background. It reconnects by
  itself after a PipeWire or WirePlumber restart, and quits cleanly on SIGTERM, SIGINT and SIGHUP.
- The tone test refuses an output above 100 % and reminds you to set your usual volume first.

Bluetooth fixes (the 1.6.4 work that never shipped on its own):

- The link waits for BlueZ 5.87 to finish loading the 5K's services.
- A notify channel BlueZ is still holding is freed.
- A dropped LE link is reconnected.
- The log says why the LE link dropped.

Known limits:

- The AI and AutoEq gaps in the app come in a later version: Library import, paste and export,
  the published-preset mode, bass and tilt, and the source cutoff. Use `qudelix` for those.
- Stage, Level and Tune have not yet been tested on real hardware by the developer.
- Apps that pick an output themselves bypass Stage.
- USB is the supported link. Bluetooth is included but untested on a real 5K.

## Earlier (released together with the Mac app)

1.6.0 to 1.6.3 shipped the command line, the desktop app, the cross-user device lock and the
Bluetooth discovery fixes. Their notes are in the
[main changelog](https://github.com/FrankieMa77/qudelix/blob/main/README.md#changelog).
