# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Сборка выпуска SteamDeck-KVM: установщик Windows и ярлык установки Steam Deck
"""
build_release_script.py

Выпуск собирается этим скриптом и никогда руками. Файлов у выпуска ДВА — по одному на
платформу, и человек скачивает ровно один:

1. `SteamDeck-KVM-<версия>-windows-x64-setup.exe` — установщик Windows (Inno Setup): ставит
   приложение для текущего пользователя, заводит ярлыки и запускает; им же приложение обновляется
2. `SteamDeck-KVM-Install.desktop` — ярлык установки для Steam Deck. Программа лежит В НЁМ ЖЕ:
   архив tar.gz строками «#P <base64>» после записи ярлыка (строки с «#» — комментарии, рабочий
   стол их не читает). Ярлык распаковывает её и запускает установщик — интернет не нужен.
   Обновление на Deck'е скачивает этот же ярлык последнего выпуска с github.com

Почему программа внутри ярлыка, а не отдельным скачиванием. На Steam Deck пользователя
raw.githubusercontent.com недоступен, а github.com открывается: ярлык, скачанный браузером,
дошёл, а установщик, который он качал с raw, — нет. Контрольную сумму каждого файла выпуска
считает GitHub (поле `digest`), отдельный файл сумм не нужен.
Третий файл `dist/RELEASE_NOTES.md` — текст выпуска для `gh release`, в выпуск не прикладывается.

Копии общих файлов берутся из папки общих исходников В МОМЕНТ СБОРКИ, если она задана настройкой
`steamdeck-kvm.shared-source`: копия, лежащая в репозитории месяцами, расходится с исходником
молча. Из копий вычищаются имена приватных проектов и пути рабочей машины — архив публичный.

Запуск:  python private_tools/scripts/build_release_script.py [--проверить | --копии]
Код возврата: 0 — собрано и сверено; 1 — сборка отклонена с названной причиной.
"""

from __future__ import annotations

import argparse
import base64
import io
import os
import tarfile
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
    checker = AI / ".code" / "scripts" / "checks" / "check-github-repo.py" if AI else None
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

PALETTE_KEYS = ("тёмная", "светлая", "типографика", "радиусы", "значок", "оболочка")


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
        (AI / ".code" / "scripts" / "lib" / "tray-common.ps1", ROOT / "apps" / "pc" / "lib" / "tray-common.ps1"),
        (AI / ".code" / "scripts" / "lib" / "tray-place.ps1", ROOT / "apps" / "pc" / "lib" / "tray-place.ps1"),
    ]
    for source, target in pairs:
        # Пропавший исходник — отказ сборки, а не заметка: копия по старому пути молча не
        # обновлялась с переезда общих скриптов, и трей отставал от канона.
        if not source.is_file():
            raise SystemExit(fail("нет общего исходника %s — копия осталась бы старой молча" % source))
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
PAYLOAD_PREFIX = "#P "


def deck_payload(version: str) -> bytes:
    """Программа Deck'а архивом tar.gz: верхняя папка SteamDeck-KVM/, внутри раскладка репозитория."""
    buffer = io.BytesIO()

    def add(tar, data: bytes, arcname: str, executable: bool = False):
        if arcname.endswith((".sh", ".py", ".desktop", ".service", ".qml", "VERSION")):
            data = data.replace(b"\r\n", b"\n")  # файлы Linux — с переводом строки Linux
        info = tarfile.TarInfo("SteamDeck-KVM/" + arcname)
        info.size = len(data)
        info.mode = 0o755 if executable else 0o644
        info.mtime = int((ROOT / "VERSION").stat().st_mtime)
        tar.addfile(info, io.BytesIO(data))

    with tarfile.open(fileobj=buffer, mode="w:gz") as tar:
        for base in ("core", "apps/deck"):
            for path in sorted((ROOT / base).rglob("*")):
                if path.is_file() and not _skip(path):
                    rel = path.relative_to(ROOT).as_posix()
                    add(tar, path.read_bytes(), rel, executable=path.suffix == ".sh")
        add(tar, (ROOT / "apps" / "palette.json").read_bytes(), "apps/palette.json")
        add(tar, (version + "\n").encode(), "VERSION")
    return buffer.getvalue()


