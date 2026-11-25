# VGuard examples

English · [日本語](README-JA.md)

## Set up VGuard

Run these commands from the repository root to build the CLI.

```sh
v -o vguard .
./vguard --help
```

Set `target_v` to the path of your [patched V compiler](../README.md#build-the-target-compiler).
If your rebuilt compiler is named `v`, use `../v/v`. Set the native backend and target for your host.

| Host | `backend` | `target` | Debugger |
|---|---|---|---|
| macOS/arm64 | `arm64` | `macos/arm64` | LLDB |
| Linux/amd64 | `amd64` | `linux/amd64` | GDB |
| Linux/arm64 | `arm64` | `linux/arm64` | GDB |

```sh
target_v=../v/v-vguard
backend=arm64
target=macos/arm64
work=$(mktemp -d)
```

Keep the same shell for the examples below. Pass the source to `./vguard build` and the
generated `build.json` to `./vguard run`. Create a fresh `work` directory to rebuild the examples.

## Crash detection

[`crash.v`](crash.v) deliberately stops with `SIGABRT` by calling `C.abort()` from `crash_here()`.

```sh
./vguard build examples/crash.v --v "$target_v" --backend "$backend" --target "$target" \
  --out "$work/crash" --v-arg -gc --v-arg none
./vguard run "$work/crash/build.json"
```

The debugger reports `SIGABRT`. The `^` marker points to [line 7 of `crash.v`](crash.v#L7), the
first mapped V caller frame. The `SSA` line shows the `call` value ID followed by
`<< signal SIGABRT (first mapped V caller frame)`. The annotated SSA marks the full instruction
inline and is saved under `diagnostics/` beside `build.json`.
The crash examples return exit code 1 when VGuard detects the expected failure.

## Can you predict where it stops?

Read each source first and predict where it will stop. Run the native example with the same
backend and debugger as above.

| Example | What to look at | Target |
|---|---|---|
| [`deferred_validation`](crashes/deferred_validation.v) | The program prints that it has finished reading a batch. | Native |
| [`rounded_divisor`](crashes/rounded_divisor.v) | All three inputs are positive. | WebAssembly |
| [`division_overflow`](crashes/division_overflow.v) | The division uses a nonzero divisor. | WebAssembly |

```sh
./vguard build examples/crashes/deferred_validation.v --v "$target_v" \
  --backend "$backend" --target "$target" --out "$work/deferred-validation" \
  --v-arg -gc --v-arg none
./vguard run "$work/deferred-validation/build.json"
```

The WebAssembly examples need `wasmtime` on `PATH`.

```sh
./vguard build examples/crashes/rounded_divisor.v --v "$target_v" \
  --backend wasm --target wasm32_emscripten/wasm32 --out "$work/rounded-divisor"
./vguard run "$work/rounded-divisor/build.json"
```

```sh
./vguard build examples/crashes/division_overflow.v --v "$target_v" \
  --backend wasm --target wasm32_emscripten/wasm32 --out "$work/division-overflow"
./vguard run "$work/division-overflow/build.json"
```

Compare the source excerpt and `^` marker with your prediction. The terminal shows the same
SSA function under `SSA (original)` and `SSA (annotated)`. In the rounded divisor example,
the summary names the second `sdiv` and the annotated copy marks its full instruction.
The compiler's SSA value IDs can vary by build.

```text
  = SSA: %5770 sdiv << WebAssembly trap: integer divide by zero

SSA (original)
SSA 5770 sdiv typ=2 ops=['5768:instruction:2:', '5769:instruction:2:']

SSA (annotated)
SSA 5770 sdiv typ=2 ops=['5768:instruction:2:', '5769:instruction:2:'] << WebAssembly trap: integer divide by zero
```

`run` saves both full dumps in the same crash report directory. Add `--json` to get the
source location in `location` and the file paths in `ssa_original_file` and `ssa_file`.
Use `--ssa` to save the annotated SSA directly from standard output.

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

### Look up a WebAssembly stop address

Use the `stop address` from your report as the module offset. This example uses `0x1d5`.

```sh
./vguard resolve "$work/rounded-divisor/build.json" --offset 0x1d5
```

## Memory check

[`memory_scan/main.v`](memory_scan/main.v) is a normal execution case for `--memory`.
The [case file](memory_scan/case.json) passes a label as an argument and a message on stdin.
Use the native target for your host and a Clang toolchain with sanitizer runtimes.

```sh
./vguard build examples/memory_scan --v "$target_v" --backend c --target "$target" \
  --memory --out "$work/memory-scan"
./vguard run "$work/memory-scan/build.json" --case examples/memory_scan/case.json
```

Expect `sample: VGuard`, followed by `VGuard: exited successfully` and exit code 0.
