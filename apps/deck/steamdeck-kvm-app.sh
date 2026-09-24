#!/usr/bin/env bash
# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Запуск окна SteamDeck-KVM на Steam Deck движком окон рабочего стола
#
# Графической библиотеки для Python в SteamOS нет, а ставить её значит тянуть зависимость в систему,
# которую обновление SteamOS перезаписывает. Зато рабочий стол Plasma сам несёт движок окон QML:
# qml6 в Plasma 6, qmlscene в Plasma 5. Окно берёт тот, что есть; нет ни одного — открывается
# текстовое меню той же службы в терминале, чтобы человек не остался без состояния вовсе.
#
# С ключом --pc-window запускается окно «Компьютер» для Alt+Tab (steamdeck-kvm-pc-window.qml): его
# поднимает автозапуск рабочего стола. Текстового запаса у него нет — без движка окон Alt+Tab на
# рабочем столе просто остаётся переключением окон Deck'а.
set -u

DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
NAME="steamdeck-kvm-app"
[ "${1:-}" = "--pc-window" ] && NAME="steamdeck-kvm-pc-window"
QML="$DIR/$NAME.qml"

# Поднять уже открытое окно. Сам процесс окна фокус себе не выдаёт — защита Plasma от кражи фокуса
# оставляет его позади, — а KWin делает окно активным сам. Скрипт KWin грузится по D-Bus, запускается и
# выгружается: приём kdotool (github.com/jinliu/kdotool), без его установки — в SteamOS его нет.
# Plasma 6 зовёт список windowList и активное activeWindow, Plasma 5 — clientList и activeClient.
raise_window() {
	local title="$1" js id
	js="$(mktemp "${XDG_RUNTIME_DIR:-/tmp}/steamdeck-kvm-raise.XXXXXX.js")" || return 1
	cat >"$js" <<EOF
var list = workspace.windowList ? workspace.windowList() : workspace.clientList();
for (var i = 0; i < list.length; i++) {
	var w = list[i];
	if (w.caption && w.caption.indexOf("$title") === 0) {
		w.minimized = false;
		if (workspace.windowList) { workspace.activeWindow = w; } else { workspace.activeClient = w; }
	}
}
EOF
	id="$(gdbus call --session --dest org.kde.KWin --object-path /Scripting \
		--method org.kde.kwin.Scripting.loadScript "$js" steamdeck-kvm-raise 2>/dev/null | grep -o '[0-9]\+' | head -1)"
	if [ -n "$id" ]; then
		gdbus call --session --dest org.kde.KWin --object-path "/Scripting/Script$id" \
			--method org.kde.kwin.Script.run >/dev/null 2>&1 ||
			gdbus call --session --dest org.kde.KWin --object-path "/$id" \
				--method org.kde.kwin.Script.run >/dev/null 2>&1
		sleep 0.3
		gdbus call --session --dest org.kde.KWin --object-path /Scripting \
			--method org.kde.kwin.Scripting.unloadScript steamdeck-kvm-raise >/dev/null 2>&1
	fi
	rm -f "$js"
}

# Одно окно на сеанс: второй щелчок по ярлыку не плодит копий, а поднимает открытое окно вперёд.
LOCK="${XDG_RUNTIME_DIR:-/tmp}/$NAME.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
	[ "$NAME" = "steamdeck-kvm-app" ] && raise_window "Общая клавиатура и мышь"
	exit 0
fi

for runtime in qml6 /usr/lib/qt6/bin/qml qmlscene6 /usr/lib/qt6/bin/qmlscene qmlscene /usr/lib/qt/bin/qmlscene; do
	if [ -x "$runtime" ] || command -v "$runtime" >/dev/null 2>&1; then
		exec "$runtime" "$QML"
	fi
done

[ "$NAME" = "steamdeck-kvm-pc-window" ] && exit 0
exec konsole --hold -e python3 "$DIR/steamdeck_kvm_service.py" --menu
