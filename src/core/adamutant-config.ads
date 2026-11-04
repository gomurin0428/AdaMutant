with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with AdaMutant.Files;
with AdaMutant.Mutators;

--  adamutant.toml: the project configuration (a subset of TOML).
package AdaMutant.Config is

   subtype String_Vector is AdaMutant.Files.String_Vectors.Vector;

   type Percentage is range 0 .. 100;

   type Configuration is record
      Root             : Unbounded_String;
      --  Directory that contains the configuration file; all paths and
      --  commands are relative to it.
      Mutate           : String_Vector;
      Exclude          : String_Vector;
      Build            : Unbounded_String;
      Test             : Unbounded_String;
      Prove            : Unbounded_String;
      Concurrency      : Positive := 1;
      Timeout_Factor   : Float := 1.5;
      Timeout_Ms       : Natural := 5_000;
      Build_Timeout_Ms : Natural := 600_000;
      Test_Memory_Limit_Mb : Natural := 0;
      Scan             : AdaMutant.Mutators.Scan_Options;
      Sandbox_Exclude  : String_Vector;
      Report_Dir       : Unbounded_String;
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
