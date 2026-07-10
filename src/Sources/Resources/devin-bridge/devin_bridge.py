#!/usr/bin/env python3
"""
Devin-to-OpenAI Bridge Service

Translates OpenAI-compatible /v1/chat/completions requests into Devin ACP
(Agent Client Protocol) JSON-RPC 2.0 calls via the `devin acp` subprocess,
exposing Devin's models through an OpenAI-compatible API.

Usage:
  python3 devin_bridge.py --port 8419

The service reads the Devin session token from:
  1. --token argument
  2. DEVIN_OUTPOSTS_TOKEN env var
  3. ~/.local/share/devin/credentials.toml (windsurf_api_key field)

The bridge spawns `devin acp` as a subprocess for each completion request
and communicates over stdio using JSON-RPC 2.0 (ACP protocol).
"""

import argparse
import asyncio
import json
import os
import sys
import time
import uuid
from pathlib import Path
from typing import Any, Optional

import uvicorn
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, StreamingResponse

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

DEFAULT_PORT = 8419
DEFAULT_API_URL = "https://api.devin.ai"
ACP_WS_PATH = "/acp/live"

# Models exposed by the bridge.  These map to Devin's internal model UIDs.
# The Devin CLI resolves model aliases via the AssignModel RPC, so we pass
# the requested model name through and let the backend resolve it.
# This list is fetched live from the Devin ACP session/new configOptions
# (142 models as of 2026-07-10, including GLM-5.2, Kimi K2.7, Grok 4.5,
# DeepSeek V4, Claude Opus 4.8, GPT-5.6 Sol/Luna/Terra, etc.)
DEVIN_MODELS = [
    {"id": "claude-opus-4-8-medium", "object": "model", "owned_by": "devin"},
    {"id": "claude-opus-4-8-low", "object": "model", "owned_by": "devin"},
    {"id": "claude-opus-4-8-high", "object": "model", "owned_by": "devin"},
    {"id": "claude-opus-4-8-xhigh", "object": "model", "owned_by": "devin"},
    {"id": "claude-opus-4-8-max", "object": "model", "owned_by": "devin"},
    {"id": "claude-opus-4-8-low-fast", "object": "model", "owned_by": "devin"},
    {"id": "claude-opus-4-8-medium-fast", "object": "model", "owned_by": "devin"},
    {"id": "claude-opus-4-8-high-fast", "object": "model", "owned_by": "devin"},
    {"id": "claude-opus-4-8-xhigh-fast", "object": "model", "owned_by": "devin"},
    {"id": "claude-opus-4-8-max-fast", "object": "model", "owned_by": "devin"},
    {"id": "claude-5-fable-medium", "object": "model", "owned_by": "devin"},
    {"id": "claude-5-fable-low", "object": "model", "owned_by": "devin"},
    {"id": "claude-5-fable-high", "object": "model", "owned_by": "devin"},
    {"id": "claude-5-fable-xhigh", "object": "model", "owned_by": "devin"},
    {"id": "claude-5-fable-max", "object": "model", "owned_by": "devin"},
    {"id": "claude-sonnet-5-medium", "object": "model", "owned_by": "devin"},
    {"id": "claude-sonnet-5-low", "object": "model", "owned_by": "devin"},
    {"id": "claude-sonnet-5-high", "object": "model", "owned_by": "devin"},
    {"id": "claude-sonnet-5-xhigh", "object": "model", "owned_by": "devin"},
    {"id": "claude-sonnet-5-max", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-sol-medium", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-sol-none", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-sol-low", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-sol-high", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-sol-xhigh", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-sol-max", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-sol-none-priority", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-sol-low-priority", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-sol-medium-priority", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-sol-high-priority", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-sol-xhigh-priority", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-luna-medium", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-luna-none", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-luna-low", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-luna-high", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-luna-xhigh", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-luna-max", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-luna-none-priority", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-luna-low-priority", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-luna-medium-priority", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-luna-high-priority", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-luna-xhigh-priority", "object": "model", "owned_by": "devin"},
    {"id": "glm-5-2", "object": "model", "owned_by": "devin"},
    {"id": "glm-5-2-max", "object": "model", "owned_by": "devin"},
    {"id": "glm-5-2-1m", "object": "model", "owned_by": "devin"},
    {"id": "glm-5-2-max-1m", "object": "model", "owned_by": "devin"},
    {"id": "glm-5-2-none", "object": "model", "owned_by": "devin"},
    {"id": "glm-5-2-none-1m", "object": "model", "owned_by": "devin"},
    {"id": "kimi-k2-7", "object": "model", "owned_by": "devin"},
    {"id": "swe-1-7", "object": "model", "owned_by": "devin"},
    {"id": "swe-1-7-lightning", "object": "model", "owned_by": "devin"},
    {"id": "adaptive", "object": "model", "owned_by": "devin"},
    {"id": "claude-opus-4-7-medium", "object": "model", "owned_by": "devin"},
    {"id": "claude-opus-4-7-low", "object": "model", "owned_by": "devin"},
    {"id": "claude-opus-4-7-high", "object": "model", "owned_by": "devin"},
    {"id": "claude-opus-4-7-xhigh", "object": "model", "owned_by": "devin"},
    {"id": "claude-opus-4-7-max", "object": "model", "owned_by": "devin"},
    {"id": "claude-opus-4-7-low-fast", "object": "model", "owned_by": "devin"},
    {"id": "claude-opus-4-7-medium-fast", "object": "model", "owned_by": "devin"},
    {"id": "claude-opus-4-7-high-fast", "object": "model", "owned_by": "devin"},
    {"id": "claude-opus-4-7-xhigh-fast", "object": "model", "owned_by": "devin"},
    {"id": "claude-opus-4-7-max-fast", "object": "model", "owned_by": "devin"},
    {"id": "gemini-3-5-flash-minimal", "object": "model", "owned_by": "devin"},
    {"id": "gemini-3-5-flash-low", "object": "model", "owned_by": "devin"},
    {"id": "gemini-3-5-flash-medium", "object": "model", "owned_by": "devin"},
    {"id": "gemini-3-5-flash-high", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-terra-none", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-terra-low", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-terra-medium", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-terra-high", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-terra-xhigh", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-terra-max", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-terra-none-priority", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-terra-low-priority", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-terra-medium-priority", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-terra-high-priority", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-6-terra-xhigh-priority", "object": "model", "owned_by": "devin"},
    {"id": "grok-4-5-low", "object": "model", "owned_by": "devin"},
    {"id": "grok-4-5-medium", "object": "model", "owned_by": "devin"},
    {"id": "grok-4-5-high", "object": "model", "owned_by": "devin"},
    {"id": "claude-opus-4-6", "object": "model", "owned_by": "devin"},
    {"id": "claude-opus-4-6-thinking", "object": "model", "owned_by": "devin"},
    {"id": "claude-opus-4-6-1m", "object": "model", "owned_by": "devin"},
    {"id": "claude-opus-4-6-thinking-1m", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-4-none", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-4-low", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-4-medium", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-4-high", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-4-xhigh", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-4-none-priority", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-4-low-priority", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-4-medium-priority", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-4-high-priority", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-4-xhigh-priority", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-5-none", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-5-low", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-5-medium", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-5-high", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-5-xhigh", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-5-none-priority", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-5-low-priority", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-5-medium-priority", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-5-high-priority", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-5-xhigh-priority", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-4-mini-low", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-4-mini-medium", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-4-mini-high", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-4-mini-xhigh", "object": "model", "owned_by": "devin"},
    {"id": "claude-sonnet-4-6", "object": "model", "owned_by": "devin"},
    {"id": "claude-sonnet-4-6-thinking", "object": "model", "owned_by": "devin"},
    {"id": "claude-sonnet-4-6-1m", "object": "model", "owned_by": "devin"},
    {"id": "claude-sonnet-4-6-thinking-1m", "object": "model", "owned_by": "devin"},
    {"id": "MODEL_GPT_5_2_LOW", "object": "model", "owned_by": "devin"},
    {"id": "MODEL_GPT_5_2_MEDIUM", "object": "model", "owned_by": "devin"},
    {"id": "MODEL_GPT_5_2_NONE", "object": "model", "owned_by": "devin"},
    {"id": "MODEL_GPT_5_2_HIGH", "object": "model", "owned_by": "devin"},
    {"id": "MODEL_GPT_5_2_XHIGH", "object": "model", "owned_by": "devin"},
    {"id": "MODEL_CLAUDE_4_5_OPUS", "object": "model", "owned_by": "devin"},
    {"id": "MODEL_CLAUDE_4_5_OPUS_THINKING", "object": "model", "owned_by": "devin"},
    {"id": "MODEL_SWE_1_5", "object": "model", "owned_by": "devin"},
    {"id": "MODEL_SWE_1_5_SLOW", "object": "model", "owned_by": "devin"},
    {"id": "MODEL_PRIVATE_11", "object": "model", "owned_by": "devin"},
    {"id": "MODEL_PRIVATE_2", "object": "model", "owned_by": "devin"},
    {"id": "MODEL_PRIVATE_3", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-3-codex-low", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-3-codex-medium", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-3-codex-high", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-3-codex-xhigh", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-3-codex-low-priority", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-3-codex-medium-priority", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-3-codex-high-priority", "object": "model", "owned_by": "devin"},
    {"id": "gpt-5-3-codex-xhigh-priority", "object": "model", "owned_by": "devin"},
    {"id": "kimi-k2-6", "object": "model", "owned_by": "devin"},
    {"id": "swe-1-6", "object": "model", "owned_by": "devin"},
    {"id": "swe-1-6-fast", "object": "model", "owned_by": "devin"},
    {"id": "gemini-3-1-pro-low", "object": "model", "owned_by": "devin"},
    {"id": "gemini-3-1-pro-high", "object": "model", "owned_by": "devin"},
    {"id": "MODEL_GOOGLE_GEMINI_3_0_FLASH_MINIMAL", "object": "model", "owned_by": "devin"},
    {"id": "MODEL_GOOGLE_GEMINI_3_0_FLASH_LOW", "object": "model", "owned_by": "devin"},
    {"id": "MODEL_GOOGLE_GEMINI_3_0_FLASH_MEDIUM", "object": "model", "owned_by": "devin"},
    {"id": "MODEL_GOOGLE_GEMINI_3_0_FLASH_HIGH", "object": "model", "owned_by": "devin"},
    {"id": "deepseek-v4", "object": "model", "owned_by": "devin"},
]

# ---------------------------------------------------------------------------
# Credential helpers
# ---------------------------------------------------------------------------

def load_credentials() -> Optional[dict]:
    """Read Devin credentials.toml and return the parsed dict.

    Devin CLI stores credentials at ~/.local/share/devin/credentials.toml
    (XDG_DATA_HOME) or ~/.devin/credentials.toml (legacy fallback).
    Returns dict with keys like windsurf_api_key, api_server_url,
    devin_api_url, devin_webapp_host.
    """
    candidates = [
        Path.home() / ".local" / "share" / "devin" / "credentials.toml",
        Path.home() / ".devin" / "credentials.toml",
    ]
    if xdg := os.environ.get("XDG_DATA_HOME"):
        candidates.insert(0, Path(xdg) / "devin" / "credentials.toml")
    for cred_path in candidates:
        if not cred_path.exists():
            continue
        try:
            import tomllib
        except ImportError:
            try:
                import tomli as tomllib
            except ImportError:
                return None
        with open(cred_path, "rb") as f:
            return tomllib.load(f)
    return None


def load_token_from_credentials() -> Optional[str]:
    creds = load_credentials()
    if not creds:
        return None
    return creds.get("windsurf_api_key") or creds.get("session_token")


def resolve_token(explicit: Optional[str]) -> str:
    token = explicit or os.environ.get("DEVIN_OUTPOSTS_TOKEN") or load_token_from_credentials()
    if not token:
        raise RuntimeError(
            "No Devin token found.  Pass --token, set DEVIN_OUTPOSTS_TOKEN, "
            "or authenticate with `devin auth`."
        )
    return token


def resolve_api_url(explicit: Optional[str]) -> str:
    """Resolve the Windsurf/Devin API server URL (informational only)."""
    if explicit:
        return explicit
    if env := os.environ.get("DEVIN_API_URL"):
        return env
    creds = load_credentials()
    if creds:
        if url := creds.get("api_server_url"):
            return url
    return DEFAULT_API_URL


def find_devin_binary() -> str:
    """Find the devin CLI binary on PATH."""
    for candidate in ["devin"]:
        # Check PATH
        from shutil import which
        path = which(candidate)
        if path:
            return path
    raise RuntimeError(
        "devin CLI not found on PATH. Install it with `brew install devin-cli` "
        "or ensure it's on your PATH."
    )

# ---------------------------------------------------------------------------
# ACP subprocess client (communicates with `devin acp` over stdio)
# ---------------------------------------------------------------------------

class ACPSubprocess:
    """Manages a `devin acp` subprocess and the ACP JSON-RPC protocol."""

    def __init__(self, token: str, devin_bin: str):
        self.token = token
        self.devin_bin = devin_bin
        self.proc: Optional[asyncio.subprocess.Process] = None
        self._id = 0
        self._responses: dict[int, asyncio.Future] = {}
        self._reader_task: Optional[asyncio.Task] = None
        self._text_chunks: list[str] = []
        self._prompt_done = asyncio.Event()
        self._prompt_result: Optional[dict] = None
        self._current_prompt_id: Optional[int] = None

    def _next_id(self) -> int:
        self._id += 1
        return self._id

    async def start(self):
        """Spawn the devin acp subprocess and start the reader loop."""
        self.proc = await asyncio.create_subprocess_exec(
            self.devin_bin, "acp",
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        self._reader_task = asyncio.create_task(self._reader_loop())

        # Initialize
        resp = await self._send_request("initialize", {
            "protocolVersion": 1,
            "clientCapabilities": {},
            "clientInfo": {"name": "devin-bridge", "version": "1.0.0"},
        })
        if "error" in resp:
            raise RuntimeError(f"initialize failed: {resp['error']}")

        # Authenticate
        resp = await self._send_request("authenticate", {
            "methodId": "devin-browser",
            "meta": {"api_key": self.token},
        })
        if "error" in resp:
            raise RuntimeError(f"authenticate failed: {resp['error']}")

    async def _reader_loop(self):
        """Background task that reads lines from stdout and dispatches."""
        assert self.proc is not None
        while True:
            line = await self.proc.stdout.readline()
            if not line:
                break
            try:
                msg = json.loads(line.decode())
            except json.JSONDecodeError:
                continue

            if "id" in msg:
                # This is a response to a request
                fut = self._responses.pop(msg["id"], None)
                if fut and not fut.done():
                    fut.set_result(msg)
                # Check if this is the prompt response
                if msg["id"] == self._current_prompt_id:
                    self._prompt_result = msg
                    self._prompt_done.set()
            elif "method" in msg:
                # This is a notification
                self._handle_notification(msg)

    def _handle_notification(self, msg: dict):
        """Handle ACP notifications (session/update, etc.)."""
        method = msg.get("method", "")
        if method == "session/update":
            params = msg.get("params", {})
            update = params.get("update", {})
            kind = update.get("sessionUpdate", "")
            if kind == "agent_message_chunk":
                content = update.get("content", {})
                if content.get("type") == "text":
                    self._text_chunks.append(content.get("text", ""))

    async def _send_request(self, method: str, params: dict) -> dict:
        """Send a JSON-RPC request and wait for the response."""
        assert self.proc is not None
        rid = self._next_id()
        msg = {"jsonrpc": "2.0", "id": rid, "method": method, "params": params}
        fut: asyncio.Future = asyncio.get_event_loop().create_future()
        self._responses[rid] = fut
        data = (json.dumps(msg) + "\n").encode()
        self.proc.stdin.write(data)
        await self.proc.stdin.drain()
        try:
            return await asyncio.wait_for(fut, timeout=30)
        except asyncio.TimeoutError:
            self._responses.pop(rid, None)
            return {"error": {"message": f"Timeout waiting for {method} response"}}

    async def new_session(self, model: Optional[str] = None) -> str:
        """Create a new ACP session and return the session ID."""
        params: dict[str, Any] = {
            "cwd": "/tmp",
            "mcpServers": [],
            "agentCapabilities": [],
        }
        resp = await self._send_request("session/new", params)
        if "error" in resp:
            raise RuntimeError(f"session/new failed: {resp['error']}")
        sid = resp.get("result", {}).get("sessionId", "")
        if not sid:
            raise RuntimeError("No sessionId in session/new response")

        # Set model if specified
        if model:
            resp = await self._send_request("session/set_config_option", {
                "sessionId": sid,
                "configId": "model",
                "value": model,
            })
            # Ignore errors — fall back to default model
        return sid

    async def send_prompt(self, session_id: str, prompt: str) -> dict:
        """Send a prompt and wait for completion. Returns the prompt result."""
        self._text_chunks.clear()
        self._prompt_done.clear()
        self._prompt_result = None
        mid = str(uuid.uuid4())
        self._current_prompt_id = self._next_id()
        msg = {
            "jsonrpc": "2.0",
            "id": self._current_prompt_id,
            "method": "session/prompt",
            "params": {
                "sessionId": session_id,
                "messageId": mid,
                "prompt": [{"type": "text", "text": prompt}],
            },
        }
        self._responses[self._current_prompt_id] = asyncio.get_event_loop().create_future()
        data = (json.dumps(msg) + "\n").encode()
        self.proc.stdin.write(data)
        await self.proc.stdin.drain()

        # Wait for the prompt response (notifications fill _text_chunks)
        await asyncio.wait_for(self._prompt_done.wait(), timeout=300)
        return self._prompt_result or {}

    def get_text(self) -> str:
        return "".join(self._text_chunks)

    async def stop(self):
        """Terminate the subprocess."""
        if self._reader_task:
            self._reader_task.cancel()
        if self.proc:
            try:
                self.proc.terminate()
                await asyncio.wait_for(self.proc.wait(), timeout=5)
            except (asyncio.TimeoutError, ProcessLookupError):
                try:
                    self.proc.kill()
                except ProcessLookupError:
                    pass


# ---------------------------------------------------------------------------
# OpenAI message → ACP prompt conversion
# ---------------------------------------------------------------------------

def messages_to_prompt(messages: list[dict]) -> str:
    """Convert OpenAI chat messages into a single text prompt for Devin."""
    parts: list[str] = []
    for msg in messages:
        role = msg.get("role", "user")
        content = msg.get("content", "")
        # Handle content that is a list of parts (vision etc.)
        if isinstance(content, list):
            text_parts = []
            for part in content:
                if isinstance(part, dict) and part.get("type") == "text":
                    text_parts.append(part["text"])
                elif isinstance(part, str):
                    text_parts.append(part)
            content = "\n".join(text_parts)
        if role == "system":
            parts.append(f"[System]\n{content}")
        elif role == "user":
            parts.append(f"[User]\n{content}")
        elif role == "assistant":
            parts.append(f"[Assistant]\n{content}")
        elif role == "tool":
            parts.append(f"[Tool Result]\n{content}")
    return "\n\n".join(parts)

# ---------------------------------------------------------------------------
# OpenAI stream chunk helpers
# ---------------------------------------------------------------------------

def make_chunk(content: str, model: str, finish_reason: Optional[str] = None) -> dict:
    return {
        "id": f"chatcmpl-{uuid.uuid4().hex[:12]}",
        "object": "chat.completion.chunk",
        "created": int(time.time()),
        "model": model,
        "choices": [{
            "index": 0,
            "delta": {"content": content} if content else {},
            "finish_reason": finish_reason,
        }],
    }

def make_final_chunk(model: str) -> dict:
    return {
        "id": f"chatcmpl-{uuid.uuid4().hex[:12]}",
        "object": "chat.completion.chunk",
        "created": int(time.time()),
        "model": model,
        "choices": [{
            "index": 0,
            "delta": {},
            "finish_reason": "stop",
        }],
    }

# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------

app = FastAPI(title="Devin OpenAI Bridge", version="1.0.0")

# Global config (set in main)
_config: dict = {}

def get_config() -> dict:
    return _config

@app.get("/v1/models")
async def list_models():
    return {"object": "list", "data": DEVIN_MODELS}

@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    body = await request.json()
    messages = body.get("messages", [])
    model = body.get("model", "claude-sonnet-4-6")
    stream = body.get("stream", False)

    cfg = get_config()
    token = cfg["token"]
    devin_bin = cfg["devin_bin"]

    prompt_text = messages_to_prompt(messages)

    if stream:
        return StreamingResponse(
            _stream_completion(token, devin_bin, model, prompt_text),
            media_type="text/event-stream",
        )
    else:
        return await _non_stream_completion(token, devin_bin, model, prompt_text)

async def _run_acp_prompt(token: str, devin_bin: str, model: str, prompt: str) -> tuple[str, dict]:
    """Run a single ACP session and return (text, usage_info)."""
    client = ACPSubprocess(token, devin_bin)
    try:
        await client.start()
        sid = await client.new_session(model=model)
        result = await client.send_prompt(sid, prompt)
        text = client.get_text()
        usage = result.get("result", {}).get("usage", {})
        return text, usage
    finally:
        await client.stop()

async def _stream_completion(token: str, devin_bin: str, model: str, prompt: str):
    """Stream OpenAI SSE chunks from Devin ACP."""
    try:
        text, usage = await _run_acp_prompt(token, devin_bin, model, prompt)
        # Stream the text as a single chunk (ACP doesn't support true streaming
        # via subprocess, but we emit it as SSE for OpenAI compatibility)
        if text:
            yield _sse_data(make_chunk(text, model))
        yield _sse_data(make_final_chunk(model))
        yield "data: [DONE]\n\n"
    except Exception as e:
        yield _sse_error({"message": str(e)})

async def _non_stream_completion(token: str, devin_bin: str, model: str, prompt: str) -> JSONResponse:
    """Collect all text and return a single OpenAI response."""
    try:
        text, usage = await _run_acp_prompt(token, devin_bin, model, prompt)
        return JSONResponse({
            "id": f"chatcmpl-{uuid.uuid4().hex[:12]}",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": model,
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": text},
                "finish_reason": "stop",
            }],
            "usage": {
                "prompt_tokens": usage.get("inputTokens", 0),
                "completion_tokens": usage.get("outputTokens", 0),
                "total_tokens": usage.get("totalTokens", 0),
            },
        })
    except Exception as e:
        raise HTTPException(status_code=502, detail=str(e))

def _sse_data(obj: dict) -> str:
    return f"data: {json.dumps(obj)}\n\n"

def _sse_error(error: dict) -> str:
    err_obj = {
        "error": {
            "message": error.get("message", str(error)),
            "type": "devin_bridge_error",
            "code": error.get("code", "internal_error"),
        }
    }
    return f"data: {json.dumps(err_obj)}\n\n"

@app.get("/health")
async def health():
    return {"status": "ok", "service": "devin-bridge"}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Devin-to-OpenAI Bridge")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--api-url", default=None, help="Devin API URL (informational)")
    parser.add_argument("--token", default=None, help="Devin session token")
    args = parser.parse_args()

    token = resolve_token(args.token)
    api_url = resolve_api_url(args.api_url)
    devin_bin = find_devin_binary()

    _config["token"] = token
    _config["api_url"] = api_url
    _config["devin_bin"] = devin_bin

    print(f"Devin OpenAI Bridge starting on {args.host}:{args.port}")
    print(f"  Devin binary: {devin_bin}")
    print(f"  API URL: {api_url}")
    print(f"  Models: {len(DEVIN_MODELS)}")
    print(f"  Endpoints:")
    print(f"    GET  /v1/models")
    print(f"    POST /v1/chat/completions")
    print(f"    GET  /health")

    uvicorn.run(app, host=args.host, port=args.port, log_level="info")

if __name__ == "__main__":
    main()
