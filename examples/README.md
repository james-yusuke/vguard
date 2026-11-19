# VGuard examples

English · [日本語](README-JA.md)

## Crash detection

[`crash.v`](crash.v) deliberately stops with `SIGABRT` by calling `C.abort()` from `crash_here()`.

The script builds VGuard with `v` from `PATH`. Set `VGUARD_HOST_V` to use a specific compiler.
It compiles the example with the patched `../v/v-vguard` if available, or with the rebuilt
`../v/v` otherwise.
See [how to build the target compiler](../README.md#build-the-target-compiler).

```sh
# From the repository root
sh examples/run_crash.sh

# From the examples directory
sh run_crash.sh
```

Set `VGUARD_TARGET_V` to the path of a V compiler that supports `-vguard-map`.
The `vguard` executable is the diagnostic CLI.

```sh
VGUARD_TARGET_V=/path/to/patched/v sh examples/run_crash.sh --json
```

The native examples support macOS/arm64 with LLDB, and Linux/amd64 and Linux/arm64 with GDB.

1. `vguard build` compiles the example to a native binary. It writes the source-to-SSA mapping to
   `program.vgmap.json` and the code generation SSA to `program.vgmap.json.ssa`. Find both files
   next to the `build.json` path printed by the script.
2. `vguard run` runs the example under a debugger and detects `SIGABRT`. Since execution stops
   inside the runtime, VGuard looks up the V caller frame.
3. VGuard reports [line 7 of `crash.v`](crash.v#L7) and the SSA `call` for `C.abort()`.
   The `caller_frame` precision indicates where VGuard found the location. Exit code 1 indicates
   that VGuard detected the crash.
4. VGuard writes the SSA for `crash_here` to `diagnostics/crash-…/crash.ssa` next to `build.json`.
   The line immediately above the mapped instruction contains `>>>`. Find the full path under
   `SSA report` in the terminal or `ssa_file` in JSON.

## Can you predict where it stops?

Read each source first, then pick an example with `--example`. The native example needs the
same debugger as above. The WebAssembly examples need `wasmtime` on `PATH`.

| Example | What to look at | Target |
|---|---|---|
| [`deferred_validation`](crashes/deferred_validation.v) | The program prints that it has finished reading a batch. | Native |
| [`rounded_divisor`](crashes/rounded_divisor.v) | All three inputs are positive. | WebAssembly |
| [`division_overflow`](crashes/division_overflow.v) | The division uses a nonzero divisor. | WebAssembly |

```sh
sh examples/run_crash.sh --list
sh examples/run_crash.sh --example deferred_validation
sh examples/run_crash.sh --example rounded_divisor
sh examples/run_crash.sh --example division_overflow
```

Each run returns exit code 1 and writes a marked SSA report. Compare the source excerpt and its
`^` marker with your prediction, then open the file listed under `SSA report`.
Add `--json` to get the same location and report path in `location` and `ssa_file`.

<details>
<summary>Expected stops and SSA instructions</summary>

- **Deferred validation.** Skipping the empty row leaves the accepted count at 1. After the
  final message, `defer` runs the validation and deliberately aborts. VGuard reports the
  [call to `C.abort()`](crashes/deferred_validation.v#L9) as `call` with `caller_frame`.
- **Rounded divisor.** Integer division makes `3 / 5` equal to 0. The
  [second division](crashes/rounded_divisor.v#L6) traps with `integer divide by zero` at `sdiv`.
- **Division overflow.** Dividing the smallest `i64` by `-1` would produce a value one greater
  than the largest `i64`. The [division](crashes/division_overflow.v#L5) traps with
  `integer overflow` at `sdiv`.

</details>

## Memory check

[`memory_scan/main.v`](memory_scan/main.v) is a normal execution case for `--memory`.
The [case file](memory_scan/case.json) passes a label as an argument and a message on stdin.
Run these commands from the repository root on macOS/arm64 after building VGuard and its
[target compiler](../README.md#build-the-target-compiler).

```sh
work=$(mktemp -d)
./vguard build examples/memory_scan --v ../v/v-vguard --backend c --target macos/arm64 --memory --out "$work/build"
./vguard run "$work/build/build.json" --case examples/memory_scan/case.json --json
```

Use `linux/amd64` or `linux/arm64` on a matching Linux host. Expect exit code 0, report kind
`exited`, and target stdout `sample: VGuard`. The CI workflow also runs this example and
uploads its JSON report.
