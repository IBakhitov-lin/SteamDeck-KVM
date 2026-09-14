# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Проверки локального интерфейса службы: состояние, действия, защита от чужой страницы
from __future__ import annotations

import json
import urllib.error
import urllib.request

import pytest

from core.control_api_facade import ACTION_HEADER, ControlApiFacade


@pytest.fixture
def api():
    calls = []
    facade = ControlApiFacade(lambda: {"state": "connected", "pc_name": "DESKTOP-PC"},
                              lambda name: (calls.append(name) or True, "принято"), port=0).start()
    facade.calls = calls
    yield facade
    facade.stop()


def request(api, path, method="GET", header=True):
    req = urllib.request.Request("http://127.0.0.1:%d/%s" % (api.port, path), method=method,
                                 data=b"" if method == "POST" else None)
    if header and method == "POST":
        req.add_header(ACTION_HEADER, "1")
    try:
        with urllib.request.urlopen(req, timeout=5) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read())


def test_status_is_served(api):
    code, body = request(api, "status")
    assert code == 200 and body == {"state": "connected", "pc_name": "DESKTOP-PC"}


def test_action_with_header_reaches_service(api):
    code, body = request(api, "forget", method="POST")
    assert code == 200 and body["ok"] is True and api.calls == ["forget"]


def test_action_without_header_is_refused(api):
    code, _ = request(api, "forget", method="POST", header=False)
    assert code == 403 and api.calls == [], "страница в браузере не забудет компьютер за человека"


def test_unknown_action_and_path(api):
    assert request(api, "format-disk", method="POST")[0] == 404
    assert request(api, "nothing")[0] == 404
