# core

The Steam Deck client: Barrier/Synergy protocol, Linux virtual input devices, LAN pairing, updates from releases.

- `soldiers/` — single-purpose building blocks: input device, protocol frames, pairing beacon, release download.
- `officers/` — decisions: how a server message becomes input; `intelligence/` watches the Deck's state.
- `commanders/` — the session with the PC.
- `dto/` — the client status shape.
- `config_policy.py` — ports, protocol name, release URL, data paths.
- `control_api_facade.py` — local API the status window talks to.

Rules:

- Layers import downwards only: soldiers know nothing about officers, officers nothing about commanders; `tests/architecture` enforces it.
- Modules import on Windows too: the Linux input interface is opened when a device is created, not on import.
- Every `.py` starts with a one-line purpose comment.
