#!/bin/bash
# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Сценарий песочницы Steam Deck: установка из собранного ярлыка так, как её запускает служба
# Запускает tests/deck/test_update_sandbox.py внутри Linux; довод — путь к собранному ярлыку в Linux.
# Установка идёт с признаком запуска службой (STEAMDECK_KVM_NO_PAUSE): так ставятся обновления по кнопке,
# по просьбе компьютера и сами. Проверяется: программа встала, служба перезапущена, автозапуск окна
# «Компьютер» заведён, окно приложения НЕ открыто (в игровом режиме оно встало бы поверх игры).
set -euo pipefail
# Песочница Linux во встроенной подсистеме Windows выводит окна Linux прямо на рабочий стол
# человека: окно Deck'а, открытое установщиком, висело у него в панели задач. Экрана у проверки нет.
unset DISPLAY WAYLAND_DISPLAY
export QT_QPA_PLATFORM=offscreen
DESKTOP="$1"
BASE=$(mktemp -d)
export HOME=$BASE/home USER=deck XDG_RUNTIME_DIR=$BASE/run STEAMDECK_KVM_IN_TERMINAL=1 STEAMDECK_KVM_NO_PAUSE=1
export XDG_CURRENT_DESKTOP=KDE
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$BASE/shim" "$BASE/v"
LOG=$BASE/calls.log; : > "$LOG"

for cmd in systemctl modprobe udevadm nmcli update-desktop-database kbuildsycoca6 kbuildsycoca5 notify-send nohup; do
	printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 0\n' "$cmd" "$LOG" > "$BASE/shim/$cmd"
	chmod +x "$BASE/shim/$cmd"
done
cat > "$BASE/shim/sudo" <<EOF
#!/bin/sh
echo "sudo \$*" >> "$LOG"
while [ "\${1#-}" != "\$1" ]; do shift; done
[ \$# -eq 0 ] && exit 0
[ "\$1" = true ] && exit 0
exec "\$@"
EOF
chmod +x "$BASE/shim/sudo"
export PATH="$BASE/shim:$PATH"

python3 - "$DESKTOP" "$BASE/v/new" <<'PY'
import base64, io, sys, tarfile
text = open(sys.argv[1], encoding="utf-8").read()
payload = "".join(l[3:].strip() for l in text.splitlines() if l.startswith("#P "))
tarfile.open(fileobj=io.BytesIO(base64.b64decode(payload)), mode="r:gz").extractall(sys.argv[2])
PY
STEAMDECK_KVM_CLEANUP="$BASE/v/new" bash "$BASE/v/new/SteamDeck-KVM/apps/deck/install.sh" < /dev/null
APP="$HOME/.local/share/steamdeck-kvm/app"
AUTOSTART="$HOME/.config/autostart/steamdeck-kvm-pc-window.desktop"

echo "== сверка"
echo "установлено: $(cat "$APP/VERSION")"
[ -f "$APP/apps/deck/steamdeck-kvm-pc-window.qml" ] && echo "окно «Компьютер» в программе: есть"
grep -q -- "--pc-window" "$AUTOSTART" && echo "автозапуск окна «Компьютер»: заведён"
grep -q 'systemctl --user restart' "$LOG" && echo "служба перезапущена"
if grep -q "^nohup" "$LOG"; then echo "ОКНО ОТКРЫТО при установке службой — дефект"; exit 3; fi
echo "окон при установке службой не открыто"
python3 -c "import sys; sys.path.insert(0, sys.argv[1]); from apps.deck import steamdeck_kvm_service as s; print('решение об обновлении загружается:', s.should_update(True, False))" "$APP" 2>/dev/null \
  || python3 -c "import importlib.util, sys; sp = importlib.util.spec_from_file_location('s', sys.argv[1] + '/apps/deck/steamdeck_kvm_service.py'); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m); print('решение об обновлении загружается:', m.should_update(True, False))" "$APP"
echo "ИТОГ: установка из сборки прошла"
