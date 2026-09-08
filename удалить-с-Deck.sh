#!/usr/bin/env bash
# Полное удаление общей клавиатуры и мыши с Steam Deck.
set -euo pipefail
sudo systemctl disable --now deck-kvm.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/deck-kvm.service /etc/deck-kvm.conf \
	/etc/modules-load.d/deck-kvm-uinput.conf
sudo rm -rf /var/lib/deck-kvm
sudo systemctl daemon-reload
echo "Удалено. Ничего от deck-kvm в системе не осталось."
