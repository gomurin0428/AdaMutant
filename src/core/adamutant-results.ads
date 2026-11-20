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

   type Suggestion_Status is
     (No_Suggestion, Ineligible, Unsupported, Failed, Verified);

   function Name (S : Suggestion_Status) return String;

   type Verification_Outcome is
     (Not_Run, Passed, Failed, Build_Failed, Timed_Out, Spawn_Failed,
      Invalid_Output);

   function Name (S : Verification_Outcome) return String;

   type Suggestion_Record is record
      Status          : Suggestion_Status := No_Suggestion;
      Reason          : Unbounded_String;
      Call            : Unbounded_String;
      Assertion       : Unbounded_String;
      Artifact_Path   : Unbounded_String;
      Project_Path    : Unbounded_String;
      Command         : Unbounded_String;
      Probe_Build     : Verification_Outcome := Not_Run;
      Probe_Run       : Verification_Outcome := Not_Run;
      Assertion_Build : Verification_Outcome := Not_Run;
      Original_Run    : Verification_Outcome := Not_Run;
      Mutant_Build    : Verification_Outcome := Not_Run;
      Mutant_Run      : Verification_Outcome := Not_Run;
   end record;

   type Input_Search_Status is
     (Search_Not_Run, Search_Inconclusive, Search_Found);

   type Input_Search_Record is record
      Status          : Input_Search_Status := Search_Not_Run;
      Reason          : Unbounded_String;
      Input           : Unbounded_String;
      Original_Output : Unbounded_String;
      Mutant_Output   : Unbounded_String;
      Attempts        : Natural := 0;
   end record;

   type Proof_Evidence is (None, Confirmed, Weak_Contract, Undecided);
   --  For a mutant that only the proof detects, what GNATprove gives with
   --  the failure.  Confirmed: a message of severity high (GNATprove ran
   --  a counterexample with the real code and the check failed), or an
   --  error.  Weak_Contract: GNATprove adds "possible fix: add or complete
   --  related loop invariants or postconditions", which it does when the
   --  counterexample fails only with the contracts of the calls (or the
   --  loop invariants) in place of the code they stand for.  Undecided:
   --  anything else, with or without a counterexample (GNATprove could
   --  not run it with the real code, or gave none).

   type Coverage is (Unknown, Covered, Not_Covered);
   --  Whether the unmodified tests execute the place of a mutant.

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
      Failed_Checks : AdaMutant.Config.String_Vector;
      --  For a mutant that the proof detects: the kinds of the checks that
      --  could not be proved ("postcondition", "range check", ...), each
      --  once, in the order of the messages.
      Evidence      : Proof_Evidence := None;
      Example       : Unbounded_String;
      --  The counterexample that GNATprove gives with the failure, "e.g.
      --  when H = 51", or "".
      Has_Suggestion : Boolean := False;
      Suggestion     : Suggestion_Record;
      Input_Search   : Input_Search_Record;
      Reached       : Coverage := Unknown;
      Covered_By    : AdaMutant.Config.String_Vector;
      --  With Reached = Covered: the names of the tests that execute the
      --  place of the mutant.
      Killers       : AdaMutant.Config.String_Vector;
      --  The names of the tests that failed or did not finish in time.
      Tests_Run     : Natural := 0;
      --  The number of tests that were run with the mutant.
      Equivalent    : Boolean := False;
      --  Ignored because its object code is that of the unmodified
      --  project.
      Unchanged     : Boolean := False;
      --  Ignored because its lines are unchanged since the revision of
      --  "--since".
      Reused        : Boolean := False;
      --  The result is that of an earlier run ("--baseline").
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
      Proof_Warnings : AdaMutant.Config.String_Vector;
      --  What the proof of the unmodified project (with --proof-warnings)
      --  says is always False or never reached, as "file:line:col:
      --  warning: text": there the proof of anything succeeds.
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

   Confirmed_Failure : constant String := "proof failed, confirmed: ";
   Weak_Contract_Failure : constant String :=
     "proof failed, a contract says too little: ";
   --  How the reason of a mutant with Evidence = Confirmed or
   --  Weak_Contract starts.  The other proof failures start with "proof
   --  failed".

   Proof_Unfinished : constant String :=
     "the proof did not finish within the timeout";
   --  The end of the reason of a mutant that survived because its proof
   --  ran out of time.  That is not a detection: a proof that would fail
   --  and one that is only slow look the same.

   function Proof_Timed_Out (M : Mutant) return Boolean;

end AdaMutant.Results;
