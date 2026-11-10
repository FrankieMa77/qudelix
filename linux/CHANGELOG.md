# Qudelix for Linux: changelog

## Version numbers

Linux now has its own version line, starting at 0.7.0. It follows the Mac app's 1.6.3, so
nothing here is a downgrade: the Debian packages carry an epoch (`1:0.7.0`) and apt upgrades
an installed 1.6.x normally. AUR packagers need `epoch=1` in their PKGBUILDs.

Linux releases are tagged `linux-v<version>` and titled "Qudelix for Linux". Mac releases keep
the `v<version>` tags and the Mac changelog in the main README.

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

Bluetooth fixes (the 1.6.4 work that never shipped on its own):

- The link waits for BlueZ 5.87 to finish loading the 5K's services.
- A notify channel BlueZ is still holding is freed.
- A dropped LE link is reconnected.
- The log says why the LE link dropped.

Known limits:

- The AI and AutoEq gaps in the app come in a later version: Library import, paste and export,
  the published-preset mode, bass and tilt, and the source cutoff. Use `qudelix` for those.
- Stage, Level and Tune have not yet been tested on real hardware by the developer.
- USB is the supported link. Bluetooth is included but untested on a real 5K.

## Earlier (released together with the Mac app)

1.6.0 to 1.6.3 shipped the command line, the desktop app, the cross-user device lock and the
Bluetooth discovery fixes. Their notes are in the
[main changelog](https://github.com/FrankieMa77/qudelix/blob/main/README.md#changelog).
