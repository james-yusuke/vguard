# Try crash detection

English · [日本語](README-JA.md)

[`crash.v`](crash.v) deliberately stops with `SIGABRT` by calling `C.abort()` from `crash_here()`.

The script builds VGuard with `~/dev/v/v` by default. It compiles the example with the patched
`../v/v-vguard` if available, or with the rebuilt `../v/v` otherwise.
See [how to build the target compiler](../README.md#build-the-target-compiler).

```sh
# From the repository root
sh examples/run_crash.sh

# From the examples directory
sh run_crash.sh --json
```

Set `VGUARD_TARGET_V` to the path of a V compiler that supports `-vguard-map`.
The `vguard` executable is the diagnostic CLI.

```sh
VGUARD_TARGET_V=/path/to/patched/v sh examples/run_crash.sh --json
```

The script supports macOS/arm64 with LLDB, and Linux/amd64 and Linux/arm64 with GDB.

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
