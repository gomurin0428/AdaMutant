with Ada.Containers.Vectors;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

--  Mutant schemata: one version of a source file that contains many of its
--  mutants at once.  Which of them is active is decided when the program
--  runs, by the number in the environment variable ADAMUTANT_MUTANT_ID, so
--  the project is built once and its tests run once per mutant.
--
--  A mutant is put into the schema when it lies in one of these places,
--  which the lexer can delimit without knowing types:
--
--  * a simple statement (assignment, call, return, exit, raise, ...), which
--    becomes a case statement with one alternative per mutant;
--  * the condition of an if, elsif or while, which becomes a case
--    expression;
--  * the expression of an expression function, likewise.
--
--  Everything else (declarations, where a static expression may be needed,
--  loop ranges, case choices, contracts) is left to the caller, which has
--  to build such mutants one at a time.  So are units with tasking
--  constructs, whose block structure is not followed here.
package AdaMutant.Schemata is

   type Candidate is record
      Id          : Positive := 1;
      First       : Positive := 1;
      Last        : Natural := 0;
      Replacement : Unbounded_String;
      Probe       : Boolean := False;
   end record;
   --  Mutant Id replaces Source (First .. Last) by Replacement.  Of a Probe
   --  the schema does not contain the mutant itself, only the report that
   --  its place has been executed (see Sites).

   package Candidate_Vectors is new Ada.Containers.Vectors
     (Positive, Candidate);

   package Id_Vectors is new Ada.Containers.Vectors (Positive, Positive);

   package Owner_Vectors is new Ada.Containers.Vectors (Positive, Natural);

   type Site is record
      Id     : Positive := 1;
      Number : Positive := 1;
   end record;

   package Site_Vectors is new Ada.Containers.Vectors (Positive, Site);

   type Schema is record
      Text     : Unbounded_String;
      --  The source with the mutants built in; "" when Sites is empty.
      Included : Id_Vectors.Vector;
      --  The mutants that Text contains, in the order of the candidates.
      Sites    : Site_Vectors.Vector;
      --  The candidates that lie in one of the places above (those in
      --  Included and the probes), in the order of the candidates, each
      --  with the number of its place: the Id of the first candidate
      --  there.  The support unit can record the places that a program
      --  executes (see Support_Body).
      Owners   : Owner_Vectors.Vector;
      --  Owners (L) is the mutant whose code is on line L of Text, or the
      --  probe whose place alone line L belongs to, or 0 for a line that
      --  belongs to no single candidate.  A compiler message on a line
      --  with an owner is that mutant's compile error, or means that the
      --  place of that probe cannot be watched.
   end record;

   function Build
     (Source     : String;
      Candidates : Candidate_Vectors.Vector;
      Tag        : Positive) return Schema;
   --  Candidates that are not in one of the places above are left out.
   --  Tag makes the name that the schema declares in the unit unique among
   --  the files of a project.  Propagates AdaMutant.Lexer.Lexical_Error.

   --  The schema reads the active mutant, and reports the places that are
   --  executed, through a function that every changed unit imports by its
   --  link name.  The function lives in a unit
   --  of its own, which must be part of the program: the main subprogram
   --  gets a with clause for it.

   Support_Spec_File : constant String := "adamutant_schemata_support.ads";
   Support_Body_File : constant String := "adamutant_schemata_support.adb";

   function Support_Spec return String;
   function Support_Body
     (Last_Site : Natural := 0; Coverage_Dir : String := "") return String;
   --  Last_Site is the largest number of a place in the schemas of the
   --  program.  With a Coverage_Dir, a program that runs with no mutant
   --  active records the places that it executes: each process appends
   --  their numbers, one per line and each once, to the file
   --  "<process id>.txt" in that directory, which has to exist.  The
   --  first line is 0 and is written when the unit is elaborated, so a
   --  process that executes no place leaves a file too.

   function With_Support (Source : String) return String;
   --  Source, the text of a main subprogram or of a schema of one, with a
   --  with clause for the support unit.  Adds a line only when Source is
   --  not a schema, so the Owners of a schema stay valid.

   type Diagnostic is record
      File : Unbounded_String;  --  lower-case base name
      Line : Positive := 1;
      Text : Unbounded_String;  --  the whole line of the log
      Name_First : Positive := 1;
      --  Where the base name of the file starts in Text.
   end record;

   package Diagnostic_Vectors is new Ada.Containers.Vectors
     (Positive, Diagnostic);

   function Diagnostics (Log : String) return Diagnostic_Vectors.Vector;
   --  The compiler messages ("file:line:column: text") in a build log.
   --  A line whose line number is 0 is not one.

   function Main_Source (Ali : String) return String;
   --  The lower-case file name of the source of the main subprogram that
   --  the text of a GNAT ALI file describes, or "" when the ALI file is
   --  not that of a main subprogram.

end AdaMutant.Schemata;
