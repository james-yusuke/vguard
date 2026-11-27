# VGuard

[English](README.md) · 日本語

VGuardは、Vが生成したバイナリの異常をVソースへ逆引きするツールです。amd64・arm64・Wasmを直接生成した場合は、ソース位置に加えてSSAの値IDと命令も表示します。

## セットアップ

### VPMでインストール

`v` と Git が `PATH` 上にある状態で、GitHubからVGuardのソースをインストールし、CLIをビルドします。

```sh
v install --git https://github.com/james-yusuke/vguard
vguard_src="$(v env VMODULES)/vguard"
v -prod -o vguard "$vguard_src"
./vguard --help
```

VPMが別のインストール先を表示した場合は、そのパスを `vguard_src` に指定します。
`v run "$vguard_src" --help` で、インストール先から直接実行することもできます。

### VGuard本体

リポジトリのルートで、`PATH` 上の `v` を使って実行します。
VGuardは複数の `.v` ファイルで構成されるため、コンパイル対象にはディレクトリ `.` を指定します。

```sh
v run . --help
v -prod -o vguard .
```

`-prod` を付けると追跡用の補助スクリプトが実行ファイルに組み込まれます。
実行ファイルを移動した後や、インストール元のソースを削除した後も使えます。

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
./vguard run ./ssa-analysis/build.json --dataflow
```

`program.vgmap.json.passes.jsonl` には初期状態と、各チェックポイント間で追加・変更・削除された
命令を保存します。置換は、実際にオペランドを書き換えた使用箇所を記録します。
Verifierを実行した地点と所見の重要度も記録します。最適化を実行しないビルドでは理由と
その時点のSSAグラフを保存します。グラフは `program.vgmap.json.passes.jsonl.graph.json` にあり、
マニフェストには両ファイルのチェックサムが入ります。

SSA構築時に変換後のASTノードを記録できた命令には、パスログと最終グラフに `ast` が付きます。
ノードのIDと種類、診断に使うファイル・行・列、`source_file` 上の半開バイト範囲を示します。
`#line` がある場合、診断上のファイルと実際のソースファイルは異なることがあります。
ノードIDはビルド内で有効です。インライン化で由来を記録した命令を複製した場合は、
`copied_from` が複製元のSSA Value IDを示します。由来を記録していない命令は `ast` を省略します。

`run --dataflow` は停止位置に対応したSSA命令から、定義、φ関数の入力、φの展開で生成された
コピー、先行ブロックの分岐を逆向きにたどります。`ssa_dataflow` は静的な候補を表します。
端末では停止位置に対応したASTを表示します。`--json` を付けると依存先の命令のASTも確認できます。
探索は128命令までで、上限に達した場合はその旨を報告します。メモリの別名と実際に通過した分岐はこの解析の対象外です。

### 実行時のSSA値・分岐・メモリ依存

Linux/amd64、Linux/arm64、macOS/arm64の直接ネイティブ生成では、`build --trace-runtime` で
対象ソース内の関数を計測し、`run --runtime-ssa` で結果を取得できます。
このビルドは `--trace-ssa` も有効にします。`--memory` と同時に指定できます。

```sh
./vguard build ./app.v --v ../v/v-vguard --backend arm64 --target linux/arm64 \
  --trace-runtime --memory --out ./observed-build
./vguard run ./observed-build/build.json --case ./case.json --runtime-ssa --json
```

