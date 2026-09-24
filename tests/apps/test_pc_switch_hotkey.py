# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Проверка перехода на ПК: раскладка сервера по настройкам и служебные клавиши вместо сочетаний для человека
"""
test_pc_switch_hotkey.py

Сочетание для человека одно — Alt+Tab: окно «Steam Deck» в списке на ПК и Alt+Tab на Deck'е. Его
Windows горячей клавишей не отдаёт, поэтому переход делает приложение, нажимая программой
служебное сочетание сервера на F23/F24 (таких клавиш на клавиатурах нет). Край экрана — раздел
links, он есть только при включённом крае. Функция `Текст-Раскладки` берётся из самого
приложения разбором PowerShell и вызывается настоящим интерпретатором; что сервер ловит
служебную клавишу, проверено живым сервером (замер 23.09.2026) и здесь не повторяется.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
APP_PATH = ROOT / "apps" / "pc" / "SteamDeck-KVM.ps1"
APP = APP_PATH.read_text(encoding="utf-8-sig")
POWERSHELL = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"


def layout(edge: bool, side: str) -> str:
    """Текст раскладки из настоящей функции приложения."""
    script = (
        "$ErrorActionPreference='Stop'; [Console]::OutputEncoding=[Text.Encoding]::UTF8; "
        "$ast=[System.Management.Automation.Language.Parser]::ParseFile('%s',[ref]$null,[ref]$null); "
        "$f=$ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] "
        "-and $n.Name -eq 'Текст-Раскладки'}, $true) | Select-Object -First 1; "
        "if (-not $f) { throw 'нет функции Текст-Раскладки' }; Invoke-Expression $f.Extent.Text; "
        "Текст-Раскладки 'MYPC' '# метка' $%s '%s' | ConvertTo-Json"
    ) % (APP_PATH, "true" if edge else "false", side)
    done = subprocess.run([POWERSHELL, "-NoProfile", "-NonInteractive", "-Command", script],
                          capture_output=True, timeout=120,
                          creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    assert done.returncode == 0, done.stderr.decode("utf-8", "replace")
    return json.loads(done.stdout.decode("utf-8", "replace"))


pytestmark = pytest.mark.skipif(sys.platform != "win32", reason="приложение ПК — Windows PowerShell")


def keystrokes(text: str):
    return re.findall(r"(?m)^\s*keystroke\(([^)]*)\)\s*=\s*(\S+)", text)


def test_only_service_keys_no_human_combinations():
    text = layout(True, "right")
    assert keystrokes(text) == [("Control+Alt+Shift+F23", "switchToScreen(steamdeck)"),
                                ("Control+Alt+Shift+F24", "switchToScreen(MYPC)")], keystrokes(text)


def test_edge_on_gives_links_on_the_chosen_side():
    right = layout(True, "right")
    left = layout(True, "left")
    assert re.search(r"MYPC:\s*\n\s*right = steamdeck", right) and re.search(r"steamdeck:\s*\n\s*left = MYPC", right)
    assert re.search(r"MYPC:\s*\n\s*left = steamdeck", left)


def test_edge_off_has_no_links_but_keeps_service_keys():
    text = layout(False, "right")
    assert "section: links" not in text
    assert len(keystrokes(text)) == 2


def test_layout_label_carries_settings_so_changes_rebuild():
    assert "$МеткаРаскладки = '# steamdeck-kvm-layout v4'" in APP
    assert "'{0} edge={1} side={2}' -f $МеткаРаскладки" in APP


def test_no_old_combinations_left():
    for old in ("switchInDirection", "Control+Alt+Return", "switchToNextScreen", "Ctrl+Alt+Enter", "Ctrl+Alt+→"):
        assert old not in APP, old


def test_alt_tab_window_and_deck_request_are_wired():
    assert "$deckForm.Text = 'Steam Deck'" in APP and "Перейти-На-Deck 'Alt+Tab" in APP
    assert "-eq 'TOPC'" in APP and "Вернуть-На-ПК" in APP
