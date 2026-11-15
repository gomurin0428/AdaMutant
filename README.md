# AdaMutant

**English** | [日本語](README.ja.md)

A mutation testing tool for Ada and SPARK. It follows the same idea as [Stryker.NET](https://stryker-mutator.io/docs/stryker-net/introduction/) for .NET: it makes small changes (mutants) to the sources automatically, checks whether the tests or the GNATprove proofs detect each change, and reports the **mutation score**.

- A built-in lexer for Ada up to Ada 2022 (no extra dependencies such as libadalang)
- Mutants can be killed **by a failed GNATprove proof** as well as by a failed test (for SPARK)
- **All the mutants are built once**, and the tests run while switching which mutant is active (mutant schemata). It is fast because it does not rebuild for every mutant
- Runs in parallel in several sandboxes. A test that times out is terminated together with its process group (its job object on Windows)
- `test_memory_limit_mb` limits the memory of each test process (`RLIMIT_AS` on POSIX, a job object on Windows. macOS does not accept `RLIMIT_AS`, so AdaMutant checks the physical memory (phys_footprint) of the test processes every 10 milliseconds). When a mutant that changes, for example, a loop count allocates several GB, the whole machine can run out of memory during a parallel run and the whole run can crash. An allocation beyond the limit fails (`Storage_Error` in Ada) and the mutant is Killed. On macOS the test processes are terminated together as soon as the limit is exceeded, and the mutant is also Killed (the log contains `adamutant: killed, a process exceeded test_memory_limit_mb`). The tests of the unchanged project run under the same limit, so a limit that is too small is reported as an error at that point
- Reports: a console table, a self-contained HTML file, and JSON in [mutation-testing-report-schema](https://github.com/stryker-mutator/mutation-testing-elements) v2 (the Stryker dashboard can read it)

## Requirements

- GNAT with Ada 2022 support (tested with GNAT 14) and GPRbuild
- GNATprove, if you want to kill mutants by proof
- Python 3, to run the end-to-end tests

## Building

```sh
make build        # produces bin/adamutant
make test         # unit tests + end-to-end tests that use the examples
```

## Usage

Create a configuration file in the root of your project and run AdaMutant there.

```sh
adamutant init                 # write a template adamutant.toml
adamutant list                 # list the mutants that would be made (runs nothing)
adamutant run                  # run and write the reports
adamutant run --mutate 'src/parser*.adb' --concurrency 4
adamutant run --since origin/main   # only the lines changed in a pull request
```

| Option | Meaning |
|---|---|
| `--config FILE` | Configuration file (default `adamutant.toml`). The project root is the directory that contains the configuration file |
| `--mutate GLOB` | Narrow down the files to mutate (repeatable) |
| `--concurrency N` | Number of parallel sandboxes |
| `--since REF` | Only mutate the lines changed since the merge base of the git revision REF and HEAD (see below) |
| `--keep-sandbox` | Keep `.adamutant/sandbox` after the run (for investigation) |

`--since` is meant for CI on pull requests, like `--since` in Stryker.NET. It covers the diff from `git merge-base REF HEAD` (both committed and uncommitted changes) and the untracked files that are not ignored. Unchanged files are not read. In a changed file, the mutants that do not touch a changed line become `Ignored` (reason `unchanged since REF`), so the score is computed from the mutants on the changed lines only. When only a spec (`.ads`) changed, the mutants of the body are not included. CI needs the history, so on GitHub Actions set `fetch-depth: 0` on `actions/checkout`.

Exit status: 0 = success, 1 = error (a mistake in the configuration, the original project fails to build or its tests fail, and so on), 2 = the score is below the `break` threshold.

### Configuration (adamutant.toml)

```toml
mutate = ["src/**/*.adb", "src/**/*.ads"]   # files to mutate
exclude = ["src/generated/**"]
build = "gprbuild -p -q -P tests.gpr"       # required. A mutant that fails to build is CompileError
test = "bin/run_tests"                      # Killed when the exit status is not 0
prove = "gnatprove -P prove.gpr --level=1 --checks-as-errors=on"  # Killed (by proof) when not 0
concurrency = 4                             # default: half the number of CPUs
timeout_factor = 1.5                        # time limit of the tests = original time * factor + timeout_ms
timeout_ms = 5000
test_memory_limit_mb = 2048                 # memory limit of each test process. The default 0 means no limit
mutators = ["ArithmeticOperator", "EqualityOperator"]  # all of them when omitted
mutate_contracts = false                    # true also mutates aspects such as Pre/Post
sandbox_exclude = [".git", "obj", "bin"]    # not copied into the sandboxes
report_dir = ".adamutant/reports"

[thresholds]
high = 80
low = 60
break = 0
```

The "original time" is the slowest run when the tests (proofs) of the unmutated project run in all the sandboxes at the same time. It is measured under the same load as the parallel runs of the mutants, so tests that become slower in parallel are not reported as Timeout by mistake.

At least one of `test` and `prove` is required. When both are set, the tests run first, and only the mutants that pass the tests go on to the proof. The commands run with `/bin/sh -c` on POSIX and with `cmd.exe /c` on Windows, and receive the environment variable `ADAMUTANT_MUTANT_ID`. The build, the tests and the proof of a mutant also receive the path of the mutated file in `ADAMUTANT_MUTANT_FILE` (relative to the project root, exactly as it appears under `files` in the JSON report; it is empty in the baseline runs). cmd.exe takes what follows the `/` of `bin/test` as a switch, so quote a path that contains `/`, as in `test = '"bin/test"'` (this also works as it is with `/bin/sh`). An unknown key is an error.

## Mutators

| Name | Examples |
|---|---|
| ArithmeticOperator | `+`↔`-`, `*`↔`/`, `mod`,`rem`→`*` (`mod`↔`rem` differ only when the signs differ, so that would almost always be an equivalent mutant), `**`→`*`. `&` is not mutated |
| EqualityOperator | `<`→`<=`,`>=`, `=`↔`/=` and so on |
| LogicalOperator | `and`↔`or`, `and then`↔`or else`, `xor`→`or`. In a chain such as `A and then B and then C`, parentheses are added, as in `(A or else B) and then C` |
| UnaryOperator | `not X`→`X`, `-X`↔`+X`, `abs X`→`X` |
| BooleanLiteral | `True`↔`False` |
| MembershipOperator | `in`↔`not in` |
| ConditionalExpression | the condition of `if`/`elsif` → `True`/`False`, of `while` → `False`, of `exit when` → `True` |
| StatementDeletion | assignment statements and procedure call statements → `null;` |
| NumericLiteral | `0`→`1`, `1`→`0`, `n`→`n+1`, a real literal → `0.0`. Based integer literals and integer literals with an exponent follow the same rules, and the base is kept (`16#FF#`→`16#100#`, `1E6`→`1000001`). The bounds of the range of a declared subtype, such as `String (1 .. 6)`, are not mutated |
| StringLiteral | `"abc"`→`""`, `""`→`"AdaMutant was here!"` |

`with`/`use` clauses, `pragma`s, representation clauses (`for X'Size use ...`) and `digits`/`delta` are not mutated. The default values of the formal parameters of a subprogram are not mutated either, because the program does not compile unless the declaration and the body match (full conformance). The default values in `is null` and `is abstract` subprograms, in expression functions and in generic formal subprograms are mutated. Aspects (`Pre`, `Post`, `Type_Invariant` and so on) and ghost code (the declarations and bodies of the subprograms, objects and types declared with the `Ghost` aspect, and the statements that call them or assign to them) are mutated only when `mutate_contracts = true`. The ghost names are collected from the `.adb` being mutated and from the `.ads` of the same name.

### Disabling with comments

```ada
--  adamutant:disable-next-line EqualityOperator: equivalent mutant
if A + B > Max then

--  adamutant:disable StatementDeletion, StringLiteral
Log ("...");
--  adamutant:enable
```

Leave out the names, or write `all`, to disable every mutator. A disabled mutant stays in the report as `Ignored` and is not counted in the score.

## Statuses and score

| Status | Meaning |
|---|---|
| Killed | A test or a proof failed (detected) |
| Timeout | The tests did not finish in time (counted as detected) |
| Survived | The tests and the proof both passed (not detected) |
| NoCoverage | The build does not compile the file (counted as not detected, and not run) |
| CompileError | The mutant could not be built (not in the score) |
| RuntimeError | A command could not be started, and the like (not in the score) |
| Ignored | Disabled by a comment (not in the score) |

`score = (Killed + Timeout) / (Killed + Timeout + Survived + NoCoverage) * 100`

## How it works

1. Copy the original project to `.adamutant/sandbox/1`, then build it and run the tests (and the proof) once to measure how long they take. If any of them fails, stop with an error
2. A file that does not appear in the `D` lines (the source dependencies) of the GNAT ALI files that the original build wrote cannot be detected by any test, so its mutants are not run and are reported as NoCoverage with a warning. This check is not made when there is no ALI file at all, or when `prove` is set (GNATprove may prove sources that the build does not cover). Stale ALI files only make the check more lenient (the mutants are run), so putting `obj` in `sandbox_exclude` makes it accurate
3. Copy that state into one sandbox for each worker
4. When `test` is set, make **sources that contain all the mutants**, build them once, and run only the tests for each mutant (see below)
5. For the mutants that could not be put together, each worker repeats: rewrite one file → `build` → `test` → restore. The time stamps in GNAT's ALI files have a resolution of one second, and on Windows they are rounded up to an even second, so the mtime is moved forward by two seconds or more at every rewrite to make sure that the file is recompiled
6. When `prove` is set, the mutants that the tests did not detect go to the proof one at a time (rewrite one file → `prove` → restore). The proof is not run on the sources that contain all the mutants, because it could not tell which mutant caused a failure
7. The logs are written to `.adamutant/logs` and the reports to `report_dir`

### Building the mutants once

The sources that contain the mutants look like this, for example (`ADAMUTANT_ACTIVE_1` is a function that returns the value of the environment variable `ADAMUTANT_MUTANT_ID` when the tests run. When it is 0, no mutant is active).

```ada
case ADAMUTANT_ACTIVE_1 is
when 17 =>
X := X - 1;
when 18 =>
X := X + 0;
when others =>
X := X + 1;
end case;
```

The mutants that are put together are those in the following places, whose extent can be determined reliably by lexical analysis alone.

| Place | Rewritten as |
|---|---|
| Simple statements (assignment, procedure call, `return`, `exit`, `raise` and so on) | a `case` statement |
| The conditions of `if`, `elsif` and `while` | a `case` expression |
| The expression of an expression function | a `case` expression |

The following are not put together, and are built one at a time as before.

- Mutants in declarations (constants, named numbers, the ranges of types and so on), in the ranges of `for`, in the choices of `case`, and in aspects. These may need a static expression, so they cannot be switched at run time
- StatementDeletion. When the deleted statement was the first assignment to a variable, the variable is uninitialized in the mutant. An optimizing compiler may give an uninitialized variable "the value assigned in the other branch", so in the build that contains all the mutants the mutant would behave like the original program, and a mutant that should have been detected would be missed
- Files that contain tasks, protected types, `accept` or `select`; statements that have a name; the object declaration of an extended return

When the build that contains all the mutants has a compile error, AdaMutant finds which mutant the line of the error belongs to, marks that mutant as CompileError, and builds again with the rest. When the build fails at a place that is not a line of any mutant, AdaMutant exits with an error.

There is one difference from building the mutants one at a time. The style checks are turned off in the sources that contain all the mutants, and the warnings that come from looking at the whole file (a variable is no longer used because a statement was deleted, for example) do not appear. So, in a project that treats warnings as errors (`-gnatwe`, `-gnaty`), a mutant that did not compile only because of a warning is now run instead of becoming CompileError.

What it needs:

- The main subprogram of the test program is written in Ada, and the build leaves GNAT ALI files. The function that returns the number of the active mutant is in `AdaMutant_Schemata_Support`, a unit that AdaMutant generates. Only inside the sandbox, AdaMutant puts it in the same directory as the source of the main and adds a `with` to the main. When the main cannot be found, AdaMutant prints a warning and builds every mutant one at a time
- C's `getenv` is available (to read the environment variable)
- The test command runs the built executable as it is. `ADAMUTANT_MUTANT_ID` is the environment variable that has always been passed to the test command, and it has to reach the test program

## Examples

- [examples/calculator](examples/calculator): tests that do not check the boundary values on purpose. You can see surviving mutants and a timeout
- [examples/spark_counter](examples/spark_counter): no tests. The mutants are killed by the GNATprove proof alone

```sh
cd examples/calculator && ../../bin/adamutant run
```

## License

Apache License 2.0