def build_desktop(version: str, desktop: Path) -> None:
    """Ярлык установки с программой внутри."""
    template = (ROOT / "apps" / "deck" / "SteamDeck-KVM-Install.desktop").read_bytes().decode("utf-8")
    template = template.replace("\r\n", "\n").rstrip("\n") + "\n"
    encoded = base64.b64encode(deck_payload(version)).decode("ascii")
    lines = [PAYLOAD_PREFIX + encoded[i:i + 76] for i in range(0, len(encoded), 76)]
    desktop.write_bytes((template + "\n".join(lines) + "\n").encode("utf-8"))


def read_payload(desktop: Path) -> dict:
    """Имена и содержимое файлов программы из ярлыка — так же, как их достанет Deck."""
    text = desktop.read_text(encoding="utf-8")
    encoded = "".join(line[len(PAYLOAD_PREFIX):].strip() for line in text.splitlines() if line.startswith(PAYLOAD_PREFIX))
    with tarfile.open(fileobj=io.BytesIO(base64.b64decode(encoded)), mode="r:gz") as tar:
        return {member.name: (member.mode, tar.extractfile(member).read()) for member in tar.getmembers() if member.isfile()}


def verify(version: str, pc: Path, desktop: Path) -> list[str]:
    """Сверить собранное с тем, что обещают установщики и обновление. Пустой список — чисто."""
    problems = []
    if not pc.is_file() or pc.read_bytes()[:2] != b"MZ":
        problems.append("установщик ПК %s не собран" % pc.name)
    if not desktop.is_file():
        problems.append("ярлык установки Steam Deck не собран")
        return problems
    head = desktop.read_bytes()[:4000]
    for host in (b"raw.githubusercontent.com", b"api.github.com", b"codeload.github.com"):
        if host in head:
            problems.append("ярлык установки ходит на %s — в части сетей он недоступен" % host.decode())
    try:
        files = read_payload(desktop)
    except Exception as error:  # noqa: BLE001 — любой отказ разбора и есть находка
        return problems + ["программа внутри ярлыка не читается: %s" % error]
    for need in DECK_REQUIRED:
        entry = files.get("SteamDeck-KVM/" + need)
        if entry is None:
            problems.append("в ярлыке установки нет %s" % need)
        elif need.endswith(".sh") and not entry[0] & 0o111:
            problems.append("%s в ярлыке без права на запуск" % need)
    packed = files.get("SteamDeck-KVM/VERSION", (0, b""))[1].decode().strip()
    if packed != version:
        problems.append("в ярлыке версия %s, а собирается %s" % (packed, version))
    if any(b"\r\n" in data for name, (_, data) in files.items() if name.endswith((".sh", ".py"))):
        problems.append("в ярлыке файлы Linux с переводом строки Windows")
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
    parser.add_argument("--копии", action="store_true", help="только обновить копии общих файлов, без сборки")
    args = parser.parse_args()

    if args.копии:
        load_private_words()
        for note in refresh_vendored_copies():
            print("  " + note)
        return 0

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
        build_desktop(version, desktop)
        shutil.copyfile(notes_file, DIST / "RELEASE_NOTES.md")

    problems = verify(version, pc, desktop)
    print("ЧИСЛА ПРИЁМКИ: версия %s, файлов выпуска 2, установщик ПК %d КБ, ярлык Deck %d КБ, находок %d" % (
        version, pc.stat().st_size // 1024 if pc.is_file() else 0,
        desktop.stat().st_size // 1024 if desktop.is_file() else 0, len(problems)))
    for problem in problems:
        print("  НАХОДКА: " + problem)
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
