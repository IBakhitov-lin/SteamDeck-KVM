// НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Окно «Компьютер» на рабочем столе Steam Deck: пункт в списке Alt+Tab, выбор возвращает управление на компьютер
//
// Зеркало окна «Steam Deck» на компьютере. На рабочем столе Deck'а Alt+Tab с клавиатуры компьютера
// доходит до переключателя окон KWin; среди окон стоит это — свёрнутое, невидимое, с именем
// «Компьютер». Выбрали его — окно просит службу вернуть управление и снова сворачивается, а KWin
// возвращает фокус окну, где человек работал. В игровом режиме окон нет: там Alt+Tab ловит сама
// служба. Окно есть в списке, только пока компьютер подключён и переход по Alt+Tab включён на нём.
//
// Импорты с номером версии 2.15 — как у окна состояния: один файл читают Qt 6 и Qt 5.
import QtQuick 2.15
import QtQuick.Window 2.15

Window {
    id: root
    title: "Компьютер"
    width: 1
    height: 1
    color: "transparent"
    visible: false
    property bool busy: false

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

    Timer {
        interval: 1500; running: true; repeat: true; triggeredOnStart: true
        onTriggered: root.api("GET", "status", function(data) {
            var wanted = !!data && data.state === "connected" && data.alt_tab !== false
            if (wanted && !root.visible) root.showMinimized()
            else if (!wanted && root.visible) root.hide()
        })
    }

    // Выбор в Alt+Tab делает окно активным: это и есть «вернуть на компьютер».
    onActiveChanged: {
        if (!active || !visible || busy) return
        busy = true
        api("POST", "to_pc", function(data) { root.busy = false })
        showMinimized()
    }
}
