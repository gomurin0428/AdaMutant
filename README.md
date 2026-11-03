# AdaMutant

Ada / SPARK 向けのミューテーションテストツールです。.NET の [Stryker.NET](https://stryker-mutator.io/docs/stryker-net/introduction/) と同じ考え方で、ソースに小さな変更（ミュータント）を自動で入れ、テストまたは GNATprove の証明がその変更を検出できるかを調べ、**ミューテーションスコア**を出します。

- Ada 2022 までの字句解析器を内蔵（libadalang などの追加依存なし）
- テストの失敗だけでなく **GNATprove の証明失敗でもミュータントを kill** できる（SPARK 向け）
- サンドボックスを複数作って並列実行、タイムアウトしたテストはプロセスグループ（Windows はジョブオブジェクト）ごと終了
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
```

| オプション | 意味 |
|---|---|
| `--config FILE` | 設定ファイル（既定 `adamutant.toml`）。プロジェクトルートは設定ファイルのあるディレクトリ |
| `--mutate GLOB` | 対象ファイルをさらに絞る（複数指定可） |
| `--concurrency N` | 並列サンドボックス数 |
| `--keep-sandbox` | 終了後も `.adamutant/sandbox` を残す（調査用） |

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
mutators = ["ArithmeticOperator", "EqualityOperator"]  # 省略時はすべて
mutate_contracts = false                    # true で Pre/Post などのアスペクトも変異
sandbox_exclude = [".git", "obj", "bin"]    # サンドボックスにコピーしないもの
report_dir = ".adamutant/reports"

[thresholds]
high = 80
low = 60
break = 0
```

`test` と `prove` は少なくとも一方が必要です。両方あるときはテストを先に実行し、テストが通ったミュータントだけを証明にかけます。コマンドは POSIX では `/bin/sh -c`、Windows では `cmd.exe /c` で実行され、環境変数 `ADAMUTANT_MUTANT_ID` が渡されます。cmd.exe は `bin/test` の `/` 以降をスイッチとして解釈するため、`/` を含むパスは `test = '"bin/test"'` のように引用符で囲んでください（`/bin/sh` でもそのまま動きます）。未知のキーはエラーになります。

## ミュータント

| 名前 | 例 |
|---|---|
| ArithmeticOperator | `+`↔`-`, `*`↔`/`, `mod`↔`rem`, `**`→`*`, `&` は対象外 |
| EqualityOperator | `<`→`<=`,`>=`、`=`↔`/=` など |
| LogicalOperator | `and`↔`or`, `and then`↔`or else`, `xor`→`or`。`A and then B and then C` のような連鎖では `(A or else B) and then C` のように括弧を補う |
| UnaryOperator | `not X`→`X`, `-X`↔`+X`, `abs X`→`X` |
| BooleanLiteral | `True`↔`False` |
| MembershipOperator | `in`↔`not in` |
| ConditionalExpression | `if`/`elsif` の条件 → `True`/`False`、`while` → `False`、`exit when` → `True` |
| StatementDeletion | 代入・手続き呼び出し文 → `null;` |
| NumericLiteral | `0`→`1`, `1`→`0`, `n`→`n+1`, 実数 → `0.0` |
| StringLiteral | `"abc"`→`""`, `""`→`"AdaMutant was here!"` |

`with`/`use` 節、`pragma`、表現節（`for X'Size use ...`）、`digits`/`delta` は変異させません。アスペクト（`Pre`, `Post`, `Type_Invariant` など）は `mutate_contracts = true` のときだけ変異させます。

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
2. 元のビルドが出力した GNAT の ALI ファイルの `D` 行（依存ソース）に現れないファイルは、どのテストからも検出できないので、そのミュータントは実行せず NoCoverage として警告する。ALI が 1 つもないときは判定しない
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
