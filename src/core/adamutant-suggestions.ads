with Ada.Strings.Unbounded;
with AdaMutant.Files;
with AdaMutant.Results;

package AdaMutant.Suggestions is

   function Parse_Bindings
     (Example : String;
      Formals : AdaMutant.Files.String_Vectors.Vector;
      Actuals : out AdaMutant.Files.String_Vectors.Vector;
      Reason  : out Ada.Strings.Unbounded.Unbounded_String) return Boolean;

   function Is_Integer_Literal (Value : String) return Boolean;

   function Candidate_Source
     (Procedure_Name, Package_Name, Function_Name, Arguments,
      Expected_Value, Failure_Marker, Result_Type, Type_Package : String)
      return String;

   function Is_Explicit_Mutant_Failure
     (Exit_Code : Integer; Timed_Out : Boolean; Output, Failure_Marker : String)
      return Boolean;

   procedure Generate
     (Root, File_Path, Source, Suggestion_Project, Report_Dir : String;
      Skip_Dirs : AdaMutant.Files.String_Vectors.Vector;
      Build_Timeout, Run_Timeout : Duration;
      M : in out AdaMutant.Results.Mutant;
      Memory_Limit_Mb : Natural := 0);

end AdaMutant.Suggestions;
