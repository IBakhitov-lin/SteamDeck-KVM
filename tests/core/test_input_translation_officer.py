# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Проверки офицера перевода ввода: модификаторы, способ движения курсора, клавиши
"""
test_input_translation_officer.py

Слой — поведение, глубина — функциональная, граничная и регрессионная: каждый исправленный
дефект оставляет здесь проверку, воспроизводящую его дословно.
"""

from __future__ import annotations

import struct

from conftest import FakeDevice
from core.officers.input_translation_officer import (
    K, POINTER_ABS, POINTER_REL, InputTranslationOfficer,
)
from core.soldiers.virtual_device_soldier import EV_ABS, EV_KEY, EV_REL, KEY_DOWN, KEY_REPEAT, KEY_UP, REL_WHEEL, REL_X, REL_Y


def officer(pointer=POINTER_ABS):
    return InputTranslationOfficer(FakeDevice("kbd"), FakeDevice("mouse"), 1280, 800, pointer=pointer)


def key_events(o):
    return [event for event in o.kbd.events if event[0] == EV_KEY]


def keys(o):
    """Нажатия без типа события: (код клавиши, значение)."""
    return [(code, value) for _, code, value in key_events(o)]


def dkdn(key_id, mask, button):
    return b"DKDN" + struct.pack(">HHH", key_id, mask, button)


def dkup(key_id, mask, button):
    return b"DKUP" + struct.pack(">HHH", key_id, mask, button)


def test_stuck_super_is_released_on_next_plain_key():
    """Регрессия 13.09.2026: Win, зажатый на ПК при неудавшейся горячей клавише, оставался
    нажатым на Deck'е, и каждая буква в игре приходила как Win+буква."""
    o = officer()
    o.handle_key(b"DKDN", dkdn(0xEFEB, 0x0000, 91))       # Super нажат, отпускание потеряно
    assert (EV_KEY, K["LEFTMETA"], KEY_DOWN) in o.kbd.events
    o.kbd.events.clear()
    o.handle_key(b"DKDN", dkdn(ord("w"), 0x0000, 17))     # сервер говорит: модификаторов нет
    events = key_events(o)
    assert (EV_KEY, K["LEFTMETA"], KEY_UP) in events, "зависший Super отпущен"
    assert events.index((EV_KEY, K["LEFTMETA"], KEY_UP)) < events.index((EV_KEY, K["W"], KEY_DOWN)), \
        "отпущен ДО буквы, а не после"
    assert "LEFTMETA" not in o.held_keys()


def test_held_shift_survives_plain_key_with_shift_in_mask():
    o = officer()
    o.handle_key(b"DKDN", dkdn(0xEFE1, 0x0000, 42))       # Shift нажат
    o.kbd.events.clear()
    o.handle_key(b"DKDN", dkdn(ord("A"), 0x0001, 30))     # буква при зажатом Shift
    assert (EV_KEY, K["LEFTSHIFT"], KEY_UP) not in o.kbd.events, "зажатый Shift не отпускается"
    assert (EV_KEY, K["LEFTSHIFT"], KEY_DOWN) not in o.kbd.events, "и не нажимается второй раз"
    assert (EV_KEY, K["A"], KEY_DOWN) in o.kbd.events


def test_modifier_press_is_not_synced_against_its_own_mask():
    o = officer()
    o.handle_key(b"DKDN", dkdn(0xEFE3, 0x0000, 29))       # Ctrl нажимается, маска ещё без Ctrl
    assert (EV_KEY, K["LEFTCTRL"], KEY_DOWN) in o.kbd.events
    assert (EV_KEY, K["LEFTCTRL"], KEY_UP) not in o.kbd.events


def test_right_shift_satisfies_shift_bit_without_extra_left_shift():
    o = officer()
    o.handle_key(b"DKDN", dkdn(0xEFE2, 0x0000, 54))       # правый Shift
    o.kbd.events.clear()
    o.sync_modifiers(0x0001)
    assert (EV_KEY, K["LEFTSHIFT"], KEY_DOWN) not in o.kbd.events


def test_enter_presses_modifiers_from_mask_and_skips_locks():
    o = officer()
    o.enter(10, 10, 0x0001 | 0x0002 | 0x1000)
    assert (EV_KEY, K["LEFTSHIFT"], KEY_DOWN) in o.kbd.events
    assert (EV_KEY, K["LEFTCTRL"], KEY_DOWN) in o.kbd.events
    assert not [e for e in key_events(o) if e[1] == K["CAPSLOCK"]], "замок не досылается"
    o.kbd.events.clear()
    o.sync_modifiers(0x0002)
    assert (EV_KEY, K["LEFTSHIFT"], KEY_UP) in o.kbd.events
    assert (EV_KEY, K["LEFTCTRL"], KEY_DOWN) not in o.kbd.events


def test_leave_releases_everything():
    o = officer()
    o.enter(0, 0, 0x0001)
    o.handle_key(b"DKDN", dkdn(ord("a"), 0x0001, 30))
    o.button(0x110, True)
    o.leave()
    assert o.pressed == {} and o.mods == set() and o.buttons == set()
    assert o.on_screen is False


