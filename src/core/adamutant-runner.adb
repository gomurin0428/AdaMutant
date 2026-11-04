with Ada.Calendar; use Ada.Calendar;
with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;
with AdaMutant.Changes;
with AdaMutant.Lexer;
with AdaMutant.Mutators; use AdaMutant.Mutators;
with AdaMutant.Positions;
with AdaMutant.Processes; use AdaMutant.Processes;

package body AdaMutant.Runner is

   use AdaMutant.Config;
   use AdaMutant.Files;
   use AdaMutant.Results;

   function Discover
     (Settings : Configuration; Only : String_Vectors.Vector;
      Since    : String := "") return Report
   is
      R     : Report;
      Root  : constant String := To_String (Settings.Root);
      Next  : Positive := 1;
      Changes : AdaMutant.Changes.Change_Maps.Map;

      function Matches_Any (List : String_Vectors.Vector; Path : String)
        return Boolean is
      begin
         for G of List loop
            if Glob_Match (G, Path) then
               return True;
            end if;
         end loop;
         return False;
      end Matches_Any;
   begin
      R.Settings := Settings;
      if Since /= "" then
         begin
            Changes := AdaMutant.Changes.Changed_Since (Root, Since);
         exception
            when E : AdaMutant.Changes.Change_Error =>
               raise Run_Error with
                 "--since: " & Ada.Exceptions.Exception_Message (E);
         end;
      end if;
      for Path of Find_Files (Root, Settings.Sandbox_Exclude) loop
         if Matches_Any (Settings.Mutate, Path)
           and then not Matches_Any (Settings.Exclude, Path)
           and then (Only.Is_Empty or else Matches_Any (Only, Path))
           and then (Since = "" or else Changes.Contains (Path))
         then
            declare
               Source  : constant String := Read (Join (Root, Path));
               Spec    : constant String :=
                 (if Path'Length > 4
                    and then Ada.Characters.Handling.To_Lower
                      (Path (Path'Last - 3 .. Path'Last)) = ".adb"
                  then Path (Path'First .. Path'Last - 1) & "s" else "");
               Options : Scan_Options := Settings.Scan;
               Found   : Mutation_Vectors.Vector;
            begin
               begin
                  if not Options.Mutate_Contracts and then Spec /= ""
                    and then Ada.Directories.Exists (Join (Root, Spec))
                  then
                     Options.Ghost_Names.Union
                       (Ghost_Names (Read (Join (Root, Spec))));
                  end if;
                  Found := Find (Source, Options);
               exception
                  when E : AdaMutant.Lexer.Lexical_Error
                    | AdaMutant.Mutators.Directive_Error =>
                     raise Run_Error with
                       Path & ": " & Ada.Exceptions.Exception_Message (E);
               end;
               R.Files.Append
                 (Source_File'(Path   => To_Unbounded_String (Path),
                   Source => To_Unbounded_String (Source)));
               for M of Found loop
                  declare
                     Start_Pos : constant AdaMutant.Positions.Position :=
                       AdaMutant.Positions.Of_Offset (Source, M.First);
                     End_Pos   : constant AdaMutant.Positions.Position :=
                       AdaMutant.Positions.Of_Offset (Source, M.Last + 1);
                     Unchanged : constant Boolean :=
                       Since /= "" and then not M.Ignored
                       and then not AdaMutant.Changes.Touches
                         (Changes, Path, Start_Pos.Line, End_Pos.Line);
                  begin
                     R.Mutants.Append
                       (Mutant'
                          (Id            => Next,
                           File          => R.Files.Last_Index,
                           Mutation      => M,
                           Start_Pos     => Start_Pos,
                           End_Pos       => End_Pos,
                           Original      => To_Unbounded_String
                             (Source (M.First .. M.Last)),
                           Status        => (if M.Ignored or else Unchanged
                                             then Ignored else Pending),
                           Status_Reason =>
                             (if M.Ignored then
                                To_Unbounded_String
                                  ("disabled by an adamutant comment")
                              elsif Unchanged then
                                To_Unbounded_String
                                  ("unchanged since " & Since)
                              else Null_Unbounded_String),
                           Killed_By     => None,
                           Elapsed       => 0.0));
                  end;
                  Next := Next + 1;
               end loop;
            end;
         end if;
      end loop;
      return R;
   end Discover;

   function Ms (D : Natural) return Duration is (Duration (D) / 1000.0);

   function Image (N : Natural) return String is
      S : constant String := N'Image;
   begin
      return S (S'First + 1 .. S'Last);
   end Image;

   function Build_Error (Log : String) return String is
      First : Positive := Log'First;
   begin
      for K in Log'Range loop
         if Log (K) = ASCII.LF or else K = Log'Last then
            declare
               Last : Natural := (if Log (K) = ASCII.LF then K - 1 else K);
            begin
               if Last >= First and then Log (Last) = ASCII.CR then
                  Last := Last - 1;
               end if;
               if Index (To_Unbounded_String (Log (First .. Last)),
                         ": error: ") > 0
               then
                  return Log (First .. Last);
               end if;
            end;
            First := K + 1;
         end if;
      end loop;
      return "";
   end Build_Error;

   function Base_Name (Path : String) return String is
   begin
      for K in reverse Path'Range loop
         if Path (K) = '/' or else Path (K) = '\' then
            return Ada.Characters.Handling.To_Lower (Path (K + 1 .. Path'Last));
         end if;
      end loop;
      return Ada.Characters.Handling.To_Lower (Path);
   end Base_Name;

   function Compiled_Sources (Dir : String) return String_Vectors.Vector is
      Result : String_Vectors.Vector;
   begin
      for Path of Find_Files (Dir, String_Vectors.Empty_Vector) loop
         if Path'Length > 4
           and then Ada.Characters.Handling.To_Lower
             (Path (Path'Last - 3 .. Path'Last)) = ".ali"
         then
            declare
               Text  : constant String := Read (Join (Dir, Path));
               First : Positive := Text'First;
               Last  : Natural;
            begin
               while First <= Text'Last loop
                  Last := First;
                  while Last <= Text'Last and then Text (Last) /= ASCII.LF loop
                     Last := Last + 1;
                  end loop;
                  if Last - First > 2 and then Text (First) = 'D'
                    and then Text (First + 1) = ' '
                  then
                     declare
                        E : Positive := First + 2;
                     begin
                        while E < Last and then Text (E) /= ' '
                          and then Text (E) /= ASCII.HT
                          and then Text (E) /= ASCII.CR
                        loop
                           E := E + 1;
                        end loop;
                        declare
                           Name : constant String :=
                             Base_Name (Text (First + 2 .. E - 1));
                        begin
                           if not Result.Contains (Name) then
                              Result.Append (Name);
                           end if;
                        end;
                     end;
                  end if;
                  First := Last + 1;
               end loop;
            end;
         end if;
      end loop;
      return Result;
   end Compiled_Sources;

   procedure Execute
     (R            : in out Report;
      Keep_Sandbox : Boolean;
      Progress     : access procedure
        (Done, Total : Natural;
         M           : AdaMutant.Results.Mutant;
         File        : String) := null;
      Warn         : access procedure (Message : String) := null)
   is
      S        : Configuration renames R.Settings;
      Root     : constant String := To_String (S.Root);
      Work     : constant String := Join (Root, ".adamutant");
      Sandbox  : constant String := Join (Work, "sandbox");
      Logs     : constant String := Join (Work, "logs");
      Started  : constant Time := Clock;
      Build_TO : constant Duration := Ms (S.Build_Timeout_Ms);
      Test_TO  : Duration := 0.0;
      Prove_TO : Duration := 0.0;
      Has_Test : constant Boolean := Length (S.Test) > 0;
      Has_Prove : constant Boolean := Length (S.Prove) > 0;

      type Mutant_Array is array (Positive range <>) of Mutant;
      type Mutant_Array_Access is access Mutant_Array;
      procedure Free is new Ada.Unchecked_Deallocation
        (Mutant_Array, Mutant_Array_Access);
      Work_Items : Mutant_Array_Access :=
        new Mutant_Array (1 .. Natural (R.Mutants.Length));
      Pending_Count : Natural := 0;

      function Slot_Dir (Slot : Positive) return String is
        (Join (Sandbox, Image (Slot)));

      procedure Baseline_Step
        (Name, Command : String; Timeout : Duration; Elapsed : out Duration;
         Memory_Limit_Mb : Natural := 0)
      is
         Log : constant String := Join (Logs, "baseline-" & Name & ".log");
         Res : constant Run_Result :=
           Run (Command, Slot_Dir (1), Log, 0, Timeout, Memory_Limit_Mb);
      begin
         Elapsed := Res.Elapsed;
         if Res.Timed_Out then
            raise Run_Error with
              "the " & Name & " command of the unmodified project timed out"
              & " ('" & Command & "', log " & Log & ")";
         elsif Res.Exit_Code /= 0 then
            raise Run_Error with
              "the " & Name & " command fails on the unmodified project"
              & " (exit status" & Res.Exit_Code'Image & ", '" & Command
              & "', log " & Log
              & (if Memory_Limit_Mb > 0
                 then ", test_memory_limit_mb =" & Memory_Limit_Mb'Image
                 else "")
              & ")" & ASCII.LF & Tail (Log, 20);
         end if;
      end Baseline_Step;

      protected Queue is
         procedure Next (Index : out Natural);
         procedure Finished (Done_Now : out Natural);
         procedure Fail (Message : String);
         function Failure return String;
      private
         Cursor  : Natural := 0;
         Done    : Natural := 0;
         Problem : Unbounded_String;
      end Queue;

      protected body Queue is
         procedure Next (Index : out Natural) is
         begin
            Index := 0;
            if Length (Problem) > 0 then
               return;
            end if;
            while Cursor < Work_Items'Last loop
               Cursor := Cursor + 1;
               if Work_Items (Cursor).Status = Pending then
                  Index := Cursor;
                  return;
               end if;
            end loop;
         end Next;

         procedure Finished (Done_Now : out Natural) is
         begin
            Done := Done + 1;
            Done_Now := Done;
         end Finished;

         procedure Fail (Message : String) is
         begin
            if Length (Problem) = 0 then
               Problem := To_Unbounded_String (Message);
            end if;
         end Fail;

         function Failure return String is (To_String (Problem));
      end Queue;

      Prove_Ended : array (1 .. Positive'Max (1, S.Concurrency)) of Time :=
        [others => Started];

      --  GNATprove skips its proof phase when the files it regenerates get
      --  the same time stamp as the previous run's results.  Time stamps
      --  have whole-second (two-second on FAT) resolution, so start the next
      --  proof two seconds after the second in which the previous one ended.
      procedure Wait_For_New_Stamp (Last : Time) is
         Whole : constant Duration :=
           Duration (Long_Float'Floor (Long_Float (Seconds (Last))));
      begin
         delay until Last - (Seconds (Last) - Whole) + 2.0;
      end Wait_For_New_Stamp;

      procedure Test_Mutant (Slot : Positive; M : in out Mutant) is
         Dir      : constant String := Slot_Dir (Slot);
         Rel      : constant String := To_String (R.Files (M.File).Path);
         Path     : constant String := Join (Dir, Rel);
         Original : constant String := To_String (R.Files (M.File).Source);
         Log_Base : constant String :=
           Join (Logs, "mutant-" & Image (M.Id));
         T0       : constant Time := Clock;

         function Step (Name, Command : String; Timeout : Duration)
           return Run_Result is
           (Run (Command, Dir, Log_Base & "-" & Name & ".log", M.Id, Timeout,
                 (if Name = "test" then S.Test_Memory_Limit_Mb else 0), Rel));
      begin
         Write_Changed (Path, Apply (Original, M.Mutation));
         declare
            B : constant Run_Result :=
              Step ("build", To_String (S.Build), Build_TO);
         begin
            if B.Timed_Out then
               M.Status := Compile_Error;
               M.Status_Reason := To_Unbounded_String ("build timed out");
            elsif B.Exit_Code /= 0 then
               M.Status := Compile_Error;
               declare
                  E : constant String :=
                    Build_Error (Read (Log_Base & "-build.log"));
               begin
                  M.Status_Reason := To_Unbounded_String
                    (if E = "" then
                        "build failed with exit status" & B.Exit_Code'Image
                     else "build failed: " & E);
               end;
            end if;
         end;
         if M.Status = Pending and then Has_Test then
            declare
               T : constant Run_Result :=
                 Step ("test", To_String (S.Test), Test_TO);
            begin
               if T.Timed_Out then
                  M.Status := Timeout;
                  M.Killed_By := Tests;
                  M.Status_Reason := To_Unbounded_String
                    ("tests did not finish within the timeout");
               elsif T.Exit_Code /= 0 then
                  M.Status := Killed;
                  M.Killed_By := Tests;
                  M.Status_Reason := To_Unbounded_String
                    ("tests failed with exit status" & T.Exit_Code'Image);
               end if;
            end;
         end if;
         if M.Status = Pending and then Has_Prove then
            Wait_For_New_Stamp (Prove_Ended (Slot));
            declare
               P : constant Run_Result :=
                 Step ("prove", To_String (S.Prove), Prove_TO);
            begin
               Prove_Ended (Slot) := Clock;
               if P.Timed_Out then
                  M.Status := Timeout;
                  M.Killed_By := Proof;
                  M.Status_Reason := To_Unbounded_String
                    ("proof did not finish within the timeout");
               elsif P.Exit_Code /= 0 then
                  M.Status := Killed;
                  M.Killed_By := Proof;
                  M.Status_Reason := To_Unbounded_String
                    ("proof failed with exit status" & P.Exit_Code'Image);
               end if;
            end;
         end if;
         if M.Status = Pending then
            M.Status := Survived;
            M.Status_Reason := To_Unbounded_String
              (if Has_Test and then Has_Prove then "tests and proof passed"
               elsif Has_Test then "tests passed" else "proof passed");
         end if;
         Write_Changed (Path, Original);
         M.Elapsed := Clock - T0;
      end Test_Mutant;

      protected Output is
         entry Seize;
         procedure Release;
      private
         Busy : Boolean := False;
      end Output;

      protected body Output is
         entry Seize when not Busy is
         begin
            Busy := True;
         end Seize;

         procedure Release is
         begin
            Busy := False;
         end Release;
      end Output;

      task type Worker (Slot : Positive) with Storage_Size => 64 * 1024 * 1024;

      task body Worker is
         Index : Natural;
         Done  : Natural;
      begin
         loop
            Queue.Next (Index);
            exit when Index = 0;
            Test_Mutant (Slot, Work_Items (Index));
            Queue.Finished (Done);
            if Progress /= null then
               Output.Seize;
               begin
                  Progress (Done, Pending_Count, Work_Items (Index),
                            To_String (R.Files (Work_Items (Index).File).Path));
               exception
                  when others =>
                     Output.Release;
                     raise;
               end;
               Output.Release;
            end if;
         end loop;
      exception
         when E : others =>
            Queue.Fail ("sandbox" & Slot'Image & ": "
                        & Ada.Exceptions.Exception_Information (E));
      end Worker;

      type Worker_Access is access Worker;
      Slots : Positive;
   begin
      for K in Work_Items'Range loop
         Work_Items (K) := R.Mutants (K);
         if Work_Items (K).Status = Pending then
            Pending_Count := Pending_Count + 1;
         end if;
      end loop;

      Delete_Tree (Sandbox);
      Delete_Tree (Logs);
      Ada.Directories.Create_Path (Logs);
      Copy_Tree (Root, Slot_Dir (1), S.Sandbox_Exclude);

      declare
         Elapsed : Duration;
      begin
         Baseline_Step ("build", To_String (S.Build), Build_TO, Elapsed);
         if Has_Test then
            Baseline_Step ("test", To_String (S.Test), 0.0, Elapsed,
                           S.Test_Memory_Limit_Mb);
            Test_TO := Elapsed * Duration (S.Timeout_Factor) + Ms (S.Timeout_Ms);
         end if;
         if Has_Prove then
            Baseline_Step ("prove", To_String (S.Prove), 0.0, Elapsed);
            Prove_Ended := [others => Clock];
            Prove_TO :=
              Elapsed * Duration (S.Timeout_Factor) + Ms (S.Timeout_Ms);
         end if;
      end;

      --  A mutated file that no compilation of the build depends on can
      --  never be detected; skip its mutants instead of reporting them as
      --  survivors.  Without any GNAT ALI file there is nothing to go by,
      --  and a prove command may analyse sources outside the build.
      declare
         Compiled : constant String_Vectors.Vector :=
           (if Has_Prove then String_Vectors.Empty_Vector
            else Compiled_Sources (Slot_Dir (1)));
      begin
         if not Compiled.Is_Empty then
            for F in R.Files.First_Index .. R.Files.Last_Index loop
               declare
                  Path    : constant String := To_String (R.Files (F).Path);
                  Skipped : Natural := 0;
               begin
                  if not Compiled.Contains (Base_Name (Path)) then
                     for M of Work_Items.all loop
                        if M.File = F and then M.Status = Pending then
                           M.Status := No_Coverage;
                           M.Status_Reason := To_Unbounded_String
                             ("the build command does not compile " & Path);
                           Skipped := Skipped + 1;
                        end if;
                     end loop;
                     Pending_Count := Pending_Count - Skipped;
                     if Skipped > 0 and then Warn /= null then
                        Warn (Path & " is not compiled by the build command;"
                              & Skipped'Image & " mutants marked NoCoverage");
                     end if;
                  end if;
               end;
            end loop;
         end if;
      end;

      Slots := Positive'Max (1, Natural'Min (S.Concurrency, Pending_Count));
      for Slot in 2 .. Slots loop
         Copy_Tree (Slot_Dir (1), Slot_Dir (Slot), String_Vectors.Empty_Vector);
      end loop;

      if Pending_Count > 0 then
         declare
            Workers : array (1 .. Slots) of Worker_Access;
         begin
            for K in Workers'Range loop
               Workers (K) := new Worker (K);
            end loop;
            --  Wait for every worker.
            for W of Workers loop
               while not W'Terminated loop
                  delay 0.05;
               end loop;
            end loop;
         end;
      end if;

      if Queue.Failure /= "" then
         Free (Work_Items);
         raise Run_Error with Queue.Failure;
      end if;

      for K in Work_Items'Range loop
         R.Mutants.Replace_Element (K, Work_Items (K));
      end loop;
      Free (Work_Items);
      R.Elapsed := Clock - Started;
      if not Keep_Sandbox then
         Delete_Tree (Sandbox);
      end if;
   end Execute;

end AdaMutant.Runner;
