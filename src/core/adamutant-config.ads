with Ada.Containers.Vectors;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with AdaMutant.Files;
with AdaMutant.Mutators;

--  adamutant.toml: the project configuration (a subset of TOML).
package AdaMutant.Config is

   subtype String_Vector is AdaMutant.Files.String_Vectors.Vector;

   type Percentage is range 0 .. 100;

   type Test_Command is record
      Name    : Unbounded_String;
      Command : Unbounded_String;
   end record;

   package Test_Vectors is new Ada.Containers.Vectors
     (Positive, Test_Command);

   type Configuration is record
      Root             : Unbounded_String;
      --  Directory that contains the configuration file; all paths and
      --  commands are relative to it.
      Mutate           : String_Vector;
      Exclude          : String_Vector;
      Build            : Unbounded_String;
      Test             : Unbounded_String;
      Tests            : Test_Vectors.Vector;
      --  The test commands, in the order in which they run: the entries
      --  of the [tests] table, or Test under the name "tests".
      Named_Tests      : Boolean := False;
      --  Tests comes from a [tests] table.
      Bail             : Boolean := True;
      --  Stop testing a mutant at the first test that detects it.
      Prove            : Unbounded_String;
      Equivalence_Build : Unbounded_String;
      --  A build with optimization: a surviving mutant whose object files
      --  come out the same as those of the unmodified project is an
      --  equivalent mutant.  Not looked for when "".
      Concurrency      : Positive := 1;
      Timeout_Factor   : Float := 1.5;
      Timeout_Ms       : Natural := 5_000;
      Build_Timeout_Ms : Natural := 600_000;
      Prove_Timeout_Ms : Natural := 0;
      --  The time limit of the proof of a mutant; 0 takes it from the
      --  proof of the unmodified project, as for the tests.
      Test_Memory_Limit_Mb : Natural := 0;
      Coverage_Analysis : Boolean := True;
      Scan             : AdaMutant.Mutators.Scan_Options;
      Sandbox_Exclude  : String_Vector;
      Report_Dir       : Unbounded_String;
      Suggestion_Project : Unbounded_String;
      Search_Project   : Unbounded_String;
      Search_Budget_Ms : Natural := 10_000;
      Console_Report   : Boolean := True;
      Html_Report      : Boolean := True;
      Json_Report      : Boolean := True;
      High             : Percentage := 80;
      Low              : Percentage := 60;
      Break            : Percentage := 0;
   end record;

   Config_Error : exception;

   Default_File_Name : constant String := "adamutant.toml";

   function Load (Path : String) return Configuration;
   --  Raises Config_Error with "<path>:<line>: <reason>" for unreadable,
   --  malformed or inconsistent configurations.  Unknown keys are errors.

   function Parse (Text : String; Root : String) return Configuration;
   --  As Load, for configuration text (error messages use "line N").

   function Template return String;
   --  The commented configuration written by "adamutant init".

end AdaMutant.Config;
