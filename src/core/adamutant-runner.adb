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
with AdaMutant.Schemata;

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

   function Main_Sources (Dir : String) return String_Vectors.Vector is
      --  Paths, relative to Dir, of the sources of the main subprograms
      --  that the GNAT ALI files under Dir describe.
      Files  : constant String_Vectors.Vector :=
        Find_Files (Dir, String_Vectors.Empty_Vector);
      Names  : String_Vectors.Vector;
      Result : String_Vectors.Vector;
   begin
      for Path of Files loop
         if Path'Length > 4
           and then Ada.Characters.Handling.To_Lower
             (Path (Path'Last - 3 .. Path'Last)) = ".ali"
         then
            declare
               Name : constant String :=
                 AdaMutant.Schemata.Main_Source (Read (Join (Dir, Path)));
            begin
               if Name /= "" and then not Names.Contains (Name) then
                  Names.Append (Name);
               end if;
            end;
         end if;
      end loop;
      for Path of Files loop
         if Names.Contains (Base_Name (Path)) then
            Result.Append (Path);
         end if;
      end loop;
      return Result;
   end Main_Sources;

   function Directory_Of (Path : String) return String is
   begin
      for K in reverse Path'Range loop
         if Path (K) = '/' then
            return Path (Path'First .. K - 1);
         end if;
      end loop;
      return "";
   end Directory_Of;

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

      --  Mutants that are part of the one build that contains many mutants
      --  (see AdaMutant.Schemata), and those among them that its tests did
      --  not detect: these still go to the proof, without another build.
      type Flags is array (1 .. Natural (R.Mutants.Length)) of Boolean;
      Combined : Flags := [others => False];
      Tested   : Flags := [others => False];
      Combined_Test_TO : Duration := 0.0;

      function Slot_Dir (Slot : Positive) return String is
        (Join (Sandbox, Image (Slot)));

      procedure Baseline_Step
        (Name, Command : String; Timeout : Duration; Elapsed : out Duration;
         Memory_Limit_Mb : Natural := 0; Slots : Positive := 1)
      is
         --  The step runs in sandboxes 1 .. Slots at once, as the workers
         --  will run mutants, so Elapsed (the slowest run) includes the
         --  slowdown of running in parallel.
         function Log (Slot : Positive) return String is
           (Join (Logs, "baseline-" & Name
                  & (if Slot = 1 then "" else "-" & Image (Slot)) & ".log"));

         Results : array (1 .. Slots) of Run_Result;
         Errors  : array (1 .. Slots) of Unbounded_String;
      begin
         declare
            task type Runner is
               entry Start (Slot : Positive);
            end Runner;

            task body Runner is
               Mine : Positive;
            begin
               accept Start (Slot : Positive) do
                  Mine := Slot;
               end Start;
               Results (Mine) :=
                 Run (Command, Slot_Dir (Mine), Log (Mine), 0, Timeout,
                      Memory_Limit_Mb);
            exception
               when E : others =>
                  Errors (Mine) := To_Unbounded_String
                    (Ada.Exceptions.Exception_Message (E));
            end Runner;

            Runners : array (1 .. Slots) of Runner;
         begin
            for K in Runners'Range loop
               Runners (K).Start (K);
            end loop;
         end;

         Elapsed := 0.0;
         for K in Results'Range loop
            if Length (Errors (K)) > 0 then
               raise Spawn_Error with To_String (Errors (K));
            elsif Results (K).Timed_Out then
               raise Run_Error with
                 "the " & Name & " command of the unmodified project timed out"
                 & " ('" & Command & "', log " & Log (K) & ")";
            elsif Results (K).Exit_Code /= 0 then
               raise Run_Error with
                 "the " & Name & " command fails on the unmodified project"
                 & " (exit status" & Results (K).Exit_Code'Image & ", '"
                 & Command & "', log " & Log (K)
                 & (if Memory_Limit_Mb > 0
                    then ", test_memory_limit_mb =" & Memory_Limit_Mb'Image
                    else "")
                 & ")" & ASCII.LF & Tail (Log (K), 20);
            end if;
            Elapsed := Duration'Max (Elapsed, Results (K).Elapsed);
         end loop;
      end Baseline_Step;

      protected Queue is
         procedure Next (Index : out Natural);
         procedure Next_Combined (Index : out Natural);
         procedure Finished (Done_Now : out Natural);
         procedure Fail (Message : String);
         function Failure return String;
      private
         Cursor  : Natural := 0;
         Cursor_Combined : Natural := 0;
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

         procedure Next_Combined (Index : out Natural) is
         begin
            Index := 0;
            if Length (Problem) > 0 then
               return;
            end if;
            while Cursor_Combined < Work_Items'Last loop
               Cursor_Combined := Cursor_Combined + 1;
               if Combined (Cursor_Combined)
                 and then Work_Items (Cursor_Combined).Status = Pending
               then
                  Index := Cursor_Combined;
                  return;
               end if;
            end loop;
         end Next_Combined;

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

      procedure Test_Mutant
        (Slot : Positive; M : in out Mutant; Already_Tested : Boolean)
      is
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
         if not Already_Tested then
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
         end if;
         if M.Status = Pending and then Has_Test and then not Already_Tested
         then
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
         M.Elapsed := M.Elapsed + (Clock - T0);
      end Test_Mutant;

      procedure Test_Combined
        (Slot : Positive; Index : Positive; M : in out Mutant)
      is
         --  The build in the sandbox contains M: run its tests with M
         --  switched on.
         T0 : constant Time := Clock;
         T  : constant Run_Result :=
           Run (To_String (S.Test), Slot_Dir (Slot),
                Join (Logs, "mutant-" & Image (M.Id) & "-test.log"), M.Id,
                Combined_Test_TO, S.Test_Memory_Limit_Mb,
                To_String (R.Files (M.File).Path));
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
         elsif Has_Prove then
            Tested (Index) := True;
         else
            M.Status := Survived;
            M.Status_Reason := To_Unbounded_String ("tests passed");
         end if;
         M.Elapsed := Clock - T0;
      end Test_Combined;

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

      task type Worker (Slot : Positive; Combined_Build : Boolean)
        with Storage_Size => 64 * 1024 * 1024;

      task body Worker is
         Index : Natural;
         Done  : Natural;
      begin
         loop
            if Combined_Build then
               Queue.Next_Combined (Index);
            else
               Queue.Next (Index);
            end if;
            exit when Index = 0;
            if Combined_Build then
               Test_Combined (Slot, Index, Work_Items (Index));
            else
               Test_Mutant (Slot, Work_Items (Index), Tested (Index));
            end if;
            if Work_Items (Index).Status = Pending then
               --  Its tests passed in the combined build; the proof is
               --  still to come.
               Done := 0;
            else
               Queue.Finished (Done);
            end if;
            if Progress /= null and then Done /= 0 then
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

      procedure Run_Workers (Combined_Build : Boolean) is
         Workers : array (1 .. Slots) of Worker_Access;
      begin
         for K in Workers'Range loop
            Workers (K) := new Worker (K, Combined_Build);
         end loop;
         --  Wait for every worker.
         for W of Workers loop
            while not W'Terminated loop
               delay 0.05;
            end loop;
         end loop;
         if Queue.Failure /= "" then
            raise Run_Error with Queue.Failure;
         end if;
      end Run_Workers;

      procedure Run_Combined is
         --  Build the project once with as many of the pending mutants as
         --  a schema can hold, and run the tests once for each of them.
         Mains : constant String_Vectors.Vector :=
           Main_Sources (Slot_Dir (1));
         Log   : constant String := Join (Logs, "combined-build.log");

         type Schema_Array is
           array (R.Files.First_Index .. R.Files.Last_Index)
           of AdaMutant.Schemata.Schema;
         type Schema_Array_Access is access Schema_Array;
         procedure Free is new Ada.Unchecked_Deallocation
           (Schema_Array, Schema_Array_Access);
         Schemas : Schema_Array_Access := new Schema_Array;

         function Rel (F : Positive) return String is
           (To_String (R.Files (F).Path));

         function Is_Main (Path : String) return Boolean is
           (Mains.Contains (Path));

         procedure Generate (F : Positive) is
            Candidates : AdaMutant.Schemata.Candidate_Vectors.Vector;
         begin
            --  A deleted statement stays out.  Where the statement was the
            --  first assignment to a variable, the variable has no value
            --  in the mutant, and an optimizing compiler may then give it
            --  the value that the original statement assigns in the other
            --  alternative: the mutant would do what the original does.
            for M of Work_Items.all loop
               if M.File = F and then M.Status = Pending
                 and then M.Mutation.Kind /= Statement_Deletion
               then
                  Candidates.Append
                    (AdaMutant.Schemata.Candidate'
                       (Id          => M.Id,
                        First       => M.Mutation.First,
                        Last        => M.Mutation.Last,
                        Replacement => M.Mutation.Replacement));
               end if;
            end loop;
            Schemas (F) := AdaMutant.Schemata.Build
              (To_String (R.Files (F).Source), Candidates, Tag => F);
         end Generate;

         procedure Write_Sources (Slot : Positive; Restore : Boolean) is
            --  The sources of the combined build, or the original ones
            --  again.
            Dir : constant String := Slot_Dir (Slot);
         begin
            for F in Schemas'Range loop
               if not Schemas (F).Included.Is_Empty
                 and then not Is_Main (Rel (F))
               then
                  Write_Changed
                    (Join (Dir, Rel (F)),
                     (if Restore then To_String (R.Files (F).Source)
                      else To_String (Schemas (F).Text)));
               end if;
            end loop;
            for Main of Mains loop
               declare
                  Original : constant String := Read (Join (Root, Main));
                  Text     : Unbounded_String :=
                    To_Unbounded_String (Original);
                  Support  : constant String :=
                    (if Directory_Of (Main) = "" then Dir
                     else Join (Dir, Directory_Of (Main)));
                  Spec     : constant String := Join
                    (Support, AdaMutant.Schemata.Support_Spec_File);
                  Body_File : constant String := Join
                    (Support, AdaMutant.Schemata.Support_Body_File);
               begin
                  for F in Schemas'Range loop
                     if Rel (F) = Main
                       and then not Schemas (F).Included.Is_Empty
                     then
                        Text := Schemas (F).Text;
                     end if;
                  end loop;
                  if Restore then
                     Write_Changed (Join (Dir, Main), Original);
                     if Ada.Directories.Exists (Spec) then
                        Ada.Directories.Delete_File (Spec);
                     end if;
                     if Ada.Directories.Exists (Body_File) then
                        Ada.Directories.Delete_File (Body_File);
                     end if;
                  else
                     Write_Changed
                       (Join (Dir, Main),
                        AdaMutant.Schemata.With_Support (To_String (Text)));
                     Write (Spec, AdaMutant.Schemata.Support_Spec);
                     Write (Body_File, AdaMutant.Schemata.Support_Body);
                  end if;
               end;
            end loop;
         end Write_Sources;

         function Drop_Compile_Errors return Natural is
            --  Mutants whose own lines the compiler complained about do
            --  not compile; they leave the combined build.
            Dropped : Natural := 0;
         begin
            for D of AdaMutant.Schemata.Diagnostics (Read (Log)) loop
               for F in Schemas'Range loop
                  if Base_Name (Rel (F)) = To_String (D.File)
                    and then D.Line <= Natural (Schemas (F).Owners.Length)
                    and then Schemas (F).Owners (D.Line) /= 0
                  then
                     declare
                        M : Mutant renames
                          Work_Items (Schemas (F).Owners (D.Line));
                        Done : Natural;
                     begin
                        if M.Status = Pending then
                           M.Status := Compile_Error;
                           M.Status_Reason := To_Unbounded_String
                             ("build failed: " & To_String (D.Text));
                           Dropped := Dropped + 1;
                           Queue.Finished (Done);
                           if Progress /= null then
                              Progress (Done, Pending_Count, M, Rel (F));
                           end if;
                        end if;
                     end;
                  end if;
               end loop;
            end loop;
            return Dropped;
         end Drop_Compile_Errors;

         Any : Boolean;
      begin
         if Mains.Is_Empty then
            if Warn /= null then
               Warn ("no GNAT ALI file of a main subprogram after the build;"
                     & " every mutant is built on its own");
            end if;
            Free (Schemas);
            return;
         end if;

         loop
            Any := False;
            for F in Schemas'Range loop
               Generate (F);
               Any := Any or else not Schemas (F).Included.Is_Empty;
            end loop;
            exit when not Any;
            Write_Sources (1, Restore => False);
            declare
               B : constant Run_Result :=
                 Run (To_String (S.Build), Slot_Dir (1), Log, 0, Build_TO);
            begin
               exit when not B.Timed_Out and then B.Exit_Code = 0;
               if B.Timed_Out then
                  raise Run_Error with
                    "the build that contains the mutants timed out (log "
                    & Log & ")";
               elsif Drop_Compile_Errors = 0 then
                  raise Run_Error with
                    "the build that contains the mutants fails, and no"
                    & " compiler message is on the lines of one mutant"
                    & " (exit status" & B.Exit_Code'Image & ", log " & Log
                    & ")" & ASCII.LF & Tail (Log, 20);
               end if;
            end;
         end loop;

         if Any then
            for F in Schemas'Range loop
               for Id of Schemas (F).Included loop
                  Combined (Id) := True;
               end loop;
            end loop;
            for Slot in 2 .. Slots loop
               Delete_Tree (Slot_Dir (Slot));
               Copy_Tree (Slot_Dir (1), Slot_Dir (Slot),
                          String_Vectors.Empty_Vector);
            end loop;
            --  With no mutant switched on the tests must pass as before.
            --  This run also measures them: the combined build is slower.
            declare
               Elapsed : Duration;
            begin
               Baseline_Step ("combined-test", To_String (S.Test), 0.0,
                              Elapsed, S.Test_Memory_Limit_Mb, Slots);
               Combined_Test_TO :=
                 Elapsed * Duration (S.Timeout_Factor) + Ms (S.Timeout_Ms);
            end;
            Run_Workers (Combined_Build => True);
         end if;
         for Slot in 1 .. Slots loop
            Write_Sources (Slot, Restore => True);
         end loop;
         Free (Schemas);
      end Run_Combined;
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
      end;

      --  Counted before the NoCoverage check, which needs the files the
      --  baseline test compiles too, so a few sandboxes may stay idle.
      Slots := Positive'Max (1, Natural'Min (S.Concurrency, Pending_Count));
      for Slot in 2 .. Slots loop
         Copy_Tree (Slot_Dir (1), Slot_Dir (Slot), String_Vectors.Empty_Vector);
      end loop;

      declare
         Elapsed : Duration;
      begin
         if Has_Test then
            Baseline_Step ("test", To_String (S.Test), 0.0, Elapsed,
                           S.Test_Memory_Limit_Mb, Slots);
            Test_TO := Elapsed * Duration (S.Timeout_Factor) + Ms (S.Timeout_Ms);
         end if;
         if Has_Prove then
            Baseline_Step ("prove", To_String (S.Prove), 0.0, Elapsed,
                           Slots => Slots);
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

      if Pending_Count > 0 then
         if Has_Test then
            Run_Combined;
         end if;
         --  What is left: mutants that no schema can hold, and the proof
         --  of those that passed the tests of the combined build.
         Run_Workers (Combined_Build => False);
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
