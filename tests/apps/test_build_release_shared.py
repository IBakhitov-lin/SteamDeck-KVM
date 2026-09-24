# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Сборщик кладёт общую библиотеку и палитру из общих исходников: с пометкой, без путей машины
"""Файлы общей библиотеки попадают в выпуск и в apps/pc/lib только из общих исходников и только сборщиком.

Каждый случай сначала строит папку общих исходников во временной папке, потом зовёт сборщик.
"""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import pytest

СБОРЩИК = Path(__file__).resolve().parents[2] / "private_tools" / "scripts" / "build_release_script.py"


def загрузить(общие: Path):
    spec = importlib.util.spec_from_file_location("build_release_script", СБОРЩИК)
    модуль = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(модуль)
    модуль.AI = общие
    return модуль


@pytest.fixture()
def общие(tmp_path: Path) -> Path:
    корень = tmp_path / "shared"
    библиотека = корень / ".code" / "scripts" / "lib"
    библиотека.mkdir(parents=True)
    for имя in ("tray-common.ps1", "tray-place.ps1", "app-shell.ps1"):
        (библиотека / имя).write_text("function Проба { '%s' }\n" % (корень / "templates" / "palette.json"), encoding="utf-8")
    (корень / "templates").mkdir()
    (корень / "templates" / "palette.json").write_text(json.dumps(
        {"тёмная": {"фон": "#151517"}, "оболочка": {"окно_кнопка": 28}, "стекло": {"плотность": 0.6},
         "_приватное": 1}, ensure_ascii=False), encoding="utf-8")
    return корень


def test_stage_shared_puts_every_library_file_with_mark_and_palette(общие: Path, tmp_path: Path):
    сборщик = загрузить(общие)
    цель = tmp_path / "stage" / "lib"
    сборщик.stage_shared(цель)
    имена = sorted(p.name for p in цель.iterdir())
    assert имена == ["app-shell.ps1", "palette.json", "tray-common.ps1", "tray-place.ps1"]
    текст = (цель / "app-shell.ps1").read_bytes()
    assert текст.startswith(b"\xef\xbb\xbf")
    assert "Правится исходник, а не он" in текст.decode("utf-8-sig")
    assert str(общие) not in текст.decode("utf-8-sig")


def test_public_palette_keeps_shell_numbers_and_drops_private_fields(общие: Path):
    данные = json.loads(загрузить(общие).public_palette().decode("utf-8"))
    assert данные["оболочка"]["окно_кнопка"] == 28
    assert "_приватное" not in данные, "служебные поля контракта (имя с «_») в копию не идут"
    assert данные["стекло"]["плотность"] == 0.6, "новый раздел контракта переносится без правки сборщика"


def test_stage_shared_without_palette_for_repository_lib(общие: Path, tmp_path: Path):
    цель = tmp_path / "repo" / "lib"
    загрузить(общие).stage_shared(цель, with_palette=False)
    assert not (цель / "palette.json").exists()
