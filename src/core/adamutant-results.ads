with Ada.Containers.Vectors;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with AdaMutant.Config;
with AdaMutant.Mutators;
with AdaMutant.Positions;

--  Mutants of a run and their outcome.
package AdaMutant.Results is

   type Mutant_Status is
     (Pending, Killed, Survived, No_Coverage, Timeout, Compile_Error,
      Runtime_Error, Ignored);

   function Name (S : Mutant_Status) return String;
   --  Status name of mutation-testing-report-schema, e.g. "CompileError".

   type Detector is (None, Tests, Proof);

   type Mutant is record
      Id            : Positive := 1;
      File          : Positive := 1;
      Mutation      : AdaMutant.Mutators.Mutation;
      Start_Pos     : AdaMutant.Positions.Position;
      End_Pos       : AdaMutant.Positions.Position;
      Original      : Unbounded_String;
      Status        : Mutant_Status := Pending;
      Status_Reason : Unbounded_String;
      Killed_By     : Detector := None;
      Elapsed       : Duration := 0.0;
   end record;

   package Mutant_Vectors is new Ada.Containers.Vectors (Positive, Mutant);

   type Source_File is record
      Path   : Unbounded_String;
      --  Relative to the project root, with '/' separators.
      Source : Unbounded_String;
   end record;

   package File_Vectors is new Ada.Containers.Vectors (Positive, Source_File);

   type Report is record
      Files    : File_Vectors.Vector;
      Mutants  : Mutant_Vectors.Vector;
      Settings : AdaMutant.Config.Configuration;
      Elapsed  : Duration := 0.0;
   end record;

   type Status_Counts is array (Mutant_Status) of Natural;

   function Count (R : Report) return Status_Counts;

   function Count (R : Report; File : Positive) return Status_Counts;

   function Detected (C : Status_Counts) return Natural is
     (C (Killed) + C (Timeout));

   function Undetected (C : Status_Counts) return Natural is
     (C (Survived) + C (No_Coverage));

   function Has_Score (C : Status_Counts) return Boolean is
     (Detected (C) + Undetected (C) > 0);

   function Score (C : Status_Counts) return Float is
     (100.0 * Float (Detected (C)) / Float (Detected (C) + Undetected (C)))
     with Pre => Has_Score (C);

   function Score_Image (C : Status_Counts) return String;
   --  "83.33" or "n/a".

end AdaMutant.Results;
