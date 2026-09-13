// НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Окно SteamDeck-KVM на Steam Deck: состояние связи, пара с компьютером, обновление
//
// Окно ничего не решает само: всё состояние и все действия идут через локальный интерфейс службы
// (core/control_api_facade.py). Поэтому окно можно закрыть в любой момент — связь держит служба.
//
// Импорты с номером версии 2.15 намеренно: так один файл читают и Qt 6 (рабочий стол Plasma 6), и
// Qt 5 (Plasma 5 на старых SteamOS). Своих контролов из QtQuick.Controls не берётся: их вид
// задаёт тема системы, а окно обязано выглядеть как приложение на ПК — цвета, гарнитура и радиусы
// приходят из того же контракта палитры.
import QtQuick 2.15
import QtQuick.Window 2.15

Window {
    id: root
    width: 560
    height: Math.min(content.implicitHeight + 2 * pad, 760)
    minimumWidth: 480
    visible: true
    title: "Общая клавиатура и мышь"
    color: theme("фон", "#151517")

    readonly property int pad: 20
    property var status: ({})
    property bool alive: false
    property string confirming: ""     // "forget" | "uninstall" | ""
    property string note: ""
    property bool showLog: false

    function theme(name, fallback) {
        var p = status.palette
        return (p && p.theme && p.theme[name]) ? p.theme[name] : fallback
    }
    function radius(name, fallback) {
        var p = status.palette
        return (p && p.radii && p.radii[name]) ? p.radii[name] : fallback
    }
    readonly property string fontFamily: (status.palette && status.palette.font) ? status.palette.font : ""

    readonly property var stateWords: ({
        "starting": "Служба поднимается",
        "waiting_pc": "Ждём компьютер",
        "pc_off": "Компьютер рядом — нажмите «Включить» на нём",
        "connecting": "Соединяемся",
        "connected": "Подключено",
        "display_off": "Экран Deck'а погас — связь снята",
        "no_uinput": "Нет доступа к устройствам ввода"
    })
    readonly property var stateHints: ({
        "starting": "Несколько секунд после включения Deck'а — это нормально.",
        "waiting_pc": "Откройте приложение на компьютере. Deck найдёт его сам, адрес вводить не нужно.",
        "pc_off": "Компьютер в сети, но общая клавиатура на нём выключена.",
        "connecting": "Компьютер нашёлся, поднимаем связь.",
        "connected": "Доведите курсор на компьютере до края экрана или нажмите Ctrl+Alt+→. Обратно — Ctrl+Alt+←.",
        "display_off": "Так курсор не уйдёт в погасший экран. Экран загорится — связь вернётся сама.",
        "no_uinput": "Запустите установщик ещё раз — он выдаст доступ."
    })

    function api(method, path, done) {
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            var data = null
            try { data = JSON.parse(xhr.responseText) } catch (e) { data = null }
            done(xhr.status === 0 ? null : data)
        }
        xhr.open(method, "http://127.0.0.1:24802/" + path)
        if (method === "POST") xhr.setRequestHeader("X-SteamDeck-KVM", "1")
        xhr.send()
    }

    function act(name) {
        root.confirming = ""
        api("POST", name, function(data) {
            root.note = data && data.message ? data.message : "служба не ответила"
        })
    }

    Timer {
        interval: 1000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: api("GET", "status", function(data) {
            if (data) { root.status = data; root.alive = true } else { root.alive = false }
        })
    }

    // Кнопка своего вида: фон, скругление и гарнитура из контракта, а не из темы системы.
    component AppButton: Rectangle {
        id: button
        property string text: ""
        property bool accent: false
        property bool danger: false
        signal clicked()
        implicitHeight: 40
        implicitWidth: label.implicitWidth + 32
        radius: root.radius("кнопка", 8)
        color: accent ? root.theme("акцент", "#6eaaff")
             : danger ? root.theme("тревога", "#f0857a")
             : (area.containsMouse ? root.theme("линия", "#303238") : root.theme("подсветка", "#282a2f"))
        border.width: accent || danger ? 0 : 1
        border.color: root.theme("линия", "#303238")
        opacity: enabled ? 1 : 0.45
        Text {
            id: label
            anchors.centerIn: parent
            text: button.text
            color: (button.accent || button.danger) ? root.theme("фон", "#151517") : root.theme("текст", "#f0f1f4")
            font.family: root.fontFamily
            font.pixelSize: 14
            font.bold: button.accent
        }
        MouseArea {
            id: area
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: if (button.enabled) button.clicked()
        }
    }

    component Fact: Row {
        property string label: ""
        property string value: ""
        spacing: 0
        Text { width: 150; text: parent.label; color: root.theme("текст_второй", "#a0a5ad"); font.family: root.fontFamily; font.pixelSize: 14 }
        Text { width: root.width - 2 * root.pad - 150; text: parent.value; elide: Text.ElideRight
               color: root.theme("текст", "#f0f1f4"); font.family: root.fontFamily; font.pixelSize: 14; font.bold: true }
    }

    Flickable {
        anchors.fill: parent
        anchors.margins: root.pad
        contentHeight: content.implicitHeight
        clip: true

        Column {
            id: content
            width: parent.width
            spacing: 14

            // --- карточка состояния ---
            Rectangle {
                width: parent.width
                height: cardColumn.implicitHeight + 36
                radius: root.radius("карточка", 16)
                color: root.theme("карточка", "#1e1f23")
                Row {
                    x: 18; y: 18
                    spacing: 14
                    Rectangle {
                        width: 14; height: 14; radius: 7; y: 9
                        color: !root.alive ? root.theme("тревога", "#f0857a")
                             : root.status.state === "connected" ? root.theme("успех", "#46c878")
                             : (root.status.state === "display_off" || root.status.state === "no_uinput") ? root.theme("ожидание", "#e6b446")
                             : root.theme("акцент", "#6eaaff")
                    }
                    Column {
                        id: cardColumn
                        width: content.width - 36 - 28
                        spacing: 6
                        Text {
                            text: !root.alive ? "Служба не отвечает" : (root.stateWords[root.status.state] || "…")
                            color: root.theme("текст", "#f0f1f4"); font.family: root.fontFamily
                            font.pixelSize: 22; font.bold: true; wrapMode: Text.WordWrap; width: parent.width
                        }
                        Text {
                            text: !root.alive ? "Служба запускается сама при входе в сеанс. Если сообщение не уходит — перезагрузите Deck."
                                              : (root.stateHints[root.status.state] || "")
                            color: root.theme("текст_второй", "#a0a5ad"); font.family: root.fontFamily
                            font.pixelSize: 14; wrapMode: Text.WordWrap; width: parent.width
                        }
                    }
                }
            }

            // --- обновление: строка появляется, только когда обновление есть ---
            AppButton {
                width: parent.width
                visible: root.alive && !!root.status.update_available
                accent: true
                enabled: !root.status.updating
                text: root.status.updating ? "Обновляется…" : "Обновить до " + root.status.update_available
                onClicked: root.act("update")
            }
            Text {
                visible: !!root.status.update_error
                text: "Обновление не удалось: " + root.status.update_error
                color: root.theme("тревога", "#f0857a"); font.family: root.fontFamily; font.pixelSize: 13
                wrapMode: Text.WordWrap; width: parent.width
            }

            // --- факты ---
            Column {
                width: parent.width
                spacing: 8
                Fact { label: "Компьютер"; value: root.status.pc_name ? (root.status.pc_name + (root.status.pc_address ? " · " + root.status.pc_address : "")) : (root.status.paired ? "знаком, сейчас не в сети" : "ещё не знакомы") }
                Fact { label: "Режим"; value: root.status.mode === "game" ? "игровой" : root.status.mode === "desktop" ? "рабочий стол" : "не определён" }
                Fact { label: "Курсор"; value: root.status.pointer === "rel" ? "смещениями — для игрового режима" : "по абсолютной оси — для рабочего стола" }
                Fact { label: "Версия"; value: root.status.version || "—" }
            }

            // --- подтверждение своим видом, а не системным окном ---
            Rectangle {
                visible: root.confirming !== ""
                width: parent.width
                height: confirmColumn.implicitHeight + 28
                radius: root.radius("карточка", 16)
                color: root.theme("подсветка", "#282a2f")
                Column {
                    id: confirmColumn
                    x: 14; y: 14; width: parent.width - 28; spacing: 10
                    Text {
                        width: parent.width; wrapMode: Text.WordWrap
                        color: root.theme("текст", "#f0f1f4"); font.family: root.fontFamily; font.pixelSize: 14
                        text: root.confirming === "forget"
                              ? "Deck забудет компьютер и познакомится со следующим, который включит общую клавиатуру в этой сети."
                              : "Приложение удалится с Deck'а. Знакомство с компьютером можно сохранить — тогда после переустановки всё заработает без нового знакомства."
                    }
                    Row {
                        spacing: 8
                        AppButton { visible: root.confirming === "forget"; danger: true; text: "Забыть"; onClicked: root.act("forget") }
                        AppButton { visible: root.confirming === "uninstall"; danger: true; text: "Удалить, знакомство сохранить"; onClicked: root.act("uninstall_keep") }
                        AppButton { visible: root.confirming === "uninstall"; text: "Удалить всё"; onClicked: root.act("uninstall_all") }
                        AppButton { text: "Отмена"; onClicked: root.confirming = "" }
                    }
                }
            }

            // --- действия ---
            Row {
                spacing: 8
                AppButton { text: "Забыть компьютер"; enabled: root.alive && !!root.status.paired; onClicked: root.confirming = "forget" }
                AppButton { text: root.showLog ? "Скрыть журнал" : "Журнал"; enabled: root.alive; onClicked: root.showLog = !root.showLog }
                AppButton { text: "Удалить"; enabled: root.alive; onClicked: root.confirming = "uninstall" }
            }

            Text {
                visible: root.note !== ""
                text: root.note
                color: root.theme("текст_второй", "#a0a5ad"); font.family: root.fontFamily; font.pixelSize: 13
            }

            Rectangle {
                visible: root.showLog
                width: parent.width
                height: logText.implicitHeight + 24
                radius: root.radius("карточка", 16)
                color: root.theme("карточка", "#1e1f23")
                Text {
                    id: logText
                    x: 12; y: 12; width: parent.width - 24
                    text: (root.status.log || []).slice(-20).join("\n")
                    color: root.theme("текст_второй", "#a0a5ad")
                    font.family: "monospace"; font.pixelSize: 12
                    wrapMode: Text.WrapAnywhere
                }
            }

            Text {
                width: parent.width; wrapMode: Text.WordWrap
                text: "Окно можно закрыть — связь держит служба, она запускается сама при каждом включении Deck'а."
                color: root.theme("текст_второй", "#a0a5ad"); font.family: root.fontFamily; font.pixelSize: 12
            }
        }
    }
}
