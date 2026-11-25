# VGuard

[English](README.md) · 日本語

VGuardは、Vが生成したバイナリの異常をVソースへ逆引きするツールです。amd64・arm64・Wasmを直接生成した場合は、ソース位置に加えてSSAの値IDと命令も表示します。

## セットアップ

### VPMでインストール

`v` と Git が `PATH` 上にある状態で、GitHubからVGuardのソースをインストールし、CLIをビルドします。

```sh
v install --git https://github.com/james-yusuke/vguard
vguard_src="$(v env VMODULES)/vguard"
v -o vguard "$vguard_src"
./vguard --help
```

VPMが別のインストール先を表示した場合は、そのパスを `vguard_src` に指定します。
`v run "$vguard_src" --help` で、インストール先から直接実行することもできます。

### VGuard本体

リポジトリのルートで、`PATH` 上の `v` を使って実行します。
VGuardは複数の `.v` ファイルで構成されるため、コンパイル対象にはディレクトリ `.` を指定します。

```sh
v run . --help
v -o vguard .
```

### 解析対象をビルドするV

`vguard build --v` には、SSA対応表を出力できるVコンパイラを指定します。隣の `../v` に同梱の [VGuard対応パッチ](compiler/vguard.patch) を適用し、再ビルドしてください。パッチの基準リビジョンは `323045464d07c3f6e426f994cfbfe6cfb365ae84` です。
VPMでインストールした場合、パッチは `$vguard_src/compiler/vguard.patch` にあります。
`--v` に指定するコンパイラのチェックアウトに適用してください。

```sh
# パッチが未適用の場合
git -C ../v apply --check ../vguard/compiler/vguard.patch
git -C ../v apply ../vguard/compiler/vguard.patch

(cd ../v && ./v -all-backends self)
```

Vの通常のビルド依存関係に加え、`run` はLinuxでGDB、macOS・WindowsでLLDB、WasmでWasmtime CLIを使用します。C・FastCの逆引きには `llvm-symbolizer` を使います。WasmのC参照版にはEmscriptenの `emcc` を使います。ビルド時に `--v-arg -cc --v-arg /path/to/emcc` を渡すと、参照版にも同じCコンパイラを使います。

## 使い方

引数なしで起動すると、コマンド一覧を表示します。まず `build` に診断するVファイルまたはディレクトリを指定し、生成された `build.json` を `run` や `compare` に渡します。`./vguard` の箇所は `v run .` でも実行できます。

[クラッシュ検知とメモリ検査の実行例](examples/README-JA.md)を試せます。

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

`resolve`・`run`・`compare` は、ソース位置を取得できた場合に周辺の行を端末に表示します。
列まで分かるときは `^`、行だけ分かるときは `>` で示します。機械処理には `--json` を使えます。
終了コードは成功が0、クラッシュや出力差分が1、ツールエラーや診断不能が2です。

amd64・arm64・Wasmの直接生成では、`run` がクラッシュに対応する関数のSSAを、元の形式と注釈付きで順に表示します。コンパイラは、スナップショットの保存とamd64の `V_X64_DUMP_SSA` に同じ書式を使います。注釈付きSSAでは、対応する命令行の末尾に `<<` と停止理由が付きます。Vの呼び出し元フレームまで特定した場合は、注釈にその旨が表示されます。2つのダンプ全体はビルドフォルダ内の `diagnostics/crash-…/` に保存されます。

| ファイル | JSONフィールド |
|---|---|
| 元の `original.ssa` | `ssa_original_file` |
| クラッシュ情報と注釈が付いた `crash.ssa` | `ssa_file` |

このダンプ形式を使うには、指定のVリビジョンをクリーンにチェックアウトし、更新したパッチを適用してコンパイラと診断対象を再ビルドしてください。ビルド済みの成果物には従来のスナップショット形式が適用されます。SSAの読み込みや保存に失敗した場合は、JSONの `ssa_error` に理由が入ります。

`--ssa` を付けると、注釈付きのV SSA全体を標準出力に出します。診断の詳細はコメントに記録し、対応する命令を特定できない場合はコメントだけを出力します。診断対象のプログラム出力は標準エラーに流れます。

```sh
./vguard run ./guard-build/build.json --ssa > report.ssa
```

### ネイティブコンパイルの追跡

`amd64` または `arm64` バックエンドで直接生成するときに `--trace-build` を付けます。
Apple Siliconでは、リポジトリのルートからパッチ適用済みのVコンパイラを指定して実行します。

```sh
./vguard build examples/crash.v --v ../v/v --backend arm64 --target macos/arm64 \
  --trace-build --out ./trace-build --v-arg -gc --v-arg none
```

ビルド中のコンパイラ出力は標準エラーに表示されます。コンパイルが失敗した場合も、`--out` のディレクトリに以下のファイルが残ります。

