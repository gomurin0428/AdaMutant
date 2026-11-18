with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with AdaMutant.Json;
with AdaMutant.Mutators;
with AdaMutant.Reports;

package body AdaMutant.Baselines is

   use AdaMutant.Results;

   From_Baseline : constant String := " (from the baseline report)";

   function Lines (Text : String) return Line_Vectors.Vector is
      Result : Line_Vectors.Vector;
      First  : Positive := Text'First;
   begin
      for K in Text'Range loop
         if Text (K) = ASCII.LF then
            Result.Append (Text (First .. K - 1));
            First := K + 1;
         end if;
      end loop;
      if First <= Text'Last then
         Result.Append (Text (First .. Text'Last));
      end if;
      return Result;
   end Lines;

   function Line_Map
     (Old_Lines, New_Lines : Line_Vectors.Vector) return Line_Numbers
   is
      O      : constant Natural := Natural (Old_Lines.Length);
      N      : constant Natural := Natural (New_Lines.Length);
      Result : Line_Numbers (1 .. N) := [others => 0];

      --  How often a text is a line of each side, and where it was last.
      type Occurrence is record
         Old_Count, New_Count : Natural := 0;
         Old_Line, New_Line   : Natural := 0;
      end record;

      package Occurrence_Maps is new Ada.Containers.Indefinite_Hashed_Maps
        (String, Occurrence, Ada.Strings.Hash, "=");

      Seen : Occurrence_Maps.Map;

      procedure Count (Text : String; Line : Positive; Is_Old : Boolean) is
         C : Occurrence_Maps.Cursor := Seen.Find (Text);
         Unused : Boolean;
      begin
         if not Occurrence_Maps.Has_Element (C) then
            Seen.Insert (Text, (others => <>), C, Unused);
         end if;
         declare
            Item : Occurrence renames Seen.Reference (C);
         begin
            if Is_Old then
               Item.Old_Count := Item.Old_Count + 1;
               Item.Old_Line := Line;
            else
               Item.New_Count := Item.New_Count + 1;
               Item.New_Line := Line;
            end if;
         end;
      end Count;

      --  The lines that occur once on each side, by their new line: the
      --  old line of each, or 0.
      Partner : Line_Numbers (1 .. N) := [others => 0];

      procedure Match_Between (Old_First, Old_Last, New_First, New_Last : Integer)
      is
         --  The lines at the beginning and at the end of the two parts
         --  that are the same are the same lines.
         Head : Natural := 0;
         Tail : Natural := 0;
         A    : constant Integer := Old_Last - Old_First + 1;
         B    : constant Integer := New_Last - New_First + 1;
      begin
         while Head < A and then Head < B
           and then Old_Lines (Old_First + Head) = New_Lines (New_First + Head)
         loop
            Result (New_First + Head) := Old_First + Head;
            Head := Head + 1;
         end loop;
         while Tail < A - Head and then Tail < B - Head
           and then Old_Lines (Old_Last - Tail) = New_Lines (New_Last - Tail)
         loop
            Result (New_Last - Tail) := Old_Last - Tail;
            Tail := Tail + 1;
         end loop;
      end Match_Between;
   begin
      for K in 1 .. O loop
         Count (Old_Lines (K), K, Is_Old => True);
      end loop;
      for K in 1 .. N loop
         Count (New_Lines (K), K, Is_Old => False);
      end loop;
      for Item of Seen loop
         if Item.Old_Count = 1 and then Item.New_Count = 1 then
            Partner (Item.New_Line) := Item.Old_Line;
         end if;
      end loop;

      declare
         --  A longest series of such lines that are in the same order on
         --  both sides (patience sorting): Tops (P) is the new line whose
         --  old line ends the best series of length P so far, Before (J)
         --  the new line that precedes J in its series.
         Tops   : Line_Numbers (1 .. N) := [others => 0];
         Before : Line_Numbers (1 .. N) := [others => 0];
         Length : Natural := 0;
         Low, High, Middle : Natural;
         Old_Next : Integer := O + 1;
         New_Next : Integer := N + 1;
         J        : Natural;
      begin
         for K in 1 .. N loop
            if Partner (K) /= 0 then
               --  The first series whose last old line is not below this
               --  one.
               Low := 1;
               High := Length + 1;
               while Low < High loop
                  Middle := (Low + High) / 2;
                  if Partner (Tops (Middle)) < Partner (K) then
                     Low := Middle + 1;
                  else
                     High := Middle;
                  end if;
               end loop;
               Before (K) := (if Low > 1 then Tops (Low - 1) else 0);
               Tops (Low) := K;
               Length := Natural'Max (Length, Low);
            end if;
         end loop;

         --  From the last line of the series back to the first: the lines
         --  of the series are the same lines, and so are the equal lines
         --  next to them.  A text that occurs several times is never
         --  matched on its own, so a line cannot be taken for another
         --  line with the same text somewhere else.
         J := (if Length > 0 then Tops (Length) else 0);
         while J /= 0 loop
            Result (J) := Partner (J);
            Match_Between (Partner (J) + 1, Old_Next - 1, J + 1, New_Next - 1);
            Old_Next := Partner (J);
            New_Next := J;
            J := Before (J);
         end loop;
         Match_Between (1, Old_Next - 1, 1, New_Next - 1);
      end;
      return Result;
   end Line_Map;

   function Image (N : Integer) return String is
     (Ada.Strings.Fixed.Trim (N'Image, Ada.Strings.Both));

   function Key (Line, Column, End_Line, End_Column : Integer;
                 Mutator, Replacement : String) return String is
     (Image (Line) & ":" & Image (Column) & "-" & Image (End_Line) & ":"
      & Image (End_Column) & " " & Mutator & " " & Replacement);

   package Value_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (String, AdaMutant.Json.Value, "<", AdaMutant.Json."=");

   function Text_Field (V : AdaMutant.Json.Value; Name : String)
     return String
   is
      F : constant AdaMutant.Json.Value := AdaMutant.Json.Field (V, Name);
   begin
      return (if AdaMutant.Json.Is_Text (F) then AdaMutant.Json.Text_Of (F)
              else "");
   end Text_Field;

   function Starts_With (S, Prefix : String) return Boolean is
     (S'Length >= Prefix'Length
      and then S (S'First .. S'First + Prefix'Length - 1) = Prefix);

   function As_In_Report (S : String) return String is
      --  S as a report holds it and a reader of the report gets it back:
      --  bytes that are not UTF-8 are read as Latin-1.
      V : AdaMutant.Json.Value :=
        AdaMutant.Json.Parse (AdaMutant.Reports.Json_String (S));
   begin
      return Result : constant String := AdaMutant.Json.Text_Of (V) do
         AdaMutant.Json.Free (V);
      end return;
   end As_In_Report;

   Old_Proof_Timeout : constant String :=
     "proof did not finish within the timeout";

   function Old_Mode (Old : AdaMutant.Json.Value) return Boolean is
      --  The result is from an earlier version that ran the tests alone or
      --  the proof alone: NoCoverage (no test executes the code, and there
      --  was no proof), a survivor of the tests alone or of the proof
      --  alone, or a mutant that the proof killed without any test (no
      --  "coveredBy", no "testsCompleted").  Now a mutant goes to the
      --  tests first and then to the proof, whatever happened before.  Such
      --  a result is not reused: the mutant runs again, or, on a line
      --  unchanged since the revision of --since, stays Ignored.
      use AdaMutant.Json;
      Status : constant String := Text_Field (Old, "status");
      Reason : constant String := Text_Field (Old, "statusReason");
   begin
      return Status = "NoCoverage"
        or else (Status = "Survived"
                 and then (Starts_With (Reason, "tests passed")
                           or else Starts_With (Reason, "proof passed")))
        or else (Status = "Killed" and then Starts_With (Reason, "proof")
                 and then Field (Old, "coveredBy") = No_Value
                 and then Integer_Of (Field (Old, "testsCompleted"), 0) = 0);
   end Old_Mode;

   procedure Take (M : in out Mutant; From : AdaMutant.Json.Value) is
      --  The result that the report has in From becomes that of M.

      use AdaMutant.Json;
      Status  : constant String := Text_Field (From, "status");
      Reason  : constant String := Text_Field (From, "statusReason");
      Covering : constant Value := Field (From, "coveredBy");
      Killers : constant Value := Field (From, "killedBy");
   begin
      for S in Mutant_Status loop
         if Name (S) = Status then
            M.Status := S;
         end if;
      end loop;
      M.Status_Reason := To_Unbounded_String
        ((if Reason'Length >= From_Baseline'Length
            and then Reason (Reason'Last - From_Baseline'Length + 1
                             .. Reason'Last) = From_Baseline
          then Reason (Reason'First .. Reason'Last - From_Baseline'Length)
          else Reason)
         & From_Baseline);
      M.Equivalent := M.Status = Ignored;
      M.Reused := True;
      M.Unchanged := False;
      M.Elapsed := 0.0;
      M.Tests_Run :=
        Natural'Max (0, Integer_Of (Field (From, "testsCompleted"), 0));

      M.Reached := Unknown;
      M.Covered_By.Clear;
      if Is_List (Covering) then
         M.Reached :=
           (if Length (Covering) = 0 then Not_Covered else Covered);
         for K in 1 .. Length (Covering) loop
            if Is_Text (Element (Covering, K)) then
               M.Covered_By.Append (Text_Of (Element (Covering, K)));
            end if;
         end loop;
      end if;

      M.Killed_By := None;
      M.Killers.Clear;
      M.Failed_Checks.Clear;
      if Is_List (Killers) then
         for K in 1 .. Length (Killers) loop
            if Is_Text (Element (Killers, K)) then
               declare
                  Who : constant String := Text_Of (Element (Killers, K));
               begin
                  --  No test has the name "proof", and no name of a
                  --  test has a colon.
                  if Who = "proof" then
                     M.Killed_By := Proof;
                  elsif Starts_With (Who, "proof: ") then
                     M.Killed_By := Proof;
                     M.Failed_Checks.Append (Who (Who'First + 7 .. Who'Last));
                  else
                     M.Killed_By := Tests;
                     M.Killers.Append (Who);
                  end if;
               end;
            end if;
         end loop;
      end if;
      --  An earlier version counted a proof that did not finish as a
      --  detection.
      if M.Status = Timeout and then Starts_With (Reason, Old_Proof_Timeout)
      then
         M.Status := Survived;
         --  No "coveredBy" and no "testsCompleted": an earlier version
         --  that ran the proof alone.
         M.Status_Reason := To_Unbounded_String
           ((if M.Reached = Not_Covered
             then "no test executes this code, and "
             elsif M.Tests_Run = 0 then ""
             else "the tests passed, and ")
            & Proof_Unfinished & From_Baseline);
         M.Killed_By := None;
         M.Killers.Clear;
         M.Failed_Checks.Clear;
      end if;
   end Take;

   procedure Apply
     (R      : in out Report;
      Text   : String;
      Reused : out Natural)
   is
      use AdaMutant.Json;
      Root  : Value;
      Files : Value;

      procedure Apply_To_File
        (F               : Positive;
         Lowest, Highest : Positive;
         Old_Source      : String;
         Mutants         : Value)
      is
         --  The mutants Lowest .. Highest of R are those of file F.
      begin
         declare
            --  The source as the report would hold it, so that it
            --  compares with the source in the report whatever its
            --  encoding.
            Now  : constant String :=
              As_In_Report (To_String (R.Files (F).Source));
            Map  : constant Line_Numbers := Line_Map
              (Lines (Old_Source), Lines (Now));
            Olds : Value_Maps.Map;

            function Old_Line (Line : Positive) return Natural is
              (if Line in Map'Range then Map (Line) else 0);
         begin
            for K in 1 .. Length (Mutants) loop
               declare
                  Old   : constant Value := Element (Mutants, K);
                  Loc   : constant Value := Field (Old, "location");
                  First : constant Value := Field (Loc, "start");
                  Last  : constant Value := Field (Loc, "end");
                  Id    : constant String := Key
                    (Integer_Of (Field (First, "line"), 0),
                     Integer_Of (Field (First, "column"), 0),
                     Integer_Of (Field (Last, "line"), 0),
                     Integer_Of (Field (Last, "column"), 0),
                     Text_Field (Old, "mutatorName"),
                     Text_Field (Old, "replacement"));
               begin
                  if not Olds.Contains (Id) then
                     Olds.Insert (Id, Old);
                  end if;
               end;
            end loop;

            for K in Lowest .. Highest loop
               declare
                  M     : Mutant := R.Mutants (K);
                  First : constant Natural :=
                    Old_Line (M.Start_Pos.Line);
                  Same  : Boolean := M.File = F and then First /= 0
                    and then (M.Status = Pending or else M.Unchanged);
               begin
                  --  Every line of the mutant is unchanged, and the
                  --  lines are together as before.
                  if Same then
                     for Line in M.Start_Pos.Line .. M.End_Pos.Line loop
                        Same := Same
                          and then Old_Line (Line)
                                   = First + (Line - M.Start_Pos.Line);
                     end loop;
                  end if;
                  if Same then
                     declare
                        Id : constant String := Key
                          (First, M.Start_Pos.Column,
                           First + (M.End_Pos.Line - M.Start_Pos.Line),
                           M.End_Pos.Column,
                           AdaMutant.Mutators.Name (M.Mutation.Kind),
                           As_In_Report
                             (To_String (M.Mutation.Replacement)));
                     begin
                        if Olds.Contains (Id) then
                           declare
                              Old    : constant Value := Olds (Id);
                              Status : constant String :=
                                Text_Field (Old, "status");
                           begin
                              --  A build that ran out of time may only
                              --  have been slow that once.  A result of
                              --  an earlier version that ran the tests
                              --  alone or the proof alone runs again.
                              if Old_Mode (Old) then
                                 null;
                              elsif Status = "Killed"
                                or else
                                  (Status = "Timeout"
                                   and then
                                     (M.Unchanged
                                      or else not Starts_With
                                        (Text_Field (Old, "statusReason"),
                                         Old_Proof_Timeout)))
                                or else
                                  (Status = "CompileError"
                                   and then not Starts_With
                                     (Text_Field (Old, "statusReason"),
                                      "build timed out"))
                                or else
                                  (M.Unchanged
                                   and then
                                     (Status in "Survived" | "RuntimeError"
                                      or else
                                        (Status = "Ignored"
                                         and then Starts_With
                                           (Text_Field
                                              (Old, "statusReason"),
                                            "equivalent mutant"))))
                              then
                                 Take (M, Old);
                                 R.Mutants.Replace_Element (K, M);
                                 Reused := Reused + 1;
                              end if;
                           end;
                        end if;
                     end;
                  end if;
               end;
            end loop;
         end;
      end Apply_To_File;
   begin
      Reused := 0;
      begin
         Root := Parse (Text);
      exception
         when E : Syntax_Error =>
            raise Baseline_Error with
              "not a JSON report (" & Ada.Exceptions.Exception_Message (E)
              & ")";
      end;
      Files := Field (Root, "files");
      if not Is_Object (Files) then
         raise Baseline_Error with "not a report: it has no ""files""";
      end if;

      declare
         --  The mutants of each file: Discover appends them file by file.
         First_Of : array (R.Files.First_Index .. R.Files.Last_Index + 1)
           of Natural := [others => 0];
         Last_Of  : array (R.Files.First_Index .. R.Files.Last_Index + 1)
           of Natural := [others => 0];
      begin
         for K in R.Mutants.First_Index .. R.Mutants.Last_Index loop
            declare
               F : constant Positive := R.Mutants.Constant_Reference (K).File;
            begin
               if First_Of (F) = 0 then
                  First_Of (F) := K;
               end if;
               Last_Of (F) := K;
            end;
         end loop;

         for F in R.Files.First_Index .. R.Files.Last_Index loop
            declare
               Old_File : constant Value :=
                 Field (Files, To_String (R.Files (F).Path));
               Mutants  : constant Value := Field (Old_File, "mutants");
            begin
               if First_Of (F) /= 0
                 and then Is_Text (Field (Old_File, "source"))
                 and then Is_List (Mutants)
               then
                  Apply_To_File
                    (F, First_Of (F), Last_Of (F),
                     Text_Of (Field (Old_File, "source")), Mutants);
               end if;
            end;
         end loop;
      end;
      Free (Root);
   end Apply;

end AdaMutant.Baselines;
