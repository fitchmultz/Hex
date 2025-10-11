#!/usr/bin/env python3
"""Hex Canary worker process.

This script is executed from the macOS app bundle to host the
Canary-Qwen-2.5B model through NVIDIA NeMo on top of PyTorch's MPS
backend. It communicates with the Swift host via a simple
length-prefixed JSON protocol over stdin/stdout.
"""

from __future__ import annotations

import argparse
import io
import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict

import numpy as np

try:
    import torch
    from nemo.collections.speechlm2.models import SALMModel
except Exception as exc:  # pragma: no cover - fallback logging
    print(json.dumps({
        "type": "fatal",
        "error": f"Failed to import PyTorch/NeMo: {exc!r}"
    }), file=sys.stdout, flush=True)
    raise


@dataclass
class RuntimeConfig:
    model_path: Path
    device: str


class CanaryRuntime:
    def __init__(self, config: RuntimeConfig) -> None:
        if config.device != "mps":
            raise RuntimeError("This build only supports the MPS backend")
        if not torch.backends.mps.is_available():
            raise RuntimeError("MPS backend not available")
        self._config = config
        self._model: SALMModel | None = None

    def load(self) -> None:
        if self._model is not None:
            return
        ckpt = str(self._config.model_path)
        self._model = SALMModel.restore_from(ckpt, map_location=self._config.device)
        self._model.freeze()

    def transcribe(self, wav_path: Path) -> Dict[str, Any]:
        if self._model is None:
            raise RuntimeError("Model not loaded")
        with io.BytesIO(wav_path.read_bytes()) as buf:
            audio = np.frombuffer(buf.getbuffer(), dtype=np.int16).astype(np.float32) / 32768.0
        tensor = torch.from_numpy(audio).unsqueeze(0).to(self._config.device)
        with torch.inference_mode():
            output = self._model.generate(audio_signal=tensor, signal_length=torch.tensor([tensor.shape[-1]]))
        text = output[0]["text"] if isinstance(output, list) else str(output)
        return {"text": text}


def read_message() -> Dict[str, Any]:
    header = sys.stdin.buffer.read(4)
    if len(header) < 4:
        raise EOFError
    length = int.from_bytes(header, "big")
    payload = sys.stdin.buffer.read(length)
    if len(payload) != length:
        raise EOFError
    return json.loads(payload)


def write_message(message: Dict[str, Any]) -> None:
    encoded = json.dumps(message).encode("utf-8")
    sys.stdout.buffer.write(len(encoded).to_bytes(4, "big"))
    sys.stdout.buffer.write(encoded)
    sys.stdout.flush()


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--device", default="mps")
    args = parser.parse_args(argv)

    runtime = CanaryRuntime(RuntimeConfig(model_path=args.model, device=args.device))

    try:
        runtime.load()
        write_message({"type": "ready"})
    except Exception as exc:  # pragma: no cover
        write_message({"type": "fatal", "error": str(exc)})
        return 1

    while True:
        try:
            message = read_message()
        except EOFError:
            break

        command = message.get("command")
        if command == "shutdown":
            write_message({"type": "shutdown"})
            break
        if command == "transcribe":
            try:
                wav_path = Path(message["path"])
                result = runtime.transcribe(wav_path)
                write_message({"type": "result", "text": result["text"]})
            except Exception as exc:  # pragma: no cover
                write_message({"type": "error", "error": str(exc)})
        else:
            write_message({"type": "error", "error": f"Unknown command {command}"})

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
