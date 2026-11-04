#!/usr/bin/env python3
"""Slow server-side calls from an OTLP/JSON trace file, as markdown.

Reads what the collector's `file` exporter writes (one ExportTraceServiceRequest per line), keeps
server spans (incoming HTTP requests) and database spans (SQL), and prints:

  - every request and query that took longer than the threshold at least once, grouped by route or
    statement, slowest first;
  - the slowest few overall, so the report says something even when nothing crossed the threshold.

WebSocket upgrades (server spans answered 101, e.g. a SignalR hub) are left out and counted apart:
their span lasts as long as the socket stays open, which says nothing about request latency.

Usage: slow_spans.py <traces.jsonl> <threshold_ms> <top_n>
"""

import json
import re
import sys
from collections import defaultdict
from pathlib import Path

SPAN_KIND_SERVER = 2
MAX_LABEL = 140


def attr_map(attributes):
    """OTLP attribute list -> {key: python value}."""
    out = {}
    for attribute in attributes or []:
        value = attribute.get("value") or {}
        for kind in ("stringValue", "intValue", "doubleValue", "boolValue"):
            if kind in value:
                out[attribute.get("key")] = value[kind]
                break
    return out


def is_server(span):
    kind = span.get("kind")
    return kind == SPAN_KIND_SERVER or kind == "SPAN_KIND_SERVER"


def one_line(text):
    text = re.sub(r"\s+", " ", str(text)).strip()
    return text if len(text) <= MAX_LABEL else text[: MAX_LABEL - 1] + "…"


def classify(span, attrs):
    """('api' | 'sql' | 'websocket', label) for spans worth reporting, else None."""
    if "db.system" in attrs or "db.system.name" in attrs:
        query = attrs.get("db.query.text") or attrs.get("db.statement") or span.get("name", "")
        return "sql", one_line(query)
    if is_server(span):
        method = attrs.get("http.request.method") or attrs.get("http.method") or ""
        route = (
            attrs.get("http.route")
            or attrs.get("url.path")
            or attrs.get("http.target")
            or span.get("name", "")
        )
        label = one_line(f"{method} {route}".strip())
        status = attrs.get("http.response.status_code", attrs.get("http.status_code"))
        if str(status) == "101":
            return "websocket", label
        return "api", label
    return None


def read_spans(path):
    """Yield (category, service, label, duration_ms)."""
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            continue
        for resource_spans in request.get("resourceSpans") or []:
            resource = attr_map((resource_spans.get("resource") or {}).get("attributes"))
            service = resource.get("service.name", "?")
            for scope_spans in resource_spans.get("scopeSpans") or []:
                for span in scope_spans.get("spans") or []:
                    attrs = attr_map(span.get("attributes"))
                    category = classify(span, attrs)
                    if category is None:
                        continue
                    try:
                        start = int(span["startTimeUnixNano"])
                        end = int(span["endTimeUnixNano"])
                    except (KeyError, TypeError, ValueError):
                        continue
                    yield category[0], service, category[1], (end - start) / 1e6


def fmt_ms(ms):
    return f"{ms / 1000:.2f} s" if ms >= 1000 else f"{ms:.0f} ms"


def md_cell(text):
    return str(text).replace("|", "\\|").replace("`", "'")


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    path, threshold, top = sys.argv[1], float(sys.argv[2]), int(sys.argv[3])
    title = f"### 🐢 Slow server-side calls during e2e (> {fmt_ms(threshold)})"

    if not Path(path).is_file():
        print(f"{title}\n\nNo trace file at `{path}`: is the app exporting OTLP to the collector?")
        return

    spans = list(read_spans(path))
    websockets = sum(1 for s in spans if s[0] == "websocket")
    spans = [s for s in spans if s[0] != "websocket"]
    if not spans:
        print(f"{title}\n\nThe trace file has no server or database spans.")
        return

    groups = defaultdict(list)
    for category, service, label, ms in spans:
        groups[(category, service, label)].append(ms)

    print(title)
    print()
    counts = {c: sum(1 for s in spans if s[0] == c) for c in ("api", "sql")}
    left_out = f" {websockets} WebSocket connection{'s' if websockets != 1 else ''} left out (a socket's span is how long it stayed open)." if websockets else ""
    print(f"{counts['api']} API requests and {counts['sql']} SQL queries traced.{left_out}")
    print()

    names = {"api": "API requests", "sql": "SQL queries"}
    for category in ("api", "sql"):
        slow = sorted(
            ((max(v), len(v), sum(v) / len(v), service, label)
             for (c, service, label), v in groups.items()
             if c == category and max(v) > threshold),
            reverse=True,
        )
        if not slow:
            print(f"**{names[category]}**: none over {fmt_ms(threshold)}.")
            print()
            continue
        print(f"**{names[category]}** over {fmt_ms(threshold)}:")
        print()
        print("| Slowest | Calls | Average | Service | " + ("Request" if category == "api" else "Query") + " |")
        print("|--:|--:|--:|---|---|")
        for worst, calls, avg, service, label in slow:
            print(f"| {fmt_ms(worst)} | {calls} | {fmt_ms(avg)} | {md_cell(service)} | `{md_cell(label)}` |")
        print()

    slowest = sorted(spans, key=lambda s: s[3], reverse=True)[:top]
    print(f"<details><summary>Slowest {len(slowest)} overall</summary>")
    print()
    print("| Duration | Kind | Service | Request / query |")
    print("|--:|---|---|---|")
    for category, service, label, ms in slowest:
        print(f"| {fmt_ms(ms)} | {category.upper()} | {md_cell(service)} | `{md_cell(label)}` |")
    print()
    print("</details>")


if __name__ == "__main__":
    main()
