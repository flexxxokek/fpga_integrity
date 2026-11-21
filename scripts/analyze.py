#!/usr/bin/env python3
"""Aggregate collected measurement CSVs into tables and optional plots.

Input CSV files are produced by ``scripts/collect.py`` and use the long format:

    timestamp,board,git,seed,campaign,algo,metric,value

Outputs:
    <out>/summary.csv   machine-readable aggregate
    <out>/summary.md    Markdown table for docs
    <out>/*.png         plots when matplotlib is available

Examples:
    python scripts/analyze.py --input data/*.csv
    python scripts/analyze.py --input data/ --out docs/results --no-plot
"""

from __future__ import annotations

import argparse
import csv
import glob
import sys
from collections import defaultdict
from pathlib import Path

METRIC_ORDER = [
    "packets",
    "corrupted",
    "detected",
    "missed",
    "false",
    "detection_rate",
    "false_rate",
]


def expand_inputs(patterns: list[str]) -> list[Path]:
    paths: list[Path] = []
    for pattern in patterns:
        if Path(pattern).is_dir():
            paths.extend(sorted(Path(pattern).glob("*.csv")))
        else:
            matches = sorted(glob.glob(pattern))
            paths.extend(Path(match) for match in matches)
    unique: list[Path] = []
    seen: set[Path] = set()
    for path in paths:
        resolved = path.resolve()
        if resolved not in seen:
            seen.add(resolved)
            unique.append(path)
    return unique


def load_rows(paths: list[Path]) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for path in paths:
        with open(path, newline="", encoding="utf-8") as handle:
            reader = csv.DictReader(handle)
            if reader.fieldnames is None:
                continue
            missing = {"algo", "metric", "value"} - set(reader.fieldnames)
            if missing:
                print(
                    f"skip {path}: not a collected report (missing {sorted(missing)})",
                    file=sys.stderr,
                )
                continue
            for row in reader:
                row["_source"] = str(path)
                rows.append(row)
    return rows


def as_float(value: str) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def aggregate(rows: list[dict[str, str]]) -> dict[tuple[str, str], dict[str, float]]:
    values: dict[tuple[str, str], dict[str, list[float]]] = defaultdict(
        lambda: defaultdict(list)
    )
    for row in rows:
        algo = row.get("algo") or "unknown"
        campaign = row.get("campaign") or "default"
        metric = row.get("metric") or "unknown"
        number = as_float(row.get("value", ""))
        if number is not None:
            values[(algo, campaign)][metric].append(number)

    summary: dict[tuple[str, str], dict[str, float]] = {}
    for key, metrics in values.items():
        entry = {name: sum(vals) / len(vals) for name, vals in metrics.items() if vals}
        counted = entry.get("detected", 0.0) + entry.get("missed", 0.0)
        if counted > 0:
            entry["detection_rate"] = entry.get("detected", 0.0) / counted
        packets = entry.get("packets", 0.0)
        if packets > 0 and "false" in entry:
            entry["false_rate"] = entry["false"] / packets
        summary[key] = entry
    return summary


def metric_columns(summary: dict[tuple[str, str], dict[str, float]]) -> list[str]:
    present = set()
    for entry in summary.values():
        present.update(entry)
    ordered = [name for name in METRIC_ORDER if name in present]
    ordered.extend(sorted(present - set(ordered)))
    return ordered


def write_csv(
    path: Path,
    summary: dict[tuple[str, str], dict[str, float]],
    columns: list[str],
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(["algo", "campaign", *columns])
        for (algo, campaign), entry in sorted(summary.items()):
            writer.writerow(
                [
                    algo,
                    campaign,
                    *[f"{entry.get(column, ''):.6g}" if entry.get(column) is not None else "" for column in columns],
                ]
            )


def write_markdown(
    path: Path,
    summary: dict[tuple[str, str], dict[str, float]],
    columns: list[str],
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = ["# Measurement summary", ""]
    header = ["algorithm", "campaign", *columns]
    lines.append("| " + " | ".join(header) + " |")
    lines.append("|" + "|".join("---" for _ in header) + "|")
    for (algo, campaign), entry in sorted(summary.items()):
        row = [algo, campaign]
        for column in columns:
            value = entry.get(column)
            if value is None:
                row.append("")
            elif column.endswith("_rate"):
                row.append(f"{100.0 * value:.1f}%")
            else:
                row.append(f"{value:.4g}")
        lines.append("| " + " | ".join(row) + " |")
    lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8")


def write_plots(
    out_dir: Path,
    summary: dict[tuple[str, str], dict[str, float]],
    columns: list[str],
) -> None:
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("matplotlib not installed; skipping plots", file=sys.stderr)
        return

    out_dir.mkdir(parents=True, exist_ok=True)
    campaigns = sorted({campaign for _, campaign in summary})
    algos = sorted({algo for algo, _ in summary})

    for metric in ("detection_rate", "false_rate", "packets"):
        if metric not in columns:
            continue
        fig, ax = plt.subplots(figsize=(max(6, 1.4 * len(algos)), 4))
        width = 0.8 / max(1, len(campaigns))
        for index, campaign in enumerate(campaigns):
            heights = [
                summary.get((algo, campaign), {}).get(metric, 0.0) for algo in algos
            ]
            offset = (index - (len(campaigns) - 1) / 2) * width
            ax.bar(
                [position + offset for position in range(len(algos))],
                heights,
                width=width,
                label=campaign,
            )
        ax.set_xticks(range(len(algos)))
        ax.set_xticklabels(algos, rotation=30, ha="right")
        ax.set_ylabel(metric)
        ax.set_title(f"{metric} by algorithm")
        ax.legend(fontsize="small")
        fig.tight_layout()
        fig.savefig(out_dir / f"{metric}.png", dpi=150)
        plt.close(fig)
        print(f"wrote {out_dir / f'{metric}.png'}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", nargs="+", default=["data"], help="CSV files/dirs")
    parser.add_argument("--out", default="docs/results")
    parser.add_argument("--no-plot", action="store_true")
    args = parser.parse_args(argv)

    paths = expand_inputs(args.input)
    if not paths:
        print("no input CSV files found", file=sys.stderr)
        return 1
    rows = load_rows(paths)
    if not rows:
        print("no measurement rows found", file=sys.stderr)
        return 1

    summary = aggregate(rows)
    columns = metric_columns(summary)
    out_dir = Path(args.out)
    write_csv(out_dir / "summary.csv", summary, columns)
    write_markdown(out_dir / "summary.md", summary, columns)
    print(f"wrote {out_dir / 'summary.csv'}")
    print(f"wrote {out_dir / 'summary.md'}")
    if not args.no_plot:
        write_plots(out_dir, summary, columns)
    return 0


if __name__ == "__main__":
    sys.exit(main())
