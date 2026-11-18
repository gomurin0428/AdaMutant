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

# Three test programs instead of one.  Test_Arith and Test_Misc check
# different functions; Test_Idle calls Add and checks nothing.
NAMED_TESTS = {
    "calculator_tests.gpr":
        "project Calculator_Tests is\n"
        "   for Source_Dirs use (\"src\", \"tests\");\n"
        "   for Object_Dir use \"obj\";\n"
        "   for Exec_Dir use \"bin\";\n"
        "   for Main use (\"test_arith.adb\", \"test_misc.adb\", \"test_idle.adb\");\n"
        "   package Compiler is\n"
        "      for Default_Switches (\"Ada\") use (\"-gnat2022\", \"-gnata\");\n"
        "   end Compiler;\n"
        "end Calculator_Tests;\n",
    "tests/test_arith.adb":
        "with Ada.Command_Line;\n"
        "with Calculator; use Calculator;\n"
        "procedure Test_Arith is\n"
        "begin\n"
        "   if Add (2, 3) /= 5 or else Max (1, 7) /= 7 or else Max (9, 4) /= 9 then\n"
        "      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);\n"
        "   end if;\n"
        "end Test_Arith;\n",
    "tests/test_misc.adb":
        "with Ada.Command_Line;\n"
        "with Calculator; use Calculator;\n"
        "procedure Test_Misc is\n"
        "begin\n"
        "   if Clamp (-5, 0, 10) /= 0 or else Clamp (50, 0, 10) /= 10\n"
        "     or else not Is_Even (4) or else Grade (95) /= \"A\"\n"
        "     or else Sum_To (4) /= 10 or else Max (2, 1) /= 2\n"
        "   then\n"
        "      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);\n"
        "   end if;\n"
        "end Test_Misc;\n",
    "tests/test_idle.adb":
        "with Calculator; use Calculator;\n"
        "procedure Test_Idle is\n"
        "   Sum : constant Integer := Add (2, 3);\n"
        "   pragma Unreferenced (Sum);\n"
        "begin\n"
        "   null;\n"
        "end Test_Idle;\n",
}
NAMED_TESTS_TABLE = ("\n[tests]\n"
                     "arith = '\"bin/test_arith\"'\n"
                     "misc = '\"bin/test_misc\"'\n"
                     "idle = '\"bin/test_idle\"'\n")

