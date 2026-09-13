# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Точка входа службы SteamDeck-KVM на Steam Deck и текстовое меню состояния
"""
steamdeck_kvm_service.py

Запускается службой пользователя systemd при каждом входе в сеанс — в игровом режиме и на
рабочем столе. Служба работает от имени пользователя, а не администратора: доступ к
виртуальным устройствам ядра на SteamOS выдаётся активному пользователю правилом `uaccess`,
тем же, которым пользуется сам Steam для своих виртуальных геймпадов. Если в системе такого
правила нет, установщик ставит его один раз и называет это вслух.

Режимы запуска:
    steamdeck_kvm_service.py               служба: связь, окно состояния, обновления
    steamdeck_kvm_service.py --status      одна строка состояния из работающей службы
    steamdeck_kvm_service.py --menu        текстовое меню, когда окно запустить нечем
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from core import config_policy  # noqa: E402
from core.commanders.deck_client_commander import POINTER_AUTO, DeckClientCommander  # noqa: E402
from core.control_api_facade import ACTION_HEADER, ControlApiFacade  # noqa: E402
from core.dto.client_status_dto import NO_UINPUT  # noqa: E402
from core.soldiers.lan_discovery_soldier import LanDiscoverySoldier, migrate_legacy_state  # noqa: E402
from core.soldiers.release_update_soldier import ReleaseUpdateSoldier  # noqa: E402

UNIT = "steamdeck-kvm.service"


def read_settings() -> dict:
    """Настройки вручную не нужны; файл законен только для особых сетей.

    Читаются два места: своё (`~/.local/state/steamdeck-kvm/settings.conf`) и файл прежней
    установки `/etc/deck-kvm.conf` — чтобы адрес, прописанный там руками, пережил переезд.
    """
    settings = {}
    for path in (Path("/etc/deck-kvm.conf"), config_policy.state_dir() / "settings.conf"):
        try:
            for line in path.read_text(encoding="utf-8").splitlines():
                line = line.split("#", 1)[0].strip()
                if "=" in line:
                    key, value = line.split("=", 1)
                    settings[key.strip().lower()] = value.strip()
        except OSError:
            continue
    return settings


def load_palette() -> dict:
    """Цвета, гарнитура и радиусы для окна — из того же контракта, что у приложения на ПК."""
    try:
        data = json.loads((ROOT / "apps" / "palette.json").read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return {}
    return {"theme": data.get("тёмная", {}), "radii": data.get("радиусы", {}),
            "font": (data.get("типографика") or {}).get("приложение", "")}


def restart_self(log):
    """Перезапуск силами systemd: служба выходит, а `Restart=always` поднимает её снова."""
    log("перезапуск службы")
    try:
        subprocess.Popen(["systemctl", "--user", "restart", UNIT], start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        os._exit(0)


def uninstall(log, keep_state: bool):
    """Запустить удаление ОТДЕЛЬНОЙ временной службой: оно останавливает эту же службу.

    Процесс, порождённый службой, живёт в её группе процессов, и systemd при остановке службы
    гасит всю группу — удаление умерло бы на первой же строке «остановить службу», оставив
    полуудалённую программу. `systemd-run --user` поднимает удаление в своей группе.
    """
    script = ROOT / "apps" / "deck" / "uninstall.sh"
    if not script.is_file():
        return False, "не найден удалятор %s" % script
    flag = "--keep-state" if keep_state else "--erase-state"
    log("удаление запущено (%s)" % ("знакомство сохраняется" if keep_state else "всё стирается"))
    # Копия удалятора кладётся во временную папку: сам он лежит внутри удаляемой программы.
    runtime = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "steamdeck-kvm-uninstall.sh"
    try:
        runtime.write_bytes(script.read_bytes())
        subprocess.Popen(["systemd-run", "--user", "--collect", "--quiet", "bash", str(runtime), flag],
                         start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError as error:
        return False, "удаление не запустилось: %s" % error
    return True, "удаление началось — окно закроется, когда служба остановится"


def serve() -> int:
    settings = read_settings()

    def log(text):
        print("[steamdeck-kvm] %s" % text, flush=True)

    migrate_legacy_state(log)
    host = os.environ.get("DECK_KVM_SERVER") or settings.get("server", "")
    if host.strip().lower() == "auto":
        host = ""
    hosts = [part for part in host.split(",") if part.strip()]
    pointer = (os.environ.get("DECK_KVM_POINTER") or settings.get("pointer", POINTER_AUTO)).lower()
    if pointer not in ("auto", "abs", "rel"):
        pointer = POINTER_AUTO
    name = settings.get("name", config_policy.SCREEN_NAME)

    if not os.access("/dev/uinput", os.W_OK):
        log("нет доступа к /dev/uinput — запустите установщик ещё раз, он выдаст доступ")
        _serve_status_only(NO_UINPUT)
        return 3

    try:
        discovery = LanDiscoverySoldier(name, log)
    except OSError as error:
        discovery = None
        log("поиск по сети недоступен (%s) — работаем по адресу из настроек" % error)

    commander = DeckClientCommander(hosts, int(settings.get("port", config_policy.KVM_PORT)), name, log,
                                    pointer=pointer, discovery=discovery)
    updater = ReleaseUpdateSoldier(config_policy.app_version(), log=commander.log)
    pending = {"release": None}

    def check_updates_forever():
        time.sleep(60)  # сразу после входа сеть на Deck'е часто ещё не поднята
        while True:
            release = updater.check()
            pending["release"] = release
            commander.set_status(update_available=release["version"] if release else None)
            time.sleep(config_policy.UPDATE_CHECK_SECONDS)

    def apply_update():
        release = pending["release"] or updater.check()
        if not release:
            commander.set_status(updating=False, update_error="обновлений нет")
            return
        commander.set_status(updating=True, update_error=None)
        try:
            updater.apply(release)
        except Exception as error:
            commander.set_status(updating=False, update_error=str(error))
            commander.log("обновление не удалось: %s" % error)
            return
        restart_self(commander.log)

    def act(name):
        if name == "update":
            if commander.status.updating:
                return False, "обновление уже идёт"
            threading.Thread(target=apply_update, name="update", daemon=True).start()
            return True, "обновление началось"
        if name == "restart":
            threading.Timer(0.5, restart_self, args=(commander.log,)).start()
            return True, "служба перезапускается"
        if name in ("uninstall_keep", "uninstall_all"):
            return uninstall(commander.log, keep_state=(name == "uninstall_keep"))
        return commander.request(name)

    def snapshot():
        data = commander.snapshot()
        data["palette"] = load_palette()
        return data

    api = None
    try:
        api = ControlApiFacade(snapshot, act).start()
    except OSError as error:
        commander.log("окно состояния недоступно: порт %d занят (%s)" % (config_policy.CONTROL_PORT, error))

    threading.Thread(target=check_updates_forever, name="update-check", daemon=True).start()
    commander.log("служба запущена, версия %s, режим %s, курсор %s" % (
        config_policy.app_version(), commander.mode, commander.officer.pointer))
    try:
        commander.run()
    except KeyboardInterrupt:
        pass
    finally:
        if api:
            api.stop()
        commander.close()
    return 0


def _serve_status_only(state):
    """Без доступа к устройствам окно всё равно обязано сказать, в чём дело, а не молчать."""
    status = {"version": config_policy.app_version(), "state": state, "log": [], "palette": load_palette()}
    try:
        api = ControlApiFacade(lambda: status, lambda name: (False, "служба без доступа к устройствам")).start()
    except OSError:
        return
    time.sleep(3600 * 24 * 365)
    api.stop()


# ---- текстовая сторона ------------------------------------------------------------

STATE_WORDS = {
    "starting": "служба поднимается",
    "waiting_pc": "ждём компьютер в сети",
    "pc_off": "компьютер рядом, но на нём не нажато «Включить»",
    "connecting": "соединяемся",
    "connected": "подключён",
    "display_off": "экран Deck'а погас — связь снята",
    "no_uinput": "нет доступа к устройствам ввода — запустите установщик ещё раз",
}


def _api(path, method="GET"):
    request = urllib.request.Request("http://127.0.0.1:%d/%s" % (config_policy.CONTROL_PORT, path), method=method)
    if method == "POST":
        request.add_header(ACTION_HEADER, "1")
    with urllib.request.urlopen(request, data=b"" if method == "POST" else None, timeout=5) as response:
        return json.loads(response.read().decode("utf-8"))


def status_line() -> str:
    try:
        data = _api("status")
    except OSError:
        return "служба не отвечает — она не запущена"
    pc = data.get("pc_name") or "—"
    return "%s · компьютер %s · %s · версия %s" % (
        STATE_WORDS.get(data.get("state"), data.get("state")), pc,
        "игровой режим" if data.get("mode") == "game" else "рабочий стол", data.get("version"))


def menu() -> int:
    while True:
        print("\n=== SteamDeck-KVM ===")
        print(status_line())
        print("1 — забыть компьютер   2 — обновить   3 — перезапустить службу   0 — выход")
        choice = input("> ").strip()
        if choice == "0":
            return 0
        action = {"1": "forget", "2": "update", "3": "restart"}.get(choice)
        if not action:
            continue
        try:
            print(_api(action, method="POST").get("message"))
        except OSError as error:
            print("служба не ответила: %s" % error)


def main() -> int:
    parser = argparse.ArgumentParser(description="SteamDeck-KVM на Steam Deck")
    parser.add_argument("--status", action="store_true", help="одна строка состояния")
    parser.add_argument("--menu", action="store_true", help="текстовое меню состояния")
    args = parser.parse_args()
    if args.status:
        print(status_line())
        return 0
    if args.menu:
        return menu()
    return serve()


if __name__ == "__main__":
    sys.exit(main())
