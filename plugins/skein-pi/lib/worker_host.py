"""Trusted extension subprocess entrypoint for the bounded dispatcher.

Protocol: bounded JSON request on stdin, literal credential on inherited fd 3,
one bounded JSON envelope on stdout. Never print traceback, request, credential,
or child stderr. The TypeScript extension owns user confirmation and provenance.
"""

import json
import os
import sys
from pathlib import Path

from dispatcher import Dispatcher, ProfileError, approve_selection

MAX_REQUEST = 160 * 1024
MAX_KEY = 16 * 1024


def _read_bounded(stream, limit):
    data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError("input_too_large")
    return data


def _request(data):
    value = json.loads(data)
    fields = {
        "approval",
        "node",
        "pi_cli",
        "cwd",
        "temp_root",
        "state_root",
        "project_rules",
        "task",
        "timeout_s",
        "output_limit",
    }
    if not isinstance(value, dict) or set(value) != fields:
        raise ValueError("request_schema")
    for key in ("node", "pi_cli", "cwd", "temp_root", "state_root"):
        if not isinstance(value[key], str) or not Path(value[key]).is_absolute():
            raise ValueError("request_path")
    if not isinstance(value["project_rules"], str):
        raise TypeError("request_rules")
    return value


def main():
    try:
        request = _request(_read_bounded(sys.stdin.buffer, MAX_REQUEST))
        with os.fdopen(3, "rb", closefd=True) as credential_stream:
            credential_data = _read_bounded(credential_stream, MAX_KEY)
        credential = credential_data.decode("utf-8")
        selection = approve_selection(
            request["approval"], credential, confirm=lambda _summary: True
        )
        dispatcher = Dispatcher(
            selected=selection,
            node=request["node"],
            pi_cli=request["pi_cli"],
            cwd=request["cwd"],
            temp_root=request["temp_root"],
            state_root=request["state_root"],
            project_rules=request["project_rules"],
            max_workers=1,
            timeout_s=request["timeout_s"],
            output_limit=request["output_limit"],
        )
        result = dispatcher.run(request["task"])
    except (ValueError, TypeError, OSError, UnicodeError, ProfileError):
        result = {
            "schema_version": 1,
            "status": "configuration_error",
            "reason": "host_request_refused",
            "result": None,
        }
    output = json.dumps(result, ensure_ascii=True, allow_nan=False).encode()
    if len(output) > 80 * 1024:
        output = b'{"schema_version":1,"status":"invalid_output","reason":"host_output_limit","result":null}'
    sys.stdout.buffer.write(output + b"\n")
    sys.stdout.buffer.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
