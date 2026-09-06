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
```

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
1   device error or timeout
2   usage error
3   no transport, or permission denied on the device node
```

## Bluetooth

Bluetooth LE requires BlueZ 5.64 or newer and a Bluetooth adapter with LE support. USB is the recommended connection path. Bluetooth support is best-effort.

## Troubleshooting

If you see "Permission denied" when accessing the device, the udev rule did not apply. Reinstall the package or run:

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
