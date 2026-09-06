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
qudelix history list             every recorded EQ edit, newest first
qudelix history show <n>         the curve entry <n> would put back
qudelix history restore <n>      write the curve of entry <n> back to the device
qudelix history clear            forget every recorded entry
qudelix ai providers             every provider, its default model and its key
qudelix ai key set <provider>    store an API key read from standard input
qudelix ai key clear <provider>  forget the stored key for a provider
qudelix ai key status            which providers have a key stored
qudelix ai research <headphone>  what a provider knows about a headphone
qudelix ai suggest <headphone>   design a preset for a headphone
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

`library save replace <name>`, `library fetch … save <name>` and `library fetch … target <name>`
also accept the dashed spellings `--replace`, `--save` and `--target`.

Every command that rewrites the live EQ — `import`, `preset push`, `preset load`,
`library apply`, `library fetch`, `ai suggest --apply` and `history restore` — first
records the curve the device was holding, so
`qudelix history restore 1` steps back to where the previous command started.
Entries are numbered from the newest, at most 40 are kept, and they live in
`~/.local/share/QudelixBar/eq-history.json` (`$XDG_DATA_HOME/QudelixBar/` when that
is set), next to the last-seen EQ the macOS app keeps.

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
`qudelix import`, `qudelix preset push`, `qudelix eq on|off` and
`qudelix history restore` each ask the device to save its settings once the command
has finished. Read-only commands never do.

## AI presets

`qudelix ai` designs a parametric preset for a named headphone with your own account
at an AI provider, the same way the macOS app's AI preset studio does. Nothing is
billed to anyone but you, and no request is made until you ask for one.

```
qudelix ai providers
qudelix ai key set openai            # reads the key from standard input
qudelix ai research "Sennheiser HD 650"
qudelix ai suggest "Sennheiser HD 650" --kind clarity
qudelix ai suggest "Sennheiser HD 650" --kind clarity --apply
```

Flags `ai suggest` takes:

```
--kind <kind>                    what to design (default: correction)
--provider <provider>            mistral, openai, anthropic or openrouter
--model <model>                  the model name at that provider
--bands 10 | 20                  bands to design for
--apply                          write the draft to the device
```

`ai research` takes `--provider`, `--model` and `--refresh`. `qudelix ai suggest
--kind wrong` lists every kind it accepts, and `qudelix ai key set wrong` every
provider.

Without `--apply` nothing touches the device: the draft is printed as a band table
with the model's own notes, and the run needs no 5K attached. With `--apply` the
draft is written to the live EQ and then saved to the device's flash, and the band
count defaults to the bank the device is in rather than 10.

`--kind correction` needs no AI key when a published measurement of the headphone
is available: the filters come straight from that measurement, as they do in the
macOS app.

### Where the key is kept

One file per provider, `$XDG_CONFIG_HOME/qudelix/ai-key-<provider>`
(`~/.config/qudelix/ai-key-<provider>` by default), created at mode 0600 inside a
0700 directory. The key is read from standard input rather than from the command
line so it never lands in the shell history, it is never printed by any command,
and it never reaches the log. A file other users can read is refused rather than
used, with the `chmod` to fix it. `QUDELIX_AI_KEY_<PROVIDER>`, or
`QUDELIX_AI_KEY` for any provider, overrides the file.

The key travels in one request header to the provider you picked and nowhere else.
The only hosts reached are `api.mistral.ai`, `api.openai.com`,
`api.anthropic.com`, `openrouter.ai` and — for the published measurement —
`raw.githubusercontent.com`.

### What is cached

What a provider answers about a headphone is kept in
`~/.local/share/QudelixBar/ai-research.json`, the same file and format the macOS
app uses, so `ai research` and the first `ai suggest` for a model are the only
requests made for it. `ai research --refresh` asks again.

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
