# core/soldiers

Single-purpose building blocks.

- `virtual_device_soldier.py` — one virtual input device via `/dev/uinput`.
- `barrier_wire_soldier.py` — protocol frames over a TCP stream.
- `lan_discovery_soldier.py` — pairing beacon and the remembered PC.
- `release_update_soldier.py` — finds a newer GitHub release; the installer does the update.
- `keyboard/` — keyboard layouts on the Deck, taken from the PC's languages.
