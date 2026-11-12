# qudelix for Linux

`qudelix` is a headless command-line tool for the Qudelix 5K DAC and amplifier. It reads the
device's state and changes its settings over USB: volume, DAC filter, the parametric EQ, the
device's 20 preset slots, a local preset library, AutoEq import and an EQ history.

USB is the recommended link. Bluetooth control works too, but it needs the 5K's short
connection window (see Bluetooth below).

## Desktop app

`qudelix-app` is the desktop version: a GTK 4 and libadwaita window with a sidebar of Device, EQ,
Presets, Library, Tune, Stage and Level pages, a battery graph and a top-bar tray menu with
volume, mute, EQ and preset shortcuts. It does most of what the command line does and reads the
same files. It does not have the AutoEq "Published preset" mode, the bass and tilt sliders, the
source cutoff, the remembered AutoEq search, Library import, paste and export, or the EQ history
list (undo and redo cover the current session); use `qudelix` for those. What changed in each
release is in [the changelog](https://github.com/FrankieMa77/qudelix/blob/main/linux/CHANGELOG.md).

Stage, Level and the Tune tones need PipeWire. Without it the app still controls the 5K and shows
"Needs PipeWire" on those pages. Stage works through a temporary "Qudelix Stage" output, and
Auto-match USB rate in Level changes the sample rate of the whole audio graph while it is on.
Apps that choose an output themselves bypass Stage.

It needs Ubuntu 24.04 or later, or any distribution with GTK 4.14 and libadwaita 1.5. Install
the command-line package and the app together; the app package depends on `qudelix`, which
carries the udev rule:

```
sudo apt install ./qudelix_0.7.1_amd64.deb ./qudelix-app_0.7.1_amd64.deb
```

On Arch Linux install `qudelix-cli-bin` and `qudelix-app-bin` from the AUR
([qudelix-cli-bin](https://aur.archlinux.org/packages/qudelix-cli-bin),
[qudelix-app-bin](https://aur.archlinux.org/packages/qudelix-app-bin)). On other distributions
unpack the tarball and run its installer:

```
tar xzf qudelix-app-0.7.1-linux-x86_64.tar.gz
cd qudelix-app-0.7.1-linux-x86_64
sudo ./install.sh
```

It installs the binary, the launcher, the icons and the AppStream metadata under `/usr/local`
and the udev rule in `/etc/udev/rules.d/` (set `PREFIX` or `UDEV_RULES_DIR` to change that);
`sudo ./uninstall.sh` removes them. The launcher and the Start at Login entry run the binary by
its full path, so a different `PREFIX` works too.

The tray icon needs a StatusNotifier host. Ubuntu ships one. Vanilla GNOME and Fedora need the
"AppIndicator and KStatusNotifierItem Support" extension, and KDE has one built in. Without a
host there is no tray icon and closing the window quits the app. With one, closing the window
keeps the app in the tray and Quit is in the tray menu and the app menu. "Start at Login" in
the app menu starts it hidden in the tray when you sign in.

While the app is connected to the 5K it holds the device, so `qudelix` reports it as busy
(exit code 4) until the 5K is unplugged or you quit the app. Closing the window does not release
it while the app stays in the top bar: quit it from the top-bar menu or the app menu. The hold
applies to every user on the machine, root included. An app that is running but not connected
does not block `qudelix`. USB is the recommended link; Bluetooth control works but needs the 5K's short connection window.

## Install (command line)

Debian and Ubuntu (amd64):

```
sudo apt install ./qudelix_0.7.1_amd64.deb
```

Arch Linux: install `qudelix-cli-bin` from the AUR
([qudelix-cli-bin](https://aur.archlinux.org/packages/qudelix-cli-bin)).

Other distributions: unpack the tarball and run its installer.

```
tar xzf qudelix-0.7.1-linux-x86_64.tar.gz
cd qudelix-0.7.1-linux-x86_64
sudo ./install.sh
```

`install.sh` copies the binary to `/usr/local/bin/qudelix` and the udev rule to
`/etc/udev/rules.d/`, then reloads udev. Set `PREFIX` or `UDEV_RULES_DIR` to install elsewhere.

After either install, unplug and replug the Qudelix 5K so the new rule applies.

A tarball install puts `qudelix` in `/usr/local/bin`, which comes before `/usr/bin` in `PATH`,
so it shadows a copy installed from the `.deb`. Remove one of them to avoid running the wrong
version.

## Permissions

The `.deb` installs `/usr/lib/udev/rules.d/70-qudelix.rules` and the tarball installs
`/etc/udev/rules.d/70-qudelix.rules`. The rule is:

```
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="0a12", ATTRS{product}=="*Qudelix*", TAG+="uaccess", MODE="0660", GROUP="plugdev"
```

The rule matches the vendor id and the product name, not a product id, so it works whatever USB
product id the 5K reports in its current USB mode. On a desktop session managed by logind or
elogind, which covers Ubuntu, Debian, Arch and Artix with elogind, `uaccess` gives the logged-in
user access without any group change. Without a seat manager the `plugdev` group is used instead. Debian and Ubuntu ship that
group. If the device is present but not readable, add your user to it, log out and back in, then
replug the 5K:

```
sudo usermod -aG plugdev "$USER"
```

Arch and Artix have no `plugdev` group, so udev logs an error for the `GROUP` entry and ignores
it; `uaccess` still applies under logind or elogind. Without one, create the group first
(`sudo groupadd plugdev`) or change `GROUP` in the rule to a group you belong to.

`qudelix` never needs `sudo`: the rule gives your user access. A "busy" message means the Qudelix
app (or another `qudelix` command) holds the 5K. The app keeps the 5K while it sits in the top
bar, even with its window closed, so quit it from the top-bar menu or the app menu and run the
command again. The message names the program and its pid when it can find it.

`qudelix probe` needs no device access. It reports the hidraw nodes it can see, their
permissions and what the machine offers for each link.

## Commands

```
qudelix — command-line control for the Qudelix 5K

usage: qudelix [flags] <command>

commands:
  probe                     report what this machine offers, without touching the device
  status                    model, firmware, battery, volume, DAC filter, EQ, preset
  watch                     print device notifications until interrupted
  volume                    show the current output level
  volume <dB>               set the output level
  volume mute | unmute      mute or unmute the output
  filter                    list the DAC reconstruction filters
  filter <index|name>       select a DAC reconstruction filter
  eq show                   pre-gain and the band table
  eq on | off               enable or disable the EQ
  preset list               every device slot, 1…20
  preset load <n>           load a device slot into the live EQ
  preset save <n>           save the live EQ into a device slot
  preset name <n> <name>    rename a device slot
  preset pull <file>        write the live EQ to a JSON file
  preset push <file>        apply a JSON file written by pull
  import <autoeq.txt>       apply a parametric-EQ text file
  library list              every preset saved on this machine
  library show <n|name>     pre-gain and the band table of a saved preset
  library apply <n|name>    write a saved preset to the device
  library save <name>       save the live EQ; 'save replace <name>' overwrites
  library delete <n|name>   forget a saved preset
  library search <query>    find a headphone in the AutoEq catalogue
  library fetch <n|name>    fit an AutoEq correction and apply it
  ai providers              every provider, its default model and its key
  ai key set <provider>     store an API key read from standard input
  ai key clear <provider>   forget the stored key for a provider
  ai key status             which providers have a key stored
  ai research <headphone>   what a provider knows about a headphone
  ai suggest <headphone>    design a preset for a headphone
    [--kind <kind>] [--provider <p>] [--model <m>] [--bands 10|20] [--apply]
  history list              every recorded EQ edit, newest first
  history show <n>          the curve entry <n> would put back
  history restore <n>       write the curve of entry <n> to the device
  history clear             forget every recorded entry

flags:
  --usb                     use the USB link
  --ble                     use the Bluetooth link
  --json                    print one JSON object instead of text
  --timeout <seconds>       how long to wait for the device (default 5, 40 for Bluetooth)
  --verbose                 mirror the log (packets and Bluetooth steps) to stderr
  --help                    print this text
  --version                 print the version

exit codes: 0 ok · 1 the device answered and then failed · 2 usage error
            3 no transport reached the device
            4 another qudelix or the Qudelix app is using the device
```

Only one program talks to the device at a time. Every command that opens the device takes a
lock file (`qudelix.lock` in the state directory) and then a lock on the device node itself, which
is shared by every user, root included, and by the app; a second program exits at once with
code 4.

Every command that rewrites the live EQ (`import`, `preset push`, `preset load`,
`library apply`, `library fetch`, `ai suggest --apply`, `history restore`) first records the
curve the device was holding, so `qudelix history restore 1` steps back to where the previous
command started.

EQ changes are written to the device's flash, so they survive a power cycle. `import`,
`preset push`, `eq on|off`, `history restore`, `library apply`, `library fetch` and
`ai suggest --apply` each ask the
device to save its settings once they finish. Read-only commands never do.

`library` takes a saved preset either by its number in `library list` or by name: a
case-insensitive exact match first, then a unique prefix. `library search` downloads the AutoEq
catalogue and remembers its results so that `library fetch <n>` can pick one.

`ai` designs presets with your own account at a provider (mistral, openai, anthropic or
openrouter). Nothing is sent until you ask for it.

## Files and logs

| What | Where |
| --- | --- |
| Log (`--verbose` also mirrors it to stderr) | `$XDG_STATE_HOME/qudelix/qudelix.log`, default `~/.local/state/qudelix/qudelix.log` |
| Instance lock | `$XDG_STATE_HOME/qudelix/qudelix.lock` |
| Preset library | `$XDG_DATA_HOME/QudelixBar/presets.json`, default `~/.local/share/QudelixBar/presets.json` |
| AutoEq search results | `$XDG_DATA_HOME/QudelixBar/autoeq-search.json` |
| EQ history (last 40 edits) | `$XDG_DATA_HOME/QudelixBar/eq-history.json` |
| Slot last loaded | `$XDG_DATA_HOME/QudelixBar/active-slot.json` |
| AI provider keys (mode 0600) | `$XDG_CONFIG_HOME/qudelix/`, default `~/.config/qudelix/` |
| Pinned Bluetooth device | `$XDG_CONFIG_HOME/qudelix/ble-device` |
| Battery history (written by the app) | `$XDG_DATA_HOME/QudelixBar/battery-history.json` |
| Start at Login entry (written by the app) | `$XDG_CONFIG_HOME/autostart/io.github.FrankieMa77.Qudelix.desktop` |

`--bluetooth` is accepted as an alias of `--ble`, and `-v` and `-h` as aliases of `--verbose` and
`--help`.

Preset slots are numbered 1 to 20, the same way they are shown. The preset library uses the
same JSON format as the macOS QudelixBar app.

## Bluetooth

`--ble` (or `--bluetooth`) controls the 5K over Bluetooth. USB stays the recommended link; use
Bluetooth when you want to leave the cable out.

- No pairing is needed for the control link. Connect the 5K as your headphones the usual way
  for the sound; Qudelix opens its own control link next to that and never touches the audio
  connection.
- The 5K accepts a control link only for a short time after it is switched on, and again soon
  after a previous control link ends. The app waits for that by itself and connects within a
  second or so. Nothing to click.
- If it does not connect, switch the 5K off, wait two minutes, switch it on and let it
  reconnect by itself.
- Keep the Bluetooth page of Settings, or any other program that searches for Bluetooth
  devices, closed while Qudelix connects. While a search runs, this computer misses the few
  seconds in which the 5K accepts the control link, and the app says so while it waits.
  Clicking Connect there while the 5K powers on can make it miss the 5K too; let the 5K
  reconnect on its own.
- Only one program can hold the 5K's Bluetooth control link at a time. Quit the app before
  you use `qudelix --ble`.

Then run `qudelix --ble status`. If it fails, run `qudelix --ble probe` and paste its output in
a bug report; its Bluetooth section lists what this computer knows about the 5K without
connecting to anything. `--timeout` changes how long a command waits for the link.

With `--verbose`, the log also says why the link dropped when it is known (timeout, closed by
the 5K, closed by this computer).

## Uninstall

Debian and Ubuntu:

```
sudo apt remove qudelix-app qudelix
```

Tarball install:

```
sudo ./uninstall.sh
```

Each removes its own binary. The tarball uninstallers also remove the udev rule and reload udev,
but only when the other package's binary is no longer in `$PREFIX/bin`, so the one that stays
keeps working. Your settings, preset library, EQ history, battery history, the Start at Login
entry and API keys are kept; delete the paths listed under Files and logs to remove them.
