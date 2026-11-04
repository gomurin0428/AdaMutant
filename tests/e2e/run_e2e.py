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
EXAMPLES = {
    "calculator": {
        "exit": 0, "min_timeout": 1,
        # A source that the build never compiles: its mutants are NoCoverage.
        "extra": {"src/unused.adb":
                  "function Unused (X : Integer) return Integer is\n"
                  "begin\n   return X + 1;\nend Unused;\n"},
        "output": "warning: src/unused.adb is not compiled by the build command",
    },
    "spark_counter": {"exit": 0, "killed_by": "proof"},
    # Every mutant's test first allocates 1 GiB, which only the memory limit
    # makes fail: without the limit some mutants would survive.
    "memory_limit": {
        "exit": 0, "example": "calculator",
        "config": "test_memory_limit_mb = 256\n"
                  "test = '{python} alloc_then_test.py'\n",
        "extra": {"alloc_then_test.py":
                  "import os, subprocess, sys\n"
                  "if os.environ.get('ADAMUTANT_MUTANT_ID', '0') != '0':\n"
                  "    bytearray(1 << 30)\n"
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
            (work / rel).write_text(text)
        if "config" in spec:
            python = (f'"{sys.executable}"' if " " in sys.executable
                      else sys.executable).replace("\\", "/")
            config = work / "adamutant.toml"
            lines = [line for line in config.read_text().splitlines(True)
                     if not line.startswith("test =")]
            config.write_text(spec["config"].format(python=python) + "".join(lines))
        before = {p: p.read_bytes() for p in work.rglob("*") if p.is_file()}
        proc = subprocess.run([str(EXE), "run"], cwd=work, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if proc.returncode != spec["exit"]:
            errors.append(f"exit status {proc.returncode}, expected {spec['exit']}\n{proc.stdout}")
        if spec.get("output", "") not in proc.stdout:
            errors.append(f"output lacks {spec['output']!r}\n{proc.stdout}")
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
        if sum(m["status"] == "Timeout" for m in mutants) < spec.get("min_timeout", 0):
            errors.append("expected a Timeout mutant")

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
    return subprocess.run(["pgrep", "-f", name],
                          stdout=subprocess.PIPE, text=True).stdout.split()


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
    leftovers = leftover_processes("test_calculator")
    if leftovers:
        print("FAIL leftover test processes: " + " ".join(leftovers))
        failed = True
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
