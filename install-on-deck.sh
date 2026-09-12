#!/usr/bin/env bash
# Установка общей клавиатуры и мыши на Steam Deck.
# Запускать НА ДЕКЕ, в Desktop Mode, из Konsole:
#     bash ~/Desktop/SteamDeck-KVM/install-on-deck.sh
#
# Адрес компьютера указывать не нужно — Deck находит его по сети сам.
# Аргумент нужен только там, где рассылка не проходит:
#     bash ~/Desktop/SteamDeck-KVM/install-on-deck.sh 192.168.0.14
set -euo pipefail

SCREEN_NAME="steamdeck"   # это имя должно совпадать с screens.conf на ноутбуке
PORT="24800"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Адрес компьютера указывать не нужно: клиент слышит его рассылку по сети и
# запоминает сам. Аргумент оставлен на случай, когда рассылка не проходит —
# гостевая сеть Wi-Fi с изоляцией клиентов, разные подсети, VPN на компьютере.
SERVER="${1:-auto}"

echo
echo "=== Общая клавиатура и мышь для Steam Deck ==="
if [ "$SERVER" = "auto" ]; then
	echo "Компьютер:  ищется по сети сам"
else
	echo "Компьютер:  $SERVER"
fi
echo "Имя экрана: $SCREEN_NAME"
echo

if [ ! -f "$HERE/deck-kvm.py" ]; then
	echo "ОШИБКА: рядом со скриптом нет файла deck-kvm.py." >&2
	exit 1
fi

if ! command -v python3 >/dev/null; then
	echo "ОШИБКА: в системе нет python3." >&2
	exit 1
fi

# --- права администратора ---------------------------------------------------
if ! sudo -n true 2>/dev/null; then
	echo "Сейчас потребуется пароль администратора Deck'а."
	echo "Если пароль ещё не задан, сначала выполните команду  passwd  и повторите."
	echo
	if ! sudo -v; then
		echo "ОШИБКА: без прав администратора установить службу нельзя." >&2
		exit 1
	fi
fi

# --- раскладка файлов -------------------------------------------------------
sudo install -d -m 0755 /var/lib/deck-kvm
sudo install -m 0755 "$HERE/deck-kvm.py" /var/lib/deck-kvm/deck-kvm.py

printf '# server=auto — адрес компьютера берётся из его рассылки по сети\nserver=%s\nport=%s\nname=%s\n# pointer=abs — положение задаётся абсолютными осями (ускорение на него не влияет)\n# pointer=rel — запасной путь, положение задаётся смещениями\npointer=abs\n' \
	"$SERVER" "$PORT" "$SCREEN_NAME" \
	| sudo tee /etc/deck-kvm.conf >/dev/null
sudo chmod 0644 /etc/deck-kvm.conf

# --- модуль ядра для виртуальных устройств ----------------------------------
echo uinput | sudo tee /etc/modules-load.d/deck-kvm-uinput.conf >/dev/null
sudo modprobe uinput || true

# --- служба -----------------------------------------------------------------
sudo tee /etc/systemd/system/deck-kvm.service >/dev/null <<'UNIT'
[Unit]
Description=Общая клавиатура и мышь с ноутбука (deck-kvm)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /var/lib/deck-kvm/deck-kvm.py
Restart=always
RestartSec=3
Nice=-10

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now deck-kvm.service

echo
echo "--- состояние службы ---"
sleep 2
systemctl --no-pager --lines=8 status deck-kvm.service || true

echo
echo "Готово. Служба поднимается сама при каждом включении Deck'а"
echo "и работает и в игровом режиме, и на рабочем столе."
echo
echo "Смотреть связь:  journalctl -u deck-kvm -f"
echo "Выключить:       sudo systemctl disable --now deck-kvm"
echo "Сменить адрес:   sudo nano /etc/deck-kvm.conf  и потом"
echo "                 sudo systemctl restart deck-kvm"
