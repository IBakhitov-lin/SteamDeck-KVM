# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Soldier раскладок клавиатуры Steam Deck по языкам компьютера
"""
keyboard_layout_soldier.py

Клавиши приходят на Deck физическими, буквы печатает раскладка самого Deck'а. Значит, у Deck'а
должны быть те же языки, что у компьютера, и то же переключение — Alt+Shift. Компьютер называет
свои языки в маячке (`en-US,ru-RU`), солдат переводит их в раскладки XKB (`us,ru`) и прописывает
в двух местах:

1. **Игровой режим** — `~/.config/environment.d/60-steamdeck-kvm-keyboard.conf`: композитор
   gamescope берёт раскладку из `XKB_DEFAULT_LAYOUT` и `XKB_DEFAULT_OPTIONS` при запуске сеанса,
   поэтому новая раскладка вступает после перезапуска игрового режима. Другого пути у gamescope
   нет: раскладку физической клавиатуры в игровом режиме Steam не настраивает.
2. **Рабочий стол** — `~/.config/kxkbrc`, раздел `[Layout]`. Свои раскладки человека не
   стираются: недостающие языки дописываются в конец, своё переключение, если оно задано, не
   трогается. KDE перечитывает настройку по сигналу, без выхода из сеанса.

Корни папок передаются параметром: проверки подставляют временную папку.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

ENV_FILE = "60-steamdeck-kvm-keyboard.conf"
TOGGLE = "grp:alt_shift_toggle"

# Язык Windows -> раскладка XKB. Где у языка несколько стран, решает страна.
_BY_TAG = {"en-gb": "gb", "de-ch": "ch", "fr-ca": "ca", "fr-ch": "ch", "pt-br": "br", "en-ca": "us"}
_BY_LANG = {
    "en": "us", "ru": "ru", "uk": "ua", "be": "by", "kk": "kz", "de": "de", "fr": "fr", "es": "es",
    "it": "it", "pl": "pl", "pt": "pt", "tr": "tr", "cs": "cz", "sk": "sk", "sv": "se", "da": "dk",
    "nb": "no", "nn": "no", "fi": "fi", "nl": "nl", "el": "gr", "he": "il", "hu": "hu", "ro": "ro",
    "bg": "bg", "sr": "rs", "hr": "hr", "sl": "si", "lt": "lt", "lv": "lv", "et": "ee", "ka": "ge",
    "hy": "am", "az": "az", "uz": "uz", "tt": "ru(tt)", "ja": "jp", "ko": "kr", "ar": "ara", "fa": "ir",
}


_LATIN = ("us", "gb", "ca", "de", "fr", "es", "it", "pl", "pt", "br", "ch", "tr", "cz", "sk", "se", "dk", "no",
          "fi", "nl", "hu", "ro", "hr", "si", "lt", "lv", "ee", "az", "uz")


def layouts_from_languages(tags: str) -> list[str]:
    """`en-US,ru-RU` -> ['us', 'ru']. Незнакомые языки пропускаются, повторы — тоже."""
    found = []
    for tag in (tags or "").split(","):
        tag = tag.strip().lower()
        if not tag or tag == "-":
            continue
        layout = _BY_TAG.get(tag) or _BY_LANG.get(tag.split("-")[0])
        if layout and layout not in found:
            found.append(layout)
    # Латинская раскладка — первой, какой бы ни была первой на компьютере: игровой режим включает
    # первую раскладку списка, и с кириллицей первой часть игр перестаёт узнавать клавиши управления
    # (gamescope отдаёт играм символы, а не клавиши).
    latin = next((layout for layout in found if layout in _LATIN), None)
    if latin:
        found.remove(latin)
        found.insert(0, latin)
    return found


def _split(value: str) -> list[str]:
    return [part.strip() for part in value.split(",")] if value else []


class KeyboardLayoutSoldier:
    def __init__(self, config_home: str | Path | None = None, reload=None):
        self.config = Path(config_home) if config_home else Path.home() / ".config"
        self._reload = reload if reload is not None else self._reload_kde

    # ---- игровой режим --------------------------------------------------------

    def write_game_mode(self, layouts: list[str]) -> bool:
        """Прописать раскладки композитору игрового режима. Возвращает, изменился ли файл."""
        path = self.config / "environment.d" / ENV_FILE
        text = ("# Записано SteamDeck-KVM: раскладки как на компьютере, переключение Alt+Shift.\n"
                "XKB_DEFAULT_LAYOUT=%s\nXKB_DEFAULT_OPTIONS=%s\n" % (",".join(layouts), TOGGLE))
        try:
            if path.read_text(encoding="utf-8") == text:
                return False
        except OSError:
            pass
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return True

    # ---- рабочий стол -----------------------------------------------------------

    def write_desktop(self, layouts: list[str]) -> bool:
        """Дописать недостающие раскладки в настройку KDE. Возвращает, изменилась ли она."""
        path = self.config / "kxkbrc"
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError:
            lines = []
        start = next((i for i, line in enumerate(lines) if line.strip() == "[Layout]"), None)
        if start is None:
            if lines and lines[-1].strip():
                lines.append("")
            lines.append("[Layout]")
            start = len(lines) - 1
        end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("[")), len(lines))
        values = {}
        for line in lines[start + 1:end]:
            if "=" in line:
                key, value = line.split("=", 1)
                values[key.strip()] = value.strip()

        current = _split(values.get("LayoutList", "")) if values.get("Use", "false") == "true" else []
        merged = current + [layout for layout in layouts if layout not in current]
        variants = _split(values.get("VariantList", ""))
        options = _split(values.get("Options", ""))
        new = dict(values)
        new["LayoutList"] = ",".join(merged)
        new["VariantList"] = ",".join((variants + [""] * len(merged))[:len(merged)])
        new["Use"] = "true"
        if not any(option.startswith("grp:") for option in options):
            new["Options"] = ",".join(options + [TOGGLE])
            new["ResetOldOptions"] = "true"
        if new == values:
            return False
        body = ["%s=%s" % (key, value) for key, value in new.items()]
        lines[start + 1:end] = body + ([""] if end < len(lines) else [])
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(lines).rstrip("\n") + "\n", encoding="utf-8")
        return True

    @staticmethod
    def _reload_kde():
        try:
            subprocess.run(["dbus-send", "--session", "--type=signal", "/Layouts", "org.kde.keyboard.reloadConfig"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5, check=False)
        except (OSError, subprocess.SubprocessError):
            pass

    # ---- целиком ----------------------------------------------------------------

    def apply(self, languages: str) -> list[str]:
        """Раскладки по языкам компьютера в обоих режимах. Возвращает, что изменилось."""
        layouts = layouts_from_languages(languages)
        if not layouts:
            return []
        changed = []
        if self.write_game_mode(layouts):
            changed.append("game")
        if self.write_desktop(layouts):
            changed.append("desktop")
            self._reload()
        return changed
