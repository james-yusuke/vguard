# VGuard

[English](README.md) · 日本語

VGuardは、Vが生成したバイナリの異常をVソースへ逆引きするツールです。amd64・arm64・Wasmを直接生成した場合は、ソース位置に加えてSSAの値IDと命令も表示します。

## セットアップ

### VGuard本体

リポジトリのルートで `~/dev/v/v` を直接指定すると、そのチェックアウトの `vlib` でVGuardをビルドできます。VGuardは複数の `.v` ファイルで構成されるため、コンパイル対象にはディレクトリ `.` を指定します。

```sh
"$HOME/dev/v/v" run . --help
"$HOME/dev/v/v" -o vguard .
```

### 解析対象をビルドするV

`vguard build --v` には、SSA対応表を出力できるVコンパイラを指定します。隣の `../v` に同梱の [VGuard対応パッチ](compiler/vguard.patch) を適用し、再ビルドしてください。パッチの基準リビジョンは `323045464d07c3f6e426f994cfbfe6cfb365ae84` です。

```sh
# パッチが未適用の場合
git -C ../v apply --check ../vguard/compiler/vguard.patch
git -C ../v apply ../vguard/compiler/vguard.patch

(cd ../v && ./v -all-backends self)
```

Vの通常のビルド依存関係に加え、`run` はLinuxでGDB、macOS・WindowsでLLDB、WasmでWasmtime CLIを使用します。C・FastCの逆引きには `llvm-symbolizer` を使います。WasmのC参照版にはEmscriptenの `emcc` を使います。ビルド時に `--v-arg -cc --v-arg /path/to/emcc` を渡すと、参照版にも同じCコンパイラを使います。

## 使い方

引数なしで起動すると、コマンド一覧を表示します。まず `build` に診断するVファイルまたはディレクトリを指定し、生成された `build.json` を `run` や `compare` に渡します。`./vguard` の箇所は `"$HOME/dev/v/v" run .` でも実行できます。

クラッシュの検知を試すには `sh examples/run_crash.sh` を実行してください。[クラッシュ検知サンプル](examples/README-JA.md)

たとえばApple Siliconでは次のように実行します。

```sh
./vguard build ./app --v ../v/v --backend arm64 --target macos/arm64 --out ./guard-build
./vguard run ./guard-build/build.json --case ./case.json
./vguard compare ./guard-build/build.json --case ./case.json --json
```

`--out` には新規ディレクトリを指定します。コンパイラ引数は `--v-arg -cc --v-arg clang` のように1引数ずつ渡せます。最適化ビルドには `--prod` を使います。

`run` と `compare` のケースファイル例です。

```json
{
  "argv": ["sample"],
  "stdin": "7\n",
  "cwd": ".",
  "env": {"LANG": "C"},
  "timeout_ms": 30000
}
```

相対パスの基準はケースファイルのディレクトリです。共有ライブラリのケースでは `harness` に起動する実行ファイルを指定し、その実行ファイルで環境変数 `VGUARD_ARTIFACT` のパスを開きます。

`resolve` は保存済みアドレスを調べます。

| 取得した情報 | 引数 |
|---|---|
| 実行時PCと実際のイメージロードアドレス | `--pc 0x... --load-base 0x...` |
| リンク時仮想アドレス、またはPEのRVA | `--address 0x...` |
| ELF・Mach-O・COFFオブジェクト内の位置 | `--section 1 --offset 0x...` |
| Wasmモジュール内または `-hot-fn` 関数内のバイト位置 | `--offset 0x...` |

`resolve`・`run`・`compare` は `--json` に対応します。終了コードは成功が0、クラッシュや出力差分が1、ツールエラーや診断不能が2です。

amd64・arm64・Wasmの直接生成では、クラッシュに対応するSSAが見つかると、`run` がビルドフォルダ内の `diagnostics/crash-…/crash.ssa` に該当関数と命令を書き出します。JSONの `ssa_file` に保存先、SSAの読み込みや保存に失敗した場合は `ssa_error` に理由が入ります。SSAの保存に対応するVコンパイラで対象をビルドしてください。

## 診断の範囲

- ELFの直接生成はLinux/amd64とLinux/arm64、Mach-Oの直接生成はmacOS/arm64を対象とします。オブジェクトは `--object`、arm64生コードは `--hot-fn <symbol>` で生成します。
- C・FastCのELF・Mach-O・PE/COFFは、ビルド時に保存されたデバッグ情報からVの行を解決します。FastCのオブジェクトには `--v-arg -cc --v-arg clang` が必要です。PEの `.pdb` とMach-Oの `.dSYM` は成果物と一緒に保管します。
- ソース対応表は成果物のSHA-256と照合します。命令の対応がない箇所や、デバッグ情報が不足する箇所は、解決できない理由を報告します。
- `compare` はまずトレースなしの結果を比較し、差が出た場合にトレースを付けて再実行します。スカラーの代入・条件・戻り値が対象です。FastCでは真偽の条件と整数・真偽値のリテラルを計測します。トレースで見つかる位置は、比較した実行で最初に観測された差です。型・制御フロー・外部I/Oへの依存により再ビルドや再現に失敗した場合でも、観測済みの出力差分は保持します。

`"$HOME/dev/v/v" test .` で、対応表の照合、アドレス境界、デバッガー出力の解釈、トレース差分を検証できます。`VGUARD_TEST_COMPILER=../v/v` を付けると、再ビルド済みの対応版コンパイラによる結合テストも実行します。`wasmtime` が `PATH` にある場合はWasmのトラップも検証します。
