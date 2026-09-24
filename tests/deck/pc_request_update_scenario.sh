#!/bin/bash
# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Сценарий песочницы Steam Deck: кнопка «Обновить» на компьютере обновляет Deck
# Запускает tests/deck/test_update_sandbox.py внутри Linux; довод — путь к собранному ярлыку в Linux.
#
# Цепочка ровно та, что на Deck'е, кроме устройств ввода:
#   1. ставится текущая сборка под старым номером (0.0.1), как служба ставит обновление;
#   2. подставной компьютер шлёт по сети «DECKKVM2 UPDATE <номер ПК>» на порт знакомства Deck'а;
#   3. знакомство Deck'а принимает просьбу только от своей пары, чужую — нет;
#   4. решение службы should_update и её же run_installer запускают установщик последнего выпуска;
#   5. указатель программы смотрит на выпуск с github.com — Deck обновился.
# Режим (рабочий стол, игровой, игра) службе безразличен: она его при обновлении не читает.
set -euo pipefail
# Песочница Linux во встроенной подсистеме Windows выводит окна Linux прямо на рабочий стол
# человека: окно Deck'а, открытое установщиком, висело у него в панели задач. Экрана у проверки нет.
unset DISPLAY WAYLAND_DISPLAY
export QT_QPA_PLATFORM=offscreen
DESKTOP="$1"
BASE=$(mktemp -d)
export HOME=$BASE/home USER=deck XDG_RUNTIME_DIR=$BASE/run STEAMDECK_KVM_IN_TERMINAL=1 STEAMDECK_KVM_NO_PAUSE=1
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
cat > "$BASE/shim/systemd-run" <<EOF
#!/bin/sh
echo "systemd-run \$*" >> "$LOG"
while [ "\${1#-}" != "\$1" ]; do shift; done
exec "\$@"
EOF
chmod +x "$BASE/shim/sudo" "$BASE/shim/systemd-run"
export PATH="$BASE/shim:$PATH"

python3 - "$DESKTOP" "$BASE/v/new" <<'PY'
import base64, io, sys, tarfile
text = open(sys.argv[1], encoding="utf-8").read()
payload = "".join(l[3:].strip() for l in text.splitlines() if l.startswith("#P "))
tarfile.open(fileobj=io.BytesIO(base64.b64decode(payload)), mode="r:gz").extractall(sys.argv[2])
PY
echo "0.0.1" > "$BASE/v/new/SteamDeck-KVM/VERSION"          # старый номер: выпуск на github.com новее
STEAMDECK_KVM_CLEANUP="$BASE/v/new" bash "$BASE/v/new/SteamDeck-KVM/apps/deck/install.sh" < /dev/null
APP="$HOME/.local/share/steamdeck-kvm/app"
STATE="$HOME/.local/state/steamdeck-kvm"
mkdir -p "$STATE"; echo pc-test > "$STATE/pair"
echo "установлено: $(cat "$APP/VERSION")"

echo "== просьба компьютера"
cd "$APP"
python3 - <<'PY'
import importlib.util, socket, subprocess, sys, time
sys.path.insert(0, ".")
from core import config_policy
from core.soldiers.lan_discovery_soldier import LanDiscoverySoldier
spec = importlib.util.spec_from_file_location("service", "apps/deck/steamdeck_kvm_service.py")
service = importlib.util.module_from_spec(spec); spec.loader.exec_module(service)

deck = LanDiscoverySoldier("steamdeck", print, bind_port=0)
port = deck.sock.getsockname()[1]
pc = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
pc.sendto(("%s UPDATE %s" % (config_policy.PROTOCOL, "чужой-пк")).encode(), ("127.0.0.1", port))
time.sleep(0.2); deck.poll()
print("чужая просьба принята:", deck.update_requested)
pc.sendto(("%s UPDATE %s" % (config_policy.PROTOCOL, "pc-test")).encode(), ("127.0.0.1", port))
time.sleep(0.2); deck.poll()
print("просьба своего компьютера принята:", deck.update_requested)
решение = service.should_update(deck.update_requested, False)
print("служба решила обновиться:", решение)
started, message = service.run_installer(print)
print("установщик запущен:", started, message)
PY
for i in $(seq 1 120); do
	[ "$(cat "$APP/VERSION")" != "0.0.1" ] && break
	sleep 2
done
echo "ИТОГ: было 0.0.1, стало $(cat "$APP/VERSION"), указатель → $(readlink "$APP")"
echo "перезапусков службы: $(grep -c 'systemctl --user restart' "$LOG")"
[ "$(cat "$APP/VERSION")" != "0.0.1" ]
