# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Песочница Steam Deck: установка выпуска 1.1.0 и обновление кнопкой до последнего выпуска
"""
test_update_sandbox.py

Проверка обновления на Deck'е без Deck'а. Linux проходит путь настоящего устройства:

1. скачивает с GitHub ярлык установки выпуска `FROM_VERSION` и ставит программу, как при первой
   установке (программа лежит внутри ярлыка строками `#P`);
2. обновляет её ровно так, как кнопка «Обновить» установленной версии: `ReleaseUpdateSoldier.check()`
   спрашивает github.com о последней версии, установщик копируется во временную папку и
   запускается с ключом `--latest` — как это делает служба через `systemd-run`;
3. сверяет: указатель `app` смотрит на новую версию, служба перезапущена, номер Deck'а и память
   о ПК на месте, модули новой версии загружаются.

Команды, которых в Linux-песочнице нет (служба пользователя systemd, права администратора,
NetworkManager), подменены записью вызовов — так проверка видит, что установщик их позвал.
Виртуальные устройства ввода, игровой режим и сама служба на устройстве здесь не проверяются —
только на Deck'е. Каждый прогон идёт в новой временной папке.

Linux — Debian во встроенной подсистеме Windows (`wsl --install -d Debian`, в нём `python3`), иначе
контейнер Docker; нет ни того ни другого, либо нет сети до github.com — проверка пропускается с
причиной. Идёт перед выпуском: `pytest tests/deck/test_update_sandbox.py -s`.
"""

from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest

FROM_VERSION = "1.1.0"
IMAGE = "python:3.12-slim"
REPO = "IBakhitov-lin/SteamDeck-KVM"
SCENARIO = (Path(__file__).with_name("update_sandbox_scenario.sh")).read_text(encoding="utf-8")


def _wsl_debian_ready() -> bool:
    if not shutil.which("wsl"):
        return False
    try:
        done = subprocess.run(["wsl", "-d", "Debian", "-u", "root", "--", "python3", "--version"],
                              capture_output=True, timeout=120)
        return done.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def _docker_ready() -> bool:
    if not shutil.which("docker"):
        return False
    try:
        return subprocess.run(["docker", "info"], capture_output=True, timeout=60).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def _to_wsl(path: Path) -> str:
    drive, rest = str(path).split(":", 1)
    return "/mnt/" + drive.lower() + rest.replace("\\", "/")


def test_every_sandbox_scenario_hides_the_screen():
    """Песочница во встроенной подсистеме Windows выводит окна Linux на рабочий стол человека:
    24.09.2026 у него в панели задач висели четыре окна Deck'а, открытых установщиком в проверке.
    Каждый сценарий песочницы снимает экран до первой команды."""
    сценарии = sorted(Path(__file__).parent.glob("*.sh"))
    assert сценарии
    for сценарий in сценарии:
        текст = сценарий.read_text(encoding="utf-8")
        assert "unset DISPLAY WAYLAND_DISPLAY" in текст and "QT_QPA_PLATFORM=offscreen" in текст, сценарий.name


def _runner(work: Path):
    """Linux для песочницы: Debian во встроенной подсистеме Windows, иначе контейнер Docker."""
    script = work / "scenario.sh"
    if _wsl_debian_ready():
        return ["wsl", "-d", "Debian", "-u", "root", "--", "bash", _to_wsl(script), FROM_VERSION, REPO]
    if _docker_ready():
        return ["docker", "run", "--rm", "-v", f"{work}:/work:ro", IMAGE, "bash", "/work/scenario.sh",
                FROM_VERSION, REPO]
    return None


def test_update_from_old_release_to_latest_in_deck_sandbox():
    work = Path(tempfile.mkdtemp(prefix="deck-sandbox-"))
    (work / "scenario.sh").write_bytes(SCENARIO.replace("\r\n", "\n").encode("utf-8"))
    команда = _runner(work)
    if команда is None:
        pytest.skip("нет ни Debian во встроенной подсистеме Linux, ни Docker — песочницу Deck'а поднять не на чем")
    done = subprocess.run(команда, capture_output=True, timeout=900, encoding="utf-8", errors="replace")
    report = done.stdout + done.stderr
    # Отчёт — файлом: консоль Windows печатает не каждый знак, а ход песочницы нужен целиком.
    (work / "report.txt").write_text(report, encoding="utf-8")
    print("отчёт песочницы:", work / "report.txt")
    assert done.returncode == 0, report[-3000:]
    assert "ИТОГ: было " + FROM_VERSION in report and "модули новой версии загружаются" in report


