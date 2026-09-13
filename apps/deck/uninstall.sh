#!/usr/bin/env bash
# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Удаление SteamDeck-KVM с Steam Deck с выбором, сохранить ли знакомство с компьютером
#
#     bash uninstall.sh --keep-state    удалить программу, знакомство с компьютером оставить (по умолчанию)
#     bash uninstall.sh --erase-state   удалить всё, включая номер Deck'а и знакомство
#
# Почему знакомство по умолчанию остаётся. Номер Deck'а и номер его компьютера — три маленьких
# файла. Сохранённые, они дают переустановке сразу подключиться; стёртые, требуют знакомиться
# заново. Удаление программы — не повод стирать то, что человек сделал руками.
#
# Правило доступа к /dev/uinput, если его ставил установщик, остаётся: снять его можно только с
# паролем, а вреда от него нет — тот же доступ SteamOS даёт самому Steam.
set -uo pipefail

MODE="${1:---keep-state}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
APP_HOME="$DATA_HOME/steamdeck-kvm"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/steamdeck-kvm"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT="steamdeck-kvm.service"

systemctl --user disable --now "$UNIT" >/dev/null 2>&1 || true
rm -f "$UNIT_DIR/$UNIT"
systemctl --user daemon-reload >/dev/null 2>&1 || true
pkill -f "steamdeck-kvm-app.qml" >/dev/null 2>&1 || true
rm -f "$DATA_HOME/applications/steamdeck-kvm.desktop" "$HOME/Desktop/SteamDeck-KVM.desktop"
rm -rf "$APP_HOME"

if [ "$MODE" = "--erase-state" ]; then
	rm -rf "$STATE"
	echo "SteamDeck-KVM удалён полностью, включая знакомство с компьютером."
else
	echo "SteamDeck-KVM удалён. Знакомство с компьютером сохранено в $STATE —"
	echo "после повторной установки связь поднимется без нового знакомства."
fi
