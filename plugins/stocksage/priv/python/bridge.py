#!/usr/bin/env python3
"""StockSage Python bridge.

Reads newline-delimited JSON requests from stdin and writes newline-delimited
JSON responses to stdout. The protocol envelope is defined in ADR 0020 and
StockSage.Bridge.Protocol.

This file lives under ./plugins/stocksage/priv/python/. Elixir owns the Port
lifecycle; this script is the subprocess body.
"""

from __future__ import annotations

import json
import re
import sys
import traceback
from datetime import date, datetime, timezone
from typing import Any, Dict


MAX_REASON_CHARS = 500
DEFAULT_MAX_OUTPUT_BYTES = 1_048_576
VALID_ACTIONS = ("ping", "run_analysis")
TICKER_PATTERN = re.compile(r"^[A-Z0-9._-]{1,10}$")


def write_response(payload: Dict[str, Any]) -> None:
    """Serialize and flush a JSON response on a single line."""
    line = json.dumps(payload, separators=(",", ":"), default=str)
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def bounded_reason(value: Any) -> str:
    text = value if isinstance(value, str) else str(value)
    return text[:MAX_REASON_CHARS]


def error_response(request_id: str, reason: Any) -> Dict[str, Any]:
    return {
        "id": request_id or "unknown",
        "status": "error",
        "reason": bounded_reason(reason),
    }


def ok_response(request_id: str, result: Any) -> Dict[str, Any]:
    return {"id": request_id, "status": "ok", "result": result}


def handle_ping(request: Dict[str, Any]) -> Dict[str, Any]:
    return ok_response(request.get("id", ""), "pong")


def parse_ticker(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    stripped = value.strip()
    if not TICKER_PATTERN.match(stripped):
        return None
    return stripped


def parse_analysis_date(value: Any) -> date | None:
    if not isinstance(value, str):
        return None
    try:
        return datetime.strptime(value, "%Y-%m-%d").date()
    except ValueError:
        return None


def max_output_bytes(request: Dict[str, Any]) -> int:
    raw = request.get("max_output_bytes")
    if isinstance(raw, int) and raw > 0:
        return raw
    return DEFAULT_MAX_OUTPUT_BYTES


def bound_summary(summary: str, limit: int) -> tuple[str, bool]:
    raw = summary or ""
    encoded = raw.encode("utf-8")
    if len(encoded) <= limit:
        return raw, False
    truncated = encoded[: max(limit - 3, 0)].decode("utf-8", errors="ignore") + "..."
    return truncated, True


def run_tradingagents_stub(ticker: str, analysis_date: date, engine: str) -> Dict[str, Any]:
    """Placeholder used until M2 wires the real TradingAgents call.

    The bridge protocol contract is fully defined here so that the Elixir side
    and the supervised Port lifecycle can be exercised without TradingAgents
    being installed. The real call replaces this body in M2.
    """
    return {
        "ticker": ticker,
        "analysis_date": analysis_date.isoformat(),
        "engine": engine,
        "summary": (
            f"Stub analysis for {ticker} on {analysis_date.isoformat()} "
            f"using {engine}. TradingAgents integration pending v0.22 M2."
        ),
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "stub": True,
    }


def handle_run_analysis(request: Dict[str, Any]) -> Dict[str, Any]:
    request_id = request.get("id", "")
    ticker = parse_ticker(request.get("ticker"))
    if ticker is None:
        return error_response(request_id, "invalid_ticker")

    analysis_date = parse_analysis_date(request.get("analysis_date"))
    if analysis_date is None:
        return error_response(request_id, "invalid_analysis_date")

    engine = request.get("engine") or "tradingagents"
    if not isinstance(engine, str) or engine != "tradingagents":
        return error_response(request_id, "invalid_engine")

    limit = max_output_bytes(request)

    try:
        raw_result = run_tradingagents_stub(ticker, analysis_date, engine)
    except Exception as exc:  # noqa: BLE001 - bridge must not crash on subroutine error.
        return error_response(request_id, f"tradingagents_error: {exc}")

    summary, truncated = bound_summary(raw_result.get("summary", ""), limit)
    raw_json = json.dumps(raw_result, separators=(",", ":"), default=str)
    raw_bytes = raw_json.encode("utf-8")
    raw_truncated = False
    if len(raw_bytes) > limit:
        raw_json = raw_bytes[: max(limit - 3, 0)].decode("utf-8", errors="ignore") + "..."
        raw_truncated = True

    return ok_response(
        request_id,
        {
            "ticker": ticker,
            "analysis_date": analysis_date.isoformat(),
            "engine": engine,
            "summary": summary,
            "raw": raw_json,
            "truncated": truncated or raw_truncated,
            "stub": raw_result.get("stub", False),
        },
    )


def dispatch(request: Dict[str, Any]) -> Dict[str, Any]:
    action = request.get("action")
    if action not in VALID_ACTIONS:
        return error_response(request.get("id", ""), f"unknown_action: {action!r}")

    if not isinstance(request.get("id"), str) or not request["id"]:
        return error_response("unknown", "missing_id")

    if action == "ping":
        return handle_ping(request)
    if action == "run_analysis":
        return handle_run_analysis(request)
    return error_response(request.get("id", ""), "unhandled_action")


def main() -> int:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError as exc:
            write_response(error_response("unknown", f"invalid_json: {exc.msg}"))
            continue

        if not isinstance(payload, dict):
            write_response(error_response("unknown", "invalid_request_shape"))
            continue

        try:
            response = dispatch(payload)
        except Exception as exc:  # noqa: BLE001 - guard against unexpected errors.
            sys.stderr.write("StockSage bridge unhandled error:\n")
            sys.stderr.write(traceback.format_exc())
            sys.stderr.flush()
            response = error_response(
                payload.get("id", "unknown") if isinstance(payload, dict) else "unknown",
                f"bridge_internal_error: {exc}",
            )

        write_response(response)
    return 0


if __name__ == "__main__":
    sys.exit(main())
