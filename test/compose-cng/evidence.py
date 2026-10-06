#!/usr/bin/env python3
"""Measured workload evidence. Timestamps are operation starts; latency adds completion."""
import csv
import json
import pathlib
import sys

HEADER = ["epoch_ms", "op", "outcome", "latency_ms", "region", "detail"]
OPS = ("get", "upsert", "query")


def measure(path, fault=None):
    with open(path, newline="") as stream:
        reader = csv.DictReader(stream)
        if reader.fieldnames != HEADER:
            raise ValueError("missing or invalid CSV header")
        rows = list(reader)
    if not rows:
        raise ValueError("CSV has no operations")
    for row in rows:
        if None in row or None in row.values():
            raise ValueError("malformed CSV row")
        row["start"] = int(row["epoch_ms"])
        row["latency"] = int(row["latency_ms"])
        if row["start"] < 0 or row["latency"] < 0 or row["outcome"] not in ("ok", "err"):
            raise ValueError("invalid CSV sample")
        if row["op"] not in (*OPS, "idle", "connect"):
            raise ValueError("invalid operation")
        row["end"] = row["start"] + row["latency"]
    active = [row for row in rows if row["op"] != "idle"]
    if not active:
        raise ValueError("CSV has no operations")
    start = min(row["start"] for row in active)
    end = max(row["end"] for row in active)
    idle = []
    for row in rows:
        if row["op"] == "idle":
            duration = int(row["detail"].removeprefix("sleeping ").removesuffix("s")) * 1000
            idle.append((row["start"], row["start"] + duration))
    def elapsed(left, right):
        return max(0, right - left - sum(max(0, min(right, b) - max(left, a)) for a, b in idle))
    successful = sorted(row["end"] for row in active if row["outcome"] == "ok")
    boundaries = [start, *successful, end]
    gap = max(elapsed(a, b) for a, b in zip(boundaries, boundaries[1:])) if successful else -1
    duration = elapsed(start, end)
    op_metrics = {}
    for op in OPS:
        samples = [row for row in active if row["op"] == op]
        errors = [row for row in samples if row["outcome"] == "err"]
        last_error = max((row["end"] for row in errors), default=None)
        successes = [row for row in samples if row["outcome"] == "ok"]
        final = sorted((row["end"] for row in successes if last_error is None or row["end"] > last_error))
        # A wide span with two isolated successes is not sustained recovery.
        for index in range(len(final) - 1, 0, -1):
            if elapsed(final[index - 1], final[index]) > 5000:
                final = final[index:]
                break
        terminal_ms = elapsed(final[0], final[-1]) if final else 0
        recovered = bool(final and terminal_ms >= 10000 and elapsed(final[-1], end) <= 5000)
        op_metrics[op] = {
            "samples": len(samples), "ok": len(successes), "err": len(errors),
            "sample_rate_per_second": len(samples) * 1000 / duration if duration else 0,
            "error_rate": len(errors) / len(samples) if samples else None,
            "first_error_offset_ms": min((row["start"] for row in errors), default=start) - start if errors else None,
            "last_error_completion_offset_ms": last_error - start if errors else None,
            "error_span_ms": max(row["end"] for row in errors) - min(row["start"] for row in errors) if errors else 0,
            "first_terminal_success_offset_ms": final[0] - start if final else None,
            "recovery_window_ms": final[0] - min(row["start"] for row in errors) if final and errors else None,
            "terminal_success_interval_ms": terminal_ms, "terminal_recovered": recovered,
        }
    exact = [row for row in active if row["outcome"] == "ok" and row["op"] in ("get", "query") and row["region"] in ("a", "b")]
    first_b = min((row["end"] for row in exact if row["region"] == "b"), default=None)
    return {
        "schema_version": 1, "csv_columns": HEADER, "start_epoch_ms": start, "end_epoch_ms": end,
        "samples": len(active), "ok": len(successful), "err": sum(row["outcome"] == "err" for row in active),
        "active_duration_ms": duration, "sample_rate_per_second": len(active) * 1000 / duration if duration else 0,
        "zero_success_gap_ms": gap, "operations": op_metrics,
        "regions": list(dict.fromkeys(row["region"] for row in exact)),
        "fault_epoch_ms": fault, "fault_offset_ms": fault - start if fault is not None else None,
        "first_region_b_offset_ms": first_b - start if first_b is not None else None,
        "fault_to_first_region_b_ms": first_b - fault if first_b is not None and fault is not None else None,
        "limits": {"kv_timeout_ms": 2000, "query_timeout_ms": 5000, "terminal_success_required_ms": 10000, "terminal_max_success_gap_ms": 5000},
        "metric_meanings": {
            "zero_success_gap_ms": "Largest interval with no successful operation completion, excludes deliberate idle; -1 means no successes. Does not prove write recovery or customer RTO.",
            "region": "Exact successful marker get or same-request query marker only; upserts unassigned.",
            "terminal_recovered": "Operation succeeds after its last error for at least 10 seconds through final workload period, with success completion gaps <=5 seconds.",
            "first_region_b_offset_ms": "First exact successful region-b observation completion relative to workload start, not recovery or customer RTO.",
        },
    }


def main():
    name, mode = sys.argv[1:3]
    fault = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] else None
    try:
        result = measure(name, fault)
        if mode == "gap": print(result["zero_success_gap_ms"])
        elif mode == "regions": print(" ".join(result["regions"]))
        elif mode == "recovery":
            failed = [op for op, stats in result["operations"].items() if not stats["terminal_recovered"]]
            if failed: raise ValueError("no sustained terminal recovery: " + " ".join(failed))
        elif mode == "negative":
            if result["ok"]: raise ValueError("negative workload has successes")
            for op in ("get", "upsert"):
                if result["operations"][op]["err"] == 0: raise ValueError("negative workload lacks actual " + op + " errors")
            with open(name, newline="") as stream:
                for row in csv.DictReader(stream):
                    budget = 5500 if row["op"] == "query" else 2500
                    if row["op"] in OPS and int(row["latency_ms"]) > budget:
                        raise ValueError(row["op"] + " exceeds timeout budget")
        elif mode == "summary": print(json.dumps(result, indent=2))
        else: raise ValueError("unknown metric")
    except (OSError, ValueError, KeyError) as exc:
        print("FAIL: evidence: " + str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
