"""Find legacy SIBIONICS GS1 advertisements on Windows and print their BLE address.

Install once:
    py -m pip install bleak
Run:
    py tools/find_gs1_address.py

On Windows Bleak exposes BLEDevice.address as the Bluetooth address. The script only
prints devices advertising FF30, the legacy GS1 glucose-data service used by the
public Gluco Glance implementation.
"""

import asyncio
import os
from bleak import BleakScanner

GS1_SERVICE_SUFFIX = "0000ff30-0000-1000-8000-00805f9b34fb"


def looks_like_gs1(advertisement) -> bool:
    uuids = {u.lower() for u in (advertisement.service_uuids or [])}
    service_data = {u.lower() for u in (advertisement.service_data or {}).keys()}
    return GS1_SERVICE_SUFFIX in uuids or GS1_SERVICE_SUFFIX in service_data


async def main() -> None:
    if os.name != "nt":
        print("Aviso: este helper foi pensado para Windows; em outras plataformas o endereço pode ser mascarado.")

    print("Escaneando BLE por 20 segundos. Deixe o GS1 próximo do computador…")
    found = {}

    def callback(device, advertisement):
        if not looks_like_gs1(advertisement):
            return
        found[device.address] = (device.name or "GS1", advertisement.rssi)
        print(f"GS1 encontrado: {device.address}  nome={device.name or '—'}  RSSI={advertisement.rssi} dBm")

    scanner = BleakScanner(detection_callback=callback)
    await scanner.start()
    await asyncio.sleep(20)
    await scanner.stop()

    if not found:
        print("Nenhum FF30 encontrado. Tente aproximar o sensor e repetir o scan.")
        return

    print("\nEndereço(s) para cadastrar no app iOS:")
    for address, (name, rssi) in found.items():
        print(f"  {address}   ({name}, {rssi} dBm)")


if __name__ == "__main__":
    asyncio.run(main())