EXAMPLES = {
    # The example has an equivalence_build command: the two survivors that
    # are equivalent mutants become Ignored.
    "calculator": {
        "exit": 0, "min_timeout": 1, "min_uncovered": 1, "equivalent": 2,
        # Most mutants are tested in the one build that contains them all;
        # only a few are built on their own.
        "max_single_builds": 10,
        # A source that the build never compiles: its mutants are NoCoverage.
        "extra": {"src/unused.adb":
                  "function Unused (X : Integer) return Integer is\n"
                  "begin\n   return X + 1;\nend Unused;\n"},
        "output": "warning: src/unused.adb is not compiled by the build command",
    },
    # The report says which checks the proof failed on.
    "spark_counter": {"exit": 0, "killed_by": "proof",
                      "proof_checks": ["postcondition", "range check"],
                      "output": "Mutants killed by the proof, by the check that fails"},
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
    # A [tests] table: the report names the tests that execute and detect
    # each mutant, and a mutant is only tested with the tests that execute
    # its code.  The first test that detects a mutant ends its run.
    "named_tests": {
        "exit": 0, "example": "calculator", "extra": NAMED_TESTS,
        "remove": ["tests/test_calculator.adb"], "drop_keys": ["test"],
        "config_tail": NAMED_TESTS_TABLE,
        "tests": {"arith": {"kills": True}, "misc": {"kills": True},
                  "idle": {"kills": False}},
        "bail": True,
        "output": "A mutant counts for the first test that detects it",
    },
    # bail = false: every test that executes a mutant runs, so a mutant
    # that two tests detect names both, and the tests that detect nothing
    # are listed.
    "named_tests_all": {
        "exit": 0, "example": "calculator", "extra": NAMED_TESTS,
        "remove": ["tests/test_calculator.adb"], "drop_keys": ["test"],
        "config": "bail = false\n", "config_tail": NAMED_TESTS_TABLE,
        "tests": {"arith": {"kills": True}, "misc": {"kills": True},
                  "idle": {"kills": False}},
        "bail": False,
        "output": "Tests that detect no mutant: idle",
    },
    # Survivors in three files.  Two are equivalent mutants like those of
    # the example (in More); one is not, and shows only in the object of
    # another unit: the named number of B_Limits is used in Client.  The
    # command of the example compiles Client again and finds it different.
    # The object of B_Limits is compared although its name starts like
    # that of a file of the binder ("b__main.o"): the survivors of its
    # expression function are not equivalent.
    "equivalence_dependent": {
        "exit": 0, "example": "calculator", "equivalent": 3,
        "expect": {"src/b_limits.ads:2:24 NumericLiteral 4": "Survived"},
        "extra": "DEPENDENT",
    },
    # The same with an equivalence_build command that only compiles the
    # mutated file, which is not a command to use: it does not compile
    # Client again, so nothing can be said about the mutant of B_Limits, and
    # it does not bring the objects of the mutant before back to those of
    # the unmodified project, so AdaMutant has to (otherwise the equivalent
    # mutants of one file look different because of the other file).
    "equivalence_selective": {
        "exit": 0, "example": "calculator", "equivalent": 3,
        "expect": {"src/b_limits.ads:2:24 NumericLiteral 4": "Survived"},
        "config": "equivalence_build = '{python} compile_one.py'\n",
        "output": "does not compile every unit that depends on the file again",
        "extra": "DEPENDENT",
    },
    # An equivalence_build command that removes the objects and then fails
    # for every mutant: nothing is examined, and the results of the run
    # stay.
    "equivalence_breaks": {
        "exit": 0, "example": "calculator", "equivalent": 0,
        "config": "equivalence_build = '{python} clean_and_fail.py'\n",
        "output": "warning: the equivalence_build command fails for detected mutants",
        "extra": {"clean_and_fail.py":
                  "import os, shutil, subprocess, sys\n"
                  "if os.environ.get('ADAMUTANT_MUTANT_ID', '0') != '0':\n"
                  "    shutil.rmtree('obj')\n"
                  "    sys.exit(4)\n"
                  "sys.exit(subprocess.call(['gprbuild', '-p', '-q', '-c', '-P',\n"
                  "                          'calculator_tests.gpr', '-cargs', '-O2', '-g0']))\n"},
    },
    # An equivalence_build command that binds and links as well: what the
    # binder makes differs for every mutant and is not compared.
    "equivalence_linked": {
        "exit": 0, "example": "calculator", "equivalent": 2,
        "config": "equivalence_build = 'gprbuild -p -q -P calculator_tests.gpr"
                  " -cargs -O2 -g0'\n",
    },
    # Mutants of contracts that survive the proof are other contracts, not
    # equivalent mutants, although the objects are the same without
    # assertions.  So are the mutants of the call of Note, which only the
    # specification declares ghost.
    "equivalence_contracts": {
        "exit": 0, "example": "spark_counter", "equivalent": 0,
        "min_survived": 5,
        "expect": {"src/counters.adb:5:7 StatementDeletion null;": "Survived"},
        "config": "mutate = ['src/**/*.adb', 'src/**/*.ads']\n"
                  "mutate_contracts = true\n"
                  "equivalence_build = 'gprbuild -p -q -c -P counters.gpr -cargs -O2 -g0'\n",
        "extra": {
            "src/counters.ads":
                "package Counters with SPARK_Mode is\n"
                "   Max : constant := 100;\n"
                "   subtype Count is Natural range 0 .. Max;\n"
                "   procedure Note (C : Count) is null with Ghost;\n"
                "   function Increment (C : Count) return Count\n"
                "   with Pre  => C < Max,\n"
                "        Post => Increment'Result = C + 1;\n"
                "   function Saturating_Add (A, B : Count) return Count\n"
                "   with Post =>\n"
                "     (if A + B <= Max then Saturating_Add'Result = A + B\n"
                "      else Saturating_Add'Result = Max);\n"
                "end Counters;\n",
            "src/counters.adb":
                "package body Counters with SPARK_Mode is\n"
                "   function Increment (C : Count) return Count is\n"
                "   begin\n"
                "      --  Ghost code: it is not in the program.\n"
                "      Note (C + 0);\n"
                "      return C + 1;\n"
                "   end Increment;\n"
                "   function Saturating_Add (A, B : Count) return Count is\n"
                "   begin\n"
                "      if A + B > Max then\n"
                "         return Max;\n"
                "      else\n"
                "         return A + B;\n"
                "      end if;\n"
                "   end Saturating_Add;\n"
                "end Counters;\n"},
    },
}

