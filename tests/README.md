# tests

- `conftest.py` — fake input devices and session sensor, state isolated in a temp folder.
- `architecture/` — layout rules of the repository.
- `core/` — the Deck client.
- `apps/` — PC app logic that runs without a window.
- `deck/` — tests that need a real Steam Deck kernel; skipped elsewhere with a reason.

Run: `python -m pytest tests/core/test_<name>.py -q`. Every fixed bug keeps a test that reproduces it.
