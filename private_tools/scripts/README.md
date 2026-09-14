# private_tools/scripts

- `build_release_script.py` — builds and verifies the release in `dist/`: the Windows installer (Inno Setup) and the Steam Deck install shortcut.
- `make_shortcuts_script.ps1` — icon and launch shortcuts for a working copy.
- `check_window_layout_script.ps1` — checks the PC window and tray popup layout at several widths.

Releases are built only by the script: an archive zipped by hand loses the execute bits the Deck needs.
