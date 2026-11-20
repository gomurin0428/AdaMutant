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

# A prove command that proves nothing and passes.
NO_PROOF = "prove = '{python} -c \"pass\"'\n"

# A unit with a statement on a line that has a compiler warning
# ("Count := Count"), and one with a mutant that does not compile
# ("X * 2" for a Float X).
UNWATCHED = {
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
                "end Test_Calculator;\n"}

# Warnings are errors (-cargs -gnatwe, for every unit) in the builds where
# B_Spare contains the generated code that watches its statement, as in
# the build that contains the mutants: the unmodified project and the
# mutants built on their own have their warnings and still build.
UNWATCHED_WE = {
    **UNWATCHED,
    "build.py":
        "import subprocess, sys\n"
        "args = ['gprbuild', '-p', '-q', '-P', 'calculator_tests.gpr']\n"
        "with open('src/b_spare.adb') as f:\n"
        "    if 'ADAMUTANT' in f.read():\n"
        "        args += ['-cargs', '-gnatwe']\n"
        "sys.exit(subprocess.call(args))\n",
}

# Modulo.Small_Rest compares N mod 3 with 3: its mutant "<=" is always
# True, and GNAT warns of it on the line of the mutant (an equivalent
# mutant, which the equivalence build recognizes).  Modulo is compiled
# before Powers, whose mutant stops the build.
WARNINGS_KEPT = {
    **UNWATCHED,
    "src/modulo.ads":
        "package Modulo is\n"
        "   function Small_Rest (N : Integer) return Boolean;\n"
        "end Modulo;\n",
    "src/modulo.adb":
        "package body Modulo is\n"
        "   function Small_Rest (N : Integer) return Boolean is\n"
        "   begin\n"
        "      return N mod 3 < 3;\n"
        "   end Small_Rest;\n"
        "end Modulo;\n",
    "tests/test_calculator.adb":
        UNWATCHED["tests/test_calculator.adb"]
        .replace("with Powers;\n", "with Modulo;\nwith Powers;\n")
        .replace("   then\n", "     or else not Modulo.Small_Rest (4)\n   then\n"),
}

