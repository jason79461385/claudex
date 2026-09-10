#!/usr/bin/env python3
"""Local Anthropic-Messages to OpenAI-Chat-Completions bridge for claudeop.

The bridge is intentionally localhost-only. It forwards the OpenCode Go key
upstream and never logs request headers or bodies.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import sys
import urllib.error
import urllib.request
import uuid
from urllib.parse import unquote, urlsplit
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


class BridgeRequestError(Exception):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.message = message


class UpstreamError(BridgeRequestError):
    pass


def json_bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()


def text_from_content(content: Any) -> str:
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts: list[str] = []
    for block in content:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "text":
            parts.append(str(block.get("text", "")))
        elif block.get("type") == "tool_result":
            parts.append(text_from_content(block.get("content", "")))
    return "".join(parts)


def openai_content(content: Any) -> Any:
    """Convert text and the common Anthropic image shape to OpenAI content."""
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""

    parts: list[dict[str, Any]] = []
    for block in content:
        if not isinstance(block, dict):
            continue
        kind = block.get("type")
        if kind == "text":
            parts.append({"type": "text", "text": str(block.get("text", ""))})
        elif kind == "image":
            source = block.get("source") or {}
            if source.get("type") == "base64":
                media = source.get("media_type", "application/octet-stream")
                data = source.get("data", "")
                parts.append({
                    "type": "image_url",
                    "image_url": {"url": f"data:{media};base64,{data}"},
                })
            elif source.get("type") == "url":
                parts.append({
                    "type": "image_url",
                    "image_url": {"url": source.get("url", "")},
                })
            else:
                raise BridgeRequestError(400, "unsupported Anthropic image source")
        elif kind in {"thinking", "redacted_thinking"}:
            continue
        elif kind == "tool_result":
            # Tool results are split into role=tool messages by translate_messages.
            continue
        elif kind:
            raise BridgeRequestError(400, f"unsupported Anthropic content block: {kind}")

    if not parts:
        return ""
    if len(parts) == 1 and parts[0]["type"] == "text":
        return parts[0]["text"]
    return parts


def tool_arguments(value: Any) -> str:
    return json.dumps(value if isinstance(value, dict) else {}, ensure_ascii=False, separators=(",", ":"))


def translate_messages(messages: list[dict[str, Any]], system: Any) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    system_text = text_from_content(system)
    if system_text:
        result.append({"role": "system", "content": system_text})

    for message in messages:
        role = message.get("role", "user")
        content = message.get("content", "")
        blocks = content if isinstance(content, list) else [{"type": "text", "text": content}]

        if role == "system":
            text = text_from_content(content)
            if text:
                result.append({"role": "system", "content": text})
            continue

        if role == "assistant":
            text_parts: list[str] = []
            tool_calls: list[dict[str, Any]] = []
            for block in blocks:
                if not isinstance(block, dict):
                    continue
                kind = block.get("type")
                if kind == "text":
                    text_parts.append(str(block.get("text", "")))
                elif kind == "tool_use":
                    tool_calls.append({
                        "id": block.get("id") or f"tool_{uuid.uuid4().hex[:12]}",
                        "type": "function",
                        "function": {
                            "name": block.get("name", "tool"),
                            "arguments": tool_arguments(block.get("input", {})),
                        },
                    })
                elif kind in {"thinking", "redacted_thinking"}:
                    continue
            assistant: dict[str, Any] = {
                "role": "assistant",
                "content": "".join(text_parts) if text_parts else None,
            }
            if tool_calls:
                assistant["tool_calls"] = tool_calls
            result.append(assistant)
            continue

        # A user message may contain ordinary text and one or more tool results.
        text_parts = []
        for block in blocks:
            if not isinstance(block, dict):
                continue
            kind = block.get("type")
            if kind == "tool_result":
                result.append({
                    "role": "tool",
                    "tool_call_id": block.get("tool_use_id", ""),
                    "content": text_from_content(block.get("content", "")),
                })
            elif kind in {"text", "image"}:
                text_parts.append(block)
            elif kind in {"thinking", "redacted_thinking"}:
                continue
            elif kind:
                raise BridgeRequestError(400, f"unsupported Anthropic content block: {kind}")

        if text_parts:
            result.append({"role": "user", "content": openai_content(text_parts)})
        elif not any(isinstance(block, dict) and block.get("type") == "tool_result" for block in blocks):
            result.append({"role": "user", "content": ""})

    return result


def translate_tools(tools: Any) -> list[dict[str, Any]]:
    translated: list[dict[str, Any]] = []
    for tool in tools or []:
        if not isinstance(tool, dict):
            continue
        name = tool.get("name")
        schema = tool.get("input_schema")
        if not name or not isinstance(schema, dict):
            continue
        translated.append({
            "type": "function",
            "function": {
                "name": name,
                "description": tool.get("description", ""),
                "parameters": schema,
            },
        })
    return translated


def build_chat_request(request: dict[str, Any], model: str) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "model": model,
        "messages": translate_messages(request.get("messages", []), request.get("system", "")),
        "max_tokens": request.get("max_tokens", 4096),
        "stream": bool(request.get("stream", False)),
    }
    for source, target in (("temperature", "temperature"), ("top_p", "top_p")):
        if source in request:
            payload[target] = request[source]
    if request.get("stop_sequences"):
        payload["stop"] = request["stop_sequences"]

    tools = translate_tools(request.get("tools"))
    if tools:
        payload["tools"] = tools

    choice = request.get("tool_choice")
    if isinstance(choice, dict):
        kind = choice.get("type")
        if kind == "none":
            payload["tool_choice"] = "none"
        elif kind == "any":
            payload["tool_choice"] = "required"
        elif kind == "tool" and choice.get("name"):
            payload["tool_choice"] = {
                "type": "function",
                "function": {"name": choice["name"]},
            }
        else:
            payload["tool_choice"] = "auto"
    elif choice:
        payload["tool_choice"] = choice

    return payload


def anthropic_message(response: dict[str, Any], model: str) -> dict[str, Any]:
    choice = (response.get("choices") or [{}])[0]
    message = choice.get("message") or {}
    content: list[dict[str, Any]] = []
    text = message.get("content")
    if isinstance(text, str) and text:
        content.append({"type": "text", "text": text})

    for call in message.get("tool_calls") or []:
        function = call.get("function") or {}
        try:
            arguments = json.loads(function.get("arguments") or "{}")
        except json.JSONDecodeError:
            arguments = {"_raw_arguments": function.get("arguments", "")}
        content.append({
            "type": "tool_use",
            "id": call.get("id") or f"tool_{uuid.uuid4().hex[:12]}",
            "name": function.get("name", "tool"),
            "input": arguments,
        })

    if not content:
        content.append({"type": "text", "text": ""})

    finish = choice.get("finish_reason")
    stop_reason = {
        "tool_calls": "tool_use",
        "function_call": "tool_use",
        "length": "max_tokens",
        "content_filter": "end_turn",
    }.get(finish, "end_turn")
    usage = response.get("usage") or {}
    return {
        "id": response.get("id") or f"msg_bridge_{uuid.uuid4().hex}",
        "type": "message",
        "role": "assistant",
        "model": model,
        "content": content,
        "stop_reason": stop_reason,
        "stop_sequence": None,
        "usage": {
            "input_tokens": int(usage.get("prompt_tokens", 0) or 0),
            "output_tokens": int(usage.get("completion_tokens", 0) or 0),
        },
    }


def error_message(message: str, error_type: str = "api_error") -> dict[str, Any]:
    return {"type": "error", "error": {"type": error_type, "message": message}}


def parse_upstream_error(error: urllib.error.HTTPError) -> tuple[int, str]:
    try:
        body = error.read().decode("utf-8", "replace")
        parsed = json.loads(body)
        if isinstance(parsed, dict):
            if isinstance(parsed.get("error"), dict):
                return error.code, str(parsed["error"].get("message", body))
            return error.code, str(parsed.get("message", body))
        return error.code, body
    except Exception:
        return error.code, str(error)


class BridgeHandler(BaseHTTPRequestHandler):
    upstream_url = ""
    api_key = ""
    model = ""
    session_id = ""

    def log_message(self, format: str, *args: Any) -> None:
        # Do not log request paths with query strings or any request data.
        sys.stderr.write("claudeop-bridge: " + (format % args) + "\n")

    def _send_json(self, status: int, body: dict[str, Any]) -> None:
        data = json_bytes(body)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _debug(self, message: str) -> None:
        if os.environ.get("CLAUDEOP_DEBUG") == "1":
            sys.stderr.write(f"claudeop-bridge: {message}\\n")
            sys.stderr.flush()

    def _open_upstream(self, payload: dict[str, Any]):
        request = urllib.request.Request(
            self.upstream_url,
            data=json_bytes(payload),
            method="POST",
            headers={
                "Accept": "text/event-stream" if payload.get("stream") else "application/json",
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
                "User-Agent": "claudeop/1.0",
                "x-opencode-session": self.session_id,
            },
        )
        try:
            return urllib.request.urlopen(request, timeout=600)
        except urllib.error.HTTPError as error:
            status, message = parse_upstream_error(error)
            raise UpstreamError(status, message) from error
        except urllib.error.URLError as error:
            raise UpstreamError(502, f"OpenCode Go connection failed: {error.reason}") from error

    def do_HEAD(self) -> None:
        # Claude Code performs a lightweight health probe before Messages.
        path = urlsplit(self.path).path
        if path in {"/api/hello", "/v1/api/hello", "/v1/models"} or path.startswith("/v1/models/"):
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self) -> None:
        # Claude Code may probe the selected model before sending Messages.
        # Keep that local compatibility probe independent of the upstream
        # OpenCode catalogue and never forward the API key for it.
        path = urlsplit(self.path).path
        if path == "/api/hello":
            self._send_json(200, {"status": "ok"})
            return
        if path == "/v1/models" or path.startswith("/v1/models/"):
            model_id = unquote(path.rsplit("/", 1)[-1]) if path != "/v1/models" else self.model
            if not model_id:
                self._send_json(404, error_message("bridge model is not configured", "not_found_error"))
                return
            self._send_json(200, {
                "type": "model",
                "id": model_id,
                "object": "model",
                "created": 0,
                "owned_by": "opencode",
                "display_name": model_id,
            } if path != "/v1/models" else {
                "object": "list",
                "data": [{
                    "type": "model",
                    "id": model_id,
                    "object": "model",
                    "created": 0,
                    "owned_by": "opencode",
                    "display_name": model_id,
                }],
                "has_more": False,
            })
            return
        self._send_json(404, error_message("bridge only serves GET /v1/models and POST /v1/messages", "not_found_error"))

    def do_POST(self) -> None:
        if urlsplit(self.path).path != "/v1/messages":
            self._send_json(404, error_message("bridge only serves POST /v1/messages", "not_found_error"))
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
            request = json.loads(self.rfile.read(length))
            if not isinstance(request, dict):
                raise BridgeRequestError(400, "request body must be a JSON object")
            # Claude Code's model label is a local compatibility value. The
            # bridge always pins the upstream request to the selected OpenCode
            # model passed at startup.
            model = self.model or str(request.get("model") or "")
            payload = build_chat_request(request, model)
            if request.get("stream"):
                self._stream(payload, model)
            else:
                with self._open_upstream(payload) as upstream:
                    response = json.loads(upstream.read())
                self._send_json(200, anthropic_message(response, model))
        except json.JSONDecodeError as error:
            self._send_json(400, error_message(f"invalid JSON request: {error}", "invalid_request_error"))
        except BridgeRequestError as error:
            self._debug(f"request failed with HTTP {error.status}: {error.message}")
            self._send_json(error.status, error_message(error.message, "invalid_request_error"))
        except Exception as error:
            self._debug(f"request failed: {type(error).__name__}: {error}")
            self._send_json(502, error_message(f"bridge error: {error}"))

    def _sse(self, event: str, body: dict[str, Any]) -> None:
        data = json_bytes(body)
        self.wfile.write(f"event: {event}\ndata: ".encode() + data + b"\n\n")
        self.wfile.flush()

    def _stream(self, payload: dict[str, Any], model: str) -> None:
        try:
            upstream = self._open_upstream(payload)
        except BridgeRequestError as error:
            self._debug(f"stream failed with HTTP {error.status}: {error.message}")
            self._send_json(error.status, error_message(error.message))
            return

        message_id = f"msg_bridge_{uuid.uuid4().hex}"
        self.send_response(200)
        self.close_connection = True
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        self._sse("message_start", {
            "type": "message_start",
            "message": {
                "id": message_id,
                "type": "message",
                "role": "assistant",
                "model": model,
                "content": [],
                "stop_reason": None,
                "stop_sequence": None,
                "usage": {"input_tokens": 0, "output_tokens": 0},
            },
        })

        next_content_index = 0
        text_index: int | None = None
        tool_indices: dict[int, int] = {}
        finish_reason = "stop"
        output_tokens = 0
        try:
            for raw_line in upstream:
                line = raw_line.decode("utf-8", "replace").strip()
                if not line or not line.startswith("data:"):
                    continue
                raw_data = line[5:].strip()
                if raw_data == "[DONE]":
                    break
                try:
                    chunk = json.loads(raw_data)
                except json.JSONDecodeError:
                    continue

                usage = chunk.get("usage") or {}
                output_tokens = int(usage.get("completion_tokens", output_tokens) or output_tokens)
                for choice in chunk.get("choices") or []:
                    finish_reason = choice.get("finish_reason") or finish_reason
                    delta = choice.get("delta") or {}
                    text = delta.get("content")
                    if isinstance(text, str) and text:
                        if text_index is None:
                            text_index = next_content_index
                            next_content_index += 1
                            self._sse("content_block_start", {
                                "type": "content_block_start",
                                "index": text_index,
                                "content_block": {"type": "text", "text": ""},
                            })
                        self._sse("content_block_delta", {
                            "type": "content_block_delta",
                            "index": text_index,
                            "delta": {"type": "text_delta", "text": text},
                        })

                    for call in delta.get("tool_calls") or []:
                        call_index = int(call.get("index", 0))
                        if call_index not in tool_indices:
                            block_index = next_content_index
                            next_content_index += 1
                            tool_indices[call_index] = block_index
                            function = call.get("function") or {}
                            self._sse("content_block_start", {
                                "type": "content_block_start",
                                "index": block_index,
                                "content_block": {
                                    "type": "tool_use",
                                    "id": call.get("id") or f"tool_{call_index}_{uuid.uuid4().hex[:8]}",
                                    "name": function.get("name", "tool"),
                                    "input": {},
                                },
                            })
                        block_index = tool_indices[call_index]
                        arguments = (call.get("function") or {}).get("arguments")
                        if arguments:
                            self._sse("content_block_delta", {
                                "type": "content_block_delta",
                                "index": block_index,
                                "delta": {"type": "input_json_delta", "partial_json": arguments},
                            })
        except (BrokenPipeError, ConnectionResetError):
            return
        except Exception as error:
            self._debug(f"stream failed: {type(error).__name__}: {error}")
            try:
                self._sse("error", {
                    "type": "error",
                    "error": {"type": "api_error", "message": str(error)},
                })
            except (BrokenPipeError, ConnectionResetError):
                return
        finally:
            upstream.close()

        try:
            for index in sorted(([text_index] if text_index is not None else []) + list(tool_indices.values())):
                self._sse("content_block_stop", {"type": "content_block_stop", "index": index})
            stop_reason = {
                "tool_calls": "tool_use",
                "function_call": "tool_use",
                "length": "max_tokens",
            }.get(finish_reason, "end_turn")
            self._sse("message_delta", {
                "type": "message_delta",
                "delta": {"stop_reason": stop_reason, "stop_sequence": None},
                "usage": {"output_tokens": output_tokens},
            })
            self._sse("message_stop", {"type": "message_stop"})
        except (BrokenPipeError, ConnectionResetError):
            return


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--base-url", default=os.environ.get("CLAUDEOP_BASE_URL", "https://opencode.ai/zen/go/v1"))
    parser.add_argument("--api-key", default=os.environ.get("CLAUDEOP_API_KEY", ""))
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    if not args.api_key:
        print("claudeop-bridge: CLAUDEOP_API_KEY is required", file=sys.stderr)
        return 2

    BridgeHandler.upstream_url = args.base_url.rstrip("/") + "/chat/completions"
    BridgeHandler.api_key = args.api_key
    BridgeHandler.model = args.model
    BridgeHandler.session_id = f"claudeop-{uuid.uuid4().hex}"
    server = ThreadingHTTPServer(("127.0.0.1", args.port), BridgeHandler)
    server.daemon_threads = True
    print(f"PORT={server.server_address[1]}", flush=True)

    def stop(_signum: int, _frame: Any) -> None:
        server.server_close()
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