DEPENDENT = {
            "compile_one.py":
                "import os, subprocess, sys\n"
                "one = os.environ.get('ADAMUTANT_MUTANT_FILE', '')\n"
                "command = ['gprbuild', '-p', '-q', '-c', '-P', 'calculator_tests.gpr']\n"
                "if one:\n"
                "    command += ['-u', os.path.basename(one)]\n"
                "sys.exit(subprocess.call(command + ['-cargs', '-O2', '-g0']))\n",
            "src/b_limits.ads":
                "package B_Limits is\n"
                "   Small : constant := 3;\n"
                "   function Is_Big (X : Integer) return Boolean is (X > 100);\n"
                "end B_Limits;\n",
            "src/client.ads":
                "package Client is\n"
                "   function Tiny (X : Integer) return Boolean;\n"
                "end Client;\n",
            "src/client.adb":
                "with B_Limits;\n"
                "package body Client is\n"
                "   function Tiny (X : Integer) return Boolean is\n"
                "   begin\n"
                "      return X < B_Limits.Small;\n"
                "   end Tiny;\n"
                "end Client;\n",
            "src/more.ads":
                "package More is\n"
                "   function Larger (A, B : Integer) return Integer;\n"
                "end More;\n",
            "src/more.adb":
                "package body More is\n"
                "   function Larger (A, B : Integer) return Integer is\n"
                "   begin\n"
                "      if A > B then\n"
                "         return A;\n"
                "      else\n"
                "         return B;\n"
                "      end if;\n"
                "   end Larger;\n"
                "end More;\n",
            "tests/test_calculator.adb":
                "with Ada.Command_Line;\n"
                "with Calculator; use Calculator;\n"
                "with Client;\n"
                "with B_Limits;\n"
                "with More;\n"
                "procedure Test_Calculator is\n"
                "begin\n"
                "   if Add (2, 3) /= 5 or else Max (1, 7) /= 7\n"
                "     or else Max (9, 4) /= 9 or else not Is_Even (4)\n"
                "     or else Clamp (5, 0, 10) /= 5 or else Clamp (-5, 0, 10) /= 0\n"
                "     or else Clamp (50, 0, 10) /= 10 or else Grade (95) /= \"A\"\n"
                "     or else Grade (70) /= \"B\" or else Grade (10) /= \"C\"\n"
                "     or else Sum_To (4) /= 10\n"
                "     or else More.Larger (1, 7) /= 7 or else More.Larger (9, 4) /= 9\n"
                "     or else not Client.Tiny (1) or else Client.Tiny (5)\n"
                "     or else not B_Limits.Is_Big (200) or else B_Limits.Is_Big (50)\n"
                "   then\n"
                "      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);\n"
                "   end if;\n"
                "end Test_Calculator;\n"}

