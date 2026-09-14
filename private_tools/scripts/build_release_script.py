# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Сборка выпуска SteamDeck-KVM: архив для ПК, архив для Steam Deck, контрольные суммы
"""
build_release_script.py

Выпуск собирается этим скриптом и никогда руками: архив, упакованный мышью, теряет права на
запуск у файлов Deck'а, забывает копию палитры или берёт устаревшую копию общего модуля, и
выясняется это у человека, скачавшего выпуск, а не здесь.

Что получается в dist/:

Имена — по шаблону `<Имя>-<X.Y.Z>-<платформа>-<архитектура>`, как у открытых проектов того же рода;
файлы, которые скачивают по постоянной ссылке `releases/latest/download/<файл>`, — без версии.

1. `SteamDeck-KVM-<версия>-windows-x64.zip` — папка приложения для Windows: запускатель, окно,
   модули, копии общих файлов, значок
2. `SteamDeck-KVM-<версия>-steamos-x86_64.tar.gz` — установщик, удалятор и папка `app/` с
   клиентом. Именно tar.gz, а не zip: только он хранит права на запуск
3. `SteamDeck-KVM-Install.desktop` — ярлык «Установить» для Deck'а: скачивает `install.sh` из
   последнего выпуска и запускает его
4. `install.sh` — тот же установщик, что в архиве: без программы рядом он сам берёт архив
   последнего выпуска и сверяет его с суммами
5. `SHA256SUMS.txt` — контрольные суммы всех файлов; обновление и установщик без них не ставят
6. `RELEASE_NOTES.md` — текст выпуска из `private_tools/releases/v<версия>.md`

Копии общих файлов берутся из папки общих исходников В МОМЕНТ СБОРКИ, если она задана настройкой
`steamdeck-kvm.shared-source`: копия, лежащая в репозитории месяцами, расходится с исходником
молча. Из копий вычищаются имена приватных проектов и пути рабочей машины — архив публичный.

Запуск:  python private_tools/scripts/build_release_script.py [--проверить]
Код возврата: 0 — собрано и сверено; 1 — сборка отклонена с названной причиной.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import shutil
import subprocess
import sys
import tarfile
import zipfile
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


def build_pc(version: str) -> Path:
    name = "SteamDeck-KVM-%s-windows-x64" % version
    archive = DIST / (name + ".zip")
    pc = ROOT / "apps" / "pc"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zf:
        for path in sorted(pc.rglob("*")):
            if path.is_file() and not _skip(path):
                zf.write(path, "%s/%s" % (name, path.relative_to(pc).as_posix()))
        zf.write(ROOT / "apps" / "palette.json", "%s/lib/palette.json" % name)
        zf.writestr("%s/VERSION" % name, version + "\n")
        zf.write(ROOT / "LICENSE", "%s/LICENSE" % name)
    return archive


def build_deck(version: str) -> Path:
    name = "SteamDeck-KVM-%s-steamos-x86_64" % version
    archive = DIST / (name + ".tar.gz")
    deck = ROOT / "apps" / "deck"

    def add(tar, source: Path | None, arcname: str, executable=False, data: bytes | None = None):
        content = data if data is not None else source.read_bytes()
        if arcname.endswith((".sh", ".py", ".desktop", ".service", ".qml")):
            # Файлы Linux в архиве — с переводом строки Linux, независимо от настройки git на Windows.
            content = content.replace(b"\r\n", b"\n")
        info = tarfile.TarInfo("%s/%s" % (name, arcname))
        info.size = len(content)
        info.mode = 0o755 if executable else 0o644
        info.mtime = int((ROOT / "VERSION").stat().st_mtime)
        tar.addfile(info, io.BytesIO(content))

    with tarfile.open(archive, "w:gz") as tar:
        add(tar, deck / "install.sh", "install.sh", executable=True)
        add(tar, deck / "uninstall.sh", "uninstall.sh", executable=True)
        add(tar, ROOT / "LICENSE", "LICENSE")
        for path in sorted((ROOT / "core").rglob("*")):
            if path.is_file() and not _skip(path):
                add(tar, path, "app/core/" + path.relative_to(ROOT / "core").as_posix())
        for path in sorted(deck.rglob("*")):
            if path.is_file() and not _skip(path):
                add(tar, path, "app/apps/deck/" + path.relative_to(deck).as_posix(),
                    executable=path.suffix == ".sh")
        add(tar, ROOT / "apps" / "palette.json", "app/apps/palette.json")
        add(tar, None, "app/VERSION", data=(version + "\n").encode())
    return archive


def build_loose_files(desktop: Path, installer: Path) -> None:
    """Ярлык и установщик для скачивания по постоянной ссылке — с переводом строки Linux."""
    for source, target in ((ROOT / "apps" / "deck" / "SteamDeck-KVM-Install.desktop", desktop),
                           (ROOT / "apps" / "deck" / "install.sh", installer)):
        target.write_bytes(source.read_bytes().replace(b"\r\n", b"\n"))


def write_sums(files: list[Path]) -> Path:
    sums = DIST / "SHA256SUMS.txt"
    lines = ["%s  %s" % (hashlib.sha256(path.read_bytes()).hexdigest(), path.name) for path in files]
    sums.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    return sums


def verify(version: str, pc: Path, deck: Path, sums: Path, loose: list[Path]) -> list[str]:
    """Сверить собранное с тем, что обещают установщик и обновление. Пустой список — чисто."""
    problems = []
    with zipfile.ZipFile(pc) as zf:
        names = set(zf.namelist())
        for need in ("SteamDeck-KVM.vbs", "SteamDeck-KVM.ps1", "app-window.ps1", "app-update.ps1",
                     "lib/tray-common.ps1", "lib/tray-place.ps1", "lib/palette.json", "VERSION", "SteamDeck-KVM.ico"):
            if "SteamDeck-KVM-%s-windows-x64/%s" % (version, need) not in names:
                problems.append("в архиве ПК нет %s" % need)
    with tarfile.open(deck, "r:gz") as tar:
        members = {member.name: member for member in tar.getmembers()}
        prefix = "SteamDeck-KVM-%s-steamos-x86_64/" % version
        for need, executable in (("install.sh", True),
                                 ("uninstall.sh", True), ("app/VERSION", False),
                                 ("app/apps/deck/steamdeck_kvm_service.py", False),
                                 ("app/apps/deck/steamdeck-kvm-app.qml", False),
                                 ("app/apps/deck/steamdeck-kvm-app.sh", True),
                                 ("app/apps/deck/steamdeck-kvm.png", False),
                                 ("app/core/commanders/deck_client_commander.py", False),
                                 ("app/apps/palette.json", False)):
            member = members.get(prefix + need)
            if member is None:
                problems.append("в архиве Deck'а нет %s" % need)
            elif executable and not member.mode & 0o111:
                problems.append("%s в архиве Deck'а без права на запуск" % need)
        for name in members:
            if "/tests/" in name or name.endswith(".pyc"):
                problems.append("в архив Deck'а попало лишнее: %s" % name)
    lines = sums.read_text(encoding="utf-8").splitlines()
    for path in [pc, deck] + loose:
        if not path.is_file():
            problems.append("нет файла выпуска %s" % path.name)
            continue
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if "%s  %s" % (digest, path.name) not in lines:
            problems.append("сумма %s не совпадает с файлом" % path.name)
    home = str(Path.home())
    workspace = str(ROOT.parent)
    markers = {home, home.replace("\\", "/"), workspace, workspace.replace("\\", "/")}
    for archive in [pc, deck] + [path for path in loose if path.is_file()]:
        text = archive.read_bytes()
        for marker in markers:
            if marker and marker.encode("utf-8") in text:
                problems.append("в %s попал путь машины сборки" % archive.name)
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

    pc = DIST / ("SteamDeck-KVM-%s-windows-x64.zip" % version)
    deck = DIST / ("SteamDeck-KVM-%s-steamos-x86_64.tar.gz" % version)
    desktop = DIST / "SteamDeck-KVM-Install.desktop"
    installer = DIST / "install.sh"
    sums = DIST / "SHA256SUMS.txt"

    if not args.проверить:
        load_private_words()
        for note in refresh_vendored_copies():
            print("  " + note)
        build_icons()
        if DIST.exists():
            shutil.rmtree(DIST)
        DIST.mkdir()
        build_pc(version)
        build_deck(version)
        build_loose_files(desktop, installer)
        write_sums([pc, deck, desktop, installer])
        shutil.copyfile(notes_file, DIST / "RELEASE_NOTES.md")

    problems = verify(version, pc, deck, sums, [desktop, installer])
    print("ЧИСЛА ПРИЁМКИ: версия %s, файлов выпуска 4, размер ПК %d КБ, Deck %d КБ, находок %d" % (
        version, pc.stat().st_size // 1024, deck.stat().st_size // 1024, len(problems)))
    for problem in problems:
        print("  НАХОДКА: " + problem)
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
