#!/usr/bin/env python3
"""StockSage Python bridge.

Reads newline-delimited JSON requests from stdin and writes newline-delimited
JSON responses to stdout. The protocol envelope is defined in ADR 0020 and
StockSage.Bridge.Protocol.

This file lives under ./plugins/stocksage/priv/python/. Elixir owns the Port
lifecycle; this script is the subprocess body.

v0.22 M2 wires the real TradingAgents call. Requests can pass
``force_stub: true`` to use the stub path (for tests and dev environments
without LLM credentials). When ``tradingagents`` cannot be imported, the
bridge reports ``tradingagents_unavailable`` rather than silently stubbing,
so production gaps surface loudly.
"""

from __future__ import annotations

import json
import os
import re
import sys
import traceback
from datetime import date, datetime, timezone
from typing import Any, Dict, Optional


MAX_REASON_CHARS = 500
DEFAULT_MAX_OUTPUT_BYTES = 1_048_576
VALID_ACTIONS = ("ping", "run_analysis")
TICKER_PATTERN = re.compile(r"^[A-Z0-9._-]{1,10}$")

# Bounded list of final_state fields we surface in `raw`. Keeping this small
# avoids dumping every agent transcript into the persisted detail row.
_FINAL_STATE_FIELDS = (
    "final_trade_decision",
    "investment_plan",
    "trader_investment_plan",
    "market_report",
    "sentiment_report",
    "news_report",
    "fundamentals_report",
)


def _try_import_tradingagents():
    """Attempt to import TradingAgents at module load.

    Returns a tuple of (TradingAgentsGraph_cls, DEFAULT_CONFIG, error_str).
    On failure, error_str is set and the first two are None. Callers handle
    the missing-install case by returning a structured error response unless
    the request explicitly requested the stub path.
    """
    try:
        from tradingagents.graph.trading_graph import TradingAgentsGraph  # type: ignore
        from tradingagents.default_config import DEFAULT_CONFIG  # type: ignore

        return TradingAgentsGraph, DEFAULT_CONFIG, None
    except Exception as exc:  # noqa: BLE001 - import errors must not crash bridge.
        return None, None, f"tradingagents_import_failed: {exc.__class__.__name__}: {exc}"


_TA_GRAPH_CLS, _TA_DEFAULT_CONFIG, _TA_IMPORT_ERROR = _try_import_tradingagents()


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


def parse_ticker(value: Any) -> Optional[str]:
    if not isinstance(value, str):
        return None
    stripped = value.strip()
    if not TICKER_PATTERN.match(stripped):
        return None
    return stripped


def parse_analysis_date(value: Any) -> Optional[date]:
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
    """Deterministic stub path used by tests and force_stub callers.

    Returns a shape compatible with the real TradingAgents result so the
    Elixir side can exercise the full persistence and trace pipeline without
    LLM credentials, market-data API access, or the multi-minute propagation
    runtime. The Elixir side persists `stub: true` in the analysis detail
    payload so traces and operator inspection make the source obvious.
    """
    return {
        "ticker": ticker,
        "analysis_date": analysis_date.isoformat(),
        "engine": engine,
        "summary": (
            f"Stub analysis for {ticker} on {analysis_date.isoformat()} "
            f"using {engine}. force_stub=true."
        ),
        "decision": "Hold",
        "final_trade_decision": (
            f"**Rating**: Hold\n\nStub deterministic decision for {ticker} "
            f"on {analysis_date.isoformat()}. No real market data consulted."
        ),
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "stub": True,
    }


def _build_config(request: Dict[str, Any]) -> Dict[str, Any]:
    """Merge optional per-request overrides into the TradingAgents config.

    Operators can pass a bounded set of overrides through the bridge protocol
    (e.g., `deep_think_llm`, `quick_think_llm`, `max_debate_rounds`,
    `online_tools`, `data_vendors`). Anything else is ignored. The default
    config from TradingAgents itself is the base; environment variables for
    LLM credentials are still required at the python venv level.
    """
    if _TA_DEFAULT_CONFIG is None:
        return {}

    config: Dict[str, Any] = dict(_TA_DEFAULT_CONFIG)
    overrides = request.get("config") or {}
    if not isinstance(overrides, dict):
        return config

    allowed_keys = {
        "deep_think_llm",
        "quick_think_llm",
        "max_debate_rounds",
        "max_risk_discuss_rounds",
        "max_recur_limit",
        "online_tools",
        "data_vendors",
        "output_language",
        "checkpoint_enabled",
    }
    for key, value in overrides.items():
        if key in allowed_keys:
            config[key] = value

    return config