`runtime_ssa.values` は、停止位置に対応する一回の関数呼び出しで観測した引数と
スカラーSSA値のビット列を含みます。`branches` には通過したCFGの辺が入ります。
LinuxのGDBで停止した実行では、カーネルのスレッドIDと記録上のスレッド世代を照合します。
対応するフレームポインタを取得できた場合は、その呼び出しの履歴を選びます。
`runtime_ssa.stop_correlation` に照合したIDと、取得した場合はフレームアドレスも記録します。
逆方向の `dependencies` は、実際に観測した定義、分岐、φ関数の入力を参照します。
`memory_order` は、直近のスカラー読み書きの区間と、スレッドをまたいで重なるアクセスの組を記録します。
`completed_before_start` は先のアクセスの完了記録が後のアクセスの開始記録より先にある場合です。
`intervals_intersect` は記録上の区間が重なるか、先のアクセスに完了記録がない場合です。
同じバイト範囲への書き込みを読み取り元の候補とした場合は
`inferred_from_ordered_address_overlap` を付けます。Linuxで計測したPOSIXミューテックスの
解放と取得をたどれる組には `recorded_mutex_happens_before` も付けます。
アクセス区間の順序だけで同期関係を判定することはありません。`thread_generation` は同じ
スレッドハンドルが再利用された際に別のスレッドを区別します。

Linuxでは `malloc`、`calloc`、`realloc`、`free` の呼び出しをリンク時に計測し、確保ごとに世代を割り当てます。
解放または `realloc` の後に同じアドレスが再利用されると `memory_order.reuse` に記録し、
前の世代の書き込みを新しい世代の読み取り元候補から外します。共有ライブラリ内部からの呼び出しは
計測を通らないことがあります。メモリ情報は各一覧につき最大512件で、上限到達を明記します。
記録は65,536イベントまでです。停止位置の特定前に上限に達した場合や、複数スレッドが同じ命令を
実行して停止スレッドを特定できない場合は、`runtime_ssa_error` に理由が入ります。

`run --stack` は、ネイティブの停止時点でデバッガーが取得した全スレッドのバックトレースを
`stack_trace` に含めます。`threads` には、認識できたフレームをデバッガーのスレッド番号で整理して出力します。
引数はデバッガーの表示文字列を保持します。ファイル・行・列はデバッガーが報告した場合に含まれます。
直接ネイティブ生成では、対応表で逆引きできた各フレームのVソースとSSAを `mapped_location` に記録します。
直接Wasm生成では、Wasmtimeがトラップ時に出力した各フレームのオフセットをVソースとSSAに対応付けます。
WasmtimeのバックトレースにはホストのスレッドIDと関数引数は含まれません。

`compare --reference other/build.json` は、二つのビルドを同じケースで実行します。
ビルド情報と、標準出力・標準エラーで最初に異なるバイトを報告します。同じソースと
元のVコンパイラで差を再現できる場合は、スカラーのチェックポイントも照合します。

両方を `--trace-ssa` 付きでビルドした場合は、`--reference` と共に `--ssa-diff` を指定できます。
パスログとSSAグラフをチェックサムで確認してから、チェックポイントの順序、命令の変更件数、
Verifier所見の件数、最終SSAで同名関数の命令種別ごとに異なる件数を報告します。
同名関数をブロックと命令の順序で比較し、最初の構造差も表示します。
命令の参照先と分岐先は関数内の位置で照合し、記録された定数とシンボルも比較します。
これらはコンパイル時の観測です。終了コードは実行結果の比較を表します。

`verify-ssa <build.json>` はターゲットを起動せず、追跡ファイルのチェックサムを確認し、
初期SSAから命令の変更を再生して最終グラフと照合します。各チェックポイントで
コンパイラのVerifierが実行されたかどうかと、記録された所見を表示します。
重大な所見があれば終了コードは1、照合や入力のエラーがあれば2です。
コンパイルが途中で止まった場合は、残ったログを `verify-ssa <passes.jsonl> --partial` に渡して、
書き込みが完了した最後のチェックポイントまで再生できます。
このモードで照合できるのはログ内の命令変更です。

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
`regress --include-exits` を付けると、再現する非ゼロ終了コードも比較します。

`regress --compiler-series` は、指定されたコンパイラを使って同一のソースを必要な版だけ
ビルドします。設定ファイルの `build` に `source`、`backend`、`target` と必要な `args` を、
`compilers` に順序付きの `{ "label": "…", "path": "…" }` を指定します。
各版を2回実行し、結果が並びの途中で一度変わるという仮定のもとで二分探索します。

