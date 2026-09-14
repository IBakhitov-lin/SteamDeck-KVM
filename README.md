# SteamDeck-KVM — one keyboard and mouse for your PC and Steam Deck

**English** · [Русский](README.ru.md)

Move the mouse off the edge of your monitor — the cursor lands on the Steam Deck, and the keyboard follows. Works in **Game Mode and inside games**, not just on the desktop.

**[⬇ Download the latest release](https://github.com/IBakhitov-lin/SteamDeck-KVM/releases/latest)**

## Install

### Steam Deck

1. Switch to **Desktop Mode** (Steam button → Power → Switch to Desktop).
2. Download **[SteamDeck-KVM-Install.desktop](https://github.com/IBakhitov-lin/SteamDeck-KVM/releases/latest/download/SteamDeck-KVM-Install.desktop)**. Firefox may save it as `….desktop.download` — remove the `.download` ending.
3. Double-click the downloaded file. The app is inside it, so it installs without any further download. The Deck password is asked only when upgrading from a pre-1.0 install.

### PC (Windows)

1. Download `SteamDeck-KVM-<version>-windows-x64-setup.exe` from the [latest release](https://github.com/IBakhitov-lin/SteamDeck-KVM/releases/latest).
2. Run it. It installs without admin rights, adds shortcuts and starts the app. Windows may warn about an unsigned app — click **More info → Run anyway**. The app offers to install [Deskflow](https://github.com/deskflow/deskflow) (free, open source) if it's missing.
3. Press **Enable**. The Deck finds the PC by itself — both must be on the same Wi-Fi.

## Use

- **Switch** — push the cursor past the screen edge, or press `Ctrl+Alt+→` / `Ctrl+Alt+←` (any keyboard layout).
- **After a reboot** — turn on the Deck, press **Enable** on the PC. The machines remember each other by device ID, not IP address.
- **Deck screen off or Deck asleep** — the cursor stays on the PC.

## Update

An **Update** button appears in both apps when a new release is out; it runs the installer of that release. Pairing and settings are kept.

## Uninstall

- **Steam Deck** — open **SteamDeck-KVM** from the app menu → **Uninstall**. You choose whether to keep the pairing.
- **PC** — Windows Settings → Apps → Installed apps → **SteamDeck-KVM** → Uninstall. You choose whether to keep the pairing.

## Troubleshooting

- **Deck doesn't find the PC** — guest Wi-Fi with client isolation, different subnets and full-tunnel VPNs block discovery. Put `server=192.168.x.x` into `~/.local/state/steamdeck-kvm/settings.conf` on the Deck.
- **The Deck shortcut does nothing** — make sure the file name ends with `.desktop`, not `.desktop.download`; or open Konsole in Downloads and run `python3 -c "$(sed -n 's/^Exec=python3 -c "\(.*\)" %k$/\1/p' SteamDeck-KVM-Install.desktop)" SteamDeck-KVM-Install.desktop`.
- **Still stuck** — both windows have a **Log** button; the Deck log is also in `journalctl --user -u steamdeck-kvm`.

## How it works

The PC runs a Deskflow server (Barrier/Synergy protocol). The Deck client speaks that protocol and injects input straight into the Linux kernel via `/dev/uinput`, so Steam and games see a real USB keyboard and mouse. In Game Mode it moves the cursor with relative motion, on the desktop with an absolute axis. Code layout: `apps/pc`, `apps/deck`, `core`, `tests`.

No clipboard sharing and no file drag-and-drop — both would need the desktop shell, and skipping it is exactly what makes Game Mode work. The connection is unencrypted: use it on a trusted home network.

## License

[MIT](LICENSE)
