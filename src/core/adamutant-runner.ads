with AdaMutant.Config;
with AdaMutant.Files;
with AdaMutant.Results;

--  Discovery and execution of mutants.
package AdaMutant.Runner is

   Run_Error : exception;

   function Discover
     (Settings : AdaMutant.Config.Configuration;
      Only     : AdaMutant.Files.String_Vectors.Vector)
      return AdaMutant.Results.Report;
   --  Mutants of the files selected by the configuration (and by Only, a
   --  list of globs, when it is not empty).  Mutants covered by adamutant
   --  directives get the Ignored status, the others Pending.

   procedure Execute
     (R            : in out AdaMutant.Results.Report;
      Keep_Sandbox : Boolean;
      Progress     : access procedure
        (Done, Total : Natural;
         M           : AdaMutant.Results.Mutant;
         File        : String) := null);
   --  Builds and tests the unmodified project, then every pending mutant,
   --  in copies of the project under <root>/.adamutant/sandbox.  Raises
   --  Run_Error when the unmodified project does not build or its tests or
   --  proof fail.

end AdaMutant.Runner;
