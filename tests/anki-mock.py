#!/usr/bin/env python3
"""假的 AnkiConnect，用来自测「发到 Anki」的请求格式（真实接口说明：github.com/FooSoft/anki-connect 的 API_LEGACY.md）。
用法：python3 tests/anki-mock.py [端口，默认 8799]；然后
  FANYI_SELFTEST=anki FANYI_ANKI_URL=http://127.0.0.1:8799 build/Build/Products/Release/Fanyi.app/Contents/MacOS/Fanyi
已有的词：mitigate（用来测“重复的跳过”）。收到的请求不合规就返回 error。"""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

models, notes = {}, {"mitigate"}

def handle(req):
    assert req.get("version") == 6, "version 必须是 6"
    action, p = req["action"], req.get("params", {})
    if action == "version":
        return 6
    if action == "createDeck":
        assert isinstance(p["deck"], str)
        return 1700000000000
    if action == "modelNames":
        return list(models)
    if action == "createModel":
        assert set(p) <= {"modelName", "inOrderFields", "css", "isCloze", "cardTemplates"}, f"多余的参数 {set(p)}"
        assert p["inOrderFields"] and all(isinstance(f, str) for f in p["inOrderFields"])
        for t in p["cardTemplates"]:
            assert set(t) <= {"Name", "Front", "Back"} and "Front" in t and "Back" in t, f"模板键名不对 {set(t)}"
        models[p["modelName"]] = p["inOrderFields"]
        return {"name": p["modelName"]}
    if action in ("canAddNotes", "addNotes"):
        out = []
        for n in p["notes"]:
            assert n["modelName"] in models, f"model was not found: {n['modelName']}"
            assert set(n["fields"]) == set(models[n["modelName"]]), f"字段不匹配 {set(n['fields'])}"
            first = n["fields"][models[n["modelName"]][0]]
            dup = first in notes
            if action == "canAddNotes":
                out.append(not dup)
            else:
                assert not dup, "cannot create note because it is a duplicate"
                notes.add(first)
                out.append(1700000000000 + len(notes))
                print("NOTE", json.dumps(n["fields"], ensure_ascii=False), flush=True)
        return out
    raise AssertionError(f"unsupported action {action}")

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        assert "chunked" not in self.headers.get("Transfer-Encoding", ""), "不能用分块传输"
        body = self.rfile.read(int(self.headers["Content-Length"]))
        try:
            out = {"result": handle(json.loads(body)), "error": None}
        except Exception as e:  # noqa
            out = {"result": None, "error": str(e)}
        data = json.dumps(out).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self, *a): pass

HTTPServer(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 8799), H).serve_forever()
