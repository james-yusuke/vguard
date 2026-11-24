# VGuardの実行例

[English](README.md) · 日本語

## 準備

リポジトリのルートでVGuardのCLIをビルドします。

```sh
v -o vguard .
./vguard --help
```

`target_v` には[パッチを適用したVコンパイラ](../README-JA.md#解析対象をビルドするv)を指定します。
再ビルドしたコンパイラの名前が `v` の場合は `../v/v` を指定してください。
ネイティブのバックエンドとターゲットは、実行するホストに合わせます。

| ホスト | `backend` | `target` | デバッガー |
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

以降も同じシェルで実行します。`./vguard build` にVソースを渡し、生成された
`build.json` を `./vguard run` に渡します。ビルドし直す場合は新しい `work` を作成してください。

## クラッシュの検知

[`crash.v`](crash.v) は `crash_here()` から `C.abort()` を呼び、意図的に `SIGABRT` で停止します。

```sh
./vguard build examples/crash.v --v "$target_v" --backend "$backend" --target "$target" \
  --out "$work/crash" --v-arg -gc --v-arg none
./vguard run "$work/crash/build.json"
```

デバッガーが `SIGABRT` を検知し、V側の呼び出し元である [`crash.v` の7行目](crash.v#L7) に
`^` が付きます。`SSA report` に表示されたファイルを開くと、対応する `call` 命令の直前に
`>>>` が付きます。保存先は `build.json` の隣の `diagnostics/` です。
クラッシュ例では、意図した停止を検知すると終了コードが 1 になります。

## どこで止まるか予想する

先にVソースを読んで、停止する行を予想してから実行してみてください。
ネイティブの例は上と同じバックエンドとデバッガーを使います。

| 実行例 | 注目する点 | 実行方式 |
|---|---|---|
| [`deferred_validation`](crashes/deferred_validation.v) | バッチの読み込みを終えたと表示される | ネイティブ |
| [`rounded_divisor`](crashes/rounded_divisor.v) | 3つの入力がすべて正の整数 | Wasm |
| [`division_overflow`](crashes/division_overflow.v) | 除数がゼロ以外 | Wasm |

```sh
./vguard build examples/crashes/deferred_validation.v --v "$target_v" \
  --backend "$backend" --target "$target" --out "$work/deferred-validation" \
  --v-arg -gc --v-arg none
./vguard run "$work/deferred-validation/build.json"
```

Wasmの例には `PATH` 上の `wasmtime` が必要です。

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

端末のソース行と `^` を予想と見比べてください。同じ関数が `SSA (original)` と `SSA (annotated)` に表示されます。
切り捨ての例では、2回目の除算命令 `sdiv` の行末に印が付きます。SSAの値番号はビルドによって変わります。

```text
SSA (original)
  %5770 = sdiv t2 %5768, %5769

SSA (annotated)
  %5770 = sdiv t2 %5768, %5769  ; <<< stop mapped here. error[crash]: WebAssembly trap: integer divide by zero
```

両方のSSAは同じクラッシュレポートのディレクトリに保存されます。`run` に `--json` を付けると、
ソース位置を `location` に、ファイルのパスを `ssa_original_file` と `ssa_file` に出力します。
`--ssa` を付けると、注釈付きSSAを標準出力から直接保存できます。

<details>
<summary>停止箇所とSSA命令を見る</summary>

- **終了時の検証。** 空行を読み飛ばすため、受理件数は1件です。最後のメッセージを表示した後に
  `defer` の検証が実行され、意図的に停止します。[`C.abort()` の行](crashes/deferred_validation.v#L9)が
  `call`、`caller_frame` として報告されます。
- **切り捨てで生じたゼロ。** 整数の `3 / 5` は 0 になります。[2回目の除算](crashes/rounded_divisor.v#L6)の
  `sdiv` で、Wasmがゼロ除算を報告します。
- **負数の除算であふれる。** `i64` の最小値を `-1` で割った結果は、最大値を1だけ超えます。
  [除算の行](crashes/division_overflow.v#L5)の `sdiv` で、Wasmが整数オーバーフローを報告します。

</details>

### Wasmの停止アドレスを逆引きする

レポートの `stop address` をモジュール内オフセットとして指定します。以下は `0x1d5` の例です。

```sh
./vguard resolve "$work/rounded-divisor/build.json" --offset 0x1d5
```

## メモリ検査

[`memory_scan/main.v`](memory_scan/main.v) は `--memory` の正常系サンプルです。
[ケースファイル](memory_scan/case.json) は引数でラベルを、標準入力でメッセージを渡します。
ホストと同じターゲットと、サニタイザーランタイムが入ったClangを使います。

```sh
./vguard build examples/memory_scan --v "$target_v" --backend c --target "$target" \
  --memory --out "$work/memory-scan"
./vguard run "$work/memory-scan/build.json" --case examples/memory_scan/case.json
```

`sample: VGuard` に続いて `VGuard: exited successfully` が表示され、終了コードは 0 になります。
