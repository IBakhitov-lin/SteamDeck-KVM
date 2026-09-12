# Shared Keyboard & Mouse: Windows PC ↔ Steam Deck

**English** · [Русский](README.ru.md)

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
| Windows side | [Deskflow](https://github.com/deskflow/deskflow) server (Barrier/Synergy protocol), plus a one-button window to toggle it |
| `deck-kvm.py` | The Deck-side client — pure Python 3 standard library, no dependencies |
| `SteamDeck-KVM.ps1` | Windows window: one Start/Stop button and the live state of the link |
| LAN pairing | The PC beacons "I'm here"; the Deck hears it and connects on its own, and the two remember each other by a permanent device id rather than an address |
| `app-window.ps1` | Window shell: palette, typeface and corner radii from the shared contract |
| `make-shortcuts.ps1` | Builds the icon and both launch shortcuts |
| `check-window-layout.ps1` | Layout guard: nothing runs off an edge or lands on top of a neighbour |
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

Build the shortcuts once:

```powershell
powershell -ExecutionPolicy Bypass -File make-shortcuts.ps1
```

That puts a shortcut in the folder root and a copy on the Desktop. A window
opens with one button: **Start** brings the server up, **Stop** takes it down.
The window also shows whether the Deck is known and whether it is connected.
**To tray** leaves it running as an icon; closing the window stops the server.

### 2. Steam Deck

1. Copy this whole folder onto the Deck — USB drive, `scp`, whatever's handy.
2. Switch to Desktop Mode, open **Konsole**, run:

   ```bash
   bash ~/Desktop/SteamDeck-KVM/install-on-deck.sh
   ```

   No address needed: the Deck hears the PC's beacon on the LAN and remembers
   it. Pass an address only where broadcast doesn't get through — guest Wi-Fi
   with client isolation, separate subnets, a full-tunnel VPN on the PC:
   `bash install-on-deck.sh 192.168.1.50`.
3. If the Deck asks for a password you've never set, run `passwd` first, then
   repeat step 2.

Done. The client comes up as a `systemd` service on every boot, in every mode.

## Using it

| Action | How |
| --- | --- |
| Get going | Power on the Deck, open the window on the PC, press **Start** — the link comes up by itself |
| Stop | Press **Stop** in the same window — the Deck disconnects |
| Move to the Deck | Push the mouse cursor to the shared screen edge and hold it there |
| Jump to the Deck instantly | **Win+Shift+D** (or whatever hotkey you set in `screens.conf`) |
| Jump back | **Win+Shift+W**, or the opposite screen edge |
| View the Windows-side log | The **Log** button in the window |
| Keep it running without the window | **Minimize to tray**; double-click the icon to bring the window back |
| Fully quit | Close the window — the server stops with it |

## What this does *not* do

- **No shared clipboard.** Copying text on one machine won't paste on the
  other — the clipboard lives in the desktop shell, and this tool works
  around the shell entirely on purpose (that's the whole point in Game Mode).
- **No file drag-and-drop** between screens, same reason.
- Your keyboard and mouse stay fully usable on the PC the whole time; they
  only "leave" while the cursor is on the Deck's side.

## Configuration

**Deck is on the left, not the right.** Swap `right`/`left` in your
`screens.conf` on the Windows side, then restart the server from the window.

**The PC's address changed.** Nothing to do — the address comes from the
beacon, not from a config file. A hand-set address is edited where it was set:

```bash
sudo nano /etc/deck-kvm.conf   # server=auto — discover over the LAN
sudo systemctl restart deck-kvm
```

**The Deck doesn't find the PC.** Both machines must be on the SAME Wi-Fi, and
that network must not isolate clients from each other (guest networks always
do). A full-tunnel VPN on the PC can also swallow the beacon. Either way, set
the address by hand: `server=192.168.1.50` in `/etc/deck-kvm.conf`.

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

Windows-side log: the **Log** button in the window, or open
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

The input link itself is a plain TCP connection; pairing is a separate UDP
beacon on port 24801. Each side mints a permanent device id on first run (the
PC in `pair.json`, the Deck in `/var/lib/deck-kvm/identity`). The PC broadcasts
its id, name, port and on/off state every two seconds; the Deck answers with one
packet carrying its own id and takes the PC's address from that packet's header,
then dials the TCP port. The first exchange is the pairing — each side records
the other's id.

After that the pair rides on the id, not the address: a new router, a different
network, a phone hotspot, all fine, because the address is re-read from every
packet. Another Deck on the same LAN never silently replaces the paired one.
The PC beacons and the Deck listens, rather than the reverse, because the
reverse would need an inbound Windows Firewall rule — that is, administrator
rights at install time. This only works on one local network; the connection is
**unencrypted** — don't run it across anything but a trusted LAN.

## Uninstall (Deck side)

```bash
bash ~/Desktop/SteamDeck-KVM/uninstall-from-deck.sh
```

## License

MIT — see [LICENSE](LICENSE).
