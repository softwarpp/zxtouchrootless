import json
import os
import sys
import unittest


PYTHON_CLIENT_ROOT = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "layout", "usr", "share", "zxtouch", "python")
)
sys.path.insert(0, PYTHON_CLIENT_ROOT)

from zxtouch import datahandler, tasktypes  # noqa: E402
from zxtouch.client import zxtouch  # noqa: E402


class ChunkedSocket:
    def __init__(self, chunks):
        self.chunks = list(chunks)
        self.sent = []

    def sendall(self, data):
        self.sent.append(data)

    def send(self, data):
        self.sent.append(data)
        return len(data)

    def recv(self, size):
        if not self.chunks:
            return b""
        chunk = self.chunks[0]
        result = chunk[:size]
        if len(result) == len(chunk):
            self.chunks.pop(0)
        else:
            self.chunks[0] = chunk[size:]
        return result


def make_device(chunks):
    device = zxtouch.__new__(zxtouch)
    device.s = ChunkedSocket(chunks)
    device._recv_buffer = bytearray()
    return device


ELEMENTS = [
    {"index": 0, "type": "control", "text": "通用", "clickable": True,
     "rect": {"x": 10, "y": 20, "width": 80, "height": 40}, "tap": {"x": 50, "y": 40}},
    {"index": 1, "type": "element", "text": "设置", "clickable": False,
     "rect": {"x": 0, "y": 0, "width": 100, "height": 80}},
]
SNAPSHOT = {"screen": {"width": 375, "height": 667}, "count": 2, "elements": ELEMENTS}


def framed_response(payload):
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    return b"0;;application/json;;%d\r\n" % len(data) + data


class AXProtocolTests(unittest.TestCase):
    def test_fragmented_unicode_snapshot_and_following_response(self):
        response = framed_response({"jsonrpc": "2.0", "id": 1,
                                    "result": {"structuredContent": SNAPSHOT}})
        device = make_device([response[:5], response[5:43], response[43:] + b"0;;1170;;2532\r\n"])
        snapshot = device.get_ui_elements()
        self.assertEqual(snapshot["elements"][0]["text"], "通用")
        self.assertEqual(device.find_elements(text="通用", clickable=True, snapshot=snapshot), ELEMENTS[:1])
        self.assertEqual(device.find_elements(type="element", snapshot=snapshot), ELEMENTS[1:])
        self.assertEqual(device.get_screen_size(), (True, {"width": "1170", "height": "2532"}))
        self.assertEqual(device.s.sent[0], datahandler.format_socket_data(tasktypes.TASK_ACCESSIBILITY_TREE))

    def test_hierarchy_and_identifier_query(self):
        tree = {"pid": 123, "count": 3, "root": {
            "role": "AXApplication", "children": [
                {"identifier": "settings", "label": "设置", "children": [
                    {"identifier": "general", "label": "通用", "role": "AXButton",
                     "frame": {"x": 10, "y": 20, "width": 80, "height": 40},
                     "children": []}
                ]}
            ]}}
        response = framed_response(tree)
        device = make_device([response[:7], response[7:30], response[30:]])
        self.assertEqual(device.get_element_tree(), tree)
        found = device.find_tree_elements(identifier="general", role="AXButton", tree=tree)
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0]["label"], "通用")
        self.assertEqual(device.s.sent, [datahandler.format_socket_data(
            tasktypes.TASK_ACCESSIBILITY_HIERARCHY)])

    def test_hierarchy_rejects_missing_root(self):
        device = make_device([framed_response({"count": 0})])
        with self.assertRaisesRegex(RuntimeError, "missing root"):
            device.get_element_tree()

    def test_json_rpc_error(self):
        device = make_device([framed_response({"jsonrpc": "2.0", "id": 1,
                                              "error": {"code": -32602, "message": "bad args"}})])
        with self.assertRaisesRegex(RuntimeError, "bad args"):
            device.get_ui_elements()

    def test_ax_backend_error(self):
        device = make_device([framed_response({"jsonrpc": "2.0", "id": 1,
                                              "result": {"isError": True,
                                                         "structuredContent": {"ok": False, "error": "timeout"}}})])
        with self.assertRaisesRegex(RuntimeError, "timeout"):
            device.get_ui_elements()

    def test_socket_error(self):
        device = make_device([b"-1;;AX service unavailable or request failed\r\n"])
        with self.assertRaisesRegex(RuntimeError, "AX service unavailable"):
            device.get_ui_elements()

    def test_missing_elements(self):
        device = make_device([framed_response({"result": {"structuredContent": {"count": 0}}})])
        with self.assertRaisesRegex(RuntimeError, "elements array"):
            device.get_ui_elements()


if __name__ == "__main__":
    unittest.main()
