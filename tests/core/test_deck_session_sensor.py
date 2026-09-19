# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Проверки датчика сеанса Steam Deck на поддельных деревьях /sys и /proc
from __future__ import annotations

from core.officers.intelligence.deck_session_sensor import DESKTOP, GAME, UNKNOWN, DeckSessionSensor


def fake_sys(root, connectors):
    for name, (status, mode, dpms) in connectors.items():
        folder = root / "sys" / "class" / "drm" / name
        folder.mkdir(parents=True)
        (folder / "status").write_text(status)
        (folder / "modes").write_text(mode + "\n")
        if dpms is not None:
            (folder / "dpms").write_text(dpms)


def fake_proc(root, names):
    for pid, name in enumerate(names, start=100):
        folder = root / "proc" / str(pid)
        folder.mkdir(parents=True)
        (folder / "comm").write_text(name + "\n")
    (root / "proc" / "self").mkdir(parents=True, exist_ok=True)


def sensor(root):
    return DeckSessionSensor(sys_root=str(root / "sys"), proc_root=str(root / "proc"))


def test_screen_size_picks_largest_connected(tmp_path):
    fake_sys(tmp_path, {"card0-eDP-1": ("connected", "800x1280", "On"),
                        "card0-DP-1": ("connected", "1920x1080", "On"),
                        "card0-DP-2": ("disconnected", "3840x2160", "Off")})
    assert sensor(tmp_path).screen_size() == (1920, 1080)


def test_screen_size_turns_the_sideways_internal_panel(tmp_path):
    fake_sys(tmp_path, {"card0-eDP-1": ("connected", "800x1280", "On")})
    assert sensor(tmp_path).screen_size() == (1280, 800)


def test_screen_size_keeps_a_portrait_external_screen(tmp_path):
    fake_sys(tmp_path, {"card0-eDP-1": ("disconnected", "800x1280", "Off"),
                        "card0-DP-1": ("connected", "1080x1920", "On")})
    assert sensor(tmp_path).screen_size() == (1080, 1920)


def test_screen_size_falls_back_without_drm(tmp_path):
    assert sensor(tmp_path).screen_size() == (1280, 800)


def test_display_off_only_when_every_connected_screen_is_off(tmp_path):
    fake_sys(tmp_path, {"card0-eDP-1": ("connected", "800x1280", "Off"),
                        "card0-DP-1": ("connected", "1920x1080", "On")})
    assert sensor(tmp_path).display_on() is True
    (tmp_path / "sys" / "class" / "drm" / "card0-DP-1" / "dpms").write_text("Off")
    assert sensor(tmp_path).display_on() is False


def test_display_unknown_counts_as_on(tmp_path):
    fake_sys(tmp_path, {"card0-eDP-1": ("connected", "800x1280", None)})
    assert sensor(tmp_path).display_on() is True, "датчик без ответа не рвёт рабочую связь"


def test_session_mode_by_compositor(tmp_path):
    fake_proc(tmp_path / "game", ["systemd", "steam", "gamescope-wl"])
    fake_proc(tmp_path / "desk", ["plasmashell", "kwin_wayland", "gamescope"])
    fake_proc(tmp_path / "none", ["bash"])
    assert sensor(tmp_path / "game").session_mode() == GAME
    assert sensor(tmp_path / "desk").session_mode() == DESKTOP, "gamescope внутри KWin — всё равно рабочий стол"
    assert sensor(tmp_path / "none").session_mode() == UNKNOWN
