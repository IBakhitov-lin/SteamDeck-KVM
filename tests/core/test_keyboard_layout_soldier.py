# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Проверки раскладок Steam Deck по языкам компьютера на временной папке настроек
from __future__ import annotations

from core.soldiers.keyboard.keyboard_layout_soldier import ENV_FILE, TOGGLE, KeyboardLayoutSoldier, layouts_from_languages


def soldier(tmp_path, calls=None):
    return KeyboardLayoutSoldier(config_home=tmp_path, reload=lambda: (calls if calls is not None else []).append(1))


def test_windows_languages_become_xkb_layouts():
    assert layouts_from_languages("en-US,ru-RU") == ["us", "ru"]
    assert layouts_from_languages("ru-RU, en-GB,uk-UA,xx-YY,ru") == ["gb", "ru", "ua"]
    assert layouts_from_languages("ru,en-US") == ["us", "ru"], "латиница первой: так Windows отдаёт языки у автора"
    assert layouts_from_languages("ru-RU,uk-UA") == ["ru", "ua"], "без латиницы порядок компьютера"
    assert layouts_from_languages("") == [] and layouts_from_languages("-") == []


def test_game_mode_gets_layouts_and_alt_shift(tmp_path):
    s = soldier(tmp_path)
    assert s.apply("en-US,ru-RU") == ["game", "desktop"]
    env = (tmp_path / "environment.d" / ENV_FILE).read_text(encoding="utf-8")
    assert "XKB_DEFAULT_LAYOUT=us,ru\n" in env and "XKB_DEFAULT_OPTIONS=%s\n" % TOGGLE in env


def test_second_apply_changes_nothing(tmp_path):
    calls = []
    s = soldier(tmp_path, calls)
    s.apply("en-US,ru-RU")
    assert s.apply("en-US,ru-RU") == [] and calls == [1], "KDE перечитывает настройку только при изменении"


def test_desktop_keeps_own_layouts_and_own_switch(tmp_path):
    kx = tmp_path / "kxkbrc"
    kx.write_text("[Layout]\nLayoutList=de\nVariantList=nodeadkeys\nUse=true\nOptions=grp:win_space_toggle\n\n"
                  "[Other]\nx=1\n", encoding="utf-8")
    soldier(tmp_path).write_desktop(["us", "ru"])
    text = kx.read_text(encoding="utf-8")
    assert "LayoutList=de,us,ru" in text and "VariantList=nodeadkeys,," in text
    assert "Options=grp:win_space_toggle" in text and TOGGLE not in text, "своё переключение не трогается"
    assert "[Other]\nx=1" in text


def test_desktop_without_config_gets_layouts(tmp_path):
    soldier(tmp_path).write_desktop(["us", "ru"])
    text = (tmp_path / "kxkbrc").read_text(encoding="utf-8")
    assert "[Layout]" in text and "LayoutList=us,ru" in text and "Use=true" in text
    assert "Options=%s" % TOGGLE in text and "ResetOldOptions=true" in text


def test_unknown_languages_change_nothing(tmp_path):
    assert soldier(tmp_path).apply("xx-YY") == []
    assert not (tmp_path / "kxkbrc").exists()
