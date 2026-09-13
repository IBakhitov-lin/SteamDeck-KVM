# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Фасад локального интерфейса службы для окна на Steam Deck
"""
control_api_facade.py

Окно на Deck'е — отдельная программа, служба — отдельная. Окно спрашивает службу через этот
интерфейс: состояние, журнал, действия «забыть компьютер», «обновить», «перезапустить».
Фасад инфраструктуры в корне `core/`, суффикса роли не несёт — по тому же исключению канона
слоёв, что политика конфигурации.

Три решения защиты, и каждое закрывает свой путь.

1. **Слушается только `127.0.0.1`** — с другой машины в сети интерфейс не виден вовсе
2. **Действие требует заголовка `X-SteamDeck-KVM`** — страница в браузере на самом Deck'е
   может отправить запрос на локальный адрес, но не может приложить свой заголовок без
   предварительного согласования, которого интерфейс не даёт. Так чужая страница не
   «забудет компьютер» за человека
3. **Действия идут очередью в поток службы**, а не выполняются в потоке запроса: сеанс связи
   и память о паре меняет только служба, и одновременной правки двумя потоками не бывает
"""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from core import config_policy

ACTION_HEADER = "X-SteamDeck-KVM"
ACTIONS = ("forget", "update", "restart", "uninstall_keep", "uninstall_all")


class ControlApiFacade:
    def __init__(self, snapshot, act, port=None, host="127.0.0.1"):
        """snapshot() -> dict состояния; act(имя) -> (успех, сообщение)."""
        self._snapshot = snapshot
        self._act = act
        self._port = config_policy.CONTROL_PORT if port is None else port
        self._host = host
        self._server = None
        self._thread = None

    @property
    def port(self):
        return self._server.server_address[1] if self._server else self._port

    def start(self):
        facade = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass  # журнал службы ведёт командир; построчный шум запросов в него не идёт

            def _reply(self, code, payload):
                body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
                self.send_response(code)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                if self.path.split("?")[0] == "/status":
                    self._reply(200, facade._snapshot())
                else:
                    self._reply(404, {"error": "нет такого адреса"})

            def do_POST(self):
                name = self.path.strip("/").split("?")[0]
                if self.headers.get(ACTION_HEADER) != "1":
                    self._reply(403, {"error": "действие без заголовка приложения отклонено"})
                    return
                if name not in ACTIONS:
                    self._reply(404, {"error": "нет такого действия"})
                    return
                ok, message = facade._act(name)
                self._reply(200 if ok else 409, {"ok": ok, "message": message})

        self._server = ThreadingHTTPServer((self._host, self._port), Handler)
        self._server.daemon_threads = True
        self._thread = threading.Thread(target=self._server.serve_forever, name="control-api", daemon=True)
        self._thread.start()
        return self

    def stop(self):
        if self._server:
            self._server.shutdown()
            self._server.server_close()
            self._server = None
