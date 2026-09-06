# Qudelix on Linux

## Install

```
sudo apt install ./qudelix_<version>_amd64.deb
```

After installation, reconnect the Qudelix 5K device so the udev rule applies.

## Usage

```
qudelix probe                          Scan for connected Qudelix 5K devices
qudelix status                         Show current settings
qudelix watch                          Monitor device state changes
qudelix volume                         Get or set volume
qudelix filter                         Configure filter mode
qudelix eq show                        Display EQ settings
qudelix preset list                    List saved presets
qudelix preset load <name>             Load a preset
qudelix preset save <name>             Save current settings as preset
qudelix preset push <name>             Upload preset to device
qudelix preset pull <name>             Download preset from device
qudelix preset name <name>             Set the device's preset name
qudelix import <autoeq.txt>            Import AutoEQ file
```

Global flags:

```
--usb                                  Use USB connection (default if available)
--ble                                  Use Bluetooth LE connection
--json                                 Output machine-readable JSON
--timeout <seconds>                    Set operation timeout
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