| ファイル | 内容 |
|---|---|
| `compile-trace.json` | Vが報告した工程名、工程ごとの所要時間とメモリ使用量（RSS）、コンパイラの全体所要時間 |
| `compiler.stdout.log`、`compiler.stderr.log` | コンパイラの標準出力と標準エラーの記録 |

JSONには、Vが `-show-timings` で報告した順に工程を記録します。並列処理では工程ごとの計測時間が重なる場合があります。VGuardのビルドが成功すると `build.json` も生成され、`run`・`resolve`・`compare` に渡せます。

## SSA解析と実行記録

[同梱パッチ](compiler/vguard.patch)を更新したVコンパイラで、amd64・arm64・Wasmの
ビルドに `--trace-ssa` を指定します。最適化パスを観測する場合は `--prod` も付けます。

```sh
./vguard build examples/crashes/rounded_divisor.v --v ../v/v-vguard \
  --backend wasm --target wasm32_emscripten/wasm32 --prod --trace-ssa --out ./ssa-analysis
./vguard run ./ssa-analysis/build.json --dataflow --json
```

`program.vgmap.json.passes.jsonl` には初期状態と、各チェックポイント間で追加・変更・削除された
命令を保存します。置換は、実際にオペランドを書き換えた使用箇所を記録します。
Verifierを実行した地点と所見の重要度も記録します。最適化を実行しないビルドでは理由と
その時点のSSAグラフを保存します。グラフは `program.vgmap.json.passes.jsonl.graph.json` にあり、
マニフェストには両ファイルのチェックサムが入ります。

`run --dataflow` は停止位置に対応したSSA命令から、定義、φ関数の入力、φの展開で生成された
コピー、先行ブロックの分岐を逆向きにたどります。`ssa_dataflow` は静的な候補を表します。
探索は128命令までで、上限に達した場合はその旨を報告します。メモリの別名と実際に通過した分岐はこの解析の対象外です。

`run --stack` は、ネイティブの停止時点でデバッガーが取得した全スレッドのバックトレースを
`stack_trace` に含めます。取得できる引数やソース位置はデバッグ情報に依存します。

`compare --reference other/build.json` は、二つのビルドを同じケースで実行します。
ビルド情報と、標準出力・標準エラーで最初に異なるバイトを報告します。同じソースと
元のVコンパイラで差を再現できる場合は、スカラーのチェックポイントも照合します。

順序を指定した複数の既存ビルドから最初の出力変化を探すには `regress` を使います。
基準のビルドを先頭に置きます。マニフェストの相対パスは一覧ファイルの場所が基準です。

```json
{
  "builds": [
    {"label": "baseline", "manifest": "baseline/build.json"},
    {"label": "candidate", "manifest": "candidate/build.json"}
  ]
}
```

`./vguard regress ./series.json --case ./case.json --json` で実行します。
同じソースの指紋を持つビルドを、指定順に各2回実行して標準出力と標準エラーを照合します。
再現した最初の差分は `changed`、再現性のない結果や正常終了しなかった実行は `inconclusive` です。
終了コードは `unchanged` が0、`changed` が1、`inconclusive` とエラーが2です。

`record <build.json> --out <new-directory>` は、正常終了したスタンドアロン実行の
スカラー代入・分岐・戻り値を記録します。計測を付けた実行の出力と終了状態も照合します。
`replay <new-directory>/history.json` は、その記録を順に表示します。入力の指定には
`record` の `--case` を使えます。

ビルド時間、追跡ファイルのサイズ、バイナリのバイト一致を計測するベンチマークは
`python3 benchmarks/ssa_trace.py --help` で実行方法を確認できます。

CPUレジスタ・スタックスロットの対応、ネイティブのShadow Memory、メモリアクセス単位の再生、
デッドロック判定、再現コードの最小化は未実装です。

### WebAssemblyの実行上限

