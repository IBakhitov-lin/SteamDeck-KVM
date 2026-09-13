#!/usr/bin/env bash
# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Установка SteamDeck-KVM на Steam Deck: служба пользователя, окно, переезд прежней установки
#
# Три способа запуска, один файл:
#   1. ярлык «Установить SteamDeck-KVM» из выпуска скачивает этот файл и запускает — установщик сам
#      берёт последний выпуск, сверяет архив с SHA256SUMS.txt и продолжает из распакованного
#   2. `bash install.sh` в распакованном архиве выпуска — установка без сети
#   3. `bash apps/deck/install.sh` в рабочей копии репозитория
#
# Что куда кладётся — и почему раздельно:
#   ~/.local/share/steamdeck-kvm/versions/<версия>  программа; указатель app — на текущую
#   ~/.local/state/steamdeck-kvm/                   номер Deck'а и знакомство с компьютером
#   ~/.config/systemd/user/steamdeck-kvm.service    служба, поднимается при каждом входе в сеанс
# Обновление заменяет только программу, поэтому знакомство и настройки переживают любое обновление.
#
# Пароль нужен ТОЛЬКО в двух случаях, и оба называются вслух:
#   1. найдена прежняя установка от администратора — её надо отключить
#   2. у пользователя нет доступа к /dev/uinput — выдаётся правилом системы один раз
set -euo pipefail

# Щелчок в файловом менеджере запускает скрипт без терминала: пароль спросить негде, итог
# прочитать негде. Поэтому скрипт переоткрывает себя в терминале и держит окно до закрытия.
if [ ! -t 0 ] && [ -z "${STEAMDECK_KVM_IN_TERMINAL:-}" ] && command -v konsole >/dev/null 2>&1; then
	export STEAMDECK_KVM_IN_TERMINAL=1
	exec konsole -e bash "$0" "$@"
fi

# Окно терминала закрывается вместе со скриптом — и итог, и ошибка исчезли бы непрочитанными.
pause_on_exit() {
	local code=$?
	# Временная папка загрузки — своя, созданная mktemp родительским запуском, и только в /tmp.
	case "${STEAMDECK_KVM_CLEANUP:-}" in
		"${TMPDIR:-/tmp}"/tmp.*) rm -rf "$STEAMDECK_KVM_CLEANUP" ;;
	esac
	if [ -t 0 ] && [ -z "${STEAMDECK_KVM_NO_PAUSE:-}" ]; then
		printf '\nНажмите Enter, чтобы закрыть окно. / Press Enter to close.'
		read -r _ || true
	fi
	exit "$code"
}
trap pause_on_exit EXIT

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# В архиве выпуска программа лежит рядом в app/; в рабочей копии — двумя уровнями выше; скачанный
# отдельно установщик программы рядом не имеет и берёт её из последнего выпуска.
if [ -d "$HERE/app/core" ]; then
	PAYLOAD="$HERE/app"
elif [ -f "$HERE/../../core/config_policy.py" ]; then
	PAYLOAD="$(cd "$HERE/../.." && pwd)"
else
	printf '=== SteamDeck-KVM — загрузка последней версии ===\n'
	if ! command -v python3 >/dev/null 2>&1; then
		printf 'ОШИБКА: в системе нет python3 — на SteamOS он есть всегда, значит система повреждена.\n'
		exit 1
	fi
	WORK="$(mktemp -d)"
	UNPACKED="$(python3 - "$WORK" <<'PY'
import hashlib, json, os, sys, tarfile, urllib.request
work = sys.argv[1]
url = os.environ.get("STEAMDECK_KVM_RELEASES_URL") or \
    "https://api.github.com/repos/IBakhitov-lin/SteamDeck-KVM/releases/latest"
