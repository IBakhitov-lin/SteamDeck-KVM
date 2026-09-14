# private_tools/installer

- `steamdeck-kvm-setup.iss` — Windows installer script for [Inno Setup 6](https://jrsoftware.org/isinfo.php). Built only by `private_tools/scripts/build_release_script.py`.

What the installer does:

- Installs for the current user without admin rights into `%LOCALAPPDATA%\Programs\SteamDeck-KVM`.
- Adds Start menu and desktop shortcuts and starts the app.
- Registers in Windows "Installed apps"; uninstalling asks whether to remove the pairing and settings.
- The app's Update button runs the next installer with `/VERYSILENT`.
