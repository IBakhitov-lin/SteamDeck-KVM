# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Сборка выпуска SteamDeck-KVM: установщик Windows и ярлык установки Steam Deck
"""
build_release_script.py

Выпуск собирается этим скриптом и никогда руками. Файлов у выпуска ДВА — по одному на
платформу, и человек скачивает ровно один:

1. `SteamDeck-KVM-<версия>-windows-x64-setup.exe` — установщик Windows (Inno Setup): ставит
   приложение для текущего пользователя, заводит ярлыки и запускает; им же приложение обновляется
2. `SteamDeck-KVM-Install.desktop` — ярлык установки для Steam Deck: скачивает установщик из
   репозитория, а тот берёт программу из архива исходного кода последнего выпуска

Архивы исходного кода GitHub прикладывает к каждому выпуску сам — из них Steam Deck и ставится,
поэтому сборщик сверяет, что всё нужное Deck'у лежит в истории репозитория. Контрольную сумму
каждого файла выпуска считает GitHub (поле `digest`), отдельный файл сумм не нужен.
Третий файл `dist/RELEASE_NOTES.md` — текст выпуска для `gh release`, в выпуск не прикладывается.

Копии общих файлов берутся из папки общих исходников В МОМЕНТ СБОРКИ, если она задана настройкой
`steamdeck-kvm.shared-source`: копия, лежащая в репозитории месяцами, расходится с исходником
молча. Из копий вычищаются имена приватных проектов и пути рабочей машины — архив публичный.

Запуск:  python private_tools/scripts/build_release_script.py [--проверить]
Код возврата: 0 — собрано и сверено; 1 — сборка отклонена с названной причиной.
"""

from __future__ import annotations

import argparse
import os
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DIST = ROOT / "dist"
# Папка общих исходников сопровождающего — локальная настройка, в историю не попадает:
#     git config steamdeck-kvm.shared-source /path/to/shared
# Не задана — копии в apps/pc/lib и apps/palette.json берутся как есть.
def _shared_source() -> Path | None:
    try:
        value = subprocess.run(["git", "-C", str(ROOT), "config", "--get", "steamdeck-kvm.shared-source"],
                               capture_output=True, text=True,
                               creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0)).stdout.strip()
    except OSError as error:
        print("  git недоступен, общие исходники не ищутся: %s" % error)
        return None
    return Path(value) if value and Path(value).is_dir() else None


AI = _shared_source()
POWERSHELL = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"

# Имена и пути, которым не место в публичном архиве, строками здесь НЕ хранятся — иначе их
# уносил бы наружу сам сборщик. Они берутся на лету тем же исполнителем, что стережёт
# публичный репозиторий: имена приватных репозиториев владельца — у GitHub, путь рабочей папки
# и профиля — от расположения этого репозитория (`scripts/check-github-repo.py` общих исходников).
PRIVATE_WORDS = []


def load_private_words():
    checker = AI / "scripts" / "check-github-repo.py" if AI else None
    if checker is None or not checker.is_file():
        return
    import importlib.util
    spec = importlib.util.spec_from_file_location("check_github_repo", checker)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    for label, pattern in module._author_markers(ROOT, module.private_repo_names(ROOT)):
        word = "соседний проект" if label.startswith("имя") else "<рабочая папка>"
        PRIVATE_WORDS.append((re.compile(pattern.pattern + r"[^\s`'\")]*" if not label.startswith("имя") else pattern.pattern,
                                         pattern.flags), word))
    PRIVATE_WORDS.append((re.compile(r"(?i)[a-z]:[\\/]+users[\\/]+[^\\/\s`'\")]+"), "<папка пользователя>"))

PALETTE_KEYS = ("тёмная", "светлая", "типографика", "радиусы", "значок")


def fail(message: str) -> int:
    print("СБОРКА ОТКЛОНЕНА: " + message)
    return 1


def detach(text: str) -> str:
    """Копия в архиве ищет палитру рядом с собой, а пути общих исходников становятся именами файлов."""
    if AI is not None:
        base = re.escape(str(AI).rstrip("\\/"))
        text = re.sub("'" + base + r"[\\/]templates[\\/]palette\.json'", "(Join-Path $PSScriptRoot 'palette.json')", text,
                      flags=re.IGNORECASE)
        text = re.sub(base + r"[\\/](?:[\w.-]+[\\/])*([\w.-]+)", r"\1", text, flags=re.IGNORECASE)
    return text


def sanitize(text: str) -> str:
    for pattern, replacement in PRIVATE_WORDS:
        text = pattern.sub(replacement, text)
    return text


