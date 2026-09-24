# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Проверка окон приложения ПК: главное окно, настройки и журнал собраны без обрезов и наложений
"""
test_pc_window_layout.py

Гоняет сторожа компоновки `private_tools/scripts/check_window_layout_script.ps1`: он собирает в
памяти ТЕ ЖЕ окна, что видит человек (`apps/pc/app-window.ps1`), — главное на четырёх ширинах,
окно настроек и окно журнала — и ищет вылезшее за край, наложенное и обрезанное. На экране
ничего не появляется. Тест держит сторожа в наборе: правка окна без его прогона не проходит.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "private_tools" / "scripts" / "check_window_layout_script.ps1"
POWERSHELL = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"

pytestmark = pytest.mark.skipif(sys.platform != "win32", reason="окно приложения ПК — Windows Forms")


def test_windows_have_no_clipped_or_overlapping_parts():
    done = subprocess.run([POWERSHELL, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                           "-File", str(CHECKER)], capture_output=True, timeout=300,
                          creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    output = done.stdout.decode("utf-8", "replace")
    found = re.search(r"проверок: (\d+); нарушений: (\d+)", output)
    assert found, output[-2000:] + done.stderr.decode("utf-8", "replace")[-2000:]
    assert done.returncode == 0 and found.group(2) == "0", output[-3000:]
    assert int(found.group(1)) > 400, "проверок подозрительно мало: сторож проверил не всё окно (при правке окна — порог сверить с числом прогона)"
