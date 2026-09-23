# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Проверки окна «Steam Deck» для Alt+Tab на ПК: сторона Deck'а по раскладке экранов
"""
test_pc_deck_window.py

Функция выбора стороны вынимается из настоящего `apps/pc/SteamDeck-KVM.ps1` разбором PowerShell и
зовётся на подготовленной раскладке: курсор обязан уйти в тот край, где Deck стоит у сервера.
Само окно в списке Alt+Tab и уход курсора за край проверяются только на машине с запущенным сервером.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "pc" / "SteamDeck-KVM.ps1"
POWERSHELL = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"

pytestmark = pytest.mark.skipif(sys.platform != "win32", reason="приложение ПК — Windows PowerShell")


def side(conf_text, tmp_path, name="ILNUR"):
    conf = tmp_path / "screens.conf"
    if conf_text is not None:
        conf.write_text(conf_text, encoding="utf-8")
    script = (
        "$ErrorActionPreference='Stop'; $e=$null; $t=$null; "
        "$ast=[System.Management.Automation.Language.Parser]::ParseFile('%s',[ref]$t,[ref]$e); "
        "$f=$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] "
        "-and $n.Name -eq 'Сторона-Deck' }, $true) | Select-Object -First 1; "
        "if (-not $f) { throw 'нет функции' }; "
        "function Write-Log($x) {}; $ScreensConf='%s'; $env:COMPUTERNAME='%s'; "
        ". ([scriptblock]::Create($f.Extent.Text)); Сторона-Deck"
    ) % (APP, conf, name)
    done = subprocess.run([POWERSHELL, "-NoProfile", "-NonInteractive", "-Command",
                           "[Console]::OutputEncoding=[Text.Encoding]::UTF8; " + script],
                          capture_output=True, timeout=120, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    assert done.returncode == 0, done.stderr.decode("utf-8", "replace")
    return done.stdout.decode("utf-8", "replace").strip().splitlines()[-1]


def layout(side_name):
    back = "left" if side_name == "right" else "right"
    return ("section: links\n\tILNUR:\n\t\t%s = steamdeck\n\tsteamdeck:\n\t\t%s = ILNUR\nend\n" % (side_name, back))


def test_deck_on_the_right_by_default(tmp_path):
    assert side(layout("right"), tmp_path) == "right"


def test_deck_on_the_left_follows_layout(tmp_path):
    assert side(layout("left"), tmp_path) == "left"


def test_missing_layout_falls_back_to_right(tmp_path):
    assert side(None, tmp_path) == "right"


def test_window_is_listed_for_alt_tab_and_jumps_on_activation():
    text = APP.read_text(encoding="utf-8-sig")
    assert "$deckForm.ShowInTaskbar = $true" in text
    assert "$deckForm.Add_Activated({ Перейти-На-Deck })" in text
    assert "$focusTimer.Start()" in text
