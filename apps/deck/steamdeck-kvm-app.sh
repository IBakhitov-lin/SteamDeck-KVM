#!/usr/bin/env bash
# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Запуск окна SteamDeck-KVM на Steam Deck движком окон рабочего стола
#
# Графической библиотеки для Python в SteamOS нет, а ставить её значит тянуть зависимость в систему,
# которую обновление SteamOS перезаписывает. Зато рабочий стол Plasma сам несёт движок окон QML:
# qml6 в Plasma 6, qmlscene в Plasma 5. Окно берёт тот, что есть; нет ни одного — открывается
# текстовое меню той же службы в терминале, чтобы человек не остался без состояния вовсе.
set -u

DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
QML="$DIR/steamdeck-kvm-app.qml"

# Одно окно на сеанс: второй щелчок по ярлыку не плодит копий.
LOCK="${XDG_RUNTIME_DIR:-/tmp}/steamdeck-kvm-app.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
	exit 0
fi

for runtime in qml6 /usr/lib/qt6/bin/qml qmlscene6 /usr/lib/qt6/bin/qmlscene qmlscene /usr/lib/qt/bin/qmlscene; do
	if [ -x "$runtime" ] || command -v "$runtime" >/dev/null 2>&1; then
		exec "$runtime" "$QML"
	fi
done

exec konsole --hold -e python3 "$DIR/steamdeck_kvm_service.py" --menu
