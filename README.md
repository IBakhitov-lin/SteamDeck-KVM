# Shared Keyboard & Mouse: Windows PC ↔ Steam Deck

One keyboard and mouse for both machines — the mouse cursor walks off the edge
of your monitor and onto the Deck's screen, the keyboard follows it. Nothing
gets unplugged or re-paired.

**Works in SteamOS Game Mode, not just Desktop Mode.** The Deck doesn't see a
piece of software — it sees an ordinary USB keyboard and an ordinary USB
mouse, created directly in the kernel. So input reaches Steam itself and
whatever game is running, not only the desktop.

## Why this exists

[Input Leap](https://github.com/input-leap/input-leap) (the maintained fork of
Barrier/Synergy) was archived on 2026-07-26. Its spiritual successor,
[Deskflow](https://github.com/deskflow/deskflow), works well — but like every
other KVM tool (Deskflow, [waynergy](https://github.com/r-c-f/waynergy),
[lan-mouse](https://github.com/feschber/lan-mouse)), the *client* side hands
input to the desktop compositor. SteamOS's Game Mode runs `gamescope`, which
doesn't accept those clients — so none of them work outside Desktop Mode.

This client (`deck-kvm.py`) writes straight into the Linux kernel via
`/dev/uinput`, bypassing the compositor entirely. The compositor — or its
absence — becomes irrelevant.

## What's inside

| Piece | Role |
| --- | --- |
| Windows side | [Deskflow](https://github.com/deskflow/deskflow) server (Barrier/Synergy protocol), plus a system-tray toggle app |
| `deck-kvm.py` | The Deck-side client — pure Python 3 standard library, no dependencies |
| `SteamDeck-KVM.ps1` | Windows tray icon: click to start/stop the server |
| `install-on-deck.sh` | One-shot installer: systemd service, `uinput` module, config file |
| `verify_kernel.py` | Sanity check on the real kernel: creates devices, reads events back |
| `verify_protocol.py` | Sanity check of the wire protocol against a real Deskflow server |

## Setup

### 1. Windows PC (the machine whose keyboard/mouse you're sharing)

```powershell
winget install --id Deskflow.Deskflow --exact
```

Configure it as a server (GUI or config file) with **one screen entry for your
PC and one for the Deck** — the screen names must match what you put in
`/etc/deck-kvm.conf` on the Deck in step 2. Example `screens.conf`:

```
section: screens
	my-pc:
	steamdeck:
end
section: links
	my-pc:
		right = steamdeck
	steamdeck:
		left = my-pc
end
```

Run `SteamDeck-KVM.ps1` (or double-click a shortcut pointing at it) — it sits
in the system tray; click it to start/stop the server. See
[SteamDeck-KVM.ps1](SteamDeck-KVM.ps1) for what it wires up (single-instance
guard, colored tray icon, no console window).

### 2. Steam Deck

1. Copy this whole folder onto the Deck — USB drive, `scp`, whatever's handy.
2. Switch to Desktop Mode, open **Konsole**, run:

   ```bash
   bash ~/Desktop/SteamDeck-KVM/install-on-deck.sh <your-pc's-IP-or-hostname>
   ```

   Example: `bash install-on-deck.sh 192.168.1.50`. You can pass a
   comma-separated fallback list: `192.168.1.50,my-pc.local`.
3. If the Deck asks for a password you've never set, run `passwd` first, then
   repeat step 2.

Done. The client comes up as a `systemd` service on every boot, in every mode.

## Using it

| Action | How |
| --- | --- |
| Start/stop the server | Click the tray icon on Windows (left-click toggles; right-click for a menu) |
| Move to the Deck | Push the mouse cursor to the shared screen edge and hold it there |
| Jump to the Deck instantly | **Win+Shift+D** (or whatever hotkey you set in `screens.conf`) |
| Jump back | **Win+Shift+W**, or the opposite screen edge |
| View the Windows-side log | Right-click the tray icon → **Open log** |
| Fully quit | Right-click the tray icon → **Exit** (stops the server too) |

## What this does *not* do

- **No shared clipboard.** Copying text on one machine won't paste on the
  other — the clipboard lives in the desktop shell, and this tool works
  around the shell entirely on purpose (that's the whole point in Game Mode).
- **No file drag-and-drop** between screens, same reason.
- Your keyboard and mouse stay fully usable on the PC the whole time; they
  only "leave" while the cursor is on the Deck's side.

## Configuration

**Deck is on the left, not the right.** Swap `right`/`left` in your
`screens.conf` on the Windows side, then restart the tray app's server.

**The PC's address changed.** Edit `/etc/deck-kvm.conf` on the Deck:

```bash
sudo nano /etc/deck-kvm.conf
sudo systemctl restart deck-kvm
```

**Cursor jumps around or lands in the wrong spot.** Switch to relative
pointer mode: set `pointer=rel` in `/etc/deck-kvm.conf`, then
`sudo systemctl restart deck-kvm`. The default, `pointer=abs`, drives the
cursor with absolute axes so OS-level pointer acceleration can't distort it —
try `rel` only if `abs` misbehaves on your setup.

**Check the kernel side is working**, on the Deck itself:

```bash
sudo python3 ~/Desktop/SteamDeck-KVM/verify_kernel.py
```

Creates the virtual keyboard and mouse, sends events, reads them back from
the kernel. Every line should read `OK`.

**Check the wire protocol** — runs on either machine, no special privileges:

```bash
python3 ~/Desktop/SteamDeck-KVM/verify_protocol.py
```

**Disable the systemd auto-start** (run it manually instead):

```bash
sudo systemctl disable deck-kvm
sudo systemctl start deck-kvm   # for this session only
```

Idle, the service uses about 15 MB of RAM and retries the connection every
15 seconds — negligible while the Deck is on.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Deck log says "no connection" | Tray icon on the PC is grey — click it to start the server |
| Same, but the icon is colored (server running) | A VPN on the PC is rerouting traffic. Disable it and retry |
| Cursor won't cross the screen edge | Deck hasn't connected — check its log |
| Cursor crosses, but clicks/keys don't register | The Deck service isn't running as root — re-run the installer |

Deck-side log:

```bash
journalctl -u deck-kvm -f
```

Windows-side log: right-click the tray icon → **Open log**, or open
`%LOCALAPPDATA%\SteamDeck-KVM\tray.log` directly.

## How it works

The PC runs a Deskflow server: it watches for the cursor hitting a screen
edge and streams input events over TCP, port 24800. The Deck runs
`deck-kvm.py`, a from-scratch client for the same wire protocol (Barrier/
Synergy family): it decodes those events and replays them through
`/dev/uinput` as two virtual kernel devices, "Deck KVM Keyboard" and
"Deck KVM Mouse." The mouse exposes both absolute axes (cursor position) and
relative axes (in-game look/aim once the cursor is captured); the keyboard
supports press, release, and OS-level key repeat.

Addressing is a plain TCP connection, not network discovery — the Deck client
dials out to whatever address you put in `/etc/deck-kvm.conf`; the server
just listens on its port and accepts whichever client's screen name matches
its config. This only works on one local network; the connection is
**unencrypted** — don't run it across anything but a trusted LAN.

## Uninstall (Deck side)

```bash
bash ~/Desktop/SteamDeck-KVM/uninstall-from-deck.sh
```

## License

MIT — see [LICENSE](LICENSE).