EXAMPLES = {
    # The example has an equivalence_build command: the two survivors that
    # are equivalent mutants become Ignored.
    "calculator": {
        "exit": 0, "min_timeout": 1, "min_uncovered": 1, "equivalent": 2,
        # Most mutants are tested in the one build that contains them all;
        # only a few are built on their own.
        "max_single_builds": 10,
        "output": "Lines that no test executes:",
    },
    # The report says which checks the proof failed on.
    "spark_counter": {"exit": 0, "killed_by": "proof",
                      "proof_checks": ["postcondition", "range check"],
                      "output": "Mutants killed by the proof, by the check that fails",
                      "suggestion": True,
                      "report_dir": ".adamutant/reports/../custom-report",
                      "config_tail": 'report_dir = ".adamutant/reports/../custom-report"\n'},
    # Contracts on a Ghost model (sequences of SPARKlib, which comes with
    # GNATprove): the test never makes the ring buffer wrap around, and
    # the proof detects the mutants there, by an index or range check or
    # by a postcondition on the model.  The deleted loop invariants of
    # the model fail its refined postcondition.  An index check fails
    # with a counterexample (Confirmed), a postcondition on the model
    # without one (Undecided).
    "spark_model": {"exit": 0, "killed_by": "proof",
                    "proof_checks": ["postcondition", "refined postcondition",
                                     "array index check", "range check",
                                     "precondition"],
                    "killers": {
                        "src/queues.adb:36:10 ConditionalExpression True":
                            "proof: array index check",
                        "src/queues.adb:39:10 StatementDeletion null;":
                            "proof: postcondition"},
                    "output": "Detected only by the proof (candidates for a missing test)",
                    "outputs": ["  Confirmed: ", "  Undecided: "]},
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
    # The mutants in code that no test executes are not tested: they go to
    # the proof at once.  Only the deleted statements among them, and the
    # three initial values of declarations, whose execution is not watched,
    # are built on their own.
    "coverage": {
        "exit": 2, "example": "calculator", "extra": SPARE,
        "min_uncovered": 5, "max_single_builds": 7,
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
    # the mutants there are known not to be executed, without a warning.
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
    # in a build that fails because of a mutant elsewhere.  The warning
    # does not stop the build: the mutant elsewhere becomes a CompileError,
    # the statement stays watched, and the mutant whose own line has a
    # warning ("N mod 3 <= 3", always True) keeps its place in the build
    # and gets a verdict (Ignored: it is equivalent).
    "warnings_kept": {
        "exit": 0, "example": "calculator", "no_reason": "undefined reference",
        "expect": {"src/powers.adb:4:16 ArithmeticOperator *": "CompileError",
                   "src/modulo.adb:4:22 EqualityOperator <=": "Ignored"},
        # Watched: the build knows which tests execute it.
        "covered": {"src/b_spare.adb:4:7 StatementDeletion null;": ["tests"]},
        "extra": "WARNINGS_KEPT",
    },
    # The same, where warnings are errors in the build that contains the
    # mutants (-gnatwe), as the build command does here: the warning on
    # the line of the statement then stops the build too.  The statement
    # is no longer watched, and its file, which then has nothing left in
    # the combined build, gets its original source back.  (Left as it
    # was, it would make every later build fail to link.)
    "unwatched": {
        "exit": 0, "example": "calculator", "no_reason": "undefined reference",
        "config": "build = '{python} build.py'\n",
        # No longer watched: no test is known to execute it.
        "covered": {"src/b_spare.adb:4:7 StatementDeletion null;": None},
        "extra": "UNWATCHED_WE",
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
    # every survivor an equivalent mutant.  The test, which it compiles,
    # depends on calculator.ads: the survivor of Is_Even "True" (for "N
    # mod 2 >= 0", which always holds) leaves its object as it was, since
    # it only calls Is_Even (4), and is taken for an equivalent mutant.
    # (It is not one: Calculator, where Is_Even (3) would differ, is never
    # compiled by this command.  "N mod 2 <= 0", which is, is not made: N
    # mod 2 is never negative.)
    "equivalence_other": {
        "exit": 0, "example": "calculator", "equivalent": 1,
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


def suggestion_targets(report):
    found = []
    for path, file in report["files"].items():
        if path != "src/counters.adb":
            continue
        lines = file["source"].splitlines()
        for mutant in file["mutants"]:
            start = mutant["location"]["start"]
            line_number = start["line"]
            column = start["column"] - 1
            if line_number != 13 or line_number > len(lines):
                continue
            line = lines[line_number - 1]
            if (mutant["mutatorName"] == "ArithmeticOperator"
                    and mutant["replacement"] == "-"
                    and line[column:column + 1] == "+"
                    and line[:column].rstrip().endswith("A")
                    and line[column + 1:].lstrip().startswith("B")):
                found.append(mutant)
    return found


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
        # The variants of the calculator are about the tests.  The proof of
        # the example, which has nothing to prove, would only take time.
        fake = (spec.get("example") == "calculator"
                and "prove =" not in spec.get("config", ""))
        if "config" in spec or "config_tail" in spec or "drop_keys" in spec or fake:
            python = (f'"{sys.executable}"' if " " in sys.executable
                      else sys.executable).replace("\\", "/")
            config = work / "adamutant.toml"
            head = spec.get("config", "") + (NO_PROOF if fake else "")
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
        for text in spec.get("outputs", []):
            if text not in proc.stdout:
                errors.append(f"output lacks {text!r}\n{proc.stdout}")
        if "not_output" in spec and spec["not_output"] in proc.stdout:
            errors.append(f"output has {spec['not_output']!r}\n{proc.stdout}")
        for p, data in before.items():
            if p.read_bytes() != data:
                errors.append(f"{p.relative_to(work)} was modified by the run")
        if (work / ".adamutant" / "sandbox").exists():
            errors.append("sandbox directory was not removed")
        report_dir = Path(spec.get("report_dir", ".adamutant/reports"))
        report_path = work / report_dir / "mutation-report.json"
        if not report_path.exists():
            return errors + ["no JSON report"]
        report = json.loads(report_path.read_text(encoding="utf-8"))
        if not report_path.with_suffix(".html").exists():
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
        for k, killer in spec.get("killers", {}).items():
            found = [m for p, f in report["files"].items() for m in f["mutants"]
                     if key(p, m) == k]
            if len(found) != 1 or killer not in found[0].get("killedBy", []):
                errors.append(f"{k}: expected a mutant killed by {killer!r}, got {found}")
        # Mutants in code that the tests do not execute are not run.
        logs = work / ".adamutant" / "logs"
        uncovered = [m for m in mutants if m.get("coveredBy") == []]
        for m in uncovered:
            if any(logs.glob(f"mutant-{m['id']}-test*.log")):
                errors.append(f"mutant {m['id']} is not covered, but has a test log")
            # It goes to the proof instead.
            if m["status"] != "CompileError" \
                    and not (logs / f"mutant-{m['id']}-prove.log").exists():
                errors.append(f"mutant {m['id']} is not covered, but has no prove log")
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

        for k, want in spec.get("covered", {}).items():
            found = [m for p, f in report["files"].items() for m in f["mutants"]
                     if key(p, m) == k]
            if len(found) != 1 or found[0].get("coveredBy") != want:
                errors.append(f"{k}: expected coveredBy {want}, got {found}")
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
        if spec.get("suggestion"):
            targets = suggestion_targets(report)
            if len(targets) != 1:
                errors.append(f"expected one line-13 A + B to A - B mutant, got {targets}")
            else:
                target = targets[0]
                killed_by = target.get("killedBy", [])
                if target.get("status") != "Killed" or not any(
                        killer.startswith("proof:") for killer in killed_by):
                    errors.append(f"target did not remain proof-only: {target}")
                suggestion = target.get("suggestion", {})
                if suggestion.get("status") != "verified":
                    errors.append(f"target suggestion was not verified: {suggestion}")
                if suggestion.get("call") != "Counters.Saturating_Add (0, 1)" \
                        or suggestion.get("assertion") \
                        != "Counters.Saturating_Add (0, 1) = 1":
                    errors.append(f"unexpected suggested assertion: {suggestion}")
                outcomes = suggestion.get("verification", {})
                if any(outcomes.get(field) != "passed" for field in (
                        "probeBuild", "probeRun", "assertionBuild", "originalRun",
                        "mutantBuild", "mutantRun")):
                    errors.append(f"suggestion verification outcomes were incomplete: {outcomes}")
                if "suggestion: verified" not in proc.stdout:
                    errors.append("console report did not expose the verified suggestion")
                artifact = suggestion.get("artifactPath")
                project = suggestion.get("projectPath")
                command = suggestion.get("command")
                if not artifact or not (work / artifact).is_file():
                    errors.append(f"saved suggestion source is missing: {artifact}")
                if not project or not (work / project).is_file():
                    errors.append(f"saved suggestion project is missing: {project}")
                if not command:
                    errors.append("suggestion report has no runnable command")
                else:
                    failure_marker = (
                        f"ADAMUTANT_SUGGESTION_FAILURE_{target['id']}")
                    build_command, separator, run_command = command.partition(" && ")
                    if not separator:
                        errors.append("saved suggestion command lacks separate build/run steps")
                    else:
                        original_build = subprocess.run(
                            build_command, cwd=work, shell=True, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                        if original_build.returncode != 0:
                            errors.append("saved harness did not build on the original:\n"
                                          + original_build.stdout)
                        else:
                            original_harness = subprocess.run(
                                run_command, cwd=work, shell=True, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                            if (original_harness.returncode != 0
                                    or failure_marker in original_harness.stdout):
                                errors.append("saved harness failed on the original:\n"
                                              + original_harness.stdout)
                    counter_file = work / "src" / "counters.adb"
                    original_source = counter_file.read_text(encoding="utf-8")
                    lines = original_source.splitlines(keepends=True)
                    start = target["location"]["start"]
                    offset = start["column"] - 1
                    original_line = lines[start["line"] - 1]
                    lines[start["line"] - 1] = (
                        original_line[:offset] + target["replacement"]
                        + original_line[offset + 1:])
                    try:
                        counter_file.write_text("".join(lines), encoding="utf-8")
                        mutant_build = subprocess.run(
                            build_command, cwd=work, shell=True, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                        if mutant_build.returncode != 0:
                            errors.append("saved harness did not build on the exact mutant:\n"
                                          + mutant_build.stdout)
                        else:
                            mutant_harness = subprocess.run(
                                run_command, cwd=work, shell=True, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                            if (mutant_harness.returncode != 1
                                    or failure_marker not in mutant_harness.stdout):
                                errors.append(
                                    "saved harness did not report the exact mutant failure:\n"
                                    + mutant_harness.stdout)
                    finally:
                        counter_file.write_text(original_source, encoding="utf-8")

                    test_file = work / "tests" / "test_counters.adb"
                    test_source = test_file.read_text(encoding="utf-8")
                    marker = "end Test_Counters;"
                    assertion = (
                        f"   pragma Assert ({suggestion.get('assertion', '')});\n")
                    if marker not in test_source:
                        errors.append("could not inject the suggested assertion into the copied test")
                    else:
                        test_file.write_text(
                            test_source.replace(marker, assertion + marker, 1),
                            encoding="utf-8")
                        rerun = subprocess.run(
                            [str(EXE), "run"], cwd=work, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                        if rerun.returncode != 0:
                            errors.append("run with the injected test failed:\n" + rerun.stdout)
                        shifted = json.loads(report_path.read_text(encoding="utf-8"))
                        shifted_targets = suggestion_targets(shifted)
                        if (len(shifted_targets) != 1
                                or shifted_targets[0].get("status") != "Killed"
                                or "tests" not in shifted_targets[0].get("killedBy", [])
                                or any(k.startswith("proof:")
                                       for k in shifted_targets[0].get("killedBy", []))):
                            errors.append(
                                "the injected assertion did not shift the target to tests: "
                                + repr(shifted_targets))
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


def no_proof(work):
    """The calculator has nothing to prove: use a prover that only passes."""
    python = (f'"{sys.executable}"' if " " in sys.executable
              else sys.executable).replace("\\", "/")
    config = work / "adamutant.toml"
    config.write_text("".join(
        NO_PROOF.format(python=python) if line.startswith("prove =") else line
        for line in config.read_text().splitlines(True)))


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
        no_proof(work)
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
            "cache = os.environ.get('ADAMUTANT_PROVE_CACHE', '')\n"
            "print('place: [%s] [%s]' % (os.environ.get('ADAMUTANT_MUTANT_LINE', 'unset'),\n"
            "      'cache' if cache and os.path.isdir(cache) else 'no cache'))\n"
            "print('cache:', cache)\n"
            "switches = os.environ.get('ADAMUTANT_PROVE_SWITCHES', 'unset')\n"
            "print('switches: [%s]' % switches)\n"
            "print('args: %s' % sys.argv[1:])\n"
            "# A warning of the compiler, with proof warnings on and off.\n"
            "if n == '0':\n"
            "    print('counters.adb:4:1: warning: condition is always False')\n"
            "# Code that the proof never reaches: only with proof warnings on,\n"
            "# which fail the proof as --warnings=error does.\n"
            "if switches.startswith('--proof-warnings=on'):\n"
            "    print(' warning: unreachable code')\n"
            "    print('--> counters.adb:13:10')\n"
            "    sys.exit(1)\n"
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
            "    print('  e.g. when C = 0')\n"
            "    print('        and D = 1')\n"
            "    print('  possible fix: add or complete related loop invariants'\n"
            "          ' or postconditions')\n"
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
            "if n == '5':\n"
            "    # A counterexample that GNATprove could not run with the real code.\n"
            "    print(' medium: division check might fail')\n"
            "    print('--> counters.adb:5:16')\n"
            "    print('      + e.g. when C = 99')\n"
            "    sys.exit(1)\n"
            "sys.exit(0)\n")
        python = (f'"{sys.executable}"' if " " in sys.executable
                  else sys.executable).replace("\\", "/")
        config = work / "adamutant.toml"
        # No test detects anything, so every mutant goes to the prover.
        lines = [line for line in config.read_text().splitlines(True)
                 if not line.startswith(("prove", "test", "equivalence_build"))]
        # The switches go to the prover as arguments, as to a script.
        config.write_text(f"prove = '{python} fake_prove.py $ADAMUTANT_PROVE_SWITCHES'\n"
                          "timeout_ms = 1000\n"
                          f"test = '{python} -c \"pass\"'\n" + "".join(lines))
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
            # GNATprove says that a contract says too little.
            "2": ("Killed", ["proof: range check", "proof: postcondition"],
                  "proof failed, a contract says too little: counters.adb:5:16:"
                  " medium: range check might fail, cannot prove lower bound"
                  " (e.g. when C = 0 and D = 1) (and 1 more)"),
            # A message of severity high.
            "3": ("Killed", ["proof: initialization"],
                  "proof failed, confirmed: counters.adb:7:8:"
                  ' high: "Y" is not initialized in "Init" (and 1 more)'),
            # A proof that does not finish detects nothing.
            "4": ("Survived", None,
                  "the tests passed, and the proof did not finish within the timeout"),
            # A counterexample without GNATprove's word on it.
            "5": ("Killed", ["proof: division check"],
                  "proof failed: counters.adb:5:16: medium: division check might"
                  " fail (e.g. when C = 99)"),
            "6": ("Survived", None, "the tests and the proof passed"),
        }
        errors = []
        for n, want in expected.items():
            m = mutants[n]
            got = (m["status"], m.get("killedBy"), m.get("statusReason"))
            if got != want:
                errors.append(f"mutant {n}: {got}, expected {want}")
        for line in ("Detected only by the proof (candidates for a missing test):\n"
                     "  Confirmed: the failure happens with the real code (or GNATprove"
                     " reports an error)\n  #3 ",
                     "  A contract says too little: the failure happens only with the"
                     " contracts of the calls (or the loop invariants) in place of the"
                     " code\n  #2 ",
                     "\n    e.g. when C = 0 and D = 1\n",
                     "  Undecided: GNATprove could not confirm the failure with the real"
                     " code\n  #1 ",
                     "\n    e.g. when C = 99\n",
                     "  range check    |     1 |     0 alone",
                     "  postcondition  |     1 |     0 alone",
                     "  initialization |     1 |     1 alone",
                     "Detected only by the proof (candidates for a missing test):",
                     " (range check, postcondition)",
                     " (initialization)",
                     " (the proof timed out)",
                     # What to do about it, without a steps limit.
                     "  (The proof of 1 mutant did not finish in time.  On a"
                     " goal that a mutant makes fail, the provers run up to"
                     " their time limit; a steps limit (gnatprove --steps)"
                     " usually stops them much sooner."):
            if line not in proc.stdout:
                errors.append(f"output lacks {line!r}\n{proc.stdout}")
        if "overflow check" in proc.stdout:
            errors.append("a message of the unmodified project is counted")
        # What the proof of the unmodified project never reaches.  The fake
        # prover is no GNATprove: no warning about ADAMUTANT_PROVE_SWITCHES.
        # The warnings of both proofs, once each: the compiler's first.
        want = ("The proof of the unmodified project proves anything here"
                " (--proof-warnings); mutants there survive the proof:\n"
                "  counters.adb:4:1: warning: condition is always False\n"
                "  counters.adb:13:10: warning: unreachable code\n")
        if want not in proc.stdout:
            errors.append(f"output lacks {want!r}\n{proc.stdout}")
        if "ADAMUTANT_PROVE_SWITCHES" in proc.stdout:
            errors.append(f"a warning about ADAMUTANT_PROVE_SWITCHES\n{proc.stdout}")
        if proc.stdout.count("condition is always False") != 1:
            errors.append(f"a warning of both proofs is not listed once\n{proc.stdout}")
        # Survivors in the statement that is never reached are marked.
        marked = [line for line in proc.stdout.splitlines()
                  if "counters.adb:13:" in line and line.startswith("  #")]
        if not marked or any("(GNATprove: never reached)" not in line
                             for line in marked
                             if int(line.split(":")[2].split()[0]) >= 10):
            errors.append(f"survivors on line 13: {marked}\n{proc.stdout}")
        # The line of the mutant, and a cache of proof results for each
        # sandbox, which its proof of the unmodified project fills.
        logs = work / ".adamutant" / "logs"
        texts = {}
        for log, want in (("baseline-prove.log", "place: [] [cache]"),
                          ("baseline-prove-2.log", "place: [] [cache]"),
                          ("mutant-1-prove.log", "place: [5] [cache]"),
                          ("baseline-prove.log", "switches: [--proof-warnings=off]"),
                          ("baseline-proof-warnings.log",
                           "switches: [--proof-warnings=on --warnings=continue]"),
                          ("baseline-proof-warnings.log",
                           "args: ['--proof-warnings=on', '--warnings=continue']"),
                          ("baseline-proof-warnings.log", "place: [] [cache]"),
                          ("mutant-1-prove.log", "switches: [--proof-warnings=off]")):
            texts[log] = (logs / log).read_text() if (logs / log).exists() else ""
            if want not in texts[log]:
                errors.append(f"{log} lacks {want!r}\n{texts[log]}")

        def cache_of(text):
            return [line for line in text.splitlines() if line.startswith("cache:")]
        if cache_of(texts["baseline-prove.log"]) == cache_of(texts["baseline-prove-2.log"]):
            errors.append("two sandboxes share a proof cache")
        if cache_of(texts["baseline-proof-warnings.log"]) in (
                cache_of(texts["baseline-prove.log"]), cache_of(texts["baseline-prove-2.log"])):
            errors.append("the proof warnings share a proof cache with a sandbox")
        # Some failures have a counterexample: no note about them.
        if "The proof gave no counterexample" in proc.stdout:
            errors.append(f"a note about counterexamples\n{proc.stdout}")
        # With a steps limit in the prove command, the note asks for a lower
        # one.
        config.write_text("".join(
            f"prove = '{python} fake_prove.py --steps=100'\n"
            if line.startswith("prove =") else line
            for line in config.read_text().splitlines(True)))
        proc = subprocess.run([str(EXE), "run"], cwd=work, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        want = ("  (The proof of 1 mutant did not finish in time.  On a goal that"
                " a mutant makes fail, a lower steps limit (--steps, still enough"
                " for the unmodified project) stops the provers sooner")
        if proc.returncode != 0 or want not in proc.stdout:
            errors.append(f"with --steps: exit status {proc.returncode},"
                          f" output lacks {want!r}\n{proc.stdout}")
        # GNATprove 16 fails when there is no SPARK code.  The error says so,
        # with the command and its log on lines of their own.
        (work / "no_spark.py").write_text(
            "print('warning: no checks generated by GNATprove')\n"
            "print('possible reason: no bodies have been selected for analysis"
            " with SPARK_Mode')\n"
            "raise SystemExit(1)\n")
        config.write_text("".join(
            f"prove = '{python} no_spark.py'\n" if line.startswith("prove =")
            else line for line in config.read_text().splitlines(True)))
        proc = subprocess.run([str(EXE), "run"], cwd=work, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        for line in ("error: the prove command fails on the unmodified project"
                     " (exit status 1)\n",
                     "\ncommand: ", "\nlog: ", "baseline-prove.log",
                     "no checks generated by GNATprove",
                     'for a project without SPARK code, write prove = "exit 0".'):
            if proc.returncode != 1 or line not in proc.stdout:
                errors.append(f"no SPARK code: exit status {proc.returncode},"
                              f" output lacks {line!r}\n{proc.stdout}")
                break
        return errors
    finally:
        shutil.rmtree(root, ignore_errors=True)


def check_prove_cache():
    """The proofs fill a cache of proof results in each sandbox."""
    # The directory to remove afterwards: "work" becomes the project in it.
    root = Path(tempfile.mkdtemp(prefix="adamutant-cache-"))
    work = root / "p"
    try:
        shutil.copytree(ROOT / "examples" / "spark_counter", work,
                        ignore=shutil.ignore_patterns("obj", "bin", ".adamutant"))
        if "ADAMUTANT_PROVE_CACHE" not in (work / "adamutant.toml").read_text():
            return ["examples/spark_counter does not use ADAMUTANT_PROVE_CACHE"]
        proc = subprocess.run([str(EXE), "run", "--keep-sandbox"], cwd=work,
                              text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT)
        if proc.returncode != 0:
            return [f"exit status {proc.returncode}\n{proc.stdout}"]
        errors = []
        # The prove command uses ADAMUTANT_PROVE_SWITCHES: no warning.
        if "does not use ADAMUTANT_PROVE_SWITCHES" in proc.stdout:
            errors.append(f"a warning about ADAMUTANT_PROVE_SWITCHES\n{proc.stdout}")
        # Survivors whose proof finished: no note about time limits.
        if "Survived mutants:" not in proc.stdout or "did not finish in time" in proc.stdout:
            errors.append(f"survivors and a note about time limits\n{proc.stdout}")
        caches = work / ".adamutant" / "sandbox" / "prove-cache"
        for slot in ("1", "2"):
            if not (caches / slot).is_dir() or not any((caches / slot).iterdir()):
                errors.append(f"the proof cache of sandbox {slot} is empty")
        # GNATprove without ADAMUTANT_PROVE_SWITCHES: a warning.
        config = work / "adamutant.toml"
        config.write_text(config.read_text().replace(" $ADAMUTANT_PROVE_SWITCHES", ""))
        proc = subprocess.run([str(EXE), "run"], cwd=work, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if proc.returncode != 0 \
                or "the prove command does not use ADAMUTANT_PROVE_SWITCHES" not in proc.stdout:
            errors.append(f"no warning about ADAMUTANT_PROVE_SWITCHES: exit status"
                          f" {proc.returncode}\n{proc.stdout}")
        return errors
    finally:
        shutil.rmtree(root, ignore_errors=True)


def check_assertions():
    """Mutants of contracts need code built with assertions."""
    # The directory to remove afterwards: "work" becomes the project in it.
    root = Path(tempfile.mkdtemp(prefix="adamutant-assert-"))
    work = root / "p"
    try:
        (work / "src").mkdir(parents=True)
        (work / "src" / "steps.ads").write_text(
            "package Steps is\n"
            "   function Next (X : Integer) return Integer;\n"
            "end Steps;\n")
        (work / "src" / "steps.adb").write_text(
            "package body Steps is\n"
            "   function Inc (X : Integer) return Integer\n"
            "     with Post => Inc'Result > X, Inline => True\n"
            "   is\n"
            "   begin\n"
            "      return X + 1;\n"
            "   end Inc;\n"
            "   function Next (X : Integer) return Integer is (Inc (X));\n"
            "end Steps;\n")
        (work / "src" / "test_steps.adb").write_text(
            "with Steps;\n"
            "with Ada.Command_Line;\n"
            "procedure Test_Steps is\n"
            "begin\n"
            "   if Steps.Next (1) /= 2 then\n"
            "      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);\n"
            "   end if;\n"
            "end Test_Steps;\n")
        python = (f'"{sys.executable}"' if " " in sys.executable
                  else sys.executable).replace("\\", "/")
        errors = []
        for switches, warned in (('"-gnat2022"', True), ('"-gnat2022", "-gnata"', False)):
            (work / "p.gpr").write_text(
                "project P is\n"
                '   for Source_Dirs use ("src");\n'
                '   for Object_Dir use "obj";\n'
                '   for Exec_Dir use "bin";\n'
                '   for Main use ("test_steps.adb");\n'
                "   package Compiler is\n"
                f'      for Default_Switches ("Ada") use ({switches});\n'
                "   end Compiler;\n"
                "end P;\n")
            (work / "adamutant.toml").write_text(
                "mutate = ['src/steps.adb']\n"
                "build = 'gprbuild -p -q -P p.gpr'\n"
                "test = '\"bin/test_steps\"'\n"
                f"prove = '{python} -c \"pass\"'\n"
                "sandbox_exclude = ['obj', 'bin']\n")
            shutil.rmtree(work / "obj", ignore_errors=True)
            shutil.rmtree(work / "bin", ignore_errors=True)
            proc = subprocess.run([str(EXE), "run"], cwd=work, text=True,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            report = work / ".adamutant" / "reports" / "mutation-report.json"
            if proc.returncode != 0 or not report.exists():
                return [f"{switches}: exit status {proc.returncode}\n{proc.stdout}"]
            want = ("src/steps.adb is compiled without assertions (no -gnata in"
                    " its GNAT ALI file)")
            if (want in proc.stdout) != warned:
                errors.append(f"{switches}: warning {'missing' if warned else 'given'}"
                              f"\n{proc.stdout}")
            mutants = [m for f in json.loads(report.read_text(encoding="utf-8"))
                       ["files"].values() for m in f["mutants"]]
            # The postcondition is mutated; Inline is no contract (no
            # BooleanLiteral of its True).
            if not any(m["location"]["start"]["line"] == 3 for m in mutants) \
                    or any(m["mutatorName"] == "BooleanLiteral" for m in mutants):
                errors.append(f"{switches}: the mutants of the aspects: {mutants}")
            # With assertions, the test detects a mutant that makes the
            # postcondition false for Next (1) = 2 (> to <=).
            if not warned and not any(
                    m["location"]["start"]["line"] == 3 and m["status"] == "Killed"
                    for m in mutants):
                errors.append(f"{switches}: no mutant of the postcondition is"
                              f" detected\n{proc.stdout}")
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
                "   Margin : constant := 0;\n"
                "   Slack  : constant := 0;\n"
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
                "prove = '{python} -c \"pass\"'\n"
                "concurrency = 2\n"
                'sandbox_exclude = [".git", "obj", "bin", "vendor/obj", "vendor/lib"]\n',
        }
        python = (f'"{sys.executable}"' if " " in sys.executable
                  else sys.executable).replace("\\", "/")
        for rel, text in files.items():
            (work / rel).parent.mkdir(parents=True, exist_ok=True)
            (work / rel).write_text(text.replace("{python}", python))
        # The two named numbers are static, so their mutants are built one
        # by one, the first right before the second.
        expected = {"vendor/src/vend.adb:2:25 NumericLiteral 1": "Killed",
                    "vendor/src/vend.adb:3:25 NumericLiteral 1": "Survived",
                    "vendor/src/vend.adb:4:55 ArithmeticOperator -": "Survived",
                    "vendor/src/vend.adb:7:10 ConditionalExpression True": "Killed",
                    "vendor/src/vend.adb:7:10 ConditionalExpression False": "Killed",
                    "vendor/src/vend.adb:7:12 EqualityOperator >=": "Survived",
                    "vendor/src/vend.adb:7:12 EqualityOperator /=": "Killed",
                    "vendor/src/vend.adb:7:16 ArithmeticOperator -": "Survived"}
        errors = []
        # The objects of a mutant are compiled within a second of the build
        # before.  A library that is then not made again would leave its
        # mutants without effect: those of the build of all the mutants in
        # about every second run, and with one sandbox the second named
        # number would be tested with the library of the first.  (The
        # first one is detected, so no proof runs between the two builds.)
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
        no_proof(work)
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
              ("baseline", check_baseline), ("library", check_library),
              ("prove_cache", check_prove_cache),
              ("assertions", check_assertions))
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
