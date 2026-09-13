# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Архитектурные сторожа SteamDeck-KVM: паспорт, суффиксы ролей, импорты, README папок
"""
test_layout.py

Канон слоёв кода (Soldier → Officer → Commander) действует здесь в части структуры, и держит его
этот файл, а не внимательность. Улучшения ломают устройство незаметно: солдат зовёт офицера,
модуль теряет паспорт, в корне ядра появляется файл без роли — ни один тест поведения от этого
не падает.

Слой — устройство, глубина — функциональная: каждое правило проверяется на всех файлах дерева,
и нарушение называется поимённо.
"""

from __future__ import annotations

import ast
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SKIP_PARTS = {".git", "__pycache__", ".pytest_cache", "dist", ".agents", ".trash", ".githooks"}

ROLE_SUFFIX = {
    "core/soldiers": ("_soldier.py", "Soldier"),
    "core/officers": ("_officer.py", "Officer"),
    "core/officers/intelligence": ("_sensor.py", "Sensor"),
    "core/commanders": ("_commander.py", "Commander"),
    "core/dto": ("_dto.py", "DTO"),
}
# Корень ядра — только инфраструктура по исключению канона слоёв: политика
# конфигурации и фасады. Всё остальное обязано иметь роль и жить в папке роли.
CORE_ROOT_ALLOWED = {"__init__.py", "config_policy.py", "control_api_facade.py"}

# Кто кого может импортировать (§9). Слева — папка файла, справа — запрещённые префиксы импорта.
FORBIDDEN_IMPORTS = {
    "core/soldiers": ("core.officers", "core.commanders", "apps", "private_tools"),
    "core/officers": ("core.commanders", "apps", "private_tools"),
    "core/dto": ("core.soldiers", "core.officers", "core.commanders", "apps", "private_tools"),
    "core": ("apps", "private_tools"),
}


def tracked_files(suffix):
    for path in ROOT.rglob("*" + suffix):
        parts = set(path.relative_to(ROOT).parts)
        if parts & SKIP_PARTS:
            continue
        yield path


def rel(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def test_every_python_module_has_passport():
    missing = []
    for path in tracked_files(".py"):
        first = path.read_text(encoding="utf-8").splitlines()[:1]
        if not first or not first[0].startswith("# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — "):
            missing.append(rel(path))
    assert missing == [], "без паспорта модуля первой строкой: %s" % missing


def test_role_folders_use_role_suffix_and_class_suffix():
    problems = []
    for folder, (file_suffix, class_suffix) in ROLE_SUFFIX.items():
        for path in (ROOT / folder).glob("*.py"):
            if path.name == "__init__.py":
                continue
            if not path.name.endswith(file_suffix):
                problems.append("%s — в папке роли без суффикса %s" % (rel(path), file_suffix))
                continue
            classes = [node.name for node in ast.parse(path.read_text(encoding="utf-8")).body
                       if isinstance(node, ast.ClassDef)]
            if not any(name.endswith(class_suffix) for name in classes):
                problems.append("%s — нет класса с суффиксом %s" % (rel(path), class_suffix))
    assert problems == [], problems


def test_core_root_holds_only_infrastructure():
    extra = sorted(path.name for path in (ROOT / "core").glob("*.py") if path.name not in CORE_ROOT_ALLOWED)
    assert extra == [], "в корне core/ файлы без роли: %s" % extra


def test_import_matrix():
    problems = []
    for path in tracked_files(".py"):
        folder = rel(path.parent)
        rules = next((FORBIDDEN_IMPORTS[key] for key in sorted(FORBIDDEN_IMPORTS, key=len, reverse=True)
                      if folder == key or folder.startswith(key + "/")), None)
        if rules is None:
            continue
        for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
            names = []
            if isinstance(node, ast.Import):
                names = [alias.name for alias in node.names]
            elif isinstance(node, ast.ImportFrom) and node.module:
                names = [node.module]
            for name in names:
                if any(name == banned or name.startswith(banned + ".") for banned in rules):
                    problems.append("%s импортирует %s" % (rel(path), name))
    assert problems == [], problems


def test_every_folder_has_readme():
    missing = []
    for path in ROOT.rglob("*"):
        if not path.is_dir():
            continue
        parts = set(path.relative_to(ROOT).parts)
        if parts & SKIP_PARTS or path == ROOT:
            continue
        if not (path / "README.md").is_file():
            missing.append(rel(path))
    assert missing == [], "папки без README.md: %s" % missing


def test_root_holds_only_canonical_entries():
    allowed_dirs = {"apps", "core", "private_tools", "tests", ".agents", ".git", ".githooks", ".trash", "dist",
                    ".pytest_cache", "__pycache__"}
    allowed_files = {"README.md", "README.ru.md", "LICENSE", "VERSION", ".gitignore", ".gitattributes",
                     "Общая клавиатура и мышь.lnk", "AGENTS.local.md", "CLAUDE.local.md"}
    extra = sorted(path.name for path in ROOT.iterdir()
                   if (path.is_dir() and path.name not in allowed_dirs)
                   or (path.is_file() and path.name not in allowed_files))
    assert extra == [], "в корне лишнее: %s" % extra
