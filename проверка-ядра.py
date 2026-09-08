"""Проверка на настоящем ядре Linux: создаются ли виртуальные устройства
и доходят ли до ядра события, которые шлёт клиент.

Запускать НА ДЕКЕ от root:  sudo python3 ~/Desktop/SteamDeck-KVM/проверка-ядра.py
"""
import importlib.util
import os
import re
import sys
import time

ЗДЕСЬ = os.path.dirname(os.path.abspath(__file__))
ПУТЬ = os.path.join(ЗДЕСЬ, "deck-kvm.py")
if not os.path.exists(ПУТЬ):
    ПУТЬ = "/var/lib/deck-kvm/deck-kvm.py"
SPEC = importlib.util.spec_from_file_location("deckkvm", ПУТЬ)
mod = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mod)

FAILURES = []


def check(ok, label):
    print(("  OK        " if ok else "  ПРОВАЛ    ") + label, flush=True)
    if not ok:
        FAILURES.append(label)


def kernel_record(name):
    """Запись об устройстве в /proc/bus/input/devices — то, что реально
    зарегистрировано в ядре, независимо от наличия evdev и udev."""
    try:
        blob = open("/proc/bus/input/devices").read()
    except OSError:
        return None
    for chunk in blob.split("\n\n"):
        if 'Name="%s"' % name in chunk:
            return chunk
    return None


def event_node(name):
    base = "/sys/class/input"
    if not os.path.isdir(base):
        return None
    for entry in os.listdir(base):
        if not entry.startswith("event"):
            continue
        try:
            with open(os.path.join(base, entry, "device", "name")) as fh:
                if fh.read().strip() == name:
                    return "/dev/input/" + entry
        except OSError:
            continue
    return None


# --- 1. константы должны совпадать с ядром ---------------------------------
print("Константы ioctl и размеры структур")
check(mod.UI_SET_EVBIT == 0x40045564, "UI_SET_EVBIT = 0x40045564")
check(mod.UI_SET_KEYBIT == 0x40045565, "UI_SET_KEYBIT = 0x40045565")
check(mod.UI_SET_RELBIT == 0x40045566, "UI_SET_RELBIT = 0x40045566")
check(mod.UI_SET_ABSBIT == 0x40045567, "UI_SET_ABSBIT = 0x40045567")
check(mod.UI_DEV_CREATE == 0x5501, "UI_DEV_CREATE = 0x5501")
check(mod.UI_DEV_DESTROY == 0x5502, "UI_DEV_DESTROY = 0x5502")
check(mod._DEV.size == 1116, "struct uinput_user_dev = 1116 байт")
check(mod._EVENT.size == 24, "struct input_event = 24 байта")

# --- 2. устройства реально создаются ---------------------------------------
print("\nРегистрация виртуальных устройств в ядре")
kbd = mod.VirtualDevice("Deck KVM Keyboard", keys=mod.KEYBOARD_CODES)
mouse = mod.VirtualDevice(
    "Deck KVM Mouse",
    keys=sorted(mod.MOUSE_BUTTONS.values()),
    rels=(mod.REL_X, mod.REL_Y, mod.REL_WHEEL, mod.REL_HWHEEL),
    abss=(mod.ABS_X, mod.ABS_Y),
)
time.sleep(0.4)
kbd_rec, mouse_rec = kernel_record("Deck KVM Keyboard"), kernel_record("Deck KVM Mouse")
check(kbd_rec is not None, "клавиатура зарегистрирована в ядре")
check(mouse_rec is not None, "мышь зарегистрирована в ядре")
check(bool(mouse_rec) and "B: EV=f" in mouse_rec,
      "мышь объявила ядру синхронизацию, кнопки, относительные И абсолютные оси")
check(bool(mouse_rec) and re.search(r"B: REL=[0-9a-f]*3\b", mouse_rec) is not None,
      "у мыши заявлены оси REL_X и REL_Y")