`record <build.json> --out <new-directory>` は、正常終了したスタンドアロン実行の
スカラー代入・分岐・戻り値を記録します。計測を付けた実行の出力と終了状態も照合します。
`record --calls` を付けると、指定したVファイルまたはプロジェクト直下のVファイルに定義された名前付き関数への進入も記録します。
このオプションには更新したパッチで再ビルドしたコンパイラとビルドが必要です。
`record --memory-accesses` は、LinuxまたはmacOSでホストに一致するC・FastCバックエンドのビルドを
Clangで計測します。同じ履歴に読み書きのアドレス・幅・プロセス・スレッドと、
計測関数からのイメージ相対の戻りアドレスを記録します。
記録には計測用バイナリのSHA-256も入ります。対象はClangが計測した生成Cの読み書きで、
リンクされたランタイムの計測箇所を含みます。
[Clang SanitizerCoverage](https://clang.llvm.org/docs/SanitizerCoverage.html#tracing-data-flow)

`replay <new-directory>/history.json` は、その記録を順に表示します。入力の指定には
`record` の `--case` を使えます。

LinuxとmacOSの対応する直接ネイティブバックエンドでは `record --runtime-ssa` が
SSAイベントと対応グラフを保存します。`replay --at-event N` は、その番号までの記録から
選択された関数呼び出しのスカラー値と分岐、アクセスの状態を復元します。
端末とJSONで、記録されたサンプルに基づく結果だと分かるように表示します。

直接Wasmでは、`record --wasi-stdio` でバイナリ、明示した引数・環境変数・標準入力、
実際の出力を保存できます。記録時に2回の正常終了と出力の一致を確認します。
`replay --reexecute` はバイナリとWasmtimeのハッシュを照合して再実行し、
標準出力・標準エラー・終了コードの一致を報告します。
対象はWASI preview1の標準入出力、引数・環境変数、終了を使う非共有メモリのモジュールです。

### Linux仮想マシンでの記録と再生

Linux AMD64・ARM64の単体ELFは、`record --qemu-kernel` で記録できます。
実行ファイル、ケースの入力、共有ライブラリを、LinuxカーネルとQEMUのイベント記録とともに保存します。
保存前にQEMUで再生し、実測した標準出力・標準エラーと終了コードまたはシグナルを照合します。
`--trace-runtime` 付きでビルドした場合はSSAイベントも照合して保存し、`replay --at-event N` で読めます。
[QEMUの記録と再生](https://www.qemu.org/docs/master/system/replay.html)

```sh
./vguard record ./build/build.json --qemu-kernel ./vmlinuz \
  --case ./case.json --out ./vm-record
./vguard replay ./vm-record/history.json --reexecute --json
```

対象に合う `qemu-system-x86_64` または `qemu-system-aarch64` が必要です。
既定はinitramfsです。ext4とvirtioブロックデバイスを内蔵するカーネルでは
`--qemu-rootfs ext4` を指定でき、この場合は `mke2fs` を使います。
同じアーキテクチャのLinuxホストでは、`cc -static` で起動プログラムをビルドし、
glibcの共有ライブラリをELFインタープリターから取得できます。
別のOSやアーキテクチャで記録する場合は、`compiler/qemu_guest.c` から対象Linux向けに
ビルドした静的ELFを `--qemu-launcher` に指定し、共有ライブラリは
`--qemu-libraries` にゲストの絶対パスとホストのファイルを対応付けたJSONで渡します。

ゲストは1仮想CPUと512 MiBのメモリを使い、ネットワークデバイスは無効です。
`cwd` はゲスト内の絶対パスで、既定は `/vguard` です。
`timeout_ms` にはゲストの起動時間を含みます。再生時は保存したカーネル、イメージ、
イベント記録、QEMU実行ファイルのハッシュを照合します。
UTF-8として無効な出力も、履歴の `qemu_linux.binary_streams` と
再生結果の `expected_binary`、`actual_binary` に元のバイト列を保存します。

### 再現コードの縮小

`minimize` は、同じ単一のVファイルから作った二つのビルドで正常終了時の出力差が再現する場合に、
コピー上で行を削って再現ソースを縮小します。両方のコンパイラとソースの指紋が必要です。

```sh
./vguard minimize ./candidate/build.json --reference ./baseline/build.json \
  --case ./case.json --out ./reduced --attempts 32
```

縮小したVファイルと `reduction.json` を保存します。最終候補は両方の設定で再ビルドし、各2回実行して元と同じ出力になることを確認します。
`single_line_deletions_checked` は最終候補から一行ずつ削る試行を完了したかを示します。
`minimize --include-exits` を付けると、非ゼロ終了も含め、両ビルドで再現する出力と終了コードを
維持するように縮小します。実行が中断された場合は縮小を止めます。

`minimize --panic --out <new-directory>` は、単一のVファイルから作成した実行形式の
再現する `V panic` メッセージと終了コードを保って行を削ります。最終候補は2回実行して照合します。

`minimize --arithmetic-trap --out <new-directory>` は、単一のVファイルから作成した直接Wasmの
整数のゼロ除算・除算オーバーフローを対象にします。Wasmtimeの停止理由、対応するSSA命令、
関数とソース文を照合して行を削り、最終候補を2回実行します。

ビルド時間、追跡ファイルのサイズ、対応表の増加量、バイナリのバイト一致を計測するベンチマークは
`python3 benchmarks/ssa_trace.py --help` で実行方法を確認できます。

### C・FastCのLLVM最適化パス

LinuxまたはmacOSで、C・FastCの `--trace-ssa` は、実行形式の生成に使われたClangの
LLVM IRをパスの前後で保存します。`--ssa-function` にはLLVM上の関数名をカンマ区切りで
指定できます。既定値は `main,main__main` です。メインモジュールの `compute` を両バックエンドで
追う場合は、生成名の違いに合わせて `--ssa-function compute,main__compute` を指定します。
既定のClangまたは `--v-arg -cc --v-arg <Clangのパス>` が使われます。LinuxでLLVMgoldが
選ばれたLTOビルドでは、リンク時のパスも `link_time` として区別します。
[LLVMのIRダンプ仕様](https://llvm.org/docs/DebuggingLLVM.html#understanding-the-source-of-the-issue)

`program.llvm-ssa.json` は `llvm-ssa/` に保存した実ログの索引です。`verify-ssa` は
ハッシュを照合し、前後が揃ったパスのハッシュ差、増減した命令行数、実ログ上の行番号を報告します。
LLVMの出力文字列を比較するため、値名の振り直しも差に含まれます。前後を対応付けられなかったダンプと
途中までの記録は報告に明記します。コンパイル失敗時に索引が残った場合は
`verify-ssa program.llvm-ssa.json --partial` で記録済みの範囲を読めます。

同じシンボル選択で追跡したC・FastCビルドは `compare --reference ... --ssa-diff` で比較できます。
`llvm_ssa_comparison` は翻訳単位、フェーズ、パス、対象、実行回で照合します。

### ネイティブ機械語とレジスタ割り当て

AMD64・ARM64で `--trace-ssa` を付けてビルドすると、バックエンドのレジスタ割り当てと
スタック配置を記録します。`resolve --machine` または `run --machine` で、対応するSSA命令の
機械語範囲と、その結果・オペランドに記録された位置を表示できます。
ハッシュを照合した成果物から、範囲ごとに先頭128バイトまでの機械語を表示します。

```sh
./vguard build examples/crashes/deferred_validation.v --v ../v/v-vguard \
  --backend arm64 --target macos/arm64 --trace-ssa --out ./machine-build
./vguard run ./machine-build/build.json --machine --stack
```

`location.machine` の根拠は `compiler_allocator` です。機械語範囲はセクション先頭からの
オフセットで、スタックスロットはAMD64では `rbp`、ARM64では `x29` からのオフセットです。
`alloca` が指すスタック領域も記録し、ARM64で実行時にアラインメントを調整する場合は、
必要なアラインメントを出力します。

`run --machine` はネイティブ停止時にGDB・LLDBから一部の整数レジスタも取得します。
`register_snapshot` の根拠は `debugger_at_stop` で、対象は停止スレッドの最上位フレームです。
停止先からVの呼び出し元へさかのぼった場合、対応位置とレジスタ取得元が異なります。
LinuxのAMD64・ARM64では `--trace-ssa` 付きの直接ネイティブビルドに対し、Python対応の
GDBで `run --recover-ssa` を実行できます。クラッシュ時または `--at <リンク時アドレス>` で
指定した機械命令の境界で、SSAグラフで生存しているスカラー値のレジスタやスタックスロットを
読み取ります。プロローグでは、コンパイラが記録した引数ごとの保存位置の切り替えを使い、
値を呼び出し規約上のレジスタ・スタックから取得したのか、関数内の保存先から取得したのかを示します。
復帰処理では、フレームの復元が始まる命令の直前まで、元の保存先を読み取れます。
復元開始後も、コンパイラが対応するSSAオペランドを記録した整数・ポインタ・浮動小数点の戻り値は、
戻り値レジスタから取得します。ARM64の `f32` の復帰処理には型変換が二度あり、
変換結果がゼロまたはNaNの場合は元のビット列を確定できないため、値の報告を省略します。`--stack` を併用すると、
アンワインドできた各スレッドのフレームと復元可能なスカラー引数も `stopped_frames` に含めます。
コンパイラがビット幅を記録した整数とヌルの入力は `compiler_ssa_literal` として報告します。
`--trace-runtime` 付きでビルドし、`--runtime-ssa` と `--recover-ssa` を併用すると、
Linuxのスレッド、フレーム、SSA命令を照合して、同じ呼び出しで先に実測した入力値を補えます。
この場合は `native_ssa_sample_before_instruction` とイベント番号を出力します。
コンパイラの即値とデバッガーで読んだ引数だけからビット演算の結果を再計算できる場合は、
`derived_ssa_integer` として報告します。同じ値を実測できた場合は、実測値を優先します。
条件分岐の機械命令列では、コンパイラが元の保存場所を保持すると記録した区間から値を読み取ります。
分岐先のφ値を書き込む経路では、その書き込みが始まるまでの状態を対象とします。

### ロックのデッドロックとループ反復

LinuxまたはmacOSで、`--backend c --trace-hangs` を付けて単体の実行形式をビルドし、
`run --hangs --case case.json` にケースの `timeout_ms` を指定します。
時間切れ時に `sync.Mutex` や `sync.RwMutex` の読み取り・書き込みロックの所有・待機の記録に
循環があれば `deadlock`、
構文から終了しないと確定できるループへの進入を実測した場合は `infinite_loop` を報告します。
対象は、条件がないか真偽値リテラルから常に真と証明でき、本体が空、ラベルなしの `continue`、
または次の反復へ進むだけの定数分岐を持つループです。短絡評価で実行されない右辺も考慮します。
定数分岐の報告では、実測した進入を `hang.evidence` に、コンパイラの制御フロー証明を
`hang.proof_evidence` に記録します。
それ以外のループは、時間切れ時に反復の記録が残っていれば `timeout` の `hang` に観測した回数とソース位置を添えます。
チャネルの送信・受信・`select` の待機が終了していなければ、待機中のスレッドと対象を `hang.channels`
に添えます。Linuxでは、全スレッドが同じ待機集合にあり、各セマフォのアドレスが期限のない
プロセス内futex待機と2回とも一致した場合に `deadlock` を報告します。根拠は
`linux_private_channel_futexes` です。期限付きの待機や、観測できたスレッドが一部だけの場合は
`timeout` として報告します。判定の範囲は対象プロセス内の待機です。
[Linuxのシステムコール情報](https://man7.org/linux/man-pages/man5/proc_pid_syscall.5.html)
チャネルとロックが混在する場合は、各ロックのfutexが記録されたpthreadオブジェクト内にあり、
記録上の所有者も待機していることを照合します。所有関係は `hang.lock_waits` に、
根拠は `linux_private_channel_and_lock_futexes` として出力します。
終了コードは2です。

### WebAssemblyの実行上限

`run --fuel 100000` はWasmtimeに実行予算を設定します。予算を使い切ると `fuel_exhausted`、
VGuardの経過時間上限に達すると `timeout` を報告します。どちらも終了コードは2です。
JSONの `execution_limit` に設定値と報告元を含め、取得できたWasmアドレスとソース位置も表示します。
停止位置が関数本体に含まれていてSSA命令の範囲外にある場合は、`function_body` の精度で関数を報告します。
有限の処理でも予算を使い切ることがあるため、無限ループの判定には使えません。[Wasmtimeのfuel仕様](https://docs.wasmtime.dev/api/wasmtime/struct.Store.html#method.set_fuel)

## メモリ安全性の検査

C・FastCバックエンドで `--memory` を付けて実行形式をビルドし、既存のJSONケースを `run` に渡します。
macOS/arm64ではリポジトリのルートから次のように実行します。

```sh
./vguard build ./app --v ../v/v-vguard --backend c --target macos/arm64 --memory --out ./guard-memory
./vguard run ./guard-memory/build.json --case ./case.json --json
```

通常のデバッガー経路は停止を観測します。Cバックエンドのメモリ検査では、
ClangのAddressSanitizerがヒープ・スタック・グローバル領域の境界違反、
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
Cバックエンドのソース位置は、`llvm-symbolizer`、Linuxの `addr2line`、macOSの `atos` で
デバッグ情報から逆引きします。

### 直接ネイティブ生成のメモリ検査

`--backend amd64` または `--backend arm64` でも `--memory` を指定できます。
コード生成器はスカラーのSSA読み書き、集約値のSSA読み書きと対応するコピー、
アトミックアクセスの直前にASanのShadow Memory検査を追加します。
ヒープのRedzoneと標準アロケータの確保・解放にはASanのランタイムを使います。
アラインメントが16バイト以下の `alloca` にはスタックのRedzoneを設け、通常の関数復帰時に解除します。
定義済みのグローバル変数とその直後のRedzoneは、`main` への進入時にASanへ登録します。
スタックのRedzoneに入ったアクセスには、該当する `alloca` の位置も付けます。
ASanが報告したアクセス・確保・解放フレームをソース対応表で逆引きし、対応するSSAに印を付けます。
アドレス0の停止は、ASanが報告した操作と、逆引きした読み書きのSSA命令が一致した場合にnull参照と判定します。

直接生成のスタックRedzoneは、アラインメントが16バイト以下の領域が対象です。
Windowsと共有ライブラリのハーネスは未対応です。

Wasmの `--memory` は、Wasmtimeが実際に検出した線形メモリ全体の境界違反を
`wasm-linear-memory-out-of-bounds` として報告し、取得できたアクセス先と対応するVソースを示します。
`--wasm-heap` を付けて直接Wasmをビルドすると、標準アロケータで確保した各ヒープ領域も検査します。
通常のロード・ストア、コピー・初期化、組み込みのメモリ比較や出力のバッファを対象にします。
記録したサイズを越えたアクセスと解放後アクセスを区別し、バイナリ内の検査命令で停止したことを
照合してから報告します。範囲と寿命の情報は、アプリのメモリとは別の非公開Wasmメモリに保存します。
スタック・グローバル領域には従来の線形メモリ検査が適用されます。検査の対象はアクセスの先頭アドレスが
属する領域です。ホスト側のコードや独自アロケータの領域は対象外です。

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
