#!/usr/bin/env python3
"""Собирает bench/results/*.json в markdown-таблицу (печатает и пишет в summary.md)."""
import json
import re
import sys
from pathlib import Path

RESULTS = Path(__file__).parent / "results"
NAME = re.compile(r"in(\d+)_c(\d+)\.json")

COLUMNS = [
    ("TTFT p50, мс", "median_ttft_ms", 1, 0),
    ("TTFT p99, мс", "p99_ttft_ms", 1, 0),
    ("TPOT p50, мс", "median_tpot_ms", 1, 1),
    ("Latency p50, с", "median_e2el_ms", 0.001, 2),
    ("Latency p99, с", "p99_e2el_ms", 0.001, 2),
    ("Запросов/с", "request_throughput", 1, 2),
    ("Выход, ток/с", "output_throughput", 1, 1),
    ("Всего, ток/с", "total_token_throughput", 1, 1),
]


def main() -> int:
    files = sorted(
        (f for f in RESULTS.glob("*.json") if NAME.fullmatch(f.name)),
        key=lambda f: tuple(map(int, NAME.fullmatch(f.name).groups())),
    )
    if not files:
        print(f"Нет результатов в {RESULTS}: сначала make bench", file=sys.stderr)
        return 1

    header = ["Вход, ток", "Параллельно", "Успешно"] + [c[0] for c in COLUMNS]
    lines = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    missing = set()
    for f in files:
        in_len, conc = NAME.fullmatch(f.name).groups()
        data = json.loads(f.read_text())
        done, total = data.get("completed"), data.get("num_prompts")
        ok = f"{done}/{total}" if done is not None and total else "—"
        row = [in_len, conc, ok]
        for _, key, mult, digits in COLUMNS:
            value = data.get(key)
            if value is None:
                missing.add(key)
                row.append("—")
            else:
                row.append(f"{value * mult:.{digits}f}")
        lines.append("| " + " | ".join(row) + " |")

    table = "\n".join(lines)
    print(table)
    (RESULTS / "summary.md").write_text(table + "\n")
    if missing:
        print(f"\nНет ключей: {', '.join(sorted(missing))}. Сверь имена с JSON.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())