def _serialize_final_state(final_state: Any, limit: int) -> tuple[str, bool]:
    """Render the bounded subset of final_state we surface back to Elixir."""
    if not isinstance(final_state, dict):
        return "", False

    snapshot: Dict[str, Any] = {}
    for key in _FINAL_STATE_FIELDS:
        value = final_state.get(key)
        if isinstance(value, (str, int, float, bool)):
            snapshot[key] = value
        elif value is None:
            snapshot[key] = None
        else:
            snapshot[key] = str(value)

    raw_json = json.dumps(snapshot, separators=(",", ":"), default=str)
    encoded = raw_json.encode("utf-8")
    if len(encoded) <= limit:
        return raw_json, False
    truncated = encoded[: max(limit - 3, 0)].decode("utf-8", errors="ignore") + "..."
    return truncated, True


def run_tradingagents_real(
    ticker: str, analysis_date: date, engine: str, request: Dict[str, Any]
) -> Dict[str, Any]:
    """Real TradingAgents propagate path.

    Raises ``RuntimeError`` if the import path is unavailable; callers gate
    this behind the import check. Real calls take minutes and require LLM
    credentials and (depending on data vendor) market-data API keys in the
    venv environment that runs this script.
    """
    if _TA_GRAPH_CLS is None or _TA_DEFAULT_CONFIG is None:
        raise RuntimeError("tradingagents_unavailable")

    config = _build_config(request)
    graph = _TA_GRAPH_CLS(debug=False, config=config)
    final_state, decision = graph.propagate(ticker, analysis_date.isoformat())

    decision_text = decision if isinstance(decision, str) else str(decision)
    final_trade_decision = ""
    if isinstance(final_state, dict):
        candidate = final_state.get("final_trade_decision")
        if isinstance(candidate, str):
            final_trade_decision = candidate

    summary = f"TradingAgents decision: {decision_text}"
    if final_trade_decision:
        excerpt = final_trade_decision.splitlines()[0][:200]
        summary = f"{summary} — {excerpt}"

    return {
        "ticker": ticker,
        "analysis_date": analysis_date.isoformat(),
        "engine": engine,
        "summary": summary,
        "decision": decision_text,
        "final_trade_decision": final_trade_decision,
        "final_state": final_state,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "stub": False,
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
    force_stub = bool(request.get("force_stub"))

    # Loud failure: production callers must not silently degrade to the stub
    # path when tradingagents is missing. Test callers explicitly opt into
    # stub mode via `force_stub: true`.
    if not force_stub and _TA_IMPORT_ERROR is not None:
        return error_response(request_id, _TA_IMPORT_ERROR)

    try:
        if force_stub:
            raw_result = run_tradingagents_stub(ticker, analysis_date, engine)
        else:
            raw_result = run_tradingagents_real(ticker, analysis_date, engine, request)
    except RuntimeError as exc:
        return error_response(request_id, f"tradingagents_error: {exc}")
    except Exception as exc:  # noqa: BLE001 - bridge must not crash on subroutine error.
        return error_response(request_id, f"tradingagents_error: {exc}")

    summary, truncated = bound_summary(raw_result.get("summary", ""), limit)
    raw_json, raw_truncated = _serialize_final_state(
        raw_result.get("final_state", raw_result), limit
    )
    # Stub path doesn't produce a final_state; fall back to serializing the
    # whole stub result so the persisted detail row has structured data to
    # render in traces and operator inspection.
    if not raw_json:
        full_json = json.dumps(raw_result, separators=(",", ":"), default=str)
        full_bytes = full_json.encode("utf-8")
        if len(full_bytes) > limit:
            raw_json = (
                full_bytes[: max(limit - 3, 0)].decode("utf-8", errors="ignore") + "..."
            )
            raw_truncated = True
        else:
            raw_json = full_json
            raw_truncated = False

    return ok_response(
        request_id,
        {
            "ticker": ticker,
            "analysis_date": analysis_date.isoformat(),
            "engine": engine,
            "summary": summary,
            "decision": raw_result.get("decision"),
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
    # Surfacing the import error path early as a warning helps operators see
    # the gap on first run rather than only when an analysis is attempted.
    if _TA_IMPORT_ERROR is not None and os.environ.get("STOCKSAGE_BRIDGE_VERBOSE"):
        sys.stderr.write(f"StockSage bridge: {_TA_IMPORT_ERROR}\n")
        sys.stderr.flush()
    sys.exit(main())
