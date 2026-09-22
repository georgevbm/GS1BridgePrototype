# GS1BridgePrototype — V0.1

Experimental iOS prototype for reading a **legacy SIBIONICS GS1** over Bluetooth LE and, later, forwarding readings to Nightscout for display on Apple Watch.

## What is implemented

- Pure Swift port of the public legacy GS1 frame protocol.
- Unit tests for frame construction, checksum, big-endian reading parsing, and temperature correction.
- iOS SwiftUI debug screen.
- CoreBluetooth scan for GS1 service `FF30`.
- Connect → discover `FF30` → subscribe to `FF31` → write requests to `FF32`.
- History walking logic modeled after Gluco Glance (burst quiet period, next-index requests, retries/stall detection).
- Explicit handling of the `23 F7 6F D9 F4` auth request as an unsupported encrypted/newer protocol.
- Windows helper to discover the BLE MAC address, which iOS does not expose directly.
- XcodeGen + Codemagic scaffold for building on macOS CI while developing from Windows.

## Why the MAC has to be entered manually on iPhone

The legacy GS1 request frame contains the sensor's six-byte Bluetooth address, reversed. Android exposes this as `BluetoothDevice.address`; Apple's CoreBluetooth exposes a system-assigned UUID for a `CBPeripheral` instead of the Bluetooth MAC.

Windows can expose the Bluetooth address of a received BLE advertisement. The included helper uses Bleak to find devices advertising `FF30` and prints the address once, so it can be saved in the iOS app.

### Find the GS1 address on Windows

From the repository root:

```powershell
py -m pip install bleak
py tools/find_gs1_address.py
```

Keep the GS1 close to the PC. The expected output is similar to:

```text
GS1 encontrado: AA:BB:CC:DD:EE:FF  nome=...  RSSI=-54 dBm
```

Copy that address into the iOS debug app.

## Protocol mapped so far

Legacy GS1 data service:

- Service: `FF30`
- Notify: `FF31`
- Write: `FF32`
- CCCD: `2902` (CoreBluetooth handles notification subscription through `setNotifyValue`)

Ask frame:

```text
AA 55 07
[index low] [index high]
[BLE MAC reversed: 6 bytes]
[8 zero bytes]
[checksum]
```

The checksum is chosen so that all bytes in the full frame sum to `0 mod 256`.

Example for index `1`, address `AA:BB:CC:DD:EE:FF`:

```text
AA 55 07 01 00 FF EE DD CC BB AA 00 00 00 00 00 00 00 00 FE
```

Glucose-response frames begin with:

```text
AA 55 09 [count]
```

Each record is 14 bytes / seven unsigned big-endian 16-bit words:

1. reading index
2. temperature × 10
3. electrical raw value
4. sensor glucose figure × 10
5. status
6. unreceived count
7. add-time seconds

The sensor figure is **not yet the final clinically usable glucose value**. The public implementation applies temperature correction and then a separate calibration layer.

## Run the cross-platform protocol tests on Windows/Linux/macOS

With Swift installed:

```bash
swift test
```

## Generate the iOS project on a Mac/CI runner

```bash
brew install xcodegen
xcodegen generate
```

Then build `GS1Bridge.xcodeproj`.

The included `codemagic.yaml` performs an unsigned simulator build. Signing/TestFlight is deliberately postponed until the BLE prototype is proven against a real GS1.

## V0.1 acceptance test

The first real-device milestone is intentionally narrow:

1. Find the GS1 MAC from Windows.
2. Enter it in GS1 Debug on iPhone.
3. Temporarily stop the official SIBIONICS app from owning the sensor connection.
4. Scan and connect.
5. Confirm service `FF30` is found.
6. Confirm notifications on `FF31` are enabled.
7. Confirm an `AA 55 09 ...` frame arrives.
8. Compare the latest raw/debug reading with the official app after reconnecting it.

Do **not** use the prototype for treatment decisions.

## Next milestone

After a real GS1 confirms the BLE exchange works on iOS:

- port/implement the calibration layer;
- validate readings across multiple points against the official app and fingerstick values;
- add Nightscout upload;
- connect Nightguard/Apple Watch;
- harden background Bluetooth behavior and reconnection.

## Windows + iPhone sem assinatura paga

A partir da V0.1.1, o workflow `GS1 iPhone unsigned build` gera um `GS1Bridge-unsigned.ipa` para iPhone físico. Esse IPA pode ser assinado e instalado no Windows com uma Conta Apple gratuita usando uma ferramenta de sideload. Veja `INSTALL_WINDOWS.md`.


## v0.1.2

- iOS target moved to Swift 5 language mode while keeping the current Xcode compiler.
- Fixes closure capture warnings/errors in the retry timers.
- This is intentional for the prototype because CoreBluetooth's Objective-C delegate APIs do not yet carry the actor-isolation information Swift 6 strict concurrency expects.
