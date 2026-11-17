with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;
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
      Head   : Natural := 0;
      Tail   : Natural := 0;
   begin
      while Head < O and then Head < N
        and then Old_Lines (Head + 1) = New_Lines (Head + 1)
      loop
         Head := Head + 1;
         Result (Head) := Head;
      end loop;
      while Tail < O - Head and then Tail < N - Head
        and then Old_Lines (O - Tail) = New_Lines (N - Tail)
      loop
         Result (N - Tail) := O - Tail;
         Tail := Tail + 1;
      end loop;

      declare
         --  The middle parts: Old_Lines (Head + 1 .. Head + A) and
         --  New_Lines (Head + 1 .. Head + B).
         A : constant Natural := O - Head - Tail;
         B : constant Natural := N - Head - Tail;

         type Table is array (Natural range <>, Natural range <>) of Natural;
         type Table_Access is access Table;
         procedure Free is new Ada.Unchecked_Deallocation
           (Table, Table_Access);
         --  L (I, J): the length of a longest common subsequence of the
         --  last A - I old and the last B - J new lines of the middle.
         L : Table_Access;
         I : Natural := 0;
         J : Natural := 0;
      begin
         if A = 0 or else B = 0
           or else Long_Long_Integer (A) * Long_Long_Integer (B) > 4_000_000
         then
            return Result;
         end if;
         L := new Table'[0 .. A => [0 .. B => 0]];
         for X in reverse 0 .. A - 1 loop
            for Y in reverse 0 .. B - 1 loop
               L (X, Y) :=
                 (if Old_Lines (Head + X + 1) = New_Lines (Head + Y + 1)
                  then L (X + 1, Y + 1) + 1
                  else Natural'Max (L (X + 1, Y), L (X, Y + 1)));
            end loop;
         end loop;
         while I < A and then J < B loop
            if Old_Lines (Head + I + 1) = New_Lines (Head + J + 1) then
               Result (Head + J + 1) := Head + I + 1;
               I := I + 1;
               J := J + 1;
            elsif L (I + 1, J) >= L (I, J + 1) then
               I := I + 1;
            else
               J := J + 1;
            end if;
         end loop;
         Free (L);
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
      M.Tests_Run := Integer_Of (Field (From, "testsCompleted"), 0);

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
   end Take;

   procedure Apply
     (R      : in out Report;
      Text   : String;
      Reused : out Natural)
   is
      use AdaMutant.Json;
      Root  : Value;
      Files : Value;
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

      for F in R.Files.First_Index .. R.Files.Last_Index loop
         declare
            Old_File : constant Value :=
              Field (Files, To_String (R.Files (F).Path));
            Mutants  : constant Value := Field (Old_File, "mutants");
         begin
            if Is_Text (Field (Old_File, "source")) and then Is_List (Mutants)
            then
               declare
                  --  The source as the report would hold it, so that it
                  --  compares with the source in the report whatever its
                  --  encoding.
                  Now  : constant String := Text_Of
                    (Parse (AdaMutant.Reports.Json_String
                              (To_String (R.Files (F).Source))));
                  Map  : constant Line_Numbers := Line_Map
                    (Lines (Text_Of (Field (Old_File, "source"))),
                     Lines (Now));
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

                  for K in R.Mutants.First_Index .. R.Mutants.Last_Index loop
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
                                 To_String (M.Mutation.Replacement));
                           begin
                              if Olds.Contains (Id) then
                                 declare
                                    Old    : constant Value := Olds (Id);
                                    Status : constant String :=
                                      Text_Field (Old, "status");
                                 begin
                                    if Status in "Killed" | "Timeout"
                                         | "CompileError"
                                      or else
                                        (M.Unchanged
                                         and then
                                           (Status in "Survived"
                                              | "NoCoverage" | "RuntimeError"
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
            end if;
         end;
      end loop;
   end Apply;

end AdaMutant.Baselines;
