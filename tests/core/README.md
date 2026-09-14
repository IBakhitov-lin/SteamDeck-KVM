# tests/core

- `test_deck_client_protocol.py` — talking to the server, retries, screen off, a real Deskflow handshake.
- `test_input_translation_officer.py` — modifiers, cursor movement mode, keys.
- `test_deck_session_sensor.py` — screen, screen power, session mode.
- `test_lan_discovery_soldier.py` — pairing, remembered PC, migration from the old install.
- `test_release_update_soldier.py` — finding a newer release.
- `test_control_api_facade.py` — local API and its request header check.

Only what is missing on the test machine is faked: kernel devices and the compositor.