EXAMPLES.update({
    # A test that runs no program of the build records nothing.  What it
    # executes is not known, so no test is left out for any mutant: there
    # is a warning, and no mutant has coveredBy.
    "named_tests_silent": {
        "exit": 0, "example": "calculator", "extra": NAMED_TESTS,
        "remove": ["tests/test_calculator.adb"], "drop_keys": ["test"],
        "config_tail": NAMED_TESTS_TABLE + "lint = '{python} -c \"pass\"'\n",
        "tests": {"arith": {"kills": True}, "misc": {"kills": True},
                  "idle": {"kills": False}, "lint": {"kills": False}},
        "bail": True, "covered_by": False,
        "output": "warning: the programs of the tests 'lint' recorded nothing",
    },
    # An equivalence_build command that fails: a warning, and the survivors
    # stay.
    "equivalence_fails": {
        "exit": 0, "example": "calculator", "equivalent": 0,
        "config": "equivalence_build = '{python} -c \"import sys; sys.exit(3)\"'\n",
        "output": "warning: the equivalence_build command fails (exit status 3)",
    },
    # An equivalence_build command that compiles nothing: the object files
    # of the normal build are not taken for its own, so there is nothing to
    # compare.
    "equivalence_noop": {
        "exit": 0, "example": "calculator", "equivalent": 0,
        "config": "equivalence_build = '{python} -c \"pass\"'\n",
        "output": "warning: the equivalence_build command leaves no object file",
    },
    # An equivalence_build command that compiles something, but not the
    # mutated files: the object files never change.  That must not make
    # every survivor an equivalent mutant.
    "equivalence_other": {
        "exit": 0, "example": "calculator", "equivalent": 0,
        "config": "equivalence_build = 'gprbuild -p -q -c -u -P calculator_tests.gpr"
                  " test_calculator.adb -cargs -O2 -g0'\n",
        "output": "warning: the equivalence_build command does not compile every unit"
                  " that depends on the file again for detected mutants of src/calculator.adb",
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
})


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
        for rel in spec.get("remove", []):
            (work / rel).unlink()
        extra = spec.get("extra", {})
        if isinstance(extra, str):
            extra = globals()[extra]
        for rel, text in extra.items():
            (work / rel).parent.mkdir(parents=True, exist_ok=True)
            (work / rel).write_text(text)
        if "config" in spec or "config_tail" in spec or "drop_keys" in spec:
            python = (f'"{sys.executable}"' if " " in sys.executable
                      else sys.executable).replace("\\", "/")
            config = work / "adamutant.toml"
            head = spec.get("config", "")
            keys = {line.split("=")[0].strip() for line in head.splitlines()}
            keys |= set(spec.get("drop_keys", []))
            lines = [line for line in config.read_text().splitlines(True)
                     if line.split("=")[0].strip() not in keys]
            config.write_text(head.format(python=python) + "".join(lines)
                              + spec.get("config_tail", "").format(python=python))
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
        killers = {k for m in mutants for k in m.get("killedBy", [])}
        if "killed_by" in spec and not any(
                k.split(":")[0] == spec["killed_by"] for k in killers):
            errors.append(f"no mutant killed by {spec['killed_by']}")
        for check in spec.get("proof_checks", []):
            if f"proof: {check}" not in killers:
                errors.append(f"no mutant killed by the proof of a {check}: {sorted(killers)}")
        # Mutants in code that the tests do not execute are not run.
        logs = work / ".adamutant" / "logs"
        uncovered = [m for m in mutants if m.get("coveredBy") == []]
        for m in uncovered:
            if any(logs.glob(f"mutant-{m['id']}-test*.log")):
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
        if not spec.get("covered_by", True) and any("coveredBy" in m for m in mutants):
            errors.append("a mutant has coveredBy although the record is incomplete")
        if "tests" in spec:
            names = [t["id"] for f in report.get("testFiles", {}).values()
                     for t in f["tests"]]
            if names != list(spec["tests"]):
                errors.append(f"testFiles has {names}, expected {list(spec['tests'])}")
            for test, want in spec["tests"].items():
                kills = sum(test in m.get("killedBy", []) for m in mutants)
                if (kills > 0) != want["kills"]:
                    errors.append(f"test {test} detects {kills} mutants")
            for m in mutants:
                covered = m.get("coveredBy")
                if covered is None:
                    continue
                if not set(m.get("killedBy", [])) <= set(covered):
                    errors.append(f"mutant {m['id']}: killed by {m['killedBy']}, covered by {covered}")
                # Only the tests that execute the mutant have a log.
                ran = sorted(p.name[len(f"mutant-{m['id']}-test-"):-len(".log")]
                             for p in logs.glob(f"mutant-{m['id']}-test-*.log"))
                if not set(ran) <= set(covered):
                    errors.append(f"mutant {m['id']}: ran {ran}, covered by {covered}")
                if m.get("testsCompleted", 0) != len(ran):
                    errors.append(f"mutant {m['id']}: testsCompleted {m.get('testsCompleted')}, logs {ran}")
                if spec["bail"] and len(m.get("killedBy", [])) > 1:
                    errors.append(f"mutant {m['id']}: killed by {m['killedBy']} with bail")
                if not spec["bail"] and m["status"] != "NoCoverage" and ran != sorted(covered):
                    errors.append(f"mutant {m['id']}: ran {ran} without bail, covered by {covered}")
            if not spec["bail"] and not any(len(m.get("killedBy", [])) > 1 for m in mutants):
                errors.append("no mutant is detected by two tests")
        equivalent = sum(m.get("statusReason", "").startswith("equivalent mutant")
                         and m["status"] == "Ignored" for m in mutants)
        if equivalent != spec.get("equivalent", equivalent):
            errors.append(f"{equivalent} equivalent mutants, expected {spec['equivalent']}")
        survived = sum(m["status"] == "Survived" for m in mutants)
        if survived < spec.get("min_survived", 0):
            errors.append(f"{survived} survivors, expected at least {spec['min_survived']}")
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
    # The directory to remove afterwards: "work" becomes the project in it.
    root = Path(tempfile.mkdtemp(prefix="adamutant-since-"))
    work = root
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
        shutil.rmtree(root, ignore_errors=True)


def check_proof_log():
    """What the report says about a proof depends on the log of the prover."""
    # The directory to remove afterwards: "work" becomes the project in it.
    root = Path(tempfile.mkdtemp(prefix="adamutant-proof-"))
    work = root
    try:
        shutil.copytree(ROOT / "examples" / "spark_counter", work / "p",
                        ignore=shutil.ignore_patterns("obj", "bin", ".adamutant"))
        work = work / "p"
        # A prover whose output is known for each mutant.
        (work / "fake_prove.py").write_text(
            "import os, sys, time\n"
            "n = os.environ.get('ADAMUTANT_MUTANT_ID', '0')\n"
            "# The unmodified project has this message too; a mutant moves it.\n"
            "# Both formats: the one line of GNATprove 14, and the place on the\n"
            "# next line (GNATprove 16), for the unmodified project and mutant 3.\n"
            "if n in ('0', '3'):\n"
            "    print(' low: overflow check might fail')\n"
            "    print('--> counters.adb:%s:1' % (1 if n == '0' else 2))\n"
            "else:\n"
            "    print('counters.adb:2:1: low: overflow check might fail')\n"
            "if n == '1':\n"
            "    sys.exit(1)\n"
            "if n == '2':\n"
            "    print('2026-11-17T08:00:00 /x/counters.adb:5:16: medium: range check'\n"
            "          ' might fail, cannot prove lower bound')\n"
            "    print('counters.ads:9:17: medium: postcondition might fail')\n"
            "    print('counters.ali:0:0: note: not a message')\n"
            "    sys.exit(1)\n"
            "if n == '3':\n"
            "    # The format of GNATprove 16: the place on the next line.\n"
            "    print(' high: \"Y\" is not initialized in \"Init\"')\n"
            "    print('--> counters.adb:7:8')\n"
            "    print(' medium: \"X\" might not be initialized')\n"
            "    print('--> /x/counters.adb:7:9')\n"
            "    sys.exit(1)\n"
            "if n == '4':\n"
            "    time.sleep(30)\n"
            "sys.exit(0)\n")
        python = (f'"{sys.executable}"' if " " in sys.executable
                  else sys.executable).replace("\\", "/")
        config = work / "adamutant.toml"
        lines = [line for line in config.read_text().splitlines(True)
                 if not line.startswith(("prove", "equivalence_build"))]
        config.write_text(f"prove = '{python} fake_prove.py'\ntimeout_ms = 1000\n"
                          + "".join(lines))
        proc = subprocess.run([str(EXE), "run"], cwd=work, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if proc.returncode != 0:
            return [f"exit status {proc.returncode}\n{proc.stdout}"]
        report = json.loads((work / ".adamutant" / "reports" / "mutation-report.json")
                            .read_text(encoding="utf-8"))
        mutants = {m["id"]: m for f in report["files"].values() for m in f["mutants"]}
        expected = {
            # Only the message that the unmodified project has too.
            "1": ("Killed", ["proof"], "proof failed with exit status 1"),
            "2": ("Killed", ["proof: range check", "proof: postcondition"],
                  "proof failed: counters.adb:5:16: medium: range check might fail,"
                  " cannot prove lower bound (and 1 more)"),
            "3": ("Killed", ["proof: initialization"],
                  'proof failed: counters.adb:7:8: high: "Y" is not initialized in "Init"'
                  " (and 1 more)"),
            "4": ("Timeout", ["proof"], "proof did not finish within the timeout"),
            "5": ("Survived", None, "proof passed"),
        }
        errors = []
        for n, want in expected.items():
            m = mutants[n]
            got = (m["status"], m.get("killedBy"), m.get("statusReason"))
            if got != want:
                errors.append(f"mutant {n}: {got}, expected {want}")
        for line in ("  range check    |     1 |     0 alone",
                     "  postcondition  |     1 |     0 alone",
                     "  initialization |     1 |     1 alone"):
            if line not in proc.stdout:
                errors.append(f"output lacks {line!r}\n{proc.stdout}")
        if "overflow check" in proc.stdout:
            errors.append("a message of the unmodified project is counted")
        return errors
    finally:
        shutil.rmtree(root, ignore_errors=True)


def check_library():
    """A project with a library gives the same results every time."""
    # The directory to remove afterwards: "work" becomes the project in it.
    root = Path(tempfile.mkdtemp(prefix="adamutant-library-"))
    work = root / "p"
    try:
        files = {
            "p.gpr":
                'with "vendor/vendor.gpr";\n'
                "project P is\n"
                '   for Source_Dirs use ("tests");\n'
                '   for Object_Dir use "obj";\n'
                '   for Exec_Dir use "bin";\n'
                '   for Main use ("test_main.adb");\n'
                "end P;\n",
            "vendor/vendor.gpr":
                "library project Vendor is\n"
                '   for Source_Dirs use ("src");\n'
                '   for Object_Dir use "obj";\n'
                '   for Library_Name use "vendor";\n'
                '   for Library_Dir use "lib";\n'
                '   for Library_Kind use "static";\n'
                "end Vendor;\n",
            "vendor/src/vend.ads":
                "package Vend is\n"
                "   function Padded (A : Integer) return Integer;\n"
                "   function Bigger (A, B : Integer) return Integer;\n"
                "end Vend;\n",
            "vendor/src/vend.adb":
                "package body Vend is\n"
                "   Slack  : constant := 0;\n"
                "   Margin : constant := 0;\n"
                "   function Padded (A : Integer) return Integer is (A + Slack);\n"
                "   function Bigger (A, B : Integer) return Integer is\n"
                "   begin\n"
                "      if A > B + Margin then\n"
                "         return A;\n"
                "      else\n"
                "         return B;\n"
                "      end if;\n"
                "   end Bigger;\n"
                "end Vend;\n",
            "tests/test_main.adb":
                "with Ada.Command_Line;\n"
                "with Vend;\n"
                "procedure Test_Main is\n"
                "begin\n"
                "   if Vend.Bigger (1, 7) /= 7 or else Vend.Bigger (9, 4) /= 9\n"
                "     or else Vend.Bigger (5, 4) /= 5 or else Vend.Padded (3) < 3\n"
                "   then\n"
                "      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);\n"
                "   end if;\n"
                "end Test_Main;\n",
            "adamutant.toml":
                'mutate = ["vendor/src/*.adb"]\n'
                'build = "gprbuild -p -q -P p.gpr"\n'
                "test = '\"bin/test_main\"'\n"
                "concurrency = 2\n"
                'sandbox_exclude = [".git", "obj", "bin", "vendor/obj", "vendor/lib"]\n',
        }
        for rel, text in files.items():
            (work / rel).parent.mkdir(parents=True, exist_ok=True)
            (work / rel).write_text(text)
        # The two named numbers are static, so their mutants are built one
        # by one, the first right before the second.
        expected = {"vendor/src/vend.adb:2:25 NumericLiteral 1": "Survived",
                    "vendor/src/vend.adb:3:25 NumericLiteral 1": "Killed",
                    "vendor/src/vend.adb:4:55 ArithmeticOperator -": "Survived",
                    "vendor/src/vend.adb:7:10 ConditionalExpression True": "Killed",
                    "vendor/src/vend.adb:7:10 ConditionalExpression False": "Killed",
                    "vendor/src/vend.adb:7:12 EqualityOperator >=": "Survived",
                    "vendor/src/vend.adb:7:12 EqualityOperator <=": "Killed",
                    "vendor/src/vend.adb:7:16 ArithmeticOperator -": "Survived"}
        errors = []
        # The objects of a mutant are compiled within a second of the build
        # before.  A library that is then not made again would leave its
        # mutants without effect: those of the build of all the mutants in
        # about every second run, and with one sandbox the second named
        # number would be tested with the library of the first.
        for attempt in range(1, 5):
            if attempt == 3:
                config = work / "adamutant.toml"
                config.write_text(config.read_text().replace(
                    "concurrency = 2", "concurrency = 1"))
            proc = subprocess.run([str(EXE), "run"], cwd=work, text=True,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            report = work / ".adamutant" / "reports" / "mutation-report.json"
            if proc.returncode != 0 or not report.exists():
                errors.append(f"run {attempt}: exit status {proc.returncode}\n{proc.stdout}")
                break
            got = statuses(json.loads(report.read_text(encoding="utf-8")))
            if got != expected:
                errors.append(f"run {attempt}: {got}")
        return errors
    finally:
        shutil.rmtree(root, ignore_errors=True)


def check_baseline():
    """--baseline FILE reuses the results of an earlier run for unchanged lines."""
    # The directory to remove afterwards: "work" becomes the project in it.
    root = Path(tempfile.mkdtemp(prefix="adamutant-baseline-"))
    work = root
    try:
        shutil.copytree(ROOT / "examples" / "calculator", work / "p",
                        ignore=shutil.ignore_patterns("obj", "bin", ".adamutant"))
        base = work / "base.json"
        work = work / "p"
        src = work / "src" / "calculator.adb"
        test = work / "tests" / "test_calculator.adb"
        report = work / ".adamutant" / "reports" / "mutation-report.json"
        logs = work / ".adamutant" / "logs"
        (work / ".gitignore").write_text(".adamutant/\nobj/\nbin/\n")
        git(work, "init", "-q", "-b", "main")
        git(work, "add", "-A")
        git(work, "commit", "-q", "-m", "base")
        errors = []

        def run(*options):
            proc = subprocess.run([str(EXE), "run", *options], cwd=work, text=True,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            mutants = {}
            if proc.returncode in (0, 2):
                data = json.loads(report.read_text(encoding="utf-8"))
                mutants = {key(p, m): m for p, f in data["files"].items()
                           for m in f["mutants"]}
            return proc, mutants

        def reused(m):
            return m.get("statusReason", "").endswith("(from the baseline report)")

        def ran(m):
            return any(logs.glob(f"mutant-{m['id']}-*.log"))

        # A first run has no earlier report: a warning, and everything runs.
        proc, first = run("--baseline", str(base))
        if proc.returncode != 0 or "does not exist; no result is reused" not in proc.stdout:
            return [f"first run: exit {proc.returncode}\n{proc.stdout}"]
        if any(reused(m) for m in first.values()):
            errors.append("first run: a result is marked as reused")
        shutil.copy(report, base)

        # One line changes, a comment moves the lines below it, and a new
        # test detects mutants that survived.
        edit_line(src, "return A + B;", "return B + A;")
        edit_line(src, "   function Max", "   --  The larger one.\n   function Max")
        edit_line(test, '   Check (Grade (10) = "C", "Grade C");',
                  '   Check (Grade (10) = "C", "Grade C");\n'
                  '   Check (Grade (80) = "A", "Grade A, lowest");\n'
                  '   Check (Grade (79) = "B", "Grade B, highest");')
        proc, second = run("--baseline", str(base))
        if proc.returncode != 0 or "Reused " not in proc.stdout:
            return errors + [f"second run: exit {proc.returncode}\n{proc.stdout}"]
        moved = {k: m for k, m in second.items()
                 if not (k.startswith("src/calculator.adb") and "B + A" in
                         src.read_text().splitlines()[m["location"]["start"]["line"] - 1])}
        if len(moved) != len(second) - 1:
            errors.append("second run: expected one mutant on the changed line")
        for k, m in second.items():
            if k not in moved:
                if reused(m) or not ran(m) or m["status"] != "Killed":
                    errors.append(f"second run, changed line: {k} {m['status']} {m.get('statusReason')}")
            elif reused(m):
                if ran(m):
                    errors.append(f"second run: {k} is reused, but was run")
                if m["status"] not in ("Killed", "Timeout"):
                    errors.append(f"second run: {k} is reused with status {m['status']}")
            elif m["status"] in ("Killed", "Timeout") and not ran(m):
                errors.append(f"second run: {k} is detected without a run")
        count = sum(reused(m) for m in second.values())
        detected = sum(m["status"] in ("Killed", "Timeout") for m in first.values())
        if count != detected - 1:
            errors.append(f"second run: {count} results reused, the first run "
                          f"detected {detected} mutants and one is on the changed line")
        if f"Reused {count} results" not in proc.stdout:
            errors.append(f"second run: the output does not say 'Reused {count} results'")
        newly = [k for k, m in second.items()
                 if m["status"] == "Killed" and not reused(m) and k in moved]
        if len(newly) < 3:
            errors.append(f"second run: the new tests detect only {newly}")

        # With --since the results of the unchanged lines are those of the
        # earlier report, whatever they are, and only the changed line runs.
        git(work, "add", "-A")
        git(work, "commit", "-q", "-m", "second")
        shutil.copy(report, base)
        edit_line(src, "return B + A;", "return A + B;")
        proc, third = run("--since", "main", "--baseline", str(base))
        if proc.returncode != 0:
            return errors + [f"third run: exit {proc.returncode}\n{proc.stdout}"]
        if len(third) != len(second):
            errors.append(f"third run: {len(third)} mutants, expected {len(second)}")
        for k, m in third.items():
            on_changed = "A + B" in src.read_text().splitlines()[m["location"]["start"]["line"] - 1] \
                and k.startswith("src/calculator.adb")
            if on_changed:
                if reused(m) or not ran(m):
                    errors.append(f"third run, changed line: {k} {m.get('statusReason')}")
            else:
                if ran(m):
                    errors.append(f"third run: {k} was run")
                before = second[k]["status"]
                if m["status"] != before:
                    errors.append(f"third run: {k} is {m['status']}, the report had {before}")
                if before != "Ignored" and not reused(m):
                    errors.append(f"third run: {k} is not marked as reused")
        if not any(m["status"] == "Survived" and reused(m) for m in third.values()):
            errors.append("third run: no survivor of the earlier report")
        if not any(m["status"] == "Ignored" and reused(m) for m in third.values()):
            errors.append("third run: no equivalent mutant of the earlier report")
        if "Looking for equivalent mutants" in proc.stdout:
            errors.append("third run: results of the earlier report were examined again")

        bad = work / "bad.json"
        for text in ("{}", '{"files": {', ""):
            bad.write_text(text)
            proc, _ = run("--baseline", str(bad))
            if proc.returncode != 1 or "--baseline" not in proc.stdout:
                errors.append(f"bad report {text!r}: exit {proc.returncode}, {proc.stdout}")
        proc, _ = run("--baseline", str(work / "src"))
        if proc.returncode != 1 or "not a file" not in proc.stdout:
            errors.append(f"a directory as the report: exit {proc.returncode}, {proc.stdout}")
        proc = subprocess.run([str(EXE), "list", "--baseline", str(base)], cwd=work,
                              text=True, capture_output=True)
        if proc.returncode != 1 or "run command" not in proc.stderr:
            errors.append(f"list --baseline: exit {proc.returncode}, {proc.stderr}")
        return errors
    finally:
        shutil.rmtree(root, ignore_errors=True)


def main():
    update = "--update" in sys.argv
    if not EXE.exists():
        sys.exit(f"{EXE} not found; run 'make build' first")
    failed = False
    only = [a for a in sys.argv[1:] if not a.startswith("--")]
    checks = (("since", check_since), ("proof_log", check_proof_log),
              ("baseline", check_baseline), ("library", check_library))
    unknown = [a for a in only if a not in EXAMPLES and a not in dict(checks)]
    if unknown:
        sys.exit("no such case: " + " ".join(unknown))
    for name, spec in EXAMPLES.items():
        if only and name not in only:
            continue
        errors = run_example(name, spec, update)
        print(("FAIL " if errors else "ok   ") + name)
        for e in errors:
            print("  " + e)
        failed = failed or bool(errors)
    for name, check in checks:
        if only and name not in only:
            continue
        errors = check()
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
