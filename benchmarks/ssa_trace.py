"""Measure production build times with and without the SSA diagnostics flag."""

import argparse
import hashlib
import json
import statistics
import struct
import subprocess
import tempfile
import time
from pathlib import Path


def elf_allocated_sections(binary):
    if not binary.startswith(b"\x7fELF\x02\x01"):
        return None
    section_offset = struct.unpack_from("<Q", binary, 40)[0]
    entry_size, count = struct.unpack_from("<HH", binary, 58)
    sections = []
    for index in range(count):
        fields = struct.unpack_from("<IIQQQQIIQQ", binary, section_offset + index * entry_size)
        _, kind, flags, address, offset, size, *_ = fields
        if flags & 2:
            contents = b"" if kind == 8 else binary[offset:offset + size]
            sections.append((kind, flags, address, size, hashlib.sha256(contents).digest()))
    return sections


def run_benchmark(args):
    samples = {"baseline": [], "trace_ssa": []}
    trace_bytes = []
    source_map_growth = []
    artifacts_match = True
    sections_match = None
    with tempfile.TemporaryDirectory(prefix="vguard-ssa-bench-") as work:
        for index in range(args.samples):
            products = {}
            elf_sections = {}
            source_map_sizes = {}
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
                    if args.ssa_function:
                        command.extend(["--ssa-function", args.ssa_function])
                start = time.perf_counter()
                result = subprocess.run(command, check=True, capture_output=True, text=True)
                samples[mode].append((time.perf_counter() - start) * 1000)
                manifest = json.loads(Path(result.stdout.strip()).read_text())
                binary = (directory / manifest["artifact"]).read_bytes()
                products[mode] = hashlib.sha256(binary).digest()
                elf_sections[mode] = elf_allocated_sections(binary)
                source_map_sizes[mode] = (directory / manifest["source_map"]).stat().st_size
                if mode == "trace_ssa":
                    if "llvm_ssa_sha256" in manifest:
                        trace_index = directory / "program.llvm-ssa.json"
                        units = json.loads(trace_index.read_text())["units"]
                        trace_bytes.append(trace_index.stat().st_size + sum(
                            (directory / "llvm-ssa" / unit["file"]).stat().st_size
                            for unit in units
                        ))
                    else:
                        passes = directory / (manifest["source_map"] + ".passes.jsonl")
                        graph = passes.with_suffix(passes.suffix + ".graph.json")
                        trace_bytes.append(passes.stat().st_size + graph.stat().st_size)
            artifacts_match &= products["baseline"] == products["trace_ssa"]
            if elf_sections["baseline"] is not None and elf_sections["trace_ssa"] is not None:
                sections_match = sections_match is not False and elf_sections["baseline"] == elf_sections["trace_ssa"]
            source_map_growth.append(source_map_sizes["trace_ssa"] - source_map_sizes["baseline"])
    report = {
        "backend": args.backend,
        "target": args.target,
        "samples": args.samples,
        "median_wall_ms": {mode: round(statistics.median(values), 2) for mode, values in samples.items()},
        "median_trace_bytes": int(statistics.median(trace_bytes)),
        "median_source_map_growth_bytes": int(statistics.median(source_map_growth)),
        "artifact_bytes_identical": artifacts_match,
    }
    if sections_match is not None:
        report["elf_allocated_sections_identical"] = sections_match
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--vguard", type=Path, required=True)
    parser.add_argument("--compiler", type=Path, required=True)
    parser.add_argument("--backend", choices=["amd64", "arm64", "wasm", "c", "fastc"], required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--ssa-function", help="comma-separated LLVM symbols for C or FastC")
    parser.add_argument("--samples", type=int, default=5)
    parser.add_argument("--v-arg", action="append", default=[])
    args = parser.parse_args()
    if args.samples <= 0:
        parser.error("--samples must be positive")
    print(json.dumps(run_benchmark(args), indent=2))


if __name__ == "__main__":
    main()