def refresh_vendored_copies() -> list[str]:
    """Обновить копии общих файлов в репозитории из общих исходников; не заданы — копии остаются как есть."""
    notes = []
    if AI is None:
        return ["общие исходники не заданы — копии общих файлов взяты из репозитория как есть"]
    pairs = [
        (AI / "scripts" / "lib" / "tray-common.ps1", ROOT / "apps" / "pc" / "lib" / "tray-common.ps1"),
        (AI / "scripts" / "tray-place.ps1", ROOT / "apps" / "pc" / "lib" / "tray-place.ps1"),
    ]
    for source, target in pairs:
        if not source.is_file():
            notes.append("нет исходника %s — копия не обновлена" % source)
            continue
        text = source.read_bytes().decode("utf-8-sig")
        header = "# КОПИЯ общего модуля, собранная build_release_script.py из общего исходника.\n" \
                 "# Правится исходник, а не копия: копия перезаписывается при каждой сборке выпуска.\n"
        target.parent.mkdir(parents=True, exist_ok=True)
        # Скрипт PowerShell с кириллицей обязан нести метку кодировки — иначе интерпретатор читает
        # его как однобайтовый и спотыкается на первой же русской строке.
        target.write_bytes(b"\xef\xbb\xbf" + (header + detach(sanitize(text))).encode("utf-8"))
        notes.append("копия обновлена: %s" % target.relative_to(ROOT))

    palette_source = AI / "templates" / "palette.json"
    if palette_source.is_file():
        data = json.loads(palette_source.read_text(encoding="utf-8-sig"))
        public = {"_назначение": "Копия контракта палитры для публичного репозитория: цвета, гарнитура, радиусы и "
                                 "значок. Собирается build_release_script.py из общего исходника; у себя эту копию "
                                 "можно менять свободно — вид приложения поменяется только у вас."}
        public.update({key: data[key] for key in PALETTE_KEYS if key in data})
        (ROOT / "apps" / "palette.json").write_text(json.dumps(public, ensure_ascii=False, indent=2) + "\n",
                                                     encoding="utf-8")
        notes.append("копия палитры обновлена: apps/palette.json")
    return notes


def build_icons() -> None:
    """Значок .ico для Windows и .png для Deck'а — ОДИН рисунок одной функцией оболочки окна."""
    script = (
        "$ErrorActionPreference='Stop'; . '%s'; "
        "Собрать-Ico '%s'; "
        "$bmp = Новый-Значок 256; $bmp.Save('%s', [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()"
    ) % (ROOT / "apps" / "pc" / "app-window.ps1",
         ROOT / "apps" / "pc" / "SteamDeck-KVM.ico",
         ROOT / "apps" / "deck" / "steamdeck-kvm.png")
    subprocess.run([POWERSHELL, "-NoProfile", "-NonInteractive", "-Command", script], check=True,
                   capture_output=True, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))


def _skip(path: Path) -> bool:
    return "__pycache__" in path.parts or path.suffix in (".pyc", ".lnk")


PC_REQUIRED = ("SteamDeck-KVM.vbs", "SteamDeck-KVM.ps1", "app-window.ps1", "app-update.ps1",
               "lib/tray-common.ps1", "lib/tray-place.ps1", "lib/palette.json", "VERSION",
               "SteamDeck-KVM.ico", "LICENSE")


def find_iscc() -> Path | None:
    """Компилятор Inno Setup: из PATH либо из обычных мест установки."""
    found = shutil.which("ISCC")
    candidates = [Path(found)] if found else []
    candidates += [Path(os.environ.get("LOCALAPPDATA", "")) / "Programs" / "Inno Setup 6" / "ISCC.exe",
                   Path(r"C:\Program Files (x86)\Inno Setup 6\ISCC.exe"),
                   Path(r"C:\Program Files\Inno Setup 6\ISCC.exe")]
    return next((path for path in candidates if path.is_file()), None)


def stage_pc(version: str, stage: Path) -> list[str]:
    """Разложить приложение ПК во временную папку так, как оно ляжет на машину человека."""
    pc = ROOT / "apps" / "pc"
    for path in sorted(pc.rglob("*")):
        if path.is_file() and not _skip(path):
            target = stage / path.relative_to(pc)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)
    shutil.copyfile(ROOT / "apps" / "palette.json", stage / "lib" / "palette.json")
    (stage / "VERSION").write_text(version + "\n", encoding="utf-8")
    shutil.copyfile(ROOT / "LICENSE", stage / "LICENSE")
    problems = ["в установщик ПК не попал %s" % need for need in PC_REQUIRED if not (stage / need).is_file()]
    home = str(Path.home())
    workspace = str(ROOT.parent)
    markers = {home, home.replace("\\", "/"), workspace, workspace.replace("\\", "/")}
    for path in stage.rglob("*"):
        if path.is_file():
            data = path.read_bytes()
            if any(marker and marker.encode("utf-8") in data for marker in markers):
                problems.append("в установщик ПК попал путь машины сборки: %s" % path.relative_to(stage))
    return problems