def fetch(address):
    request = urllib.request.Request(address, headers={"User-Agent": "SteamDeck-KVM-installer"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()
try:
    release = json.loads(fetch(url).decode("utf-8"))
    assets = {a["name"]: a["browser_download_url"] for a in release.get("assets", [])}
    names = [n for n in assets if n.startswith("SteamDeck-KVM-") and n.endswith("-steamos-x86_64.tar.gz")]
    if not names or "SHA256SUMS.txt" not in assets:
        raise RuntimeError("в выпуске %s нет архива для Steam Deck или SHA256SUMS.txt" % release.get("tag_name"))
    name = names[0]
    data = fetch(assets[name])
    sums = fetch(assets["SHA256SUMS.txt"]).decode("utf-8")
    expected = [line.split()[0] for line in sums.splitlines() if line.strip().endswith("  " + name)]
    if not expected or hashlib.sha256(data).hexdigest() != expected[0].lower():
        raise RuntimeError("архив %s не совпал с SHA256SUMS.txt — загрузка испорчена, установка остановлена" % name)
    archive = os.path.join(work, name)
    with open(archive, "wb") as handle:
        handle.write(data)
    with tarfile.open(archive, "r:gz") as tar:
        for member in tar.getmembers():
            if member.name.startswith(("/", "\\")) or ".." in member.name.split("/") or not (member.isfile() or member.isdir()):
                raise RuntimeError("в архиве недопустимый путь: %s" % member.name)
        if hasattr(tarfile, "data_filter"):
            tar.extractall(work, filter="data")
        else:
            tar.extractall(work)
    top = os.path.join(work, name[:-len(".tar.gz")])
    if not os.path.isfile(os.path.join(top, "install.sh")):
        raise RuntimeError("в архиве %s нет install.sh" % name)
    sys.stderr.write("Скачана и сверена версия %s.\n" % release.get("tag_name"))
    print(top)
except Exception as error:
    sys.stderr.write("ОШИБКА загрузки: %s\n" % error)
    sys.exit(1)
PY
)" || { rm -rf "$WORK"; exit 1; }
	# Скачанный архив больше не нужен — /tmp на SteamOS лежит в памяти. Распакованную копию
	# убирает уже дочерний установщик: программа из неё к тому времени скопирована в свою папку.
	rm -f "$WORK"/*.tar.gz
	trap - EXIT
	export STEAMDECK_KVM_CLEANUP="$WORK"
	exec bash "$UNPACKED/install.sh" "$@"
fi
VERSION="$(tr -d '[:space:]' < "$PAYLOAD/VERSION" 2>/dev/null || echo 0.0.0)"

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
APP_HOME="$DATA_HOME/steamdeck-kvm"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/steamdeck-kvm"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
APPS_DIR="$DATA_HOME/applications"
UNIT="steamdeck-kvm.service"

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }

ensure_sudo() {
	if sudo -n true 2>/dev/null; then
		return 0
	fi
	if passwd -S "$USER" 2>/dev/null | awk '{print $2}' | grep -q '^NP$'; then
		say "У пользователя $USER ещё нет пароля. Сейчас его нужно задать — это пароль самого Deck'а."
		passwd
	fi
	say "Введите пароль Deck'а:"
	sudo -v
}

say "=== Общая клавиатура и мышь — установка на Steam Deck, версия $VERSION ==="

if ! command -v python3 >/dev/null 2>&1; then
	say "ОШИБКА: в системе нет python3 — на SteamOS он есть всегда, значит система повреждена."
	exit 1
fi

step "1. Прежняя установка"
if [ -f /etc/systemd/system/deck-kvm.service ]; then
	mkdir -p "$STATE"
	for name in identity pair last-server; do
		if [ -f "/var/lib/deck-kvm/$name" ] && [ ! -f "$STATE/$name" ]; then
			cp "/var/lib/deck-kvm/$name" "$STATE/$name"
		fi
	done
	say "Найдена прежняя установка. Знакомство с компьютером перенесено — знакомиться заново не придётся."
	say "Чтобы отключить прежнюю службу, нужен пароль Deck'а (один раз)."
	ensure_sudo
	sudo systemctl disable --now deck-kvm.service 2>/dev/null || true
	sudo rm -f /etc/systemd/system/deck-kvm.service /etc/modules-load.d/deck-kvm-uinput.conf
	sudo systemctl daemon-reload
	say "Прежняя служба отключена."
else
	say "Прежней установки нет."
fi

step "2. Доступ к устройствам ввода"
if [ -w /dev/uinput ]; then
	say "Доступ есть — пароль не нужен."
else
	say "Доступа нет. Выдаю его правилом системы — нужен пароль Deck'а (один раз)."
	ensure_sudo
	echo 'KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput"' \
		| sudo tee /etc/udev/rules.d/70-steamdeck-kvm-uinput.rules >/dev/null
	echo uinput | sudo tee /etc/modules-load.d/steamdeck-kvm-uinput.conf >/dev/null
	sudo modprobe uinput 2>/dev/null || true
	sudo udevadm control --reload-rules 2>/dev/null || true
	sudo udevadm trigger --subsystem-match=misc 2>/dev/null || true
	sleep 1
	if [ -w /dev/uinput ]; then
		say "Доступ выдан."
	else
		say "Правило поставлено; доступ появится после перезагрузки Deck'а."
	fi
fi

step "3. Программа"
mkdir -p "$APP_HOME/versions"
TARGET="$APP_HOME/versions/$VERSION"
rm -rf "$TARGET.new"
mkdir -p "$TARGET.new/apps"
cp -a "$PAYLOAD/core" "$PAYLOAD/VERSION" "$TARGET.new/"
cp -a "$PAYLOAD/apps/deck" "$TARGET.new/apps/"
cp -a "$PAYLOAD/apps/palette.json" "$TARGET.new/apps/"
find "$TARGET.new" -name '__pycache__' -type d -prune -exec rm -rf {} +
chmod +x "$TARGET.new/apps/deck/"*.sh
rm -rf "$TARGET"
mv "$TARGET.new" "$TARGET"
# Указатель переключается одним переименованием: служба никогда не смотрит в пустоту.
ln -sfn "$TARGET" "$APP_HOME/app.new"
mv -Tf "$APP_HOME/app.new" "$APP_HOME/app"
say "Версия $VERSION разложена."

step "4. Служба"
mkdir -p "$UNIT_DIR"
sed "s#@APP@#$APP_HOME/app#g" "$APP_HOME/app/apps/deck/steamdeck-kvm.service" > "$UNIT_DIR/$UNIT"
systemctl --user daemon-reload
systemctl --user enable "$UNIT" >/dev/null 2>&1
systemctl --user restart "$UNIT"

step "5. Ярлыки"
ICON="$APP_HOME/app/apps/deck/steamdeck-kvm.png"
[ -f "$ICON" ] || ICON="input-keyboard"
mkdir -p "$APPS_DIR"
cat > "$APPS_DIR/steamdeck-kvm.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=SteamDeck-KVM
Name[ru]=Общая клавиатура и мышь
Comment=Keyboard and mouse from your PC
Comment[ru]=Клавиатура и мышь с компьютера — состояние связи и обновление
Exec=$APP_HOME/app/apps/deck/steamdeck-kvm-app.sh
Icon=$ICON
Terminal=false
Categories=Utility;
EOF
if [ -d "$HOME/Desktop" ]; then
	cp "$APPS_DIR/steamdeck-kvm.desktop" "$HOME/Desktop/SteamDeck-KVM.desktop"
	chmod +x "$HOME/Desktop/SteamDeck-KVM.desktop"
fi
update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
say "Ярлык «Общая клавиатура и мышь» — в меню приложений и на рабочем столе."
say "Чтобы видеть окно и в игровом режиме: правой кнопкой по ярлыку в меню → «Добавить в Steam»."

step "6. Проверка"
sleep 2
if systemctl --user is-active --quiet "$UNIT"; then
	say "Служба работает."
else
	say "Служба не поднялась. Последние строки её журнала:"
	journalctl --user -u "$UNIT" -n 20 --no-pager || true
	exit 1
fi

say ""
say "Готово. Теперь на компьютере откройте «Общая клавиатура и мышь» и нажмите «Включить»."
say "Deck найдёт компьютер сам — и в игровом режиме, и после перезагрузки."
nohup "$APP_HOME/app/apps/deck/steamdeck-kvm-app.sh" >/dev/null 2>&1 &
