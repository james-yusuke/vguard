"""Measure production build times with and without the SSA diagnostics flag."""

import argparse
import hashlib
import json
import statistics
import subprocess
import tempfile
import time
from pathlib import Path


def run_benchmark(args):
    samples = {"baseline": [], "trace_ssa": []}
    trace_bytes = []
    artifacts_match = True
    with tempfile.TemporaryDirectory(prefix="vguard-ssa-bench-") as work:
        for index in range(args.samples):
            products = {}
            modes = ("baseline", "trace_ssa") if index % 2 == 0 else ("trace_ssa", "baseline")
            for mode in modes:
                directory = Path(work) / f"{mode}-{index}"
                command = [
                    str(args.vguard.resolve()), "build", str(args.source.resolve()),
                    "--v", str(args.compiler.resolve()), "--backend", args.backend,
                    "--target", args.target, "--out", str(directory), "--prod",
                ]
                for compiler_arg in args.v_arg:
                    command.extend(["--v-arg", compiler_arg])
                if mode == "trace_ssa":
                    command.append("--trace-ssa")
                start = time.perf_counter()
                result = subprocess.run(command, check=True, capture_output=True, text=True)
                samples[mode].append((time.perf_counter() - start) * 1000)
                manifest = json.loads(Path(result.stdout.strip()).read_text())
                products[mode] = hashlib.sha256((directory / manifest["artifact"]).read_bytes()).digest()
                if mode == "trace_ssa":
                    passes = directory / (manifest["source_map"] + ".passes.jsonl")
                    graph = passes.with_suffix(passes.suffix + ".graph.json")
                    trace_bytes.append(passes.stat().st_size + graph.stat().st_size)
            artifacts_match &= products["baseline"] == products["trace_ssa"]
    return {
        "backend": args.backend,
        "target": args.target,
        "samples": args.samples,
        "median_wall_ms": {mode: round(statistics.median(values), 2) for mode, values in samples.items()},
        "median_trace_bytes": int(statistics.median(trace_bytes)),
        "artifact_bytes_identical": artifacts_match,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--vguard", type=Path, required=True)
    parser.add_argument("--compiler", type=Path, required=True)
    parser.add_argument("--backend", choices=["amd64", "arm64", "wasm"], required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--samples", type=int, default=5)
    parser.add_argument("--v-arg", action="append", default=[])
    args = parser.parse_args()
    if args.samples <= 0:
        parser.error("--samples must be positive")
    print(json.dumps(run_benchmark(args), indent=2))


if __name__ == "__main__":
    main()