def test_key_repeat_uses_value_two():
    o = officer()
    o.handle_key(b"DKDN", dkdn(ord("a"), 0, 30))
    o.handle_key(b"DKRP", b"DKRP" + struct.pack(">HHHH", ord("a"), 0, 3, 30))
    repeats = [e for e in key_events(o) if e[2] == KEY_REPEAT]
    assert len(repeats) == 3 and all(e[1] == K["A"] for e in repeats)
    assert len([e for e in key_events(o) if e[2] == KEY_DOWN]) == 1


def test_repeat_without_press_presses_first():
    o = officer()
    o.handle_key(b"DKRP", b"DKRP" + struct.pack(">HHHH", ord("b"), 0, 2, 48))
    assert (EV_KEY, K["B"], KEY_DOWN) in o.kbd.events


def test_unknown_key_is_ignored():
    o = officer()
    o.handle_key(b"DKDN", dkdn(0xE7FF, 0, 0))              # ни скан-кода, ни знакомого символа
    o.handle_key(b"DKDN", dkdn(0xE7FF, 0, 0x160))          # расширенный скан-код вне таблицы
    assert key_events(o) == []


def test_physical_key_wins_over_character():
    # ПК в русской раскладке: символ «ф», но клавиша — та, где на латинице A (скан-код 0x1E).
    o = officer()
    o.handle_key(b"DKDN", dkdn(ord("ф"), 0, 0x1E))
    o.handle_key(b"DKUP", dkup(ord("ф"), 0, 0x1E))
    assert keys(o) == [(K["A"], KEY_DOWN), (K["A"], KEY_UP)]


def test_russian_dot_is_the_slash_key_not_the_dot_key():
    # «.» в русской раскладке стоит на клавише «/»: по символу вышла бы не та клавиша.
    o = officer()
    o.handle_key(b"DKDN", dkdn(ord("."), 0, 0x35))
    assert keys(o) == [(K["SLASH"], KEY_DOWN)]


def test_extended_scan_codes_are_arrows_and_right_modifiers():
    pressed = []
    for button in (0x148, 0x11D, 0x138, 0x15B, 0x153):      # ↑, правый Ctrl, правый Alt, Win, Delete
        o = officer()
        o.handle_key(b"DKDN", dkdn(0, 0, button))
        pressed.append(keys(o)[0][0])
    assert pressed == [K["UP"], K["RIGHTCTRL"], K["RIGHTALT"], K["LEFTMETA"], K["DELETE"]]


def test_alt_shift_reaches_the_deck_as_two_keys():
    # Переключение языка — дело Deck'а: до него доходят сами клавиши Alt и Shift.
    o = officer()
    o.handle_key(b"DKDN", dkdn(0xEFE9, 0, 0x38))
    o.handle_key(b"DKDN", dkdn(0xEFE1, 0x0004, 0x2A))
    assert [code for code, value in keys(o) if value == KEY_DOWN] == [K["LEFTALT"], K["LEFTSHIFT"]]


def test_102nd_key_is_declared_by_the_keyboard():
    from core.officers.input_translation_officer import KEYBOARD_CODES
    assert K["102ND"] in KEYBOARD_CODES


def test_wheel_rounds_towards_zero():
    o = officer()
    o.wheel(0, -40)
    assert not [e for e in o.mouse.events if e[0] == EV_REL]
    o.wheel(0, -40)
    o.wheel(0, -40)
    assert [e for e in o.mouse.events if e[0] == EV_REL and e[1] == REL_WHEEL] == [(EV_REL, REL_WHEEL, -1)]


def test_absolute_axis_maps_edges():
    o = officer()
    o.move_abs(0, 0)
    o.move_abs(1279, 799)
    xs = [e[2] for e in o.mouse.events if e[0] == EV_ABS and e[1] == 0]
    assert xs[0] == 0 and xs[1] == 32767
    assert not [e for e in o.mouse.events if e[0] == EV_REL]


def test_relative_pointer_recalibrates_on_enter_then_moves_exactly():
    o = officer(pointer=POINTER_REL)
    o.enter(200, 100, 0)
    rel = [e for e in o.mouse.events if e[0] == EV_REL]
    assert rel[:2] == [(EV_REL, REL_X, -30000), (EV_REL, REL_Y, -30000)], "сначала прижать к углу"
    assert (EV_REL, REL_X, 200) in rel and (EV_REL, REL_Y, 100) in rel, "затем ровно в точку входа"
    o.mouse.events.clear()
    o.move_abs(210, 95)
    assert o.mouse.events[:2] == [(EV_REL, REL_X, 10), (EV_REL, REL_Y, -5)]


def test_relative_model_clamps_at_screen_edge():
    o = officer(pointer=POINTER_REL)
    o.enter(1270, 10, 0)
    o.move_rel(500, 0)                    # композитор упрёт курсор в край
    assert o.cursor == (1279, 10)
    o.mouse.events.clear()
    o.move_abs(1200, 10)
    assert (EV_REL, REL_X, -79) in o.mouse.events, "модель не уехала за край вслед за смещением"


def test_pointer_switch_while_on_screen_replaces_cursor():
    o = officer(pointer=POINTER_ABS)
    o.enter(300, 300, 0)
    o.mouse.events.clear()
    assert o.set_pointer(POINTER_REL) is True
    rel = [e for e in o.mouse.events if e[0] == EV_REL]
    assert (EV_REL, REL_X, -30000) in rel and (EV_REL, REL_X, 300) in rel, \
        "при смене на смещения курсор прижат к углу и поставлен в прежнюю точку"
    assert o.set_pointer(POINTER_REL) is False
