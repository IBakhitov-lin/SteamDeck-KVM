#!/bin/bash
# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Сценарий песочницы Steam Deck: установка старого выпуска и обновление кнопкой
# Запускает tests/deck/test_update_sandbox.py внутри Linux; доводы: версия, с которой обновлять, и репозиторий.
set -euo pipefail
# Песочница Linux во встроенной подсистеме Windows выводит окна Linux прямо на рабочий стол
# человека: окно Deck'а, открытое установщиком, висело у него в панели задач. Экрана у проверки нет.
unset DISPLAY WAYLAND_DISPLAY
export QT_QPA_PLATFORM=offscreen
FROM="$1"; REPO="$2"
BASE=$(mktemp -d)          # каждый прогон — с чистого листа, прошлый на него не влияет
export HOME=$BASE/home USER=deck XDG_RUNTIME_DIR=$BASE/run STEAMDECK_KVM_IN_TERMINAL=1
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$BASE/shim" "$BASE/v"
LOG=$BASE/calls.log; : > "$LOG"

# Подмены системных команд: вызов записывается, успех возвращается.
for cmd in systemctl modprobe udevadm nmcli update-desktop-database kbuildsycoca6 kbuildsycoca5 notify-send; do
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

unpack() {  # ярлык → папка программы, как это делает строка Exec ярлыка
	python3 - "$1" "$2" <<'PY'
import base64, io, sys, tarfile
text = open(sys.argv[1], encoding="utf-8").read()
payload = "".join(l[3:].strip() for l in text.splitlines() if l.startswith("#P "))
tarfile.open(fileobj=io.BytesIO(base64.b64decode(payload)), mode="r:gz").extractall(sys.argv[2])
PY
}

echo "== 1. установка $FROM"
python3 -c "import urllib.request, sys; urllib.request.urlretrieve('https://github.com/$REPO/releases/download/v$FROM/SteamDeck-KVM-Install.desktop', sys.argv[1])" "$BASE/v/old.desktop"
unpack "$BASE/v/old.desktop" "$BASE/v/old"
STEAMDECK_KVM_CLEANUP="$BASE/v/old" bash "$BASE/v/old/SteamDeck-KVM/apps/deck/install.sh" < /dev/null
APP="$HOME/.local/share/steamdeck-kvm/app"
STATE="$HOME/.local/state/steamdeck-kvm"
echo "установлено: $(cat "$APP/VERSION")"
mkdir -p "$STATE"; echo deck-id-sandbox > "$STATE/identity"; echo pc-id-sandbox > "$STATE/pair"

echo "== 2. кнопка «Обновить» версии $(cat "$APP/VERSION")"
NEW=$(cd "$APP" && python3 -c "
import sys; sys.path.insert(0, '.')
from core import config_policy
from core.soldiers.release_update_soldier import ReleaseUpdateSoldier
r = ReleaseUpdateSoldier(config_policy.app_version()).check()
print(r['version'] if r else '')")
echo "предложено: ${NEW:-ничего}"
[ -n "$NEW" ] || { echo "ИТОГ: обновление НЕ предложено"; exit 2; }
cp "$APP/apps/deck/install.sh" "$XDG_RUNTIME_DIR/steamdeck-kvm-install.sh"
systemd-run --user --collect --quiet bash "$XDG_RUNTIME_DIR/steamdeck-kvm-install.sh" --latest < /dev/null

echo "== 3. сверка"
GOT=$(cat "$APP/VERSION")
echo "ИТОГ: было $FROM, предложено $NEW, стало $GOT, указатель → $(readlink "$APP")"
echo "номер Deck'а: $(cat "$STATE/identity"), память о ПК: $(cat "$STATE/pair")"
echo "перезапусков службы: $(grep -c 'systemctl --user restart' "$LOG")"
[ "$GOT" = "$NEW" ]
[ "$(cat "$STATE/identity")" = deck-id-sandbox ] && [ "$(cat "$STATE/pair")" = pc-id-sandbox ]
grep -q 'systemctl --user restart' "$LOG"
python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import core.commanders.deck_client_commander, core.officers.intelligence.deck_session_sensor; print('модули новой версии загружаются')" "$APP"
