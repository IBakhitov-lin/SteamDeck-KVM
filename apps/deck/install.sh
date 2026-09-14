#!/usr/bin/env bash
# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Установка SteamDeck-KVM на Steam Deck: служба пользователя, окно, переезд прежней установки
#
# Три способа запуска, один файл:
#   1. ярлык «Установить SteamDeck-KVM» из выпуска несёт программу в себе, распаковывает её и
#      запускает этот файл — интернет для установки не нужен
#   2. кнопка «Обновить» в окне на Deck'е запускает его с ключом --latest: он скачивает ярлык
#      последнего выпуска со страницы выпусков GitHub и продолжает из его программы
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
		"${TMPDIR:-/tmp}"/steamdeck-kvm-*|"${TMPDIR:-/tmp}"/tmp.*) rm -rf "$STEAMDECK_KVM_CLEANUP" ;;
	esac
	if [ -t 0 ] && [ -z "${STEAMDECK_KVM_NO_PAUSE:-}" ]; then
		printf '\nНажмите Enter, чтобы закрыть окно. / Press Enter to close.'
		read -r _ || true
	fi
	exit "$code"
}
trap pause_on_exit EXIT

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LATEST=0
ARGS=()
for arg in "$@"; do
	if [ "$arg" = "--latest" ]; then LATEST=1; else ARGS+=("$arg"); fi
done
# Программа рядом — в распакованном архиве исходного кода или в рабочей копии она двумя уровнями
# выше. Скачанный отдельно установщик программы рядом не имеет и берёт её из последнего выпуска;
# так же поступает кнопка «Обновить» (ключ --latest).
if [ "$LATEST" = 0 ] && [ -f "$HERE/../../core/config_policy.py" ]; then
	PAYLOAD="$(cd "$HERE/../.." && pwd)"
else
	printf '=== SteamDeck-KVM — загрузка последней версии ===\n'
	if ! command -v python3 >/dev/null 2>&1; then
		printf 'ОШИБКА: в системе нет python3 — на SteamOS он есть всегда, значит система повреждена.\n'
		exit 1
	fi
	WORK="$(mktemp -d)"
	UNPACKED="$(python3 - "$WORK" <<'PY'
import base64, io, os, sys, tarfile, urllib.request
work = sys.argv[1]
# Только адреса github.com: ярлык выпуска скачивается тем же путём, что и из браузера. Сервисы
# raw.githubusercontent.com и api.github.com в части сетей недоступны.
url = os.environ.get("STEAMDECK_KVM_INSTALLER_URL") or \
    "https://github.com/IBakhitov-lin/SteamDeck-KVM/releases/latest/download/SteamDeck-KVM-Install.desktop"
try:
    request = urllib.request.Request(url, headers={"User-Agent": "SteamDeck-KVM-installer"})
    with urllib.request.urlopen(request, timeout=120) as response:
        text = response.read().decode("utf-8", "replace")
    payload = "".join(line[3:].strip() for line in text.splitlines() if line.startswith("#P "))
    if not payload:
        raise RuntimeError("в ярлыке последнего выпуска нет программы")
    with tarfile.open(fileobj=io.BytesIO(base64.b64decode(payload)), mode="r:gz") as tar:
        for member in tar.getmembers():
            parts = member.name.split("/")
            if member.name.startswith(("/", "\\")) or ".." in parts or not (member.isfile() or member.isdir()):
                raise RuntimeError("в программе недопустимый путь: %s" % member.name)
        if hasattr(tarfile, "data_filter"):
            tar.extractall(work, filter="data")
        else:
            tar.extractall(work)
    top = os.path.join(work, "SteamDeck-KVM")
    if not os.path.isfile(os.path.join(top, "apps", "deck", "install.sh")):
        raise RuntimeError("в программе нет установщика")
    sys.stderr.write("Скачана последняя версия.\n")
    print(top)
except Exception as error:
    sys.stderr.write("ОШИБКА загрузки: %s\n" % error)
    sys.exit(1)
PY
)" || { rm -rf "$WORK"; exit 1; }
	# Распакованную копию убирает уже дочерний установщик: программа из неё к тому времени
	# скопирована в свою папку, а /tmp на SteamOS лежит в памяти.
	trap - EXIT
	export STEAMDECK_KVM_CLEANUP="$WORK"
	exec bash "$UNPACKED/apps/deck/install.sh" "${ARGS[@]}"
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
