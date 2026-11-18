# AdaMutant

**English** | [日本語](README.ja.md)

A mutation testing tool for Ada and SPARK. It follows the same idea as [Stryker.NET](https://stryker-mutator.io/docs/stryker-net/introduction/) for .NET: it makes small changes (mutants) to the sources automatically, checks whether the tests and the GNATprove proofs detect each change, and reports the **mutation score**.

- A built-in lexer for Ada up to Ada 2022 (no extra dependencies such as libadalang)
- **The mutants that the tests do not detect go to the GNATprove proof** (for SPARK). The mutants that only the proof detects are listed as candidates for a missing test
- **All the mutants are built once**, and the tests run while switching which mutant is active (mutant schemata). It is fast because it does not rebuild for every mutant
- **Mutants in code that no test executes skip the tests and go straight to the proof.** AdaMutant records which places the tests of the unchanged project execute
- **Results per test.** When several test commands are given with names, the report says which tests execute and detect each mutant, and a mutant is only tested with the tests that execute its place (`[tests]`)
- **The results of an earlier run are reused.** A mutant on lines that have not changed takes its result from an earlier report (`--baseline`)
- **Equivalent mutants are recognized automatically.** AdaMutant compiles the survivors with optimization and marks a mutant as Ignored when its object code is the same as before the change (`equivalence_build`)
- Runs in parallel in several sandboxes. A test that times out is terminated together with its process group (its job object on Windows)
- `test_memory_limit_mb` limits the memory of each test process (`RLIMIT_AS` on POSIX, a job object on Windows. macOS does not accept `RLIMIT_AS`, so AdaMutant checks the physical memory (phys_footprint) of the test processes every 10 milliseconds). When a mutant that changes, for example, a loop count allocates several GB, the whole machine can run out of memory during a parallel run and the whole run can crash. An allocation beyond the limit fails (`Storage_Error` in Ada) and the mutant is Killed. On macOS the test processes are terminated together as soon as the limit is exceeded, and the mutant is also Killed (the log contains `adamutant: killed, a process exceeded test_memory_limit_mb`). The tests of the unchanged project run under the same limit, so a limit that is too small is reported as an error at that point
- Reports: a console table, a self-contained HTML file, and JSON in [mutation-testing-report-schema](https://github.com/stryker-mutator/mutation-testing-elements) v2 (the Stryker dashboard can read it)

## Intended workflow

AdaMutant is made for projects that use both tests and the GNATprove proof. This is how it is meant to be used:

1. Run AdaMutant with both the tests and the proof set up. Each mutant goes to the tests first, and only the mutants that the tests do not detect go to the proof (tests first). There is no setting to run the tests alone or the proof alone.
2. Look at the mutants that only the proof detects as candidates for a missing test. The console lists them under `Detected only by the proof (candidates for a missing test):`, in three groups by what GNATprove gives with the failure. The groups need the counterexamples of GNATprove, so the prove command has `--counterexamples=on`.

   | Group | What it is based on | What to do |
   |---|---|---|
   | `Confirmed` | Severity high, or an error. High means that GNATprove ran a counterexample with the real code and the check failed | Add a test, if the tests can observe the behaviour |
   | `A contract says too little` | GNATprove adds `possible fix: add or complete related loop invariants or postconditions`: the counterexample makes the check fail only with the contracts of the calls (or the loop invariants) in place of the code | Find the contract (a postcondition of something it calls, a loop invariant) that says too little, and make it stronger |
   | `Undecided` | Anything else: no counterexample, or one that GNATprove could not run with the real code (a call to code outside SPARK, a loop that runs too long, and so on) | Decide by hand; a counterexample, if any, is in the list |

   - If the tests cannot observe it, as with a branch that cannot be reached, leave it to the proof. Nothing needs to be excluded.
   - The second group holds mutants that do not change what the program does (equivalent ones) as well as real bugs, because GNATprove only checks the one counterexample that it picked. Once the contract is stronger, an equivalent mutant proves, and a real bug moves to `Confirmed`.
3. Handle the mutants that neither the tests nor the proof detect (Survived) as before: add a test or make a contract stronger. Equivalent mutants (those whose object code is the same as before the change) are recognized and excluded automatically when `equivalence_build` is set (Ignored). The others stay Survived.
4. A mutant whose proof runs out of time is not counted as detected. It counts as Survived and is marked `(the proof timed out)` in the list. Treat it as in 2 or 3. Under the list, the console then gives their number and what to try: on a goal that a mutant makes fail, the provers often run up to their time limit, and a steps limit for the provers (`--steps`) usually lets such a proof end within the time limit of the mutant (see [Speeding up the proof of the mutants](#speeding-up-the-proof-of-the-mutants)).

This is part of the output for [examples/spark_counter](examples/spark_counter). The test only calls `Counters.Increment`, so only the proof detects the other mutants.

```
Detected only by the proof (candidates for a missing test):
  Confirmed: the failure happens with the real code (or GNATprove reports an error)
  #8 src/counters.adb:13:19 ArithmeticOperator (range check, postcondition; no test executes this code)
    - +
    + -
    e.g. when A = 0 and B = 1
  A contract says too little: the failure happens only with the contracts of the calls (or the loop invariants) in place of the code
  #12 src/halves.adb:13:10 ConditionalExpression (range check; no test executes this code)
    - H > 50
    + False
    e.g. when H = 51
  #18 src/halves.adb:16:18 NumericLiteral (range check; no test executes this code)
    - 2
    + 3
    e.g. when H = 34

Survived mutants:
  #6 src/counters.adb:10:16 EqualityOperator
    - >
    + >=
  #10 src/halves.adb:5:18 NumericLiteral
    - 2
    + 3
```

- #8 turns `A + B` into `A - B` in `Saturating_Add`. For A = 0 and B = 1, `A - B` is out of the range of `Count`, and the range check fails with the real code. It is a candidate for a test (as in 2).
- The body of `Halves.Half` returns `X / 2`, but its contract only says that the result is not greater than X. #12 removes the test `H > 50`; H is never greater than 50, so nothing changes (an equivalent mutant). #18 turns `H * 2` into `H * 3`, a real bug: for X of 68 or more the result is out of range and Constraint_Error is raised. For both, GNATprove found the failure only with the contract of `Half` in place of its body, and could not confirm it with the real code. With the postcondition `Half'Result = X / 2`, #12 proves and #18 moves to `Confirmed`.
- The survivor #6 is an equivalent mutant: when `A + B = Max`, both branches return `Max`. Even with `equivalence_build` (which this example does not set) it is not excluded automatically, because the optimized object code still differs, so it stays Survived (as in 3). #10 turns `X / 2` into `X / 3`; the contract of `Half` says too little for the proof to detect it, which also shows where a contract should be stronger (as in 3).

### What a detection by the proof means

The proof only sees the mutants that the tests do not detect (tests first). For such a mutant, a detection by the proof (Killed, with the proof in `killedBy`) means that GNATprove cannot prove the changed code with the contracts as they are. It shows how strong the contracts are around the mutant, in the places that the tests do not check.

- It does not show by itself that the program goes wrong. A proof also fails when the changed code still does what the contracts say but GNATprove cannot show it: a contract of a call or a loop invariant says too little (as for #12 above), or the provers run out of steps (see [Speeding up the proof of the mutants](#speeding-up-the-proof-of-the-mutants)). The groups say how sure the detection is. `Confirmed` (GNATprove ran a counterexample with the real code and the check failed, or reported an error) is strong evidence; with a counterexample, the behaviour of the code really changed. `A contract says too little` and `Undecided` are weaker evidence, and may be equivalent mutants
- A mutant that the tests detect is not proved, so how strong the contracts are around it is not measured. A weak contract there shows only through the mutants that the tests miss, or through the mutants of the contract itself (see [Mutators](#mutators))
- A mutant whose proof finished without detecting it is one that the contracts allow: they say too little to rule it out, the mutant is equivalent, or the proof proves anything there (see [Where the proof proves anything](#where-the-proof-proves-anything)). A mutant whose proof did not finish in time is not detected either (see 4 above), nor is one in a body outside SPARK, which GNATprove does not prove
- For a mutant of a contract, a detection means that the changed contract no longer proves: the body does not meet a stronger postcondition, a caller needs what a weaker one left out, and so on. How to read the survivors is under [Mutators](#mutators)

## Requirements

- GNAT with Ada 2022 support and GPRbuild (tested with GNAT 16.1 and GPRbuild 26; GNAT 14 builds it too)
- GNATprove, for the proof (tested with GNATprove 16.1). The `prove` command is required. GNATprove only analyses SPARK code (`SPARK_Mode`), so the proof never detects a mutant in other code. GNATprove 16 fails when there is no SPARK code at all; for such a project, write `prove = "exit 0"` (a command that always passes, so GNATprove is not needed), as [examples/calculator](examples/calculator) does
- Python 3, to run the end-to-end tests

## Building

```sh
make build        # produces bin/adamutant
make test         # unit tests + end-to-end tests that use the examples
```

With [Alire](https://alire.ada.dev), `alr build` builds the same `bin/adamutant` and gets the compiler for you. A build with Alire does not stop at warnings (`ADAMUTANT_WARNINGS_AS_ERRORS=false`); `make build` does.

## Usage

Create a configuration file in the root of your project and run AdaMutant there.

```sh
adamutant init                 # write a template adamutant.toml
adamutant list                 # list the mutants that would be made (runs nothing)
adamutant run                  # run and write the reports
adamutant run --mutate 'src/parser*.adb' --concurrency 4
adamutant run --since origin/main   # only the lines changed in a pull request
adamutant run --baseline .adamutant/reports/mutation-report.json   # reuse the results of the last run
```

| Option | Meaning |
|---|---|
| `--config FILE` | Configuration file (default `adamutant.toml`). The project root is the directory that contains the configuration file |
| `--mutate GLOB` | Narrow down the files to mutate (repeatable) |
| `--concurrency N` | Number of parallel sandboxes |
| `--since REF` | Only mutate the lines changed since the merge base of the git revision REF and HEAD (see below) |
| `--baseline FILE` | Reuse the results in FILE, the JSON report of an earlier run, for the mutants on lines that have not changed (see below) |
| `--keep-sandbox` | Keep `.adamutant/sandbox` after the run (for investigation) |

`--since` is meant for CI on pull requests, like `--since` in Stryker.NET. It covers the diff from `git merge-base REF HEAD` (both committed and uncommitted changes) and the untracked files that are not ignored. Unchanged files are not read. In a changed file, the mutants that do not touch a changed line become `Ignored` (reason `unchanged since REF`), so the score is computed from the mutants on the changed lines only. When only a spec (`.ads`) changed, the mutants of the body are not included. CI needs the history, so on GitHub Actions set `fetch-depth: 0` on `actions/checkout`.

Exit status: 0 = success, 1 = error (a mistake in the configuration, the original project fails to build or its tests fail, and so on), 2 = the score is below the `break` threshold.

### Configuration (adamutant.toml)

```toml
mutate = ["src/**/*.adb", "src/**/*.ads"]   # files to mutate
exclude = ["src/generated/**"]
build = "gprbuild -p -q -P tests.gpr -cargs -gnata"  # required. A mutant that fails to build is CompileError
test = "bin/run_tests"                      # required (or [tests]); Killed when the exit status is not 0
prove = 'gnatprove -P prove.gpr --level=1 --steps=2000 --checks-as-errors=on --counterexamples=on $ADAMUTANT_PROVE_SWITCHES "--memcached-server=file:$ADAMUTANT_PROVE_CACHE"'  # required; runs only for mutants that pass the tests; Killed (by proof) when not 0
equivalence_build = "gprbuild -p -q -c -P tests.gpr -cargs -gnata -O2 -g0"  # optional. The build used to recognize equivalent mutants
concurrency = 4                             # default: half the number of CPUs
timeout_factor = 1.5                        # time limit of the tests = original time * factor + timeout_ms
timeout_ms = 5000
prove_timeout_ms = 0                        # time limit (ms) of the proof of one mutant. The default 0 takes it from the original proof
test_memory_limit_mb = 2048                 # memory limit of each test process. The default 0 means no limit
coverage_analysis = true                    # false also runs the mutants in code that no test executes
bail = true                                 # false runs the remaining tests after one has detected the mutant (for [tests])
mutators = ["ArithmeticOperator", "EqualityOperator"]  # when omitted, all but LoopDirection
exclude_mutators = ["StringLiteral"]        # left out of the mutators above, also when in include_mutators
include_mutators = ["LoopDirection"]        # added to them
sandbox_exclude = [".git", "obj", "bin"]    # not copied into the sandboxes
report_dir = ".adamutant/reports"

[thresholds]
high = 80
low = 60
break = 0

# Instead of test, several test commands with names (see below)
# [tests]
# parser = "bin/test_parser"
# lexer = "bin/test_lexer"
```

The "original time" is the slowest run when the tests (proofs) of the unmutated project run in all the sandboxes at the same time. It is measured under the same load as the parallel runs of the mutants, so tests that become slower in parallel are not reported as Timeout by mistake.

`build`, the tests (`test` or `[tests]`) and `prove` are required. Each mutant goes to the tests first, and only the mutants that pass the tests go on to the proof. The commands run with `/bin/sh -c` on POSIX and with `cmd.exe /c` on Windows, and receive the environment variable `ADAMUTANT_MUTANT_ID`. The build, the tests and the proof of a mutant also receive the path of the mutated file in `ADAMUTANT_MUTANT_FILE` (relative to the project root, exactly as it appears under `files` in the JSON report) and the mutated line in `ADAMUTANT_MUTANT_LINE` (both are empty in the baseline runs). The prove command receives a directory for a cache of proof results in `ADAMUTANT_PROVE_CACHE` (see [Speeding up the proof of the mutants](#speeding-up-the-proof-of-the-mutants)) and switches for GNATprove in `ADAMUTANT_PROVE_SWITCHES` (see [Where the proof proves anything](#where-the-proof-proves-anything)). cmd.exe takes what follows the `/` of `bin/test` as a switch, so quote a path that contains `/`, as in `test = '"bin/test"'` (this also works as it is with `/bin/sh`). An unknown key is an error.

### Reusing the results of an earlier run

With `--baseline FILE`, where FILE is the JSON report of an earlier run (`mutation-report.json`), a mutant on lines that have not changed takes its result from that report. A mutant whose result is reused is not run. Its `statusReason` ends with `(from the baseline report)`.

Which mutants are the same is decided by comparing the sources line by line. AdaMutant compares the source in the report with the source as it is now. A mutant is the same when none of its lines has changed and the columns, the mutator and the replacement are the same. Lines added above, which shift the line numbers, do not matter. git is not used.

The lines are matched by way of the lines that occur exactly once in each of the two sources. A line that occurs several times, such as `begin` or `end if;`, is only matched where it adjoins such a line. So a line is never taken for another line with the same text. Of two functions that have changed places, one counts as changed lines.

The results that are reused depend on whether `--since` is given.

| Usage | Results reused | Mutants run |
|---|---|---|
| `--baseline FILE` | Killed, Timeout and CompileError on lines unchanged since the source in the report | The mutants on lines changed since the source in the report, and the mutants that were not detected last time (Survived and so on) |
| `--since REF --baseline FILE` | On lines unchanged since REF, every result that the report has (including Survived, and Ignored for an equivalent mutant). On lines changed since REF, as in the row above | The mutants on lines changed since REF (except those on lines unchanged since the source in the report that are already detected) |

- `--baseline` alone suits a run after tests have been added. It skips the mutants that were detected last time and tries only the survivors again
- Together with `--since`, CI on a pull request runs only the changed lines and still reports the score and the report of the whole project. Unchanged files are read in this case. FILE is, for example, the report of a full run on the main branch
- Together with `--since`, a mutant on a line unchanged since REF for which the report has no usable result stays Ignored (`unchanged since REF`), as with `--since` alone, and is outside the score
- When FILE does not exist, AdaMutant prints a warning and runs without reusing a result (for a first run). When FILE is not JSON, has no `files`, or is not a file, it is an error
- A CompileError of a build that ran out of time is not reused (without `--since` the mutant runs again)
- FILE is read before the reports are written, so it may be the file that this run writes

A reused result rests on nothing but the lines being unchanged. In the following cases stale results remain, so run everything without `--baseline` from time to time.

- Tests were removed or weakened (a mutant that counts as detected survives now)
- What an unchanged line does has changed because of a change in another line or another file
- The build or test commands or the compiler changed
- The mutators changed (`mutators`, `exclude_mutators`, `include_mutators`): with `--since`, the new mutants on unchanged lines have no result in the report and stay Ignored (`unchanged since REF`). So does a report of an earlier version that did not mutate contracts
- Mutants whose result depends on the load of the machine (a Timeout because the time ran out)

### Speeding up the proof of the mutants

The prove command proves the whole unit (or what the command says) for each mutant. In a large unit, the goals that the mutant does not change take time again for every mutant.

GNATprove can keep a cache of proof results (`--memcached-server=file:<directory>`). AdaMutant gives the prove command a directory for it in `ADAMUTANT_PROVE_CACHE`; add it to the command, with a steps limit for the provers (`--steps`, see below):

```toml
prove = 'gnatprove -P prove.gpr --level=1 --steps=2000 --checks-as-errors=on --counterexamples=on $ADAMUTANT_PROVE_SWITCHES "--memcached-server=file:$ADAMUTANT_PROVE_CACHE"'
```

On Windows (cmd.exe), write `%ADAMUTANT_PROVE_CACHE%`.

- The proof of the unmodified project fills the cache. In the proof of a mutant, the goals that did not change get their answers from the cache, and only the goals that the mutant changes are proved again
- The keys of the cache are the goals themselves, so a goal gets the answer that a prover gave to the same goal before, and the results are those of a whole proof without the cache. With GNATprove 16.1, the messages were the same, counterexamples and `possible fix` included (a counterexample is checked with the real code again, also for a goal whose answer comes from the cache). AdaMutant does not guess which subprograms a mutant affects
- Give the provers a steps limit (`--steps`; the value must be enough for the unmodified project). With the cache, GNATprove 16.1 runs a prover that stops at a time limit, rather than at a steps limit, about four times as long as the limit: in a test, CVC5 with `--timeout=2` ran 8 s for each goal that it could not prove. The goals that a mutant makes fail then take much longer than without the cache, and their proof may not finish within the time limit of the mutant, which is taken from the proof of the unmodified project, where nothing fails: the mutant is then Survived. With a steps limit, the provers took the same time with and without the cache. Steps also make the results independent of the load of the machine.

  A steps limit helps without the cache too: a goal that a mutant makes fail makes the provers run up to their limit, and with a time limit alone the proof may not finish within the time limit of the mutant (in a test at `--level=2`, three mutants that `--steps=5000` killed were Survived, with and without the cache). A smaller value makes the proofs of the mutants faster, but a goal that the mutant changes and that still holds may then fail for lack of steps, and the mutant counts as detected by the proof (never `Confirmed`, since the check holds with the real code; usually `Undecided`). So keep the value small, with a margin: for instance, twice the largest number of steps that a check of the unmodified project needs (`--report=statistics` shows the steps of each check). When it is too low, the proof of the unmodified project fails and AdaMutant stops
- The goals carry their lines. AdaMutant keeps the line breaks of the text that a mutant replaces after the replacement (a deleted statement over several lines, for example), so the lines after it do not move and their goals still hit the cache
- Each sandbox has its own cache (`.adamutant/sandbox/prove-cache/<n>`). It starts empty in every run and goes with the sandbox. The entries that a proof wrote are removed when it does not finish in time (an entry cut short stops GNATprove)
- The goals that a mutant makes fail are not faster, nor is a mutant that changes many goals (a constant used in many places, for example). When you set `prove_timeout_ms`, leave the time of a whole proof without the cache

An example with GNATprove 16.1: in a unit of 24 functions (480 checks), with a mutant in the body of one function, the whole proof took 40.9 s without the cache and 1.4 s with the cache filled by the proof of the unmodified project. Both found the same 2 failed checks.

Next to the cache, the choice of provers matters little. With GNATprove 16.1, in four runs that detected 14 to 60 mutants, `--prover=z3` alone took about as long as `--level=1` (CVC5, Z3 and Alt-Ergo) and detected the same mutants (the runs took 55 s to 219 s). With the cache added to `--prover=z3`, the same runs took 35 to 53 % less time (the longest `--prover=z3` run, 208 s, took 97 s), again with the same results.

`prove_timeout_ms` is the time limit of the proof of one mutant. When it is 0 (the default), it comes from the proof of the unmodified project, as for the tests. A mutant whose proof does not finish in time is not counted as detected (Survived).

### Where the proof proves anything

A precondition that is always False, a `pragma Assume` that is always False, or code that is never reached makes the proof of anything succeed there: a mutant in such a place survives the proof however wrong it is, and the proof of the unmodified project says nothing about it. GNATprove finds these places with `--proof-warnings=on`.

When the prove command mentions `ADAMUTANT_PROVE_SWITCHES`, AdaMutant runs it once more on the unmodified project, with `--proof-warnings=on --warnings=continue` in that variable; every other proof gets `--proof-warnings=off`. Add it to the command, after any `--warnings` switch and without quotes (`%ADAMUTANT_PROVE_SWITCHES%` on Windows; the variable is never empty). When the command runs a script, pass the variable to it (`./prove.sh $ADAMUTANT_PROVE_SWITCHES`) and give it to gnatprove there:

```toml
prove = 'gnatprove -P prove.gpr --level=1 --steps=2000 --checks-as-errors=on --counterexamples=on $ADAMUTANT_PROVE_SWITCHES "--memcached-server=file:$ADAMUTANT_PROVE_CACHE"'
```

- The console lists the warnings of both proofs (`precondition is always False`, `postcondition is always False`, `pragma Assume is always False`, `unreachable code`, `unreachable branch`, and those of the compiler, such as code after a `return`), once for each line and message, under `The proof of the unmodified project proves anything here`. A survivor between the place of an `unreachable code` warning and the next semicolon (for a compound statement, its first line and its first inner statement) gets `(GNATprove: never reached)`. GNATprove usually reports only the first statement of code that is never reached, and the other warnings point inside expressions, so look at the list for the rest. The mark is left out when two mutated files have the same name, since GNATprove names files without their directory
- Fix the contract or remove the code: until then, neither the tests nor the proof can detect a mutant there
- The extra proof costs about as much as the proof of the unmodified project, and runs before the mutants, without a time limit, when there are mutants to run. With `--proof-warnings=on`, GNATprove makes other goals for the same checks, which a cache filled with them would not answer for the mutants, and leaves files that change the proofs that follow. So the extra proof has a cache of its own, and runs in a copy of the project without the directories `gnatprove` of GNATprove, which is deleted afterwards. The sandboxes leave out the project's own directories `gnatprove` as well, so that what an earlier proof with other switches left there does not change the proofs
- Its exit status does not count. `--warnings=continue` undoes a `--warnings=error` (which stops GNATprove at the first unit with a warning under `-j1`) or a `--warnings=off` that comes before it in the command
- When the prove command names `gnatprove` and mentions neither `ADAMUTANT_PROVE_SWITCHES` nor `--proof-warnings`, AdaMutant warns. Without the variable, the list holds the warnings of the proof of the unmodified project (all of them if its command turns proof warnings on itself, which makes every proof of a mutant look for them as well)
- Checked with GNATprove 16.1. A GNATprove without `--proof-warnings` fails on the switch

## Mutators

| Name | Examples |
|---|---|
| ArithmeticOperator | `+`↔`-`, `*`↔`/`, `mod`,`rem`→`*` (`mod`↔`rem` differ only when the signs differ, so that would almost always be an equivalent mutant), `**`→`*`. `&` is not mutated |
| EqualityOperator | `<`→`<=`,`/=`,`False`; `<=`→`<`,`=`,`True`; `>`→`>=`,`/=`,`False`; `>=`→`>`,`=`,`True`; `=`→`/=`,`False`; `/=`→`=`,`True`. `False` and `True` replace the whole relation (`A < B`→`False`). A relation splits its inputs in three: `A < B`, `A = B` and `A > B`, and each of the three mutants of `<` differs from it in one of them only (`False` when `A < B`, `<=` when `A = B`, `/=` when `A > B`). So killing all three takes a test that checks the result in each case, and such tests also kill the other replacements, such as the negation `>=` (Kaminski, Ammann and Offutt, 2011). `=` and `/=` may compare records, which have no `<`, so they only get the negation and the constant. No constant replaces the whole condition of an `if`, `elsif`, `while` or `exit when`: ConditionalExpression already makes that mutant, or the loop would never end (`while True`) |
| LogicalOperator | `and`↔`or`, `and then`↔`or else`, `xor`→`or`. In a chain such as `A and then B and then C`, parentheses are added, as in `(A or else B) and then C` |
| UnaryOperator | `not X`→`X`, `-X`↔`+X`, `abs X`→`X` |
| BooleanLiteral | `True`↔`False` |
| MembershipOperator | `in`↔`not in` |
| ConditionalExpression | the condition of `if`/`elsif` → `True`/`False`, of `while` → `False`, of `exit when` → `True` |
| StatementDeletion | assignment statements, procedure call statements, raise statements and return statements without a value (`return;`) → `null;`. Not a `return;` right before `exception` or an `end` that is not `end if`/`loop`/`case`/`select`, where it changes nothing in a body (it is also left out before the end of a nested block, where it does change something). Not a raise or `return;` that is the whole branch of an `if` or `elsif` without an `else`, while ConditionalExpression is enabled: it already makes that program (condition → `False`). Not an exit statement, which could make the loop run for ever, nor a delay statement, whose only effect (time) tests and proof rarely observe |
| NumericLiteral | `0`→`1`, `1`→`0`, `n`→`n+1`, a real literal → `0.0`. Based integer literals and integer literals with an exponent follow the same rules, and the base is kept (`16#FF#`→`16#100#`, `1E6`→`1000001`). The bounds of the range of a declared subtype, such as `String (1 .. 6)`, are not mutated |
| StringLiteral | `"abc"`→`""`, `""`→`"AdaMutant was here!"` |
| AttributeSwap | `'First`↔`'Last`, `'Min`↔`'Max`, `'Succ`↔`'Pred`, `'Floor`↔`'Ceiling`, `'First_Valid`↔`'Last_Valid`. The counterpart gives a value of the same type, so the mutant type-checks; it can still fail to compile where choices must differ or cover the type (case choices, named array aggregates) or where a static value goes out of range (`Color'Succ (Color'Last)`), and is then a CompileError. Not in the subtype of a declaration (`X : String (1 .. A'Last)`, `subtype S is T range T'First .. T'Last`), like the bounds of NumericLiteral; an initial value (`L : constant Natural := A'Last`) and an aspect of the declaration (a predicate) are mutated |
| LoopDirection | `for I in A .. B loop`↔`for I in reverse A .. B loop`. `reverse` is added to a loop over a range (`A .. B`, `X'Range`) or over a type or subtype named alone that is declared in the file, in its spec or in Standard (`for I in Index loop`, `for C in Character loop`). Not to a loop over another name (`for C in L loop`, `for I in Types.Index loop`) or an iterator (`for C in V.Iterate`, `for E of A`), which may be a container or an iterator that cannot go backwards; not in a quantified expression or an aggregate. The `when` of an iterator filter ends the range. `reverse` is removed from any `for ... in reverse` loop, an iterator too, since going forwards always compiles. **Off by default**: in many loops the order does not matter (a sum, a copy into another array), and the mutant is then equivalent, yet a loop invariant usually makes its proof fail, so it is listed as a candidate for a missing test. Turn it on with `include_mutators = ["LoopDirection"]` |
| ConjunctDeletion | In a contract (a contract aspect, ghost code or an assertion pragma), one operand of `and` or `and then` is left out: `Post => A and then B and then C` → `B and then C`, `A and then C`, `A and then B`. Only in contracts |
| AssertionDeletion | An assertion pragma (`Assert`, `Assert_And_Cut`, `Assume`, `Loop_Invariant`, `Loop_Variant`) is deleted. Where it is the only statement of a sequence (`begin pragma Assert (X); end;`), it becomes `null;`; elsewhere nothing is left, since a `null;` between loop invariants would split their group, which GNAT rejects |

`with`/`use` clauses, `pragma`s, representation clauses (`for X'Size use ...`) and `digits`/`delta` are not mutated, except that ConjunctDeletion and AssertionDeletion change assertion pragmas. The default values of the formal parameters of a subprogram are not mutated either, because the program does not compile unless the declaration and the body match (full conformance). The default values in `is null` and `is abstract` subprograms, in expression functions and in generic formal subprograms are mutated. Aspects that are contracts (`Pre`, `Post` and their `'Class` forms, `Contract_Cases`, `Type_Invariant`, the predicates, `Default_Initial_Condition`, `Initial_Condition`, `Subprogram_Variant`, `Refined_Post`, `Exceptional_Cases` and so on) and ghost code (the declarations and bodies of the subprograms, objects and types declared with the `Ghost` aspect, and the statements that call them or assign to them) are always mutated: a mutant of a contract shows how strong the contract is (see below). Other aspects (`Size`, `Alignment`, `Inline`, `Import`, `External_Name`, `Global`, `Depends`, `Annotate` and so on) are never mutated, like representation clauses. The ghost names are collected from the `.adb` being mutated and from the `.ads` of the same name.

Contracts and ghost code are only executed in a build with assertions, so build the code under test with `-gnata` (with gprbuild, `-cargs -gnata` reaches the projects that the test project uses); otherwise the tests cannot detect a mutant of a contract. After the build of the unchanged project, when there are mutants of contracts, AdaMutant reads the GNAT ALI files of the mutated files and warns when none was compiled with `-gnata` (unless a configuration pragma file `.adc` or the source has an `Assertion_Policy` with `Check`). The check needs the ALI files after `build`: when the test command builds the code, it does not warn. A configuration with `mutate_contracts = false`, from earlier versions, is refused: remove the line.

A mutant of a contract that the proof detects is not listed among the candidates for a missing test: no test can detect a weaker postcondition, for instance, since the code is the same. How to read the mutants of a contract that survive the tests and the proof:

- A stronger postcondition (`Post => R >= 0` → `Post => R > 0`) that still proves: the body guarantees more than the contract says, and the contract could say more. This holds for a body that GNATprove proves; for a body outside SPARK, GNATprove only assumes the postcondition
- A weaker postcondition that still proves: no caller's proof needs that part of the contract. Tests never detect a weaker postcondition
- A stronger precondition that still proves: every caller in SPARK meets it, and no test calls the subprogram outside it. For a subprogram that SPARK code does not call (an API), add a test at the boundary
- A weaker precondition that still proves: the body does not need that part of it
- A deleted `Loop_Invariant`, `Assert` or `Assert_And_Cut` (AssertionDeletion) that still proves: the proof does not need it. A deleted `Assume` that still proves: nothing needs the assumption, so remove it, since GNATprove does not check it. A deleted `Loop_Variant` that still proves: nothing asks GNATprove to prove that the loop terminates
- An operand left out of `and` (ConjunctDeletion) that still proves: where the `and` makes the contract stronger (the top of a postcondition, of a precondition or of an assertion), as for a weaker contract above, nothing needs that operand where the contract is used; in an assertion pragma, the proof does not need it. Elsewhere, leaving it out does something else: in a condition (`(if A and B then ...)`), under `not` or in a guard of `Contract_Cases`, it makes the contract stronger (read it as a stronger postcondition above); in an `and` of bits or arrays, or in a comparison of Booleans, it changes the contract without making it weaker or stronger
- A mutant of a contract can be equivalent, when it says the same thing in another way. `equivalence_build` does not examine mutants of contracts, so such a mutant stays Survived
- Without a proof (`prove = "exit 0"`), only the tests built with assertions examine contracts: a weaker postcondition then always survives, and so does a deleted assertion pragma (an assertion that holds never makes a test fail), and the score is lower. Leave them out with `exclude_mutators = ["ConjunctDeletion", "AssertionDeletion"]`

There is no comment that disables a mutant. A mutant that the tests cannot observe is left to the proof (see [Intended workflow](#intended-workflow)), and an equivalent mutant is recognized by `equivalence_build`.

## Statuses and score

| Status | Meaning |
|---|---|
| Killed | A test or a proof failed (detected) |
| Timeout | The tests did not finish in time (counted as detected) |
| Survived | The tests and the proof both passed, or the proof did not finish in time (not detected) |
| NoCoverage | Not used by this version, which sends a mutant that no test executes to the proof (counted as not detected) |
| CompileError | The mutant could not be built (not in the score) |
| RuntimeError | A command could not be started, and the like (not in the score) |
| Ignored | Found to be an equivalent mutant, or on a line unchanged since the revision of `--since` (not in the score) |

`score = (Killed + Timeout) / (Killed + Timeout + Survived + NoCoverage) * 100`

### Results per test

A `[tests]` table instead of `test` gives several test commands, each with a name. The key is the name and the value is the command. A name consists of letters, digits, `_`, `-` and `.`. It cannot be the name of a setting (`build`, `test`, `prove` and so on) or `proof`, which the reports use for the proof, and two names cannot differ only in case. Write `[tests]` after the settings. `test` and `[tests]` cannot be used together.

```toml
[tests]
parser = "bin/test_parser"
lexer = "bin/test_lexer"
```

- The tests run in the order in which they are written. All of them have to pass on the unchanged project. The time limit is measured for each test
- A mutant is only tested with the tests that execute its place (with `coverage_analysis = true`). `coveredBy` in the JSON report names the tests that execute the place
- `killedBy` names the tests that detected the mutant (the tests that failed or did not finish in time). `testsCompleted` is the number of tests that were run with the mutant. `testFiles` lists the tests
- By default the run of a mutant ends with the first test that detects it. With `bail = false`, every test that executes the place runs. This takes longer, but it shows the tests that detect no mutant at all. A mutant that loops forever waits for the time limit of every test that executes its place
- The log of each test is `mutant-<number>-test-<name>.log`
- A mutant that is not in the build that contains all the mutants (one in a declaration, for example) is tested with every test, because the tests that execute it are not known

Tests are left out for a mutant, so two things are needed. Where they do not hold, set `coverage_analysis = false` (every mutant is then tested with every test).

- Every test runs test programs of the build. When a test has recorded no executed place at all (a test that runs no such program, or one that runs where the record cannot be written), what it executes is not known. AdaMutant prints a warning and, for that run, leaves no test out: every mutant is tested with every test. This is seen for a test as a whole: when a test runs several programs and only some of them cannot record, it goes unnoticed
- The tests do not depend on each other. When one test writes a file that another test reads, the second reads an old file whenever the first is left out

The console shows, for each test, the number of mutants whose place it executes (Covers) and the number of mutants it detects (Kills). Covers is `-` when the executed places were not examined.

```
Test  | Covers | Kills
----------------------
arith |      5 |     4
misc  |     30 |    24
idle  |      1 |     0
Tests that detect no mutant: idle
```

A test with many Covers and few Kills may execute the code without checking the results. With `bail = true`, Kills only counts the first test that detects each mutant.

### Which check of the proof detected a mutant

For a mutant that the proof detects (Killed, with the proof in `killedBy`), AdaMutant records the kinds of the checks that GNATprove could not prove. `killedBy` in the JSON report then looks like `["proof: postcondition", "proof: range check"]`, and `statusReason` holds the first message of GNATprove. The console shows the number of mutants for each kind of check.

```
Mutants killed by the proof, by the check that fails (alone: no other kind of check fails for the mutant):
  range check   |     5 |     2 alone
  postcondition |     5 |     2 alone
```

`alone` is the number of mutants that only that kind of check detected. A mutant that only a range check or an overflow check detected may be a reason to look at the contracts again, but it does not show by itself that a contract is weak. GNATprove proves the code after a check on the assumption that the check holds. So the inputs for which the mutant goes wrong may stop at the run-time check and never reach the proof of the postcondition. The two mutants that only `range check` detects in the example above are mutants of a function whose postcondition determines the result completely.

- The names of the kinds come from the messages of GNATprove (the part before `... might fail`). The names that a message quotes (of variables and subprograms) are not part of the kind. The messages of the flow analysis about objects that are not initialized are one kind, `initialization`
- A message that the proof of the unchanged project has as well does not count (a message with the same text in the same file is taken to be the same one, whatever its line and column)
- When no message can be read, `killedBy` is `["proof"]` as before
- GNATprove 16 puts the place of a message on the next line (`--> file:line:col`). AdaMutant reads this format as well as the one-line format of older versions
- The console also lists each mutant that only the proof detects under `Detected only by the proof (candidates for a missing test):`. The parentheses hold the kinds of the checks that could not be proved. A mutant in a place that no test executes also gets `no test executes this code`. A counterexample of GNATprove is on the line below
- The three groups (see [Intended workflow](#intended-workflow)) also show in how the `statusReason` starts: `proof failed, confirmed: ` for `Confirmed`, `proof failed, a contract says too little: ` for the second group, and any other `proof failed` for `Undecided`. The counterexample is in parentheses after the message (`... (e.g. when H = 51)`). `--baseline` reads the group from there when it reuses a result (a reason of an earlier version, without such a start, is `Confirmed` when its message is high or an error)
- Of the messages that the proof of the unchanged project does not have, a high one or an error decides `Confirmed` first, then one with `possible fix: add or complete related loop invariants or postconditions`. GNATprove gives counterexamples with `--counterexamples=on`, and runs them with the real code unless `--check-counterexamples=off`. Without counterexamples most mutants are `Undecided`; when the proof gave no counterexample at all, the console says so. A mutant with several failures goes to the highest group that one of them reaches: with a failure that has the `possible fix` and one that does not, it is in `A contract says too little`; a failure that remains after the contract is stronger then shows as `Confirmed` or `Undecided`
- AdaMutant reads the default output of GNATprove (`--output=pretty`). With `--output=oneline` it reads the counterexample and the `possible fix` in the message; `--output=brief` has no counterexamples
- A mutant whose proof does not finish in time is Survived (its `statusReason` ends with `the proof did not finish within the timeout`), because a proof that would fail cannot be told apart from one that is only slow. With `--baseline`, a proof Timeout in a report of an earlier version runs again, or is reused as Survived on lines unchanged since the revision of `--since`
- Earlier versions could run the tests alone or the proof alone. With `--baseline`, their results that this version would not give are never reused: NoCoverage, a survivor of the tests alone or of the proof alone, and a mutant that the proof killed without any test. Such a mutant runs again, or, on a line unchanged since the revision of `--since`, stays Ignored (`unchanged since REF`) as with `--since` alone

## How it works

1. Copy the original project to `.adamutant/sandbox/1`, then build it and run the tests and the proof once to measure how long they take. If any of them fails, stop with an error
2. Copy that state into one sandbox for each worker
3. Make **sources that contain all the mutants**, build them once, and run only the tests for each mutant (see below). Before that, run the tests with no mutant active and record the places that they execute. The mutants in the places that they do not execute skip the tests and go to the proof (see below)
4. For the mutants that could not be put together, each worker repeats: rewrite one file → `build` → `test` → restore. The time stamps in GNAT's ALI files have a resolution of one second, and on Windows they are rounded up to an even second, so the mtime is moved forward by two seconds or more at every rewrite to make sure that the file is recompiled
5. The mutants that the tests did not detect go to the proof one at a time (rewrite one file → `prove` → restore). The proof is not run on the sources that contain all the mutants, because it could not tell which mutant caused a failure
6. When `equivalence_build` is set, the survivors are built with that command one at a time, and a survivor whose object files are the same as before the change becomes Ignored as an equivalent mutant (see below)
7. The logs are written to `.adamutant/logs` and the reports to `report_dir`

Where a sandbox holds libraries after the unchanged project is built and tested (`.a`, `.lib`, `.so`, `.so.<version>`, `.dll`, `.dylib`), every later build in it, in steps 3 and 4, starts two seconds or more after the newest of them was written. gprbuild does not make a library again unless its time stamp is older than that of an object, so a mutant compiled within the same second would not get into the library, and the tests would run the code of the build before. A library that no build writes again causes no wait. AdaMutant only sees the libraries inside the sandbox: a build that writes a library to a directory outside the project is not covered, and such a directory would be shared by all the sandboxes anyway. The wait compares the time stamps of the files with the clock of this machine, so on a network file system the clock of the file server must not be two seconds or more behind.

### Building the mutants once

The sources that contain the mutants look like this, for example (`ADAMUTANT_ACTIVE_1` is a function that returns the value of the environment variable `ADAMUTANT_MUTANT_ID` when the tests run. When it is 0, no mutant is active. The argument is the number of the place: the number of the first mutant there).

```ada
case ADAMUTANT_ACTIVE_1 (17) is
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
- StatementDeletion. When the deleted statement was the first assignment to a variable, the variable is uninitialized in the mutant. An optimizing compiler may give an uninitialized variable "the value assigned in the other branch", so in the build that contains all the mutants the mutant would behave like the original program, and a mutant that should have been detected would be missed. The build that contains all the mutants still records whether the statement is executed (see below)
- Files that contain tasks, protected types, `accept` or `select`; statements that have a name; the object declaration of an extended return
- Expression functions with the aspect `Static`, whose expression must stay potentially static, which a `case` expression on the active mutant is not

When the build that contains all the mutants has a compile error, AdaMutant finds which mutant the line of the error belongs to, marks that mutant as CompileError, and builds again with the rest. When the build fails at a place that is not a line of any mutant, AdaMutant exits with an error.

What it needs:

- The main subprogram of the test program is written in Ada, and the build leaves GNAT ALI files. The function that returns the number of the active mutant is in `AdaMutant_Schemata_Support`, a unit that AdaMutant generates. Only inside the sandbox, AdaMutant puts it in the same directory as the source of the main and adds a `with` to the main. When the main cannot be found, AdaMutant prints a warning and builds every mutant one at a time
- C's `getenv` is available (to read the environment variable). Recording the executed places also uses `getpid`, `fopen`, `fputs` and `fflush`
- The directory of the record is built into the generated code as an absolute path. When the test command runs test programs in another file system (a container with the project mounted somewhere else, for example), those processes cannot record. When only some of the processes cannot record, there is no warning. Set `coverage_analysis = false` for such a setup
- The test command runs the built executable as it is. `ADAMUTANT_MUTANT_ID` is the environment variable that has always been passed to the test command, and it has to reach the test program

### Code that no test executes

The tests cannot detect a mutant in a place that no test executes. AdaMutant skips the tests of such a mutant and sends it to the proof at once. If the proof passes too, it is Survived, with the `statusReason` `no test executes this code, and the proof passed`. The tests that are not run save time.

It works as follows. In the build that contains all the mutants, the function that switches the mutants records the number of the place that it is called from. It records only while no mutant is active (`ADAMUTANT_MUTANT_ID` is 0 or not set). Before it runs the mutants, AdaMutant runs the tests once with no mutant active. Each process of the test program then writes the numbers of the places that it executes to `.adamutant/logs/coverage/<process id>.txt`. The directory is built into the generated unit. The merged result stays in `.adamutant/logs/coverage.txt` (with `[tests]`, in `coverage-<name>.txt` for each test).

- This covers the mutants that are in the build that contains all the mutants, and StatementDeletion. A StatementDeletion mutant is not in that build, but the build records whether the statement is executed. The StatementDeletion of a statement that is not executed is built, skips the tests and goes to the proof
- Mutants that cannot be put together, such as those in declarations, are not covered by this, and their tests run as before
- When the test programs record nothing, AdaMutant prints a warning and runs every mutant (they cannot write to the directory, for example). A test program writes a first line when it starts, so executing no place is told apart from not being able to record
- The run that records has to execute everything that the runs of the mutants execute. In the following cases the tests of a mutant that they would detect are skipped, so set `coverage_analysis = false`
  - Tests whose path depends on random numbers or on the time
  - A test command that chooses the tests to run by `ADAMUTANT_MUTANT_ID` or `ADAMUTANT_MUTANT_FILE` (they are 0 and empty in the run that records)
- The console lists the lines that no test executes under `Lines that no test executes:`. The JSON report has `coveredBy` for each mutant (`["tests"]` when the place is executed, `[]` when it is not, absent when it was not examined; with `[tests]`, the names of the tests that execute the place)

There is one difference from building the mutants one at a time. The style checks are turned off in the sources that contain all the mutants, and the warnings that come from looking at the whole file (a variable is no longer used because a statement was deleted, for example) do not appear. So, in a project that treats warnings as errors (`-gnatwe`, `-gnaty`), a mutant that did not compile only because of a warning is now run instead of becoming CompileError.

### Equivalent mutants

No test can detect a mutant that behaves exactly like the original program (an equivalent mutant). When `equivalence_build` holds a command, AdaMutant builds each survivor with that command and compares the object files with those of the unchanged project. When all of them are the same, the mutant is the same program as the unchanged project, so it becomes Ignored (with the reason `equivalent mutant: ...`) and leaves the score. The mutants found to be equivalent are listed on the console under `Equivalent mutants`.

```toml
equivalence_build = "gprbuild -p -q -c -P tests.gpr -cargs -gnata -O2 -g0"
```

Make the command the `build` command with only the switches for optimization and debug information changed.

- Turn optimization on (`-O2`). Without it a difference such as `A > B` and `A >= B` stays in the machine code, and equivalent mutants do not come out the same
- Leave debug information out (`-g0`). It contains column positions and the like, so equivalent mutants do not come out the same
- Keep every other switch as in `build` (assertions on or off, suppressed checks, scenario variables and so on). The verdict is about the program that the compiler and the switches of this command produce
- Use a command that compiles every unit that depends on the mutated file again (gprbuild with the whole project does). A mutant of a constant in a specification, of a generic body or of a body that is inlined only shows in the objects of other units. A command that only compiles the mutated file cannot be used
- Compile only (`-c` for gprbuild). Binding and linking are not needed, and with a library project they can make AdaMutant miss equivalent mutants

A mutant that comes out "the same" is equivalent, but a mutant that comes out "different" is not necessarily non-equivalent: only those that the compiler reduces to the same code are found.

To avoid a wrong verdict, AdaMutant does the following.

- Before it builds the unchanged project with this command, it removes the object files and the ALI files in the sandbox. With the objects of `build` still there, gprbuild would not make them again although the switches differ (unless `-s` is given). Everything is compiled once more, which takes that much time
- All the files with the extension `.o` or `.obj` in the sandbox are compared. The files that the binder makes (`b__*.o`, `b~*.o`) differ for every mutant and are not compared
- For each file, it first builds one mutant that was detected (Killed) with the command and makes sure that the object files change. If the command does not compile the file, the object files do not change and every survivor would look equivalent. When they do not change (up to three mutants are tried), when there is no detected mutant, or when the build fails, it prints a warning and does not examine the survivors of that file
- After it has built a mutant, it reads the GNAT ALI files and makes sure that every unit that depends on the mutated file has been compiled again. A mutant for which this is not so is not taken to be equivalent
- After each mutant is compared, the object files are put back to those of the unchanged project
- Mutants of contracts (aspects and ghost code) are not examined. In a build without assertions they do not show in the objects, but they are other contracts all the same
- When the command fails on the unchanged project, or when reading or writing a file fails on the way, it prints a warning and gives up. The results so far stay

## Examples

- [examples/calculator](examples/calculator): tests that do not check the boundary values on purpose. You can see surviving mutants, a timeout, a line that no test executes, and equivalent mutants being recognized
- [examples/spark_counter](examples/spark_counter): the test checks only part of the behaviour, and the GNATprove proof detects the rest. The list of mutants that only the proof detects shows confirmed ones and ones where a contract says too little (the weak postcondition of `Halves.Half`)

```sh
cd examples/calculator && ../../bin/adamutant run
```

## License

Apache License 2.0
