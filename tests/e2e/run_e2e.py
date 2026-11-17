#!/usr/bin/env python3
"""End-to-end tests: run bin/adamutant on the examples and compare statuses.

Each example is copied to a temporary directory first, so the checked-in
example stays untouched. Expected statuses live in tests/e2e/expected/.
Run with --update to rewrite them after a reviewed behaviour change.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXE = ROOT / "bin" / ("adamutant.exe" if os.name == "nt" else "adamutant")
EXPECTED = Path(__file__).resolve().parent / "expected"
# A unit that the test program contains, with a procedure that no test
# calls: the mutants in Reset are in code that the tests never execute.
SPARE = {
    "src/spare.ads":
        "package Spare is\n"
        "   Count : Integer := 0;\n"
        "   function Double (X : Integer) return Integer;\n"
        "   procedure Reset (X : out Integer);\n"
        "end Spare;\n",
    "src/spare.adb":
        "package body Spare is\n"
        "   function Double (X : Integer) return Integer is\n"
        "   begin\n"
        "      return X * 2;\n"
        "   end Double;\n"
        "   procedure Reset (X : out Integer) is\n"
        "   begin\n"
        "      Count := Count + 1;\n"
        "      X := 0;\n"
        "   end Reset;\n"
        "end Spare;\n",
    "tests/test_calculator.adb":
        "with Ada.Command_Line;\n"
        "with Calculator; use Calculator;\n"
        "with Spare;\n"
        "procedure Test_Calculator is\n"
        "begin\n"
        "   if Add (2, 3) /= 5 or else Spare.Double (4) /= 8 then\n"
        "      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);\n"
        "   end if;\n"
        "end Test_Calculator;\n",
}

EXAMPLES = {
    "calculator": {
        "exit": 0, "min_timeout": 1, "min_uncovered": 1,
        # Most mutants are tested in the one build that contains them all;
        # only a few are built on their own.
        "max_single_builds": 10,
        # A source that the build never compiles: its mutants are NoCoverage.
        "extra": {"src/unused.adb":
                  "function Unused (X : Integer) return Integer is\n"
                  "begin\n   return X + 1;\nend Unused;\n"},
        "output": "warning: src/unused.adb is not compiled by the build command",
    },
    "spark_counter": {"exit": 0, "killed_by": "proof"},
    # A mutant that does not compile ("X * 2" with a Float X) must not stop
    # the build that contains all mutants: it becomes a CompileError and the
    # others are tested.  The test here checks little, so the score is
    # below the example's break threshold (exit status 2).
    "compile_error": {
        "exit": 2, "example": "calculator", "max_single_builds": 12,
        "extra": {
            "src/powers.ads":
                "package Powers is\n"
                "   function Square (X : Float) return Float;\n"
                "end Powers;\n",
            "src/powers.adb":
                "package body Powers is\n"
                "   function Square (X : Float) return Float is\n"
                "   begin\n"
                "      return X ** 2;\n"
                "   end Square;\n"
                "end Powers;\n",
            "tests/test_calculator.adb":
                "with Ada.Command_Line;\n"
                "with Calculator; use Calculator;\n"
                "with Powers;\n"
                "procedure Test_Calculator is\n"
                "begin\n"
                "   if Add (2, 3) /= 5 or else Max (1, 7) /= 7\n"
                "     or else Max (9, 4) /= 9 or else not Is_Even (4)\n"
                "     or else Powers.Square (3.0) /= 9.0\n"
                "   then\n"
                "      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);\n"
                "   end if;\n"
                "end Test_Calculator;\n"},
    },
    # The mutants in code that no test executes are NoCoverage, and are
    # neither built nor tested: not even the deleted statements, which are
    # otherwise built one at a time.  Only the three initial values of
    # declarations, whose execution is not watched, are built.
    "coverage": {
        "exit": 2, "example": "calculator", "extra": SPARE,
        "min_uncovered": 5, "max_single_builds": 3,
        "output": "Lines that no test executes:",
    },
    # A pure package built with optimization: the statement that is only
    # watched (it has no mutant but its deletion) is executed by the test,
    # so its deletion is run, and detected.
    "coverage_pure": {
        "exit": 0, "example": "calculator",
        "expect": {"src/pure_pkg.adb:5:7 StatementDeletion null;": "Killed"},
        "extra": {
            "calculator_tests.gpr":
                "project Calculator_Tests is\n"
                "   for Source_Dirs use (\"src\", \"tests\");\n"
                "   for Object_Dir use \"obj\";\n"
                "   for Exec_Dir use \"bin\";\n"
                "   for Main use (\"test_calculator.adb\");\n"
                "   package Compiler is\n"
                "      for Default_Switches (\"Ada\") use (\"-gnat2022\", \"-gnata\", \"-O2\", \"-gnatn\");\n"
                "   end Compiler;\n"
                "end Calculator_Tests;\n",
            "src/pure_pkg.ads":
                "package Pure_Pkg with Pure is\n"
                "   procedure Copy (From : Integer; To : in out Integer);\n"
                "   function Next (X : Integer) return Integer;\n"
                "end Pure_Pkg;\n",
            "src/pure_pkg.adb":
                "package body Pure_Pkg is\n"
                "   procedure Copy (From : Integer; To : in out Integer) is\n"
                "   begin\n"
                "      --  Only its deletion can be mutated.\n"
                "      To := From;\n"
                "   end Copy;\n"
                "   function Next (X : Integer) return Integer is\n"
                "   begin\n"
                "      return X + 1;\n"
                "   end Next;\n"
                "end Pure_Pkg;\n",
            "tests/test_calculator.adb":
                "with Ada.Command_Line;\n"
                "with Calculator; use Calculator;\n"
                "with Pure_Pkg;\n"
                "procedure Test_Calculator is\n"
                "   Copied : Integer := 0;\n"
                "begin\n"
                "   Pure_Pkg.Copy (7, Copied);\n"
                "   if Add (2, 3) /= 5 or else Max (1, 7) /= 7\n"
                "     or else Max (9, 4) /= 9 or else not Is_Even (4)\n"
                "     or else Clamp (5, 0, 10) /= 5 or else Clamp (-5, 0, 10) /= 0\n"
                "     or else Clamp (50, 0, 10) /= 10 or else Grade (95) /= \"A\"\n"
                "     or else Grade (70) /= \"B\" or else Grade (10) /= \"C\"\n"
                "     or else Sum_To (4) /= 10 or else Copied /= 7\n"
                "     or else Pure_Pkg.Next (1) /= 2\n"
                "   then\n"
                "      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);\n"
                "   end if;\n"
                "end Test_Calculator;\n"},
    },
    # Without coverage analysis the same mutants are run, and survive.
    "coverage_off": {
        "exit": 2, "example": "calculator", "extra": SPARE,
        "config": "coverage_analysis = false\n", "max_uncovered": 0,
    },
    # Test programs that cannot write their record (here its directory is
    # gone) record nothing: every mutant is run, as without coverage
    # analysis.
    "coverage_lost": {
        "exit": 2, "example": "calculator", "max_uncovered": 0,
        "config": "test = '{python} no_coverage_dir.py'\n",
        "extra": dict(SPARE, **{"no_coverage_dir.py":
                  "import os, shutil, subprocess, sys\n"
                  "shutil.rmtree(os.path.join('..', '..', 'logs', 'coverage'),\n"
                  "              ignore_errors=True)\n"
                  "sys.exit(subprocess.call([os.path.join('bin', 'test_calculator')]))\n"}),
        "output": "warning: the test programs recorded nothing",
    },
    # Tests that execute none of the watched code are not a lost record:
    # the mutants there are NoCoverage, without a warning.
    "coverage_none": {
        "exit": 2, "example": "calculator", "min_uncovered": 30,
        "not_output": "warning: the test programs recorded nothing",
        "extra": {"tests/test_calculator.adb":
                  "with Calculator;\n"
                  "procedure Test_Calculator is\n"
                  "begin\n"
                  "   null;\n"
                  "end Test_Calculator;\n"},
    },
    # A statement that is only watched, on a line with a compiler warning,
    # in a build that fails because of a mutant elsewhere: the statement is
    # no longer watched, and its file, which then has nothing left in the
    # combined build, gets its original source back.  (Left as it was, it
    # would make every later build fail to link.)
    "unwatched": {
        "exit": 0, "example": "calculator", "no_reason": "undefined reference",
        "extra": {
            "calculator_tests.gpr":
                "project Calculator_Tests is\n"
                "   for Source_Dirs use (\"src\", \"tests\");\n"
                "   for Object_Dir use \"obj\";\n"
                "   for Exec_Dir use \"bin\";\n"
                "   for Main use (\"test_calculator.adb\");\n"
                "   package Compiler is\n"
                "      for Default_Switches (\"Ada\") use (\"-gnat2022\", \"-gnata\", \"-gnatwa\");\n"
                "   end Compiler;\n"
                "end Calculator_Tests;\n",
            "src/powers.ads":
                "package Powers is\n"
                "   function Square (X : Float) return Float;\n"
                "end Powers;\n",
            "src/powers.adb":
                "package body Powers is\n"
                "   function Square (X : Float) return Float is\n"
                "   begin\n"
                "      return X ** 2;\n"
                "   end Square;\n"
                "end Powers;\n",
            "src/b_spare.ads":
                "package B_Spare is\n"
                "   Count : Integer;\n"
                "   procedure Touch;\n"
                "end B_Spare;\n",
            "src/b_spare.adb":
                "package body B_Spare is\n"
                "   procedure Touch is\n"
                "   begin\n"
                "      Count := Count;\n"
                "   end Touch;\n"
                "end B_Spare;\n",
            "tests/test_calculator.adb":
                "with Ada.Command_Line;\n"
                "with B_Spare;\n"
                "with Calculator; use Calculator;\n"
                "with Powers;\n"
                "procedure Test_Calculator is\n"
                "begin\n"
                "   B_Spare.Touch;\n"
                "   if Add (2, 3) /= 5 or else Max (1, 7) /= 7\n"
                "     or else Max (9, 4) /= 9 or else not Is_Even (4)\n"
                "     or else Clamp (5, 0, 10) /= 5 or else Clamp (-5, 0, 10) /= 0\n"
                "     or else Clamp (50, 0, 10) /= 10 or else Grade (95) /= \"A\"\n"
                "     or else Grade (70) /= \"B\" or else Grade (10) /= \"C\"\n"
                "     or else Sum_To (4) /= 10 or else Powers.Square (3.0) /= 9.0\n"
                "   then\n"
                "      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);\n"
                "   end if;\n"
                "end Test_Calculator;\n"},
    },
    # Tests and proof together: a mutant in code that no test executes
    # skips the tests and goes to the proof.  The deleted statement of
    # Copy, which is built on its own, is still built before it is proved.
    "prove_and_test": {
        "exit": 0, "example": "spark_counter", "killed_by": "proof",
        "min_uncovered": 1,
        "uncovered_built": "src/copies.adb:5:7 StatementDeletion null;",
        "config": "build = 'gprbuild -p -q -P counters_tests.gpr'\n"
                  "test = '\"bin/test_counters\"'\n"
                  "sandbox_exclude = ['.git', 'obj', 'bin']\n",
        "extra": {
            "counters_tests.gpr":
                "project Counters_Tests is\n"
                "   for Source_Dirs use (\"src\", \"tests\");\n"
                "   for Object_Dir use \"obj\";\n"
                "   for Exec_Dir use \"bin\";\n"
                "   for Main use (\"test_counters.adb\");\n"
                "   package Compiler is\n"
                "      for Default_Switches (\"Ada\") use (\"-gnat2022\");\n"
                "   end Compiler;\n"
                "end Counters_Tests;\n",
            "src/copies.ads":
                "package Copies with SPARK_Mode is\n"
                "   procedure Copy (From : Integer; To : in out Integer)\n"
                "   with Post => To = From;\n"
                "end Copies;\n",
            "src/copies.adb":
                "package body Copies with SPARK_Mode is\n"
                "   procedure Copy (From : Integer; To : in out Integer) is\n"
                "   begin\n"
                "      --  Only its deletion can be mutated.\n"
                "      To := From;\n"
                "   end Copy;\n"
                "end Copies;\n",
            "tests/test_counters.adb":
                "with Ada.Command_Line;\n"
                "with Copies;\n"
                "pragma Unreferenced (Copies);\n"
                "with Counters;\n"
                "procedure Test_Counters is\n"
                "begin\n"
                "   if Counters.Increment (4) not in 5 then\n"
                "      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);\n"
                "   end if;\n"
                "end Test_Counters;\n"},
    },
    # Every mutant's test first allocates 1 GiB, which only the memory limit
    # makes fail: without the limit some mutants would survive.  The test
    # keeps the allocation while it runs, so that macOS, where AdaMutant
    # samples the memory instead of capping it, sees it too.
    "memory_limit": {
        "exit": 0, "example": "calculator",
        "config": "test_memory_limit_mb = 256\n"
                  "test = '{python} alloc_then_test.py'\n",
        "extra": {"alloc_then_test.py":
                  "import os, subprocess, sys\n"
                  "if os.environ.get('ADAMUTANT_MUTANT_ID', '0') != '0':\n"
                  "    held = bytearray(1 << 30)\n"
                  "sys.exit(subprocess.call([os.path.join('bin', 'test_calculator')]))\n"},
    },
    # The test takes one second per test running at the same time, so with
    # a baseline measured alone the parallel mutant runs would time out.
    "concurrent_baseline": {
        "exit": 0, "example": "calculator", "min_timeout": 1,
        "config": "timeout_ms = 0\n"
                  "test = '{python} contended_test.py'\n",
        "extra": {"contended_test.py":
                  "import os, subprocess, sys, time\n"
                  "d = os.path.join('..', 'running')\n"
                  "os.makedirs(d, exist_ok=True)\n"
                  "me = os.path.join(d, str(os.getpid()))\n"
                  "open(me, 'w').close()\n"
                  "time.sleep(0.5)\n"
                  "time.sleep(len(os.listdir(d)))\n"
                  "os.remove(me)\n"
                  "sys.exit(subprocess.call([os.path.join('bin', 'test_calculator')]))\n"},
    },
}


def key(path, m):
    s = m["location"]["start"]
    return f"{path}:{s['line']}:{s['column']} {m['mutatorName']} {m['replacement']}"


def statuses(report):
    return {key(p, m): m["status"]
            for p, f in report["files"].items() for m in f["mutants"]}


def run_example(name, spec, update):
    errors = []
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp) / name
        shutil.copytree(ROOT / "examples" / spec.get("example", name), work,
                        ignore=shutil.ignore_patterns(".adamutant", "obj", "bin", "lib"))
        for rel, text in spec.get("extra", {}).items():
            (work / rel).parent.mkdir(parents=True, exist_ok=True)
            (work / rel).write_text(text)
        if "config" in spec:
            python = (f'"{sys.executable}"' if " " in sys.executable
                      else sys.executable).replace("\\", "/")
            config = work / "adamutant.toml"
            keys = {line.split("=")[0].strip()
                    for line in spec["config"].splitlines()}
            lines = [line for line in config.read_text().splitlines(True)
                     if line.split("=")[0].strip() not in keys]
            config.write_text(spec["config"].format(python=python) + "".join(lines))
        before = {p: p.read_bytes() for p in work.rglob("*") if p.is_file()}
        proc = subprocess.run([str(EXE), "run"], cwd=work, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if proc.returncode != spec["exit"]:
            errors.append(f"exit status {proc.returncode}, expected {spec['exit']}\n{proc.stdout}")
        if spec.get("output", "") not in proc.stdout:
            errors.append(f"output lacks {spec['output']!r}\n{proc.stdout}")
        if "not_output" in spec and spec["not_output"] in proc.stdout:
            errors.append(f"output has {spec['not_output']!r}\n{proc.stdout}")
        for p, data in before.items():
            if p.read_bytes() != data:
                errors.append(f"{p.relative_to(work)} was modified by the run")
        if (work / ".adamutant" / "sandbox").exists():
            errors.append("sandbox directory was not removed")
        report_path = work / ".adamutant" / "reports" / "mutation-report.json"
        if not report_path.exists():
            return errors + ["no JSON report"]
        report = json.loads(report_path.read_text(encoding="utf-8"))
        if not (work / ".adamutant" / "reports" / "mutation-report.html").exists():
            errors.append("no HTML report")
        if report.get("schemaVersion") != "2":
            errors.append("schemaVersion is not 2")
        actual = statuses(report)
        mutants = [m for f in report["files"].values() for m in f["mutants"]]
        if "killed_by" in spec and not any(
                spec["killed_by"] in m.get("killedBy", []) for m in mutants):
            errors.append(f"no mutant killed by {spec['killed_by']}")
        # Mutants in code that the tests do not execute are not run.
        logs = work / ".adamutant" / "logs"
        uncovered = [m for m in mutants if m.get("coveredBy") == []]
        for m in uncovered:
            if (logs / f"mutant-{m['id']}-test.log").exists():
                errors.append(f"mutant {m['id']} is not covered, but has a test log")
            for step in ("build", "prove"):
                if m["status"] == "NoCoverage" and (logs / f"mutant-{m['id']}-{step}.log").exists():
                    errors.append(f"mutant {m['id']} is NoCoverage, but has a {step} log")
        if "uncovered_built" in spec:
            found = [m for p, f in report["files"].items() for m in f["mutants"]
                     if key(p, m) == spec["uncovered_built"]]
            if len(found) != 1 or found[0].get("coveredBy") != [] \
                    or not (logs / f"mutant-{found[0]['id']}-build.log").exists() \
                    or not (logs / f"mutant-{found[0]['id']}-prove.log").exists():
                errors.append(f"{spec['uncovered_built']}: expected an uncovered mutant "
                              f"with a build log and a prove log, got {found}")
        for m in mutants:
            if "no_reason" in spec and spec["no_reason"] in m.get("statusReason", ""):
                errors.append(f"mutant {m['id']}: {m['statusReason']}")
            if "no_reason" in spec and (logs / f"mutant-{m['id']}-build.log").exists() \
                    and spec["no_reason"] in (logs / f"mutant-{m['id']}-build.log").read_text():
                errors.append(f"mutant {m['id']}: {spec['no_reason']} in its build log")
        if len(uncovered) < spec.get("min_uncovered", 0):
            errors.append(f"{len(uncovered)} mutants without coverage, "
                          f"expected at least {spec['min_uncovered']}")
        if len(uncovered) > spec.get("max_uncovered", len(uncovered)):
            errors.append(f"{len(uncovered)} mutants without coverage, "
                          f"expected at most {spec['max_uncovered']}")
        if sum(m["status"] == "Timeout" for m in mutants) < spec.get("min_timeout", 0):
            errors.append("expected a Timeout mutant")
        if "max_single_builds" in spec:
            if not (logs / "combined-build.log").exists():
                errors.append("no build that contains the mutants")
            single = len(list(logs.glob("mutant-*-build.log")))
            if single > spec["max_single_builds"]:
                errors.append(f"{single} mutants were built on their own, "
                              f"expected at most {spec['max_single_builds']}")

        for k, want in spec.get("expect", {}).items():
            if actual.get(k) != want:
                errors.append(f"{k}: expected {want}, got {actual.get(k)}")
        expected_file = EXPECTED / f"{name}.json"
        if update:
            EXPECTED.mkdir(exist_ok=True)
            expected_file.write_text(json.dumps(actual, indent=1, sort_keys=True) + "\n")
        else:
            expected = json.loads(expected_file.read_text())
            for k in sorted(set(expected) | set(actual)):
                if expected.get(k) != actual.get(k):
                    errors.append(f"{k}: expected {expected.get(k)}, got {actual.get(k)}")
    return errors


def leftover_processes(name):
    if os.name == "nt":
        out = subprocess.run(["tasklist", "/FI", f"IMAGENAME eq {name}.exe", "/FO", "CSV", "/NH"],
                             stdout=subprocess.PIPE, text=True).stdout
        return [line.split(",")[1].strip('"') for line in out.splitlines()
                if line.lower().startswith(f'"{name}.exe"')]
    pids = subprocess.run(["pgrep", "-f", name],
                          stdout=subprocess.PIPE, text=True).stdout.split()
    # A process that has ended and that its parent has not waited for yet
    # (state Z) is not running any more.
    return [pid for pid in pids
            if not subprocess.run(["ps", "-o", "stat=", "-p", pid],
                                  stdout=subprocess.PIPE, text=True)
            .stdout.strip().startswith("Z")
            and subprocess.run(["ps", "-p", pid], stdout=subprocess.DEVNULL)
            .returncode == 0]


def git(work, *args):
    subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t",
                    "-c", "commit.gpgsign=false", *args],
                   cwd=work, check=True, capture_output=True)


def edit_line(path, old, new):
    path.write_text(path.read_text().replace(old, new, 1))


def check_since():
    """--since REF mutates only lines changed since the merge base."""
    work = Path(tempfile.mkdtemp(prefix="adamutant-since-"))
    try:
        shutil.copytree(ROOT / "examples" / "calculator", work / "p",
                        ignore=shutil.ignore_patterns("obj", "bin", ".adamutant"))
        work = work / "p"
        src = work / "src" / "calculator.adb"
        git(work, "init", "-q", "-b", "main")
        git(work, "add", "-A")
        git(work, "commit", "-q", "-m", "base")
        git(work, "checkout", "-q", "-b", "feature")
        edit_line(src, "return A + B;", "return B + A;")
        git(work, "commit", "-q", "-am", "feature")
        git(work, "checkout", "-q", "main")
        edit_line(src, "if A > B then", "if B < A then")
        git(work, "commit", "-q", "-am", "main moves on")
        git(work, "checkout", "-q", "feature")
        edit_line(src, "if X < Low then", "if Low > X then")
        (work / "src" / "extra.adb").write_text(
            "procedure Extra is\n   X : Integer := 0;\nbegin\n   X := X + 1;\nend Extra;\n")
        (work / ".gitignore").write_text(".adamutant/\nobj/\nbin/\n")

        proc = subprocess.run([str(EXE), "list", "--since", "main"], cwd=work,
                              text=True, capture_output=True)
        if proc.returncode != 0:
            return [f"list --since failed: {proc.stdout}{proc.stderr}"]
        pending = sorted({line.split()[1].rsplit(":", 1)[0]
                          for line in proc.stdout.splitlines()
                          if line.startswith("#") and "(ignored)" not in line})
        errors = []
        lines = src.read_text().splitlines()
        expected = sorted({f"src/calculator.adb:{n + 1}"
                           for n, text in enumerate(lines)
                           if "B + A" in text or "Low > X" in text})
        if [p for p in pending if p.startswith("src/calculator")] != expected:
            errors.append(f"pending lines {pending}, expected {expected}")
        if "src/extra.adb:4" not in pending:
            errors.append(f"untracked file not mutated: {pending}")
        if "src/calculator.ads" in proc.stdout:
            errors.append("an unchanged file was scanned")
        run = subprocess.run([str(EXE), "run", "--since", "main"], cwd=work,
                             text=True, capture_output=True)
        report = work / ".adamutant" / "reports" / "mutation-report.json"
        if not report.exists():
            errors.append(f"run --since wrote no report: {run.stdout}{run.stderr}")
        else:
            got = statuses(json.loads(report.read_text()))
            ran = sorted({k.split()[0].rsplit(":", 1)[0] for k, v in got.items()
                          if v != "Ignored"})
            if ran != pending:
                errors.append(f"run --since ran {ran}, expected {pending}")
            if "Pending" in got.values():
                errors.append("run --since left pending mutants")
        bad = subprocess.run([str(EXE), "list", "--since", "no-such-ref"],
                             cwd=work, text=True, capture_output=True)
        if bad.returncode != 1 or "--since" not in bad.stderr:
            errors.append(f"bad ref: exit {bad.returncode}, {bad.stderr}")
        return errors
    finally:
        shutil.rmtree(work.parent, ignore_errors=True)


def main():
    update = "--update" in sys.argv
    if not EXE.exists():
        sys.exit(f"{EXE} not found; run 'make build' first")
    failed = False
    for name, spec in EXAMPLES.items():
        errors = run_example(name, spec, update)
        print(("FAIL " if errors else "ok   ") + name)
        for e in errors:
            print("  " + e)
        failed = failed or bool(errors)
    errors = check_since()
    print(("FAIL " if errors else "ok   ") + "since")
    for e in errors:
        print("  " + e)
    failed = failed or bool(errors)
    leftovers = leftover_processes("test_calculator")
    if leftovers:
        print("FAIL leftover test processes: " + " ".join(leftovers))
        failed = True
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