check(bool(mouse_rec) and re.search(r"B: ABS=[0-9a-f]*3\b", mouse_rec) is not None,
      "у мыши заявлены оси ABS_X и ABS_Y")
абс = None
if mouse_rec:
    sysfs = re.search(r"S: Sysfs=(\S+)", mouse_rec)
    if sysfs:
        try:
            абс = open("/sys" + sysfs.group(1) + "/capabilities/abs").read().strip()
        except OSError:
            абс = None
check(абс is None or int(абс.split()[-1], 16) & 0b11 == 0b11,
      "ядро подтверждает обе абсолютные оси в списке возможностей")
check(bool(kbd_rec) and "Vendor=1209" in kbd_rec,
      "устройство опознаётся по идентификатору производителя")
check(bool(kbd_rec) and "B: EV=3" in kbd_rec,
      "клавиатура объявила ядру только синхронизацию и клавиши")

# --- 3. события доходят до ядра --------------------------------------------
print("\nОбратное чтение событий из ядра")
kbd_node, mouse_node = event_node("Deck KVM Keyboard"), event_node("Deck KVM Mouse")
if not (mouse_node and kbd_node):
    print("  ПРОПУСК   в этом ядре не собран evdev, читать события неоткуда; "
          "на Steam Deck он есть")
else:
    fk = os.open(kbd_node, os.O_RDONLY | os.O_NONBLOCK)
    fm = os.open(mouse_node, os.O_RDONLY | os.O_NONBLOCK)
    time.sleep(0.2)
    kbd.emit(mod.EV_KEY, mod.K["A"], 1)
    kbd.sync()
    kbd.emit(mod.EV_KEY, mod.K["A"], 0)
    kbd.sync()
    mouse.emit(mod.EV_REL, mod.REL_X, 17)
    mouse.emit(mod.EV_REL, mod.REL_Y, -9)
    mouse.sync()
    mouse.emit(mod.EV_KEY, mod.BTN_LEFT, 1)
    mouse.sync()
    time.sleep(0.4)

    def drain(fd):
        out = []
        while True:
            try:
                blob = os.read(fd, 24 * 64)
            except BlockingIOError:
                break
            if not blob:
                break
            for i in range(0, len(blob), 24):
                _, _, t, c, v = mod._EVENT.unpack(blob[i:i + 24])
                out.append((t, c, v))
        return out

    kev, mev = drain(fk), drain(fm)
    os.close(fk)
    os.close(fm)
    check((mod.EV_KEY, mod.K["A"], 1) in kev, "нажатие клавиши A прочитано из ядра")
    check((mod.EV_KEY, mod.K["A"], 0) in kev, "отпускание клавиши A прочитано из ядра")
    check((mod.EV_REL, mod.REL_X, 17) in mev, "смещение мыши по X прочитано из ядра")
    check((mod.EV_REL, mod.REL_Y, -9) in mev, "смещение мыши по Y прочитано из ядра")
    check((mod.EV_KEY, mod.BTN_LEFT, 1) in mev, "нажатие левой кнопки прочитано из ядра")

kbd.close()
mouse.close()
time.sleep(0.3)
check(kernel_record("Deck KVM Keyboard") is None,
      "после остановки службы устройства исчезают из ядра")

# --- 4. вспомогательное ----------------------------------------------------
print("\nПрочее")
w, h = mod.detect_screen()
check(isinstance(w, int) and w > 0 and h > 0,
      "разрешение экрана определяется без композитора (%dx%d)" % (w, h))
check(mod.KEYMAP[ord("a")] == mod.K["A"] and mod.KEYMAP[0xEF53] == mod.K["RIGHT"],
      "таблица клавиш собралась")

print()
if FAILURES:
    print("ПРОВАЛЕНО пунктов: %d" % len(FAILURES))
    for f in FAILURES:
        print("  - " + f)
    sys.exit(1)
print("Все проверки на настоящем ядре пройдены")
