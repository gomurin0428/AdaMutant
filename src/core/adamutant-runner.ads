with AdaMutant.Config;
with AdaMutant.Files;
with AdaMutant.Results;

--  Discovery and execution of mutants.
package AdaMutant.Runner is

   Run_Error : exception;

   function Discover
     (Settings : AdaMutant.Config.Configuration;
      Only     : AdaMutant.Files.String_Vectors.Vector;
      Since    : String := "")
      return AdaMutant.Results.Report;
   --  Mutants of the files selected by the configuration (and by Only, a
   --  list of globs, when it is not empty).  Mutants covered by adamutant
   --  directives get the Ignored status, the others Pending.  A Since other
   --  than "" is a git revision: only files changed since its merge base
   --  with HEAD are scanned, and their mutants on unchanged lines get the
   --  Ignored status.  Raises Run_Error when git fails.

   function Build_Error (Log : String) return String;
   --  The first compiler error in the text of a build log (a GNAT line
   --  "file:line:col: error: message"), or "" when there is none.

   procedure Execute
     (R            : in out AdaMutant.Results.Report;
      Keep_Sandbox : Boolean;
      Progress     : access procedure
        (Done, Total : Natural;
         M           : AdaMutant.Results.Mutant;
         File        : String) := null;
      Warn         : access procedure (Message : String) := null);
   --  Builds and tests the unmodified project, then every pending mutant,
   --  in copies of the project under <root>/.adamutant/sandbox.  Raises
   --  Run_Error when the unmodified project does not build or its tests or
   --  proof fail.  Pending mutants of files that no GNAT ALI file produced
   --  by the unmodified build depends on get the No_Coverage status and
   --  are reported to Warn, unless a prove command is configured.

end AdaMutant.Runner;
