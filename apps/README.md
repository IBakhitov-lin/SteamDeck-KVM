# apps

The two programs people install.

- `pc/` — the Windows app: window, tray icon, Deskflow server, pairing with the Deck, updates.
- `deck/` — the Steam Deck part: background service, status window, installer and uninstaller.
- `palette.json` — colors, font, corner radii and icon shared by both windows.

Rules:

- The Windows app is PowerShell and imports nothing from `core/`; `core/` is Python for Linux.
- The Deck service imports `core/` and nothing else.
