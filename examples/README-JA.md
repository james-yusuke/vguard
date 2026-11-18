# クラッシュの検知を試す

[English](README.md) · 日本語

[`crash.v`](crash.v) は `crash_here()` から `C.abort()` を呼び、意図的に `SIGABRT` で停止します。

VGuard本体のビルドには既定で `~/dev/v/v` を使います。サンプルをコンパイルするときは、VGuard対応版の `../v/v-vguard` があればそれを使い、それ以外は再ビルド済みの `../v/v` を使います。[Vコンパイラのセットアップ](../README-JA.md#解析対象をビルドするv)

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

スクリプトはmacOS/arm64とLinux/amd64・arm64に対応します。macOSではLLDB、LinuxではGDBが必要です。

1. `vguard build` がサンプルをネイティブバイナリに変換し、`program.vgmap.json` にSSAとソースの対応、`program.vgmap.json.ssa` にコード生成時のSSAを保存します。スクリプトが表示する `build.json` と同じフォルダに生成されます。
2. `vguard run` がデバッガーで実行し、`SIGABRT` を検知します。停止した命令はランタイム内にあるため、VGuardはV側の呼び出し元フレームを調べます。
3. 結果には [`crash.v` の7行目](crash.v#L7) と、その `C.abort()` に対応するSSAの `call` が表示されます。`caller_frame` は呼び出し元から得た位置を表し、終了コード `1` はこのサンプルではクラッシュ検知を意味します。
4. `build.json` の隣に `diagnostics/crash-…/crash.ssa` を作成します。このファイルには `crash_here` のSSAが入り、該当命令の直前に `>>>` が付きます。端末では `SSA report`、JSONでは `ssa_file` にフルパスが表示されます。
