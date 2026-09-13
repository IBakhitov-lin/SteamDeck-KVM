# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Soldier обновления клиента Steam Deck из выпусков GitHub без git
"""
release_update_soldier.py

Проверить, есть ли выпуск новее, скачать архив для Steam Deck, сверить контрольную сумму,
разложить новую версию рядом со старой и переключить указатель. Настройки и память о паре
при этом не трогаются вовсе: они живут в папке состояния, а не в папке программы
(`config_policy.py`).

Почему официальный интерфейс выпусков, а не git. Человеку на Deck'е git не нужен и не должен
быть нужен: обновление — одна кнопка. Интерфейс выпусков GitHub официальный и работает без
ключа (шестьдесят запросов в час на адрес). Ручной путь на случай его отказа — скачать архив
со страницы выпусков и нажать установщик заново: установщик делает ровно то же самое.

Почему версия раскладывается РЯДОМ, а не поверх. Замена файлов на месте, прерванная на
середине, оставляет смесь двух версий, которая не запускается. Новая версия собирается в своей
папке целиком, и только потом одним переименованием указатель `app` начинает смотреть на неё.
Прежняя версия остаётся — откат есть возврат указателя.

Что сверка суммы доказывает и чего нет. Она ловит оборванную и испорченную загрузку. От
подмены выпуска владельцем учётной записи она не защищает: сумма лежит в том же выпуске.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import tarfile
import tempfile
import urllib.request
from pathlib import Path

from core import config_policy

USER_AGENT = "SteamDeck-KVM-updater"
KEEP_VERSIONS = 2


def parse_version(text: str):
    """«v1.2.3» → (1, 2, 3). Нечитаемое — None: сравнивать не с чем, обновления нет."""
    match = re.match(r"^v?(\d+)\.(\d+)\.(\d+)", (text or "").strip())
    return tuple(int(part) for part in match.groups()) if match else None


def _default_fetch(url: str, timeout: float = 20.0) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310 — адрес свой
        return response.read()


class ReleaseUpdateSoldier:
    def __init__(self, current_version: str, log=lambda text: None, fetch=None, home: Path | None = None):
        self.current = current_version
        self.log = log
        self.fetch = fetch or _default_fetch
        self.home = home or config_policy.app_home()

    # ---- проверка -------------------------------------------------------------

    def check(self):
        """Выпуск новее текущей версии либо None. Любой отказ сети — None и строка в журнал."""
        try:
            release = json.loads(self.fetch(config_policy.releases_url()).decode("utf-8"))
        except Exception as error:  # сеть, лимит, неразборчивый ответ — обновления просто нет
            self.log("проверка обновлений не удалась: %s" % error)
            return None
        latest = parse_version(release.get("tag_name", ""))
        current = parse_version(self.current)
        if latest is None or current is None or latest <= current:
            return None
        assets = {asset.get("name"): asset.get("browser_download_url") for asset in release.get("assets", [])}
        archive = next((name for name in assets
                        if name and name.startswith(config_policy.ASSET_PREFIX) and name.endswith(config_policy.DECK_ASSET_SUFFIX)), None)
        if not archive or config_policy.CHECKSUMS_ASSET not in assets:
            self.log("выпуск %s без архива для Steam Deck или без контрольных сумм — пропущен"
                     % release.get("tag_name"))
            return None
        notes = (release.get("body") or "").strip().splitlines()
        return {
            "version": "%d.%d.%d" % latest,
            "archive_name": archive,
            "archive_url": assets[archive],
            "sums_url": assets[config_policy.CHECKSUMS_ASSET],
            "notes": notes[0].lstrip("#- ").strip() if notes else "",
        }

    # ---- установка ------------------------------------------------------------

    def apply(self, release: dict) -> Path:
        """Скачать, сверить, разложить рядом и переключить указатель. Возвращает папку версии."""
        sums = self.fetch(release["sums_url"]).decode("utf-8")
        expected = None
        for line in sums.splitlines():
            parts = line.strip().split()
            if len(parts) == 2 and parts[1].lstrip("*") == release["archive_name"]:
                expected = parts[0].lower()
        if not expected:
            raise ValueError("в контрольных суммах нет строки для %s" % release["archive_name"])

        payload = self.fetch(release["archive_url"], timeout=120.0)
        actual = hashlib.sha256(payload).hexdigest()
        if actual != expected:
            raise ValueError("контрольная сумма не сошлась: загрузка испорчена или оборвана")

        versions = self.home / "versions"
        versions.mkdir(parents=True, exist_ok=True)
        target = versions / release["version"]
        with tempfile.TemporaryDirectory(dir=versions) as scratch:
            archive_path = Path(scratch) / release["archive_name"]
            archive_path.write_bytes(payload)
            unpacked = Path(scratch) / "unpacked"
            safe_extract(archive_path, unpacked)
            app_dirs = [path for path in unpacked.glob("*/app") if path.is_dir()] or \
                       [path for path in unpacked.glob("app") if path.is_dir()]
            if not app_dirs:
                raise ValueError("в архиве нет папки app — это не архив SteamDeck-KVM для Deck'а")
            if target.exists():
                shutil.rmtree(target)
            shutil.move(str(app_dirs[0]), str(target))

        switch_current(self.home, target)
        prune_versions(versions, keep=KEEP_VERSIONS, current=target)
        self.log("обновлено до %s" % release["version"])
        return target


def safe_extract(archive: Path, destination: Path) -> None:
    """Распаковать архив, отклонив пути наружу и ссылки за пределы папки.

    Параметр `filter` у `extractall` есть не во всех сборках Python на SteamOS, поэтому
    проверка сделана своими руками: абсолютный путь, `..` и ссылка, ведущая наружу, отклоняют
    архив целиком — частично распакованный архив хуже нераспакованного.
    """
    destination.mkdir(parents=True, exist_ok=True)
    root = destination.resolve()
    with tarfile.open(archive, "r:gz") as tar:
        members = tar.getmembers()
        for member in members:
            path = (root / member.name).resolve()
            if not str(path).startswith(str(root)):
                raise ValueError("архив пытается выйти за папку: %s" % member.name)
            if member.issym() or member.islnk():
                linked = (path.parent / member.linkname).resolve()
                if not str(linked).startswith(str(root)):
                    raise ValueError("ссылка в архиве ведёт наружу: %s" % member.name)
            if member.isdev():
                raise ValueError("в архиве файл устройства: %s" % member.name)
        if hasattr(tarfile, "data_filter"):
            # Встроенный фильтр — второй рубеж поверх своей проверки: снимает опасные права.
            tar.extractall(destination, members=members, filter="data")
        else:
            tar.extractall(destination, members=members)


def switch_current(home: Path, target: Path) -> None:
    """Переключить указатель `app` на новую версию одним переименованием.

    Переименование поверх существующего указателя атомарно: в любой момент `app` смотрит либо
    на старую версию, либо на новую, но никогда в пустоту.
    """
    link = home / "app"
    temporary = home / ("app.new-%d" % os.getpid())
    if temporary.is_symlink() or temporary.exists():
        temporary.unlink()
    os.symlink(target, temporary, target_is_directory=True)
    os.replace(temporary, link)


def prune_versions(versions: Path, keep: int, current: Path) -> None:
    """Оставить последние версии — текущую и одну для отката."""
    folders = sorted((path for path in versions.iterdir() if path.is_dir() and parse_version(path.name)),
                     key=lambda path: parse_version(path.name), reverse=True)
    for folder in folders[keep:]:
        if folder.resolve() != current.resolve():
            shutil.rmtree(folder, ignore_errors=True)
