# usbcable

A small macOS command-line tool that tells you what the USB-C cable plugged
into your Mac can actually do — its rated power and data speed — by reading
the cable's onboard **e-marker** chip.

USB-C cables rated for more than 3 A or faster than USB 2.0 contain an
e-marker that announces capabilities over USB Power Delivery (the
*Discover Identity SOP'* message). macOS interrogates it during PD
negotiation and publishes the result in the IORegistry's `IOPort` plane.
This tool reads and decodes that data — no root, no kernel extensions.

## Requirements

- Apple Silicon Mac (Intel Macs don't expose USB-PD state through IOKit)
- Swift toolchain (Xcode Command Line Tools)

## Build & run

```sh
swift build -c release
.build/release/usbcable            # summary
.build/release/usbcable --verbose  # + raw VDOs, PDO lists, SOP' properties
.build/release/usbcable --watch    # live mode: re-reports as you plug cables
```

`--watch` is the fastest way to test a pile of cables: keep a charger on the
far end, swap cables one by one, and read each verdict as it appears.

Besides cable identity, the tool shows the attached device/charger's
self-reported name, model, serial and firmware; the actual USB link speed;
battery charge/discharge wattage; and a ⚠ verdict when the negotiated power
or link speed is being limited by the cable.

## Example output

```
● Port-MagSafe 3@1 — connection active
  Cable:       e-marked — Apple Inc. (VID 0x05AC), PID 0x7800
               carrying 3.24 A — proven 5 A class (100 W+)
  Charger:     negotiated 20 V @ 3.24 A (64.8 W)

● Port-USB-C@1 — connection active
  Cable:       no e-marker — passive USB 2.0-class cable
               max 60 W (3 A @ 20 V), 480 Mbps
  Charger:     negotiated 20 V @ 3 A (60.0 W)
  ⚠ Verdict:   charger offers 96.0 W but only 60.0 W negotiated —
               this unmarked cable (3 A limit) is likely the limiter

○ Port-USB-C@2 — nothing connected

⚡ Battery: 80% — charging at 24.3 W
```

Output is colorized on interactive terminals (honors `NO_COLOR`); piped
output is plain text.

## Tips

- The e-marker is only read during PD negotiation, so plug a **charger or
  device** into the far end of the cable. A cable dangling from one port may
  show nothing.
- "No e-marker detected" is a real answer: plain charge-only cables have no
  chip and are limited to 3 A (60 W) and USB 2.0 speeds (480 Mbps) by spec.
- Power math: 3 A @ 20 V = 60 W, 5 A @ 20 V = 100 W, 5 A @ 48 V (EPR) = 240 W.

## How it works

1. Walks the IORegistry `IOPort` plane (`Port-USB-C@*` / `Port-MagSafe*`
   nodes from the `AppleHPM*` / `AppleTCController*` USB-PD port drivers).
2. Reads the cable identity VDOs from the port's `CC` → USB-PD → SOP'
   transport component, and charger PDOs from `IOPortFeaturePowerSource`.
3. Decodes the ID Header and Passive/Active Cable VDOs per the USB PD 3.x
   spec into plain English.