LOCAL_SCENARIO = (Path(__file__).with_name("local_install_scenario.sh")).read_text(encoding="utf-8")
BUILT_DESKTOP = Path(__file__).resolve().parents[2] / "dist" / "SteamDeck-KVM-Install.desktop"


def test_local_build_installs_like_service_update_without_windows():
    """Текущий код, собранный сборщиком, ставится так, как его ставит служба: окон не открывает,
    окно «Компьютер» для Alt+Tab заводит автозапуском. Идёт после `build_release_script.py`."""
    if not BUILT_DESKTOP.is_file():
        pytest.skip("нет собранного ярлыка dist/SteamDeck-KVM-Install.desktop — сначала сборщик выпуска")
    work = Path(tempfile.mkdtemp(prefix="deck-local-"))
    (work / "scenario.sh").write_bytes(LOCAL_SCENARIO.replace("\r\n", "\n").encode("utf-8"))
    shutil.copyfile(BUILT_DESKTOP, work / "install.desktop")
    if _wsl_debian_ready():
        команда = ["wsl", "-d", "Debian", "-u", "root", "--", "bash", _to_wsl(work / "scenario.sh"),
                   _to_wsl(work / "install.desktop")]
    elif _docker_ready():
        команда = ["docker", "run", "--rm", "-v", f"{work}:/work:ro", IMAGE, "bash", "/work/scenario.sh",
                   "/work/install.desktop"]
    else:
        pytest.skip("нет ни Debian во встроенной подсистеме Linux, ни Docker")
    done = subprocess.run(команда, capture_output=True, timeout=600, encoding="utf-8", errors="replace")
    report = done.stdout + done.stderr
    (work / "report.txt").write_text(report, encoding="utf-8")
    print("отчёт песочницы:", work / "report.txt")
    assert done.returncode == 0, report[-3000:]
    for признак in ("автозапуск окна «Компьютер»: заведён", "служба перезапущена",
                    "окон при установке службой не открыто", "решение об обновлении загружается: True"):
        assert признак in report, признак


REQUEST_SCENARIO = (Path(__file__).with_name("pc_request_update_scenario.sh")).read_text(encoding="utf-8")


def test_pc_update_button_updates_the_deck():
    """Кнопка «Обновить» на компьютере: просьба по сети → служба Deck'а → установщик → выпуск с github.com.

    Чужая просьба не принимается, своя — принимается; установщик запускается так же, как его
    запускает служба на Deck'е. Идёт после `build_release_script.py`."""
    if not BUILT_DESKTOP.is_file():
        pytest.skip("нет собранного ярлыка dist/SteamDeck-KVM-Install.desktop — сначала сборщик выпуска")
    work = Path(tempfile.mkdtemp(prefix="deck-request-"))
    (work / "scenario.sh").write_bytes(REQUEST_SCENARIO.replace("\r\n", "\n").encode("utf-8"))
    shutil.copyfile(BUILT_DESKTOP, work / "install.desktop")
    if not _wsl_debian_ready():
        pytest.skip("нет Debian во встроенной подсистеме Linux")
    done = subprocess.run(["wsl", "-d", "Debian", "-u", "root", "--", "bash", _to_wsl(work / "scenario.sh"),
                           _to_wsl(work / "install.desktop")], capture_output=True, timeout=900,
                          encoding="utf-8", errors="replace")
    report = done.stdout + done.stderr
    (work / "report.txt").write_text(report, encoding="utf-8")
    print("отчёт песочницы:", work / "report.txt")
    assert done.returncode == 0, report[-3000:]
    for признак in ("чужая просьба принята: False", "просьба своего компьютера принята: True",
                    "служба решила обновиться: True", "установщик запущен: True"):
        assert признак in report, признак
    assert "ИТОГ: было 0.0.1, стало 0.0.1" not in report