`run --fuel 100000` はWasmtimeに実行予算を設定します。予算を使い切ると `fuel_exhausted`、
VGuardの経過時間上限に達すると `timeout` を報告します。どちらも終了コードは2です。
JSONの `execution_limit` に設定値と報告元を含め、取得できたWasmアドレスとソース位置も表示します。
停止位置が関数本体に含まれていてSSA命令の範囲外にある場合は、`function_body` の精度で関数を報告します。
有限の処理でも予算を使い切ることがあるため、無限ループの判定には使えません。[Wasmtimeのfuel仕様](https://docs.wasmtime.dev/api/wasmtime/struct.Store.html#method.set_fuel)

## メモリ安全性の検査

Cバックエンドで `--memory` を付けて実行形式をビルドし、既存のJSONケースを `run` に渡します。
macOS/arm64ではリポジトリのルートから次のように実行します。

```sh
./vguard build ./app --v ../v/v-vguard --backend c --target macos/arm64 --memory --out ./guard-memory
./vguard run ./guard-memory/build.json --case ./case.json --json
```

通常のデバッガー経路は停止を観測するため、実行を継続できる不正アクセスは捕捉できません。
メモリ検査ではClangのAddressSanitizerがヒープ・スタック・グローバル領域の境界違反、
ヒープ解放後アクセス、二重解放、不正解放を検査します。UndefinedBehaviorSanitizerはnull参照と、
Clangが境界を把握できる配列への範囲外アクセスを検査します。VGuardはサニタイザーの報告を
終了状態と独立に読み取るため、CPU例外が起きる前の違反も報告できます。
[AddressSanitizer](https://clang.llvm.org/docs/AddressSanitizer.html) ·
[UndefinedBehaviorSanitizer](https://clang.llvm.org/docs/UndefinedBehaviorSanitizer.html)

検出時の終了コードは 1、JSONの `kind` は `memory_error` です。`memory_errors` には種別と、
取得できたアドレス・操作・アクセス幅・Vソース位置が入ります。サニタイザーに確保・解放時の
スタックがあり、Vのフレームを解決できた場合は、その位置も報告します。ASanの境界違反は
読み取りと書き込みを区別します。UBSanの配列境界報告では操作とアドレスを取得できない場合があります。

`--memory` はClangと `-gc none` を選びます。対応対象はLinux/amd64、Linux/arm64、
macOS/arm64で、ホストとターゲットの一致およびClangのサニタイザーランタイムが必要です。
ソース位置の逆引きには `llvm-symbolizer`、Linuxの `addr2line`、macOSの `atos` を使います。
メモリ診断の位置はCバックエンドのデバッグ情報に基づくため、SSA命令IDは取得できません。
通常のネイティブおよびWasmのクラッシュ診断では、引き続きSSAを逆引きできます。
メモリ検査の未対応対象はFastC、直接ネイティブおよびWasm生成、Windows、共有ライブラリのハーネスです。

検査範囲はケースが実際に実行した経路に限られます。インラインアセンブリ、未計測のライブラリ、
ASanと連携しない独自アロケータ、同じ有効な確保領域内の境界違反は見逃す場合があります。
解放後アクセスの検出は、解放領域の隔離と再利用にも依存します。

## 診断の範囲

- ELFの直接生成はLinux/amd64とLinux/arm64、Mach-Oの直接生成はmacOS/arm64を対象とします。オブジェクトは `--object`、arm64生コードは `--hot-fn <symbol>` で生成します。
- C・FastCのELF・Mach-O・PE/COFFは、ビルド時に保存されたデバッグ情報からVの行を解決します。FastCのオブジェクトには `--v-arg -cc --v-arg clang` が必要です。PEの `.pdb` とMach-Oの `.dSYM` は成果物と一緒に保管します。
- ソース対応表は成果物のSHA-256と照合します。命令の対応がない箇所や、デバッグ情報が不足する箇所は、解決できない理由を報告します。
- `compare` はまずトレースなしの結果を比較し、差が出た場合にトレースを付けて再実行します。スカラーの代入・条件・戻り値が対象です。FastCでは真偽の条件と整数・真偽値のリテラルを計測します。トレースで見つかる位置は、比較した実行で最初に観測された差です。型・制御フロー・外部I/Oへの依存により再ビルドや再現に失敗した場合でも、観測済みの出力差分は保持します。

`v test .` で、対応表の照合、アドレス境界、デバッガー出力の解釈、トレース差分を検証できます。`VGUARD_TEST_COMPILER=../v/v` を付けると、再ビルド済みの対応版コンパイラによる結合テストも実行します。`wasmtime` が `PATH` にある場合はWasmのトラップも検証します。

## GitHubでの開発とCI

Issueには[バグ報告フォーム](.github/ISSUE_TEMPLATE/bug_report.yml)と
[機能提案フォーム](.github/ISSUE_TEMPLATE/feature_request.yml)を用意しています。
[Pull Requestテンプレート](.github/PULL_REQUEST_TEMPLATE.md)には変更内容、確認手順、実行例を記載できます。

[CIワークフロー](.github/workflows/ci.yml)はPull Requestと `main` へのpushで動き、Actionsタブから手動でも
起動できます。Linux/amd64、Linux/arm64、macOS/arm64で整形チェック、単体・結合テスト、
クラッシュ検知とメモリ検査のサンプルを実行します。成功したジョブからバイナリのアーカイブ、
JSONレポート、クラッシュ位置のSSAをダウンロードできます。

Pull Requestの **Checks** タブか `gh pr checks --watch` で進捗を確認できます。
