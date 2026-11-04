# AdaMutant

Ada / SPARK 向けのミューテーションテストツールです。.NET の [Stryker.NET](https://stryker-mutator.io/docs/stryker-net/introduction/) と同じ考え方で、ソースに小さな変更（ミュータント）を自動で入れ、テストまたは GNATprove の証明がその変更を検出できるかを調べ、**ミューテーションスコア**を出します。

- Ada 2022 までの字句解析器を内蔵（libadalang などの追加依存なし）
- テストの失敗だけでなく **GNATprove の証明失敗でもミュータントを kill** できる（SPARK 向け）
- サンドボックスを複数作って並列実行、タイムアウトしたテストはプロセスグループ（Windows はジョブオブジェクト）ごと終了
- `test_memory_limit_mb` でテストの各プロセスのメモリを制限できます（POSIX は `RLIMIT_AS`、Windows はジョブオブジェクト。macOS は `RLIMIT_AS` を受け付けないので、AdaMutant がテストのプロセスの物理メモリ（phys_footprint）を 10 ミリ秒ごとに調べます）。ループ回数などを変えたミュータントが数 GB を確保すると、並列実行中にマシン全体がメモリ不足になり、ラン全体が落ちることがあります。上限を超えた確保は失敗し（Ada では `Storage_Error`）、そのミュータントは Killed になります。macOS では上限を超えた時点でテストのプロセスをまとめて終了し、同じく Killed になります（ログに `adamutant: killed, a process exceeded test_memory_limit_mb` と残ります）。変更前のテストも同じ上限で実行するので、上限が小さすぎればその時点でエラーになります
- レポート: コンソール表、単体で開ける HTML、[mutation-testing-report-schema](https://github.com/stryker-mutator/mutation-testing-elements) v2 の JSON（Stryker のダッシュボードでも読めます）

## 必要なもの

- GNAT（Ada 2022 対応、GNAT 14 で確認）と GPRbuild
- 証明で kill したい場合は GNATprove
- E2E テストを動かす場合は Python 3

## ビルド

```sh
make build        # bin/adamutant ができる
make test         # 単体テスト + examples を使った E2E テスト
```

## 使い方

プロジェクトのルートで設定ファイルを作って実行します。

```sh
adamutant init                 # adamutant.toml のひな形を作る
adamutant list                 # 作られるミュータントの一覧（実行はしない）
adamutant run                  # 実行してレポートを出す
adamutant run --mutate 'src/parser*.adb' --concurrency 4
adamutant run --since origin/main   # PR で変更した行だけ
```

| オプション | 意味 |
|---|---|
| `--config FILE` | 設定ファイル（既定 `adamutant.toml`）。プロジェクトルートは設定ファイルのあるディレクトリ |
| `--mutate GLOB` | 対象ファイルをさらに絞る（複数指定可） |
| `--concurrency N` | 並列サンドボックス数 |
| `--since REF` | git のリビジョン REF と HEAD のマージベースから変更された行だけを変異させる（下記） |
| `--keep-sandbox` | 終了後も `.adamutant/sandbox` を残す（調査用） |

`--since` は Stryker.NET の `--since` と同じく PR の CI 向けです。`git merge-base REF HEAD` からの差分（コミット済み・未コミットの両方）と、無視されていない未追跡ファイルを対象にします。変更のないファイルは読み込まず、変更のあるファイルでも変更行にかからないミュータントは `Ignored`（理由 `unchanged since REF`）になるので、スコアは変更行のミュータントだけで計算されます。仕様（`.ads`）だけを変えた場合でも本体のミュータントは対象になりません。CI では履歴が必要なので、GitHub Actions なら `actions/checkout` に `fetch-depth: 0` を指定してください。

終了コード: 0 = 成功、1 = エラー（設定ミス、元のプロジェクトのビルド・テスト失敗など）、2 = スコアが `break` しきい値未満。

### 設定 (adamutant.toml)

```toml
mutate = ["src/**/*.adb", "src/**/*.ads"]   # 変異させるファイル
exclude = ["src/generated/**"]
build = "gprbuild -p -q -P tests.gpr"       # 必須。失敗したミュータントは CompileError
test = "bin/run_tests"                      # 終了コード 0 以外なら Killed
prove = "gnatprove -P prove.gpr --level=1 --checks-as-errors=on"  # 0 以外なら Killed (証明)
concurrency = 4                             # 既定は CPU 数の半分
timeout_factor = 1.5                        # テスト時間の上限 = 元の時間 * factor + timeout_ms
timeout_ms = 5000
test_memory_limit_mb = 2048                 # テスト 1 プロセスあたりのメモリ上限。既定 0 は無制限
mutators = ["ArithmeticOperator", "EqualityOperator"]  # 省略時はすべて
mutate_contracts = false                    # true で Pre/Post などのアスペクトも変異
sandbox_exclude = [".git", "obj", "bin"]    # サンドボックスにコピーしないもの
report_dir = ".adamutant/reports"

[thresholds]
high = 80
low = 60
break = 0
```

「元の時間」は、変異させていないプロジェクトのテスト（証明）を全サンドボックスで同時に流したときの最も遅い実行時間です。ミュータントを並列で流すときと同じ負荷で測るので、並列にすると遅くなるテストでも誤って Timeout になりません。

`test` と `prove` は少なくとも一方が必要です。両方あるときはテストを先に実行し、テストが通ったミュータントだけを証明にかけます。コマンドは POSIX では `/bin/sh -c`、Windows では `cmd.exe /c` で実行され、環境変数 `ADAMUTANT_MUTANT_ID` が渡されます。ミュータントのビルド・テスト・証明には、変異させたファイルのパス（`files` に書いたとおりのプロジェクトルートからの相対パス）が `ADAMUTANT_MUTANT_FILE` でも渡されます（ベースラインの実行では空です）。cmd.exe は `bin/test` の `/` 以降をスイッチとして解釈するため、`/` を含むパスは `test = '"bin/test"'` のように引用符で囲んでください（`/bin/sh` でもそのまま動きます）。未知のキーはエラーになります。

## ミュータント

| 名前 | 例 |
|---|---|
| ArithmeticOperator | `+`↔`-`, `*`↔`/`, `mod`,`rem`→`*`（`mod`↔`rem` は符号が異なるときしか差が出ず、ほぼ等価ミュータントになるため）, `**`→`*`, `&` は対象外 |
| EqualityOperator | `<`→`<=`,`>=`、`=`↔`/=` など |
| LogicalOperator | `and`↔`or`, `and then`↔`or else`, `xor`→`or`。`A and then B and then C` のような連鎖では `(A or else B) and then C` のように括弧を補う |
| UnaryOperator | `not X`→`X`, `-X`↔`+X`, `abs X`→`X` |
| BooleanLiteral | `True`↔`False` |
| MembershipOperator | `in`↔`not in` |
| ConditionalExpression | `if`/`elsif` の条件 → `True`/`False`、`while` → `False`、`exit when` → `True` |
| StatementDeletion | 代入・手続き呼び出し文 → `null;` |
| NumericLiteral | `0`→`1`, `1`→`0`, `n`→`n+1`, 実数 → `0.0`。基数付き・指数付きの整数リテラルも同じ規則で、基数は保ちます（`16#FF#`→`16#100#`, `1E6`→`1000001`）。宣言した部分型の範囲の上下限 `String (1 .. 6)` などは対象外 |
| StringLiteral | `"abc"`→`""`, `""`→`"AdaMutant was here!"` |

`with`/`use` 節、`pragma`、表現節（`for X'Size use ...`）、`digits`/`delta` は変異させません。サブプログラムの仮引数の既定値も、宣言と本体で一致していないとコンパイルできない（完全準拠）ため変異させません（`is null`、`is abstract`、式関数、ジェネリック仮サブプログラムの既定値は変異させます）。アスペクト（`Pre`, `Post`, `Type_Invariant` など）とゴーストコード（`Ghost` アスペクト付きで宣言されたサブプログラム・オブジェクト・型の宣言と本体、およびそれらを呼び出す・代入する文）は `mutate_contracts = true` のときだけ変異させます。ゴーストの名前は変異対象の `.adb` と、同じ名前の `.ads` から集めます。

### コメントで無効化

```ada
--  adamutant:disable-next-line EqualityOperator: 等価ミュータント
if A + B > Max then

--  adamutant:disable StatementDeletion, StringLiteral
Log ("...");
--  adamutant:enable
```

名前を省略するか `all` ですべてのミュータント。無効化されたものは `Ignored` としてレポートに残り、スコアには含まれません。

## 状態とスコア

| 状態 | 意味 |
|---|---|
| Killed | テストまたは証明が失敗した（検出できた） |
| Timeout | テストが時間内に終わらなかった（検出扱い） |
| Survived | テストも証明も通った（検出できなかった） |
| NoCoverage | ビルドがそのファイルをコンパイルしていない（未検出扱い、実行はしない） |
| CompileError | ミュータントがビルドできなかった（スコア対象外） |
| RuntimeError | コマンドを起動できなかったなど（スコア対象外） |
| Ignored | コメントで無効化（スコア対象外） |

`スコア = (Killed + Timeout) / (Killed + Timeout + Survived + NoCoverage) * 100`

## 仕組み

1. 元のプロジェクトを `.adamutant/sandbox/1` にコピーし、ビルドとテスト（と証明）を一度通して所要時間を測る。失敗したらエラーで止まる
2. 元のビルドが出力した GNAT の ALI ファイルの `D` 行（依存ソース）に現れないファイルは、どのテストからも検出できないので、そのミュータントは実行せず NoCoverage として警告する。ALI が 1 つもないとき、`prove` を設定したとき（GNATprove はビルド対象外のソースも証明し得る）は判定しない。古い ALI が残っていると判定は甘くなる（実行される）だけなので、`sandbox_exclude` に `obj` を入れておくと正確になる
3. 同じ状態をワーカー数ぶんのサンドボックスに複製
4. 各ワーカーが 1 ファイルだけを書き換え → `build` → `test` → `prove` → 元に戻す、を繰り返す。GNAT の ALI は 1 秒単位のタイムスタンプなので、書き換え時に mtime を必ず進めて再コンパイル漏れを防いでいる
5. ログは `.adamutant/logs`、レポートは `report_dir` に出力

## サンプル

- [examples/calculator](examples/calculator): わざと境界値を検査しないテスト。生き残ったミュータントとタイムアウトが見られる
- [examples/spark_counter](examples/spark_counter): テストなし、GNATprove の証明だけでミュータントを kill する例

```sh
cd examples/calculator && ../../bin/adamutant run
```

## ライセンス

Apache License 2.0