def build_pc(version: str) -> tuple[Path, list[str]]:
    setup = DIST / ("SteamDeck-KVM-%s-windows-x64-setup.exe" % version)
    iscc = find_iscc()
    if iscc is None:
        return setup, ["нет Inno Setup 6 — поставьте: winget install JRSoftware.InnoSetup"]
    with tempfile.TemporaryDirectory(prefix="steamdeck-kvm-pc-") as folder:
        stage = Path(folder)
        problems = stage_pc(version, stage)
        if problems:
            return setup, problems
        completed = subprocess.run(
            [str(iscc), "/Q", "/DAppVersion=%s" % version, "/DSourceDir=%s" % stage, "/DOutputDir=%s" % DIST,
             str(ROOT / "private_tools" / "installer" / "steamdeck-kvm-setup.iss")],
            capture_output=True, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        if completed.returncode != 0:
            text = (completed.stdout + completed.stderr).decode("utf-8", "replace")[-1500:]
            return setup, ["Inno Setup не собрал установщик: %s" % text]
    return setup, []


DECK_REQUIRED = ("apps/deck/install.sh", "apps/deck/uninstall.sh", "apps/deck/steamdeck_kvm_service.py",
                 "apps/deck/steamdeck-kvm-app.qml", "apps/deck/steamdeck-kvm-app.sh", "apps/deck/steamdeck-kvm.service",
                 "apps/deck/steamdeck-kvm.png", "apps/palette.json", "core/config_policy.py", "VERSION")


def verify(version: str, pc: Path, desktop: Path) -> list[str]:
    """Сверить собранное с тем, что обещают установщики и обновление. Пустой список — чисто."""
    problems = []
    if not pc.is_file() or pc.read_bytes()[:2] != b"MZ":
        problems.append("установщик ПК %s не собран" % pc.name)
    if not desktop.is_file() or b"raw.githubusercontent.com" not in desktop.read_bytes():
        problems.append("ярлык установки Steam Deck не собран или не ведёт на установщик")
    tracked = set(subprocess.run(["git", "-C", str(ROOT), "ls-files"], capture_output=True, text=True,
                                 creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0)).stdout.split())
    for need in DECK_REQUIRED:
        if need not in tracked:
            problems.append("в истории репозитория нет %s — архив исходного кода выпуска не поставит Deck" % need)
    committed = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    if committed != version:
        problems.append("VERSION %s расходится со сборкой %s" % (committed, version))
    return problems

def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except AttributeError:
        pass
    parser = argparse.ArgumentParser(description="Сборка выпуска SteamDeck-KVM")
    parser.add_argument("--проверить", action="store_true", help="только сверить уже собранное в dist/")
    args = parser.parse_args()

    version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        return fail("VERSION «%s» — не версия вида 1.2.3" % version)
    notes_file = ROOT / "private_tools" / "releases" / ("v%s.md" % version)
    if not notes_file.is_file():
        return fail("нет текста выпуска %s — выпуск без описания не собирается" % notes_file.relative_to(ROOT))

    pc = DIST / ("SteamDeck-KVM-%s-windows-x64-setup.exe" % version)
    desktop = DIST / "SteamDeck-KVM-Install.desktop"

    if not args.проверить:
        load_private_words()
        for note in refresh_vendored_copies():
            print("  " + note)
        build_icons()
        if DIST.exists():
            shutil.rmtree(DIST)
        DIST.mkdir()
        pc, build_problems = build_pc(version)
        if build_problems:
            for problem in build_problems:
                print("  НАХОДКА: " + problem)
            return 1
        desktop.write_bytes((ROOT / "apps" / "deck" / "SteamDeck-KVM-Install.desktop").read_bytes().replace(b"\r\n", b"\n"))
        shutil.copyfile(notes_file, DIST / "RELEASE_NOTES.md")

    problems = verify(version, pc, desktop)
    print("ЧИСЛА ПРИЁМКИ: версия %s, файлов выпуска 2, установщик ПК %d КБ, находок %d" % (
        version, pc.stat().st_size // 1024 if pc.is_file() else 0, len(problems)))
    for problem in problems:
        print("  НАХОДКА: " + problem)
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
