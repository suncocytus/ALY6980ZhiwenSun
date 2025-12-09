"""Lightweight local stub of the `python_a2a` package used by NANDA examples.

This implements a minimal A2A message model, a simple HTTP-based server (`/a2a`)
and a client using `requests`. It is intentionally small and dependency-free so the
repository can run examples without installing the full external package.

Note: This is a best-effort compatibility shim for local development and testing
and does not implement all features of the upstream package.
"""
from http import HTTPStatus
from wsgiref.simple_server import make_server, WSGIRequestHandler
import json
import threading
import uuid
from typing import Any, Dict, Optional
import requests


class MessageRole:
    USER = "user"
    AGENT = "agent"


class TextContent:
    def __init__(self, text: str):
        self.text = text


class Metadata:
    def __init__(self, custom_fields: Optional[Dict[str, Any]] = None):
        self.custom_fields = custom_fields or {}


class Message:
    def __init__(self,
                 role: str,
                 content: TextContent,
                 conversation_id: Optional[str] = None,
                 parent_message_id: Optional[str] = None,
                 message_id: Optional[str] = None,
                 metadata: Optional[Metadata] = None):
        self.role = role
        self.content = content
        self.conversation_id = conversation_id
        self.parent_message_id = parent_message_id
        self.message_id = message_id or str(uuid.uuid4())
        self.metadata = metadata or Metadata()


class A2AServer:
    """Base server class - user should subclass and implement handle_message(msg: Message) -> Message"""
    def handle_message(self, msg: Message) -> Message:
        raise NotImplementedError()


class _SimpleResponsePart:
    def __init__(self, text: str):
        self.text = text


class _ClientResponse:
    def __init__(self, parts=None):
        self.parts = parts or []


class A2AClient:
    def __init__(self, base_url: str, timeout: int = 30):
        self.base_url = base_url.rstrip('/')
        self.timeout = timeout

    def send_message(self, message: Message):
        payload = {
            "role": message.role,
            "content": {"text": message.content.text},
            "conversation_id": message.conversation_id,
            "parent_message_id": message.parent_message_id,
            "message_id": message.message_id,
            "metadata": message.metadata.custom_fields if message.metadata else {}
        }

        resp = requests.post(f"{self.base_url}", json=payload, timeout=self.timeout)
        if resp.status_code != 200:
            resp.raise_for_status()

        try:
            data = resp.json()
        except ValueError:
            return None

        # Expecting response like {"role":..., "content": {"text": ...}} or parts
        if isinstance(data, dict) and data.get("parts"):
            parts = [ _SimpleResponsePart(p.get("text", "")) for p in data.get("parts") ]
            return _ClientResponse(parts=parts)

        # Fallback: try to extract text
        if isinstance(data, dict) and data.get("content") and isinstance(data["content"], dict):
            return _ClientResponse(parts=[ _SimpleResponsePart(data["content"].get("text", "")) ])

        return _ClientResponse(parts=[ _SimpleResponsePart(str(data)) ])


def _message_from_json(obj: Dict[str, Any]) -> Message:
    content = TextContent(obj.get("content", {}).get("text", ""))
    metadata = Metadata(custom_fields=obj.get("metadata", {}))
    return Message(
        role=obj.get("role", MessageRole.USER),
        content=content,
        conversation_id=obj.get("conversation_id"),
        parent_message_id=obj.get("parent_message_id"),
        message_id=obj.get("message_id"),
        metadata=metadata
    )


def _message_to_json(msg: Message) -> Dict[str, Any]:
    return {
        "role": msg.role,
        "message_id": msg.message_id,
        "conversation_id": msg.conversation_id,
        "parent_message_id": msg.parent_message_id,
        "content": {"text": msg.content.text},
        "metadata": msg.metadata.custom_fields if msg.metadata else {}
    }


def run_server(bridge: A2AServer, host: str = "0.0.0.0", port: int = 6000):
    """Run a minimal WSGI server exposing a single /a2a endpoint that accepts JSON POSTs.

    The bridge must implement handle_message(Message) -> Message.
    """

    def app(environ, start_response):
        path = environ.get('PATH_INFO', '')
        method = environ.get('REQUEST_METHOD', 'GET')

        if path != '/a2a' and path != '/a2a/':
            start_response(f"{HTTPStatus.NOT_FOUND.value} {HTTPStatus.NOT_FOUND.phrase}", [('Content-Type', 'text/plain')])
            return [b'Not Found']

        if method != 'POST':
            start_response(f"{HTTPStatus.METHOD_NOT_ALLOWED.value} {HTTPStatus.METHOD_NOT_ALLOWED.phrase}", [('Content-Type', 'text/plain')])
            return [b'Method Not Allowed']

        try:
            length = int(environ.get('CONTENT_LENGTH') or 0)
        except (ValueError, TypeError):
            length = 0

        body = environ['wsgi.input'].read(length) if length else b''
        try:
            payload = json.loads(body.decode('utf-8') or '{}')
        except Exception:
            payload = {}

        msg = _message_from_json(payload)

        try:
            response_msg = bridge.handle_message(msg)
            out = _message_to_json(response_msg)
            # Also provide parts for client compatibility
            out['parts'] = [{"text": response_msg.content.text}]
            body_bytes = json.dumps(out).encode('utf-8')
            start_response(f"{HTTPStatus.OK.value} {HTTPStatus.OK.phrase}", [('Content-Type', 'application/json')])
            return [body_bytes]
        except Exception as e:
            body_bytes = json.dumps({"error": str(e)}).encode('utf-8')
            start_response(f"{HTTPStatus.INTERNAL_SERVER_ERROR.value} {HTTPStatus.INTERNAL_SERVER_ERROR.phrase}", [('Content-Type', 'application/json')])
            return [body_bytes]

    server = make_server(host, port, app, handler_class=WSGIRequestHandler)

    # Print a small notice and serve forever until interrupted
    print(f"🔌 A2A server running on http://{host}:{port}/a2a (Press Ctrl+C to stop)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\n🛑 A2A server shutting down')
    finally:
        server.server_close()
