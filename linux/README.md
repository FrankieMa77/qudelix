# Qudelix on Linux

## Install

```
sudo apt install ./qudelix_<version>_amd64.deb
```

After installation, reconnect the Qudelix 5K device so the udev rule applies.

## Usage

```
qudelix probe                    what this machine offers, without touching the device
qudelix status                   model, firmware, battery, volume, DAC filter, EQ, preset
qudelix watch                    print device notifications until interrupted
qudelix volume                   show the current output level
qudelix volume <dB>              set the output level (clamped to the device's own window)
qudelix volume mute | unmute     mute or unmute the output
qudelix filter                   list the DAC reconstruction filters, marking the current one
qudelix filter <index|name>      select a DAC reconstruction filter
qudelix eq show                  pre-gain and the band table
qudelix eq on | off              enable or disable the EQ
qudelix preset list              every device slot, 1…20, marking the active one
qudelix preset load <n>          load a device slot into the live EQ
qudelix preset save <n>          save the live EQ into a device slot
qudelix preset name <n> <name>   rename a device slot
qudelix preset pull <file>       write the live EQ to a JSON file
qudelix preset push <file>       apply a JSON file written by pull
qudelix import <autoeq.txt>      apply a parametric-EQ text file (AutoEq, Equalizer APO, Peace)
qudelix library list             every preset saved on this machine
qudelix library show <n|name>    pre-gain and the band table of a saved preset
qudelix library apply <n|name>   write a saved preset to the device
qudelix library save <name>      save the live EQ into the library
qudelix library save replace <name>
                                 overwrite the preset already saved under that name
qudelix library delete <n|name>  forget a saved preset
qudelix library search <query>   find a headphone in the AutoEq catalogue
qudelix library fetch <n|name>   fit an AutoEq correction for it and apply it
qudelix library fetch <n> target <target-name>
                                 fit against a named target instead of the recommended one
qudelix library fetch <n> save <name>
                                 keep what was applied as a library preset too
```

The library lives in `~/.local/share/QudelixBar/presets.json` — the same file, in the same
format, that the macOS app keeps its saved presets in, so a library copied between the two
is readable on either. `$XDG_DATA_HOME` moves it if it is set.

A saved preset records which of the device's two EQ banks it was made for. `library apply`
refuses a 20-band preset while the device is in 10-band mode rather than stretching the
curve to fit.

`library` takes a saved preset either by its number in `library list` or by name:
a case-insensitive exact match first, then a unique prefix. A prefix matching more than one
preset is an error listing them.

`library search` downloads the AutoEq catalogue, prints up to 20 measurements with a number
each, and remembers them in `~/.local/share/QudelixBar/autoeq-search.json` so
`library fetch <n>` can pick one. The catalogue itself is not cached: it is fetched on every
run and kept in memory. `library fetch <name>` skips the search when the name resolves to a
single measurement; a headphone measured on more than one rig has to be fetched by number.

`library apply` and `library fetch` ask the device to save its settings once they finish,
the same way `import` and `preset push` do. Every other `library` subcommand only touches
the file on this machine, and `library list`, `show`, `delete` and `search` need no device
at all.

`library save`, `library fetch … save` and `library fetch … target` are spelled without
dashes because global flags are parsed before a subcommand sees them. The dashed spellings
work after `--`: `qudelix -- library save --replace Bassy`.

Preset slots are numbered 1 to 20, the same way they are shown.

`preset pull` and `preset push` use the same JSON the macOS app keeps its last-seen
EQ in, so a file written on either platform is readable on the other.

A name that starts with a dash needs `--` in front of it:
`qudelix preset name 4 -- --loud`.

Global flags:

```
--usb                            use the USB link
--ble                            use the Bluetooth link
--json                           print one JSON object instead of text
--timeout <seconds>              how long to wait for the device (default 5)
--verbose                        mirror the packet log to stderr
--help                           print the usage text
```

Exit codes:

```
0   ok
1   the device answered and then failed, or stopped answering mid-conversation
2   usage error, including a file that cannot be read, parsed or written
3   no transport: no link could be used, and none ever reached the device
```

When no link reaches the device, one line per link is printed to stderr — `qudelix:
usb: …` and `qudelix: bluetooth: …` — followed by the udev advice if a Qudelix node
is present but not readable.

## Persistence

EQ changes are written to the device's flash, so they survive a power cycle:
`qudelix import`, `qudelix preset push` and `qudelix eq on|off` each ask the device
to save its settings once the command has finished. Read-only commands never do.

## Bluetooth

Bluetooth LE requires BlueZ 5.64 or newer and a Bluetooth adapter with LE support. USB is the recommended connection path. Bluetooth support is best-effort.

## Troubleshooting

If you see "Permission denied" when accessing the device, the udev rule at
`/lib/udev/rules.d/70-qudelix.rules` did not apply. Reinstall the package or run:

```
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=hidraw
```

Then reconnect the device.

Application log: `~/.local/state/qudelix/qudelix.log`

## Building from source

To build the `.deb` package from source inside Docker:

```
bash linux/docker-build-deb.sh
```

This requires Docker and builds with Swift 6.2 on Ubuntu 22.04.
