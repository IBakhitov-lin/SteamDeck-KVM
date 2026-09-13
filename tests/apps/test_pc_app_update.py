# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Проверки обновления приложения ПК: выбор выпуска, сверка суммы, раскладка без порчи папки
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
import zipfile
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


def release(tag, with_sums=True, archive="SteamDeck-KVM-1.2.0-windows-x64.zip"):
    assets = [{"name": archive, "browser_download_url": "http://x/a"}]
    if with_sums:
        assets.append({"name": "SHA256SUMS.txt", "browser_download_url": "http://x/s"})
    return {"tag_name": tag, "assets": assets, "body": "## Мышь в игровом режиме\n- подробности"}


def choose(payload, current):
    data = json.dumps(payload, ensure_ascii=False).replace("'", "''")
    return run_ps("$r = Выбрать-Обновление ('%s' | ConvertFrom-Json) '%s'; "
                  "if ($r) { $r.Remove('Архив'); $r.Remove('Суммы'); $r | ConvertTo-Json -Compress } else { '{}' }"
                  % (data, current))


def test_newer_release_is_chosen_with_note():
    result = choose(release("v1.2.0"), "1.0.0")
    assert result == {"Версия": "1.2.0", "Заметка": "Мышь в игровом режиме"}


def test_same_older_or_unparsable_release_is_not_chosen():
    assert choose(release("v1.0.0"), "1.0.0") == {}
    assert choose(release("v0.9.0"), "1.0.0") == {}
    assert choose(release("nightly"), "1.0.0") == {}


def test_release_without_sums_is_reported_as_skip():
    result = choose(release("v2.0.0", with_sums=False), "1.0.0")
    assert "Пропуск" in result and "без архива" in result["Пропуск"]


def make_zip(folder: Path, version: str, name="SteamDeck-KVM-1.2.0-windows-x64.zip") -> Path:
    archive = folder / name
    with zipfile.ZipFile(archive, "w") as zf:
        zf.writestr("SteamDeck-KVM-%s-windows-x64/SteamDeck-KVM.ps1" % version, "# новая версия\n")
        zf.writestr("SteamDeck-KVM-%s-windows-x64/VERSION" % version, version + "\n")
        zf.writestr("SteamDeck-KVM-%s-windows-x64/lib/palette.json" % version, "{}")
    return archive


def lay(archive: Path, sums: str, version: str, program: Path) -> dict:
    return run_ps("try { Разложить-Обновление -Архив '%s' -ТекстСумм '%s' -Версия '%s' -ПапкаПрограммы '%s' | Out-Null; "
                  "'{\"ok\":true}' } catch { @{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress }"
                  % (archive, sums.replace("'", "''"), version, program))


def test_good_archive_replaces_program_files(tmp_path):
    program = tmp_path / "program"
    program.mkdir()
    (program / "SteamDeck-KVM.ps1").write_text("# старая версия\n", encoding="utf-8")
    archive = make_zip(tmp_path, "1.2.0")
    sums = "%s  %s\n" % (hashlib.sha256(archive.read_bytes()).hexdigest(), archive.name)
    assert lay(archive, sums, "1.2.0", program) == {"ok": True}
    assert (program / "SteamDeck-KVM.ps1").read_text(encoding="utf-8") == "# новая версия\n"
    assert (program / "lib" / "palette.json").exists()


def test_checksum_mismatch_leaves_program_untouched(tmp_path):
    program = tmp_path / "program"
    program.mkdir()
    (program / "SteamDeck-KVM.ps1").write_text("# старая версия\n", encoding="utf-8")
    archive = make_zip(tmp_path, "1.2.0")
    result = lay(archive, "0" * 64 + "  " + archive.name, "1.2.0", program)
    assert result["ok"] is False and "сумма" in result["error"]
    assert (program / "SteamDeck-KVM.ps1").read_text(encoding="utf-8") == "# старая версия\n"


def test_version_mismatch_is_refused(tmp_path):
    program = tmp_path / "program"
    program.mkdir()
    archive = make_zip(tmp_path, "1.1.0")
    sums = "%s  %s\n" % (hashlib.sha256(archive.read_bytes()).hexdigest(), archive.name)
    result = lay(archive, sums, "1.2.0", program)
    assert result["ok"] is False and "ожидалась 1.2.0" in result["error"]
    assert not (program / "SteamDeck-KVM.ps1").exists()
