with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;
with AdaMutant.Config;
with AdaMutant.Files;
with AdaMutant.Results;

--  Discovery and execution of mutants.
package AdaMutant.Runner is

   Run_Error : exception;

   procedure Fail (Text : String) with No_Return;
   --  Raises Run_Error with Text.  A Text longer than an exception message
   --  can be (200 characters) is cut there, and Details gives all of it.

   function Details return String;
   --  More about the Run_Error that Execute raised last (the command, its
   --  log and the end of it, what to do), or "".  GNAT keeps no more than
   --  200 characters of an exception message.

   function Discover
     (Settings : AdaMutant.Config.Configuration;
      Only     : AdaMutant.Files.String_Vectors.Vector;
      Since    : String := "";
      Unchanged_Files : Boolean := False)
      return AdaMutant.Results.Report;
   --  Mutants of the files selected by the configuration (and by Only, a
   --  list of globs, when it is not empty), with the Pending status except
   --  as follows.  A Since other than "" is a git revision: only files
   --  changed since its merge base with HEAD are scanned, and their
   --  mutants on unchanged lines get the Ignored status.  With Unchanged_Files the files that have not
   --  changed are scanned too, and all their mutants get the Ignored
   --  status: the report is then complete, for the results of an earlier
   --  run to be filled in.  Raises Run_Error when git fails.

   function Build_Error (Log : String) return String;
   --  The first compiler error in the text of a build log (a GNAT line
   --  "file:line:col: error: message"), or "" when there is none.

   function Proof_Failures
     (Log : String) return AdaMutant.Files.String_Vectors.Vector;
   --  The messages in the text of a GNATprove log that make a proof fail:
   --  the lines "file:line:col: severity: text" whose severity is high,
   --  medium, low or error, each from the name of its file on.  The
   --  messages of GNATprove 16, which puts the place on the next line
   --  ("--> file:line:col"), are read too, as such lines.

   type Proof_Message is record
      Text    : Ada.Strings.Unbounded.Unbounded_String;
      --  "file:line:col: severity: text", as Proof_Failures gives it.
      Example : Ada.Strings.Unbounded.Unbounded_String;
      --  The counterexample that GNATprove prints under the message, on
      --  one line ("e.g. when A = 0 and B = 1"), or "".
      Weak_Contract : Boolean := False;
      --  GNATprove adds "possible fix: add or complete related loop
      --  invariants or postconditions" (see Results.Proof_Evidence).
   end record;

   package Proof_Message_Vectors is new Ada.Containers.Vectors
     (Positive, Proof_Message);

   function Proof_Messages
     (Log : String) return Proof_Message_Vectors.Vector;
   --  The messages of Proof_Failures, each with its counterexample.

   function Without_Assertions
     (Dir : String; Sources : AdaMutant.Files.String_Vectors.Vector)
      return String;
   --  One of Sources (paths relative to Dir) whose GNAT ALI files under
   --  Dir, outside the directories of GNATprove, show that it was compiled
   --  without assertions (no "-gnata"), or "" when one of them was
   --  compiled with them, when there is no such ALI file, or when a
   --  project file, a configuration pragma file or one of Sources says
   --  Assertion_Policy, which can turn them on without the switch.

   function Check_Kind (Message : String) return String;
   --  What a message of Proof_Failures is about: "postcondition" for
   --  "p.ads:9:17: medium: postcondition might fail", "range check" for
   --  "p.adb:5:16: medium: range check might fail, cannot prove ...",
   --  "initialization" for the messages of the flow analysis about
   --  objects that are not initialized, "error" for an error.  The names
   --  that a message quotes are not part of the kind.

   procedure Execute
     (R            : in out AdaMutant.Results.Report;
      Keep_Sandbox : Boolean;
      Progress     : access procedure
        (Done, Total : Natural;
         M           : AdaMutant.Results.Mutant;
         File        : String) := null;
      Warn         : access procedure (Message : String) := null;
      Note         : access procedure (Message : String) := null);
   --  Builds, tests and proves the unmodified project, then every pending
   --  mutant, in copies of the project under <root>/.adamutant/sandbox.
   --  Raises Run_Error when the unmodified project does not build or its
   --  tests or proof fail.  A mutant runs the tests first; the proof only
   --  sees the mutants that the tests do not detect.  With coverage
   --  analysis, a mutant in a place that the tests of the unmodified
   --  project do not execute skips the tests and goes to the proof at
   --  once.  With an equivalence_build command the survivors are then
   --  built with it, which Note announces; those whose object files are
   --  the same as the ones the command makes of the unmodified project
   --  get the Ignored status.

end AdaMutant.Runner;
