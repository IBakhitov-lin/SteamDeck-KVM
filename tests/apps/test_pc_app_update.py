# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Проверки обновления приложения ПК: выбор выпуска, сверка суммы установщика
"""
test_pc_app_update.py

Запускает настоящий модуль `apps/pc/app-update.ps1` в Windows PowerShell без окна: модуль читается
точкой, функции зовутся на подготовленных данных, итог возвращается строкой JSON.
"""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
MODULE = ROOT / "apps" / "pc" / "app-update.ps1"
POWERSHELL = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"

pytestmark = pytest.mark.skipif(sys.platform != "win32", reason="приложение ПК — Windows PowerShell")


def run_ps(body: str) -> dict:
    script = "$ErrorActionPreference='Stop'; . '%s'; %s" % (MODULE, body)
    completed = subprocess.run([POWERSHELL, "-NoProfile", "-NonInteractive", "-Command",
                                "[Console]::OutputEncoding=[Text.Encoding]::UTF8; " + script],
                               capture_output=True, timeout=120,
                               creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    output = completed.stdout.decode("utf-8", "replace").strip().splitlines()
    assert completed.returncode == 0, completed.stderr.decode("utf-8", "replace")
    return json.loads(output[-1])


def release(tag, with_sums=True, archive="SteamDeck-KVM-1.2.0-windows-x64-setup.exe"):
    asset = {"name": archive, "browser_download_url": "http://x/a"}
    if with_sums:
        asset["digest"] = "sha256:" + "ab" * 32
    assets = [asset]
    return {"tag_name": tag, "assets": assets, "body": "## Мышь в игровом режиме\n- подробности"}


def choose(payload, current):
    data = json.dumps(payload, ensure_ascii=False).replace("'", "''")
    return run_ps("$r = Выбрать-Обновление ('%s' | ConvertFrom-Json) '%s'; "
                  "if ($r) { $r.Remove('Архив'); $r | ConvertTo-Json -Compress } else { '{}' }"
                  % (data, current))


def test_newer_release_is_chosen_with_note():
    result = choose(release("v1.2.0"), "1.0.0")
    assert result == {"Версия": "1.2.0", "Заметка": "Мышь в игровом режиме", "Сумма": "AB" * 32}


def test_same_older_or_unparsable_release_is_not_chosen():
    assert choose(release("v1.0.0"), "1.0.0") == {}
    assert choose(release("v0.9.0"), "1.0.0") == {}
    assert choose(release("nightly"), "1.0.0") == {}


def test_release_without_sums_is_reported_as_skip():
    result = choose(release("v2.0.0", with_sums=False), "1.0.0")
    assert "Пропуск" in result and "без установщика" in result["Пропуск"]


def test_release_with_only_old_zip_is_skipped():
    result = choose(release("v2.0.0", archive="SteamDeck-KVM-2.0.0-windows-x64.zip"), "1.0.0")
    assert "Пропуск" in result and "без установщика" in result["Пропуск"]


def make_setup(folder: Path, body: bytes = b"MZ" + b"\x90" * 64, name="SteamDeck-KVM-1.2.0-windows-x64-setup.exe") -> Path:
    setup = folder / name
    setup.write_bytes(body)
    return setup


def verify(setup: Path, digest: str) -> dict:
    return run_ps("try { Проверить-Установщик -Установщик '%s' -Сумма '%s' | Out-Null; '{\"ok\":true}' } "
                  "catch { @{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress }"
                  % (setup, digest))


def test_good_installer_passes(tmp_path):
    setup = make_setup(tmp_path)
    assert verify(setup, hashlib.sha256(setup.read_bytes()).hexdigest()) == {"ok": True}


def test_checksum_mismatch_is_refused(tmp_path):
    setup = make_setup(tmp_path)
    result = verify(setup, "0" * 64)
    assert result["ok"] is False and "сумма" in result["error"]


def test_installer_without_checksum_is_refused(tmp_path):
    setup = make_setup(tmp_path)
    result = verify(setup, "")
    assert result["ok"] is False and "нет контрольной суммы" in result["error"]


def test_non_executable_with_matching_sum_is_refused(tmp_path):
    setup = make_setup(tmp_path, body=b"<html>not found</html>")
    result = verify(setup, hashlib.sha256(setup.read_bytes()).hexdigest())
    assert result["ok"] is False and "не исполняемый" in result["error"]
