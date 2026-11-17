with AdaMutant.Config;
with AdaMutant.Files;
with AdaMutant.Results;

--  Discovery and execution of mutants.
package AdaMutant.Runner is

   Run_Error : exception;

   function Discover
     (Settings : AdaMutant.Config.Configuration;
      Only     : AdaMutant.Files.String_Vectors.Vector;
      Since    : String := "";
      Unchanged_Files : Boolean := False)
      return AdaMutant.Results.Report;
   --  Mutants of the files selected by the configuration (and by Only, a
   --  list of globs, when it is not empty).  Mutants covered by adamutant
   --  directives get the Ignored status, the others Pending.  A Since other
   --  than "" is a git revision: only files changed since its merge base
   --  with HEAD are scanned, and their mutants on unchanged lines get the
   --  Ignored status.  With Unchanged_Files the files that have not
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
   --  medium, low or error, each from the name of its file on.

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
   --  Builds and tests the unmodified project, then every pending mutant,
   --  in copies of the project under <root>/.adamutant/sandbox.  Raises
   --  Run_Error when the unmodified project does not build or its tests or
   --  proof fail.  Pending mutants of files that no GNAT ALI file produced
   --  by the unmodified build depends on get the No_Coverage status and
   --  are reported to Warn, unless a prove command is configured.  So do,
   --  with coverage analysis, the mutants in places that the tests of the
   --  unmodified project do not execute; with a prove command these skip
   --  the tests and go to the proof.
   --  With an equivalence_build command the survivors are then built with
   --  it, which Note announces; those whose object files are the same as
   --  the ones the command makes of the unmodified project get the Ignored
   --  status.

end AdaMutant.Runner;
