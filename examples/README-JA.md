# VGuardの実行例

[English](README.md) · 日本語

## クラッシュの検知

[`crash.v`](crash.v) は `crash_here()` から `C.abort()` を呼び、意図的に `SIGABRT` で停止します。

VGuard本体のビルドには `PATH` 上の `v` を使います。特定のVを使うには `VGUARD_HOST_V` にパスを指定します。
サンプルのコンパイルには、VGuard対応版の `../v/v-vguard` があればそれを使い、それ以外は再ビルド済みの
`../v/v` を使います。[Vコンパイラのセットアップ](../README-JA.md#解析対象をビルドするv)

```sh
# リポジトリのルートで実行
sh examples/run_crash.sh

# examples ディレクトリで実行
sh run_crash.sh --json
```

`VGUARD_TARGET_V` には、`-vguard-map` に対応するVコンパイラのパスを指定します。`vguard` は診断を実行するCLIです。

```sh
VGUARD_TARGET_V=/path/to/patched/v sh examples/run_crash.sh --json
```

ネイティブの例はmacOS/arm64とLinux/amd64・arm64に対応します。macOSではLLDB、LinuxではGDBが必要です。

1. `vguard build` がサンプルをネイティブバイナリに変換し、`program.vgmap.json` にSSAとソースの対応、`program.vgmap.json.ssa` にコード生成時のSSAを保存します。スクリプトが表示する `build.json` と同じフォルダに生成されます。
2. `vguard run` がデバッガーで実行し、`SIGABRT` を検知します。停止した命令はランタイム内にあるため、VGuardはV側の呼び出し元フレームを調べます。
3. 結果には [`crash.v` の7行目](crash.v#L7) と、その `C.abort()` に対応するSSAの `call` が表示されます。`caller_frame` は呼び出し元から得た位置を表し、終了コード `1` はこのサンプルではクラッシュ検知を意味します。
4. `build.json` の隣に `diagnostics/crash-…/crash.ssa` を作成します。このファイルには `crash_here` のSSAが入り、該当命令の直前に `>>>` が付きます。端末では `SSA report`、JSONでは `ssa_file` にフルパスが表示されます。

## どこで止まるか予想する

先にVソースを読んで、停止する行を予想してから `--example` で実行してみてください。
ネイティブの例には上記と同じデバッガーが必要です。Wasmの例には `PATH` 上の `wasmtime` が必要です。

| 実行例 | 注目する点 | 実行方式 |
|---|---|---|
| [`deferred_validation`](crashes/deferred_validation.v) | バッチの読み込みを終えたと表示される | ネイティブ |
| [`rounded_divisor`](crashes/rounded_divisor.v) | 3つの入力がすべて正の整数 | Wasm |
| [`division_overflow`](crashes/division_overflow.v) | 除数がゼロ以外 | Wasm |

```sh
sh examples/run_crash.sh --list
sh examples/run_crash.sh --example deferred_validation --json
sh examples/run_crash.sh --example rounded_divisor --json
sh examples/run_crash.sh --example division_overflow --json
```

どの例も終了コード 1 になり、停止位置に印を付けたSSAレポートが出力されます。
JSONの `location` を予想と見比べ、`ssa_file` のファイルを開いて該当命令を確認できます。

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

## メモリ検査

[`memory_scan/main.v`](memory_scan/main.v) は `--memory` の正常系サンプルです。
[ケースファイル](memory_scan/case.json) は引数でラベルを、標準入力でメッセージを渡します。
VGuardと[解析対象をビルドするV](../README-JA.md#解析対象をビルドするv)を準備し、macOS/arm64では
リポジトリのルートで次のように実行します。

```sh
work=$(mktemp -d)
./vguard build examples/memory_scan --v ../v/v-vguard --backend c --target macos/arm64 --memory --out "$work/build"
./vguard run "$work/build/build.json" --case examples/memory_scan/case.json --json
```

Linuxではホストに合わせて `linux/amd64` または `linux/arm64` を指定します。期待結果は終了コード 0、
`kind` が `exited`、対象の標準出力が `sample: VGuard` です。CIでもこの例を実行し、
JSONレポートを成果物に保存します。
