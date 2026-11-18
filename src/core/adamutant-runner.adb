with Ada.Calendar; use Ada.Calendar;
with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Strings.Fixed;
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
      Since    : String := ""; Unchanged_Files : Boolean := False)
      return Report
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
           and then (Since = "" or else Unchanged_Files
                     or else Changes.Contains (Path))
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
                  --  Also when contracts are mutated: the mutations in
                  --  ghost code are known as such.
                  if Spec /= ""
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
                           Failed_Checks => String_Vectors.Empty_Vector,
                           Reached       => Unknown,
                           Covered_By    => String_Vectors.Empty_Vector,
                           Killers       => String_Vectors.Empty_Vector,
                           Tests_Run     => 0,
                           Equivalent    => False,
                           Unchanged     => Unchanged,
                           Reused        => False,
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

   function Severity_Of (Message : String; Text_First : out Positive)
     return String
   is
      --  The severity of a "file:line:col: severity: text" message and the
      --  start of its text, or "".
      Colons : Natural := 0;
      First  : Natural := 0;
   begin
      Text_First := Message'First;
      for K in Message'Range loop
         if Message (K) = ':' then
            Colons := Colons + 1;
            if Colons = 3 then
               First := K + 1;
            elsif Colons = 4 then
               while First < K and then Message (First) = ' ' loop
                  First := First + 1;
               end loop;
               Text_First := K + 1;
               while Text_First <= Message'Last
                 and then Message (Text_First) = ' '
               loop
                  Text_First := Text_First + 1;
               end loop;
               return Message (First .. K - 1);
            end if;
         end if;
      end loop;
      return "";
   end Severity_Of;

   function One_Line_Messages (Log : String) return String is
      --  Log with each message of GNATprove 16 written on one line, as
      --  older versions write it.  GNATprove 16 puts the place on the
      --  next line:
      --
      --   medium: postcondition might fail
      --  --> p.ads:9:17
      --
      --  which becomes "p.ads:9:17: medium: postcondition might fail".
      --  The other lines stay as they are.
      Result : Unbounded_String;
      First  : Positive := Log'First;
      Last   : Natural;

      function Trimmed (S : String) return String is
        (Ada.Strings.Fixed.Trim (S, Ada.Strings.Both));

      function Line_From (From : Positive; Stop : out Natural)
        return String
      is
         --  The line that starts at From, without its end; Stop is the
         --  position of its LF, or Log'Last.
      begin
         Stop := From;
         while Stop <= Log'Last and then Log (Stop) /= ASCII.LF loop
            Stop := Stop + 1;
         end loop;
         declare
            E : Natural := Stop - 1;
         begin
            if E >= From and then Log (E) = ASCII.CR then
               E := E - 1;
            end if;
            Stop := Natural'Min (Stop, Log'Last);
            return Log (From .. E);
         end;
      end Line_From;

      function Severity (L : String) return String is
         --  "medium" for " medium: text", or "".
         T     : constant String := Trimmed (L);
         Colon : constant Natural := Ada.Strings.Fixed.Index (T, ": ");
      begin
         if Colon > T'First
           and then T (T'First .. Colon - 1)
                    in "high" | "medium" | "low" | "error" | "warning"
                     | "info"
         then
            return T (T'First .. Colon - 1);
         end if;
         return "";
      end Severity;
   begin
      while First <= Log'Last loop
         declare
            L    : constant String := Line_From (First, Last);
            Next : Natural;
         begin
            if Severity (L) /= "" and then Last < Log'Last then
               declare
                  N : constant String := Trimmed (Line_From (Last + 1, Next));
               begin
                  if N'Length > 4 and then N (N'First .. N'First + 3) = "--> "
                  then
                     declare
                        T : constant String := Trimmed (L);
                     begin
                        Append (Result, N (N'First + 4 .. N'Last) & ": " & T);
                     end;
                  else
                     Append (Result, L);
                  end if;
               end;
            else
               Append (Result, L);
            end if;
            Append (Result, ASCII.LF);
            First := Last + 1;
         end;
      end loop;
      return To_String (Result);
   end One_Line_Messages;

   function Proof_Failures (Log : String) return String_Vectors.Vector is
      Result : String_Vectors.Vector;
   begin
      for D of AdaMutant.Schemata.Diagnostics (One_Line_Messages (Log)) loop
         declare
            Line  : constant String := To_String (D.Text);
            --  Without what precedes the file name: its directories, or
            --  what a wrapper of the prover puts in front of the line.
            Text  : constant String :=
              Line (Line'First + D.Name_First - 1 .. Line'Last);
            First : Positive;
            Sev   : constant String := Severity_Of (Text, First);
            pragma Unreferenced (First);
         begin
            if Sev in "high" | "medium" | "low" | "error" then
               Result.Append (Text);
            end if;
         end;
      end loop;
      return Result;
   end Proof_Failures;

   function Check_Kind (Message : String) return String is
      First : Positive;
      Sev   : constant String := Severity_Of (Message, First);
      Kind  : Unbounded_String;
      Quote : Boolean := False;
   begin
      if Sev = "error" then
         return "error";
      end if;
      --  The text without the names that it quotes, up to its first comma
      --  or to a reference to the SPARK RM: a kind has to be the same for
      --  every subprogram and object.
      for K in First .. Message'Last loop
         exit when not Quote
           and then (Message (K) = ','
                     or else (K + 9 <= Message'Last
                              and then Message (K .. K + 9) = "(SPARK RM "));
         if Message (K) = '"' then
            Quote := not Quote;
         elsif not Quote
           and then (Message (K) not in ' ' | ASCII.HT
                     or else (Length (Kind) > 0
                              and then Element (Kind, Length (Kind)) /= ' '))
         then
            Append (Kind, (if Message (K) = ASCII.HT then ' ' else Message (K)));
         end if;
      end loop;
      while Length (Kind) > 0 and then Element (Kind, Length (Kind)) = ' ' loop
         Delete (Kind, Length (Kind), Length (Kind));
      end loop;
      declare
         Text  : constant String := To_String (Kind);
         Might : constant Natural := Index (Kind, " might ");
      begin
         if Text = "" then
            return "unknown";
         elsif Index (Kind, "initialized") > 0 then
            --  '"X" might not be initialized', '"X" is not initialized in
            --  "P"', '"B" constituent of "S" is not initialized'.
            return "initialization";
         elsif Index (Kind, "aliased") > 0 then
            --  'formal parameters "X" and "Y" might be aliased', 'formal
            --  parameter "X" and global "G" are aliased'.
            return "aliasing";
         elsif Index (Kind, "Always_Terminates") > 0
           or else Index (Kind, "terminat") > 0
         then
            --  'aspect Always_Terminates on "P" could be incorrect', 'all
            --  paths in "P" raise exceptions or do not terminate normally'.
            return "termination";
         elsif Index (Kind, "Global aspect") > 0 then
            --  '"G" must be listed in the Global aspect of "P"'.
            return "Global aspect";
         elsif Might > 0 then
            return Text (Text'First .. Text'First + Might - 2);
         else
            return Text;
         end if;
      end;
   end Check_Kind;

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
      Warn         : access procedure (Message : String) := null;
      Note         : access procedure (Message : String) := null)
   is
      S        : Configuration renames R.Settings;
      Root     : constant String := To_String (S.Root);
      Work     : constant String := Join (Root, ".adamutant");
      Sandbox  : constant String := Join (Work, "sandbox");
      Logs     : constant String := Join (Work, "logs");
      Started  : constant Time := Clock;
      Build_TO : constant Duration := Ms (S.Build_Timeout_Ms);
      Prove_TO : Duration := 0.0;
      N_Tests  : constant Natural := Natural (S.Tests.Length);
      Has_Test : constant Boolean := N_Tests > 0;
      Test_TO  : array (1 .. N_Tests) of Duration := [others => 0.0];

      function Test_Name (T : Positive) return String is
        (To_String (S.Tests (T).Name));

      function Test_Command (T : Positive) return String is
        (To_String (S.Tests (T).Command));

      function Test_Step (T : Positive) return String is
        (if S.Named_Tests then "test-" & Test_Name (T) else "test");
      --  The name of the step in the names of the logs.
      Has_Prove : constant Boolean := Length (S.Prove) > 0;

      --  The messages of the proof of the unmodified project that would
      --  count as failures, without their lines and columns.  The proof
      --  passes all the same when the command does not treat them as
      --  errors.
      Baseline_Failures : String_Vectors.Vector;

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
      Combined_Test_TO : array (1 .. N_Tests) of Duration := [others => 0.0];

      --  Covers (T, K): test T executes the place of mutant K.  Set for
      --  the mutants whose Reached is Covered.
      type Cover_Matrix is
        array (Positive range <>, Positive range <>) of Boolean;
      type Cover_Matrix_Access is access Cover_Matrix;
      procedure Free is new Ada.Unchecked_Deallocation
        (Cover_Matrix, Cover_Matrix_Access);
      Covers : Cover_Matrix_Access;

      --  The number of the place of each mutant in that build (0 for a
      --  mutant in no place that the build watches), and the mutants that
      --  are not built in whose place cannot be watched either.
      Place     : array (1 .. Natural (R.Mutants.Length)) of Natural :=
        [others => 0];
      Unwatched : Flags := [others => False];

      function Slot_Dir (Slot : Positive) return String is
        (Join (Sandbox, Image (Slot)));

      Coverage_Dir : constant String := Join (Logs, "coverage");
      --  Where the programs of the combined build record the places that
      --  they execute while no mutant is active, a file per process.

      procedure Baseline_Step
        (Name, Command : String; Timeout : Duration; Elapsed : out Duration;
         Memory_Limit_Mb : Natural := 0; Slots : Positive := 1)
      is
         --  The step runs in sandboxes 1 .. Slots at once, as the workers
         --  will run mutants, so Elapsed (the slowest run) includes the
         --  slowdown of running in parallel.
         function Log (Slot : Positive) return String is
           (Join (Logs, "baseline-" & Name
                  & (if Slot = 1 then ""
                     --  The name of a test can end with "-2".
                     elsif S.Named_Tests then "@" & Image (Slot)
                     else "-" & Image (Slot)) & ".log"));

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
                 and then not Tested (Cursor_Combined)
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

      --  The libraries that a sandbox holds after the first build, as
      --  relative paths.  gprbuild takes a library to be up to date when
      --  its time stamp is not older than those of its objects, and time
      --  stamps have whole-second resolution: an object compiled in the
      --  second in which the library was made does not get into it, and
      --  the tests then run the library of the build before.  So a build
      --  starts two seconds after the newest of the libraries was written
      --  (see Wait_For_Libraries).  A library that no build writes again
      --  costs no wait.
      Libraries : String_Vectors.Vector;

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

      procedure Wait_For_Libraries (Slot : Positive) is
      begin
         AdaMutant.Files.Wait_Past_Stamps (Slot_Dir (Slot), Libraries);
      end Wait_For_Libraries;

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

      function Without_Place (Message : String) return String is
         --  A message of Proof_Failures without its line and column: the
         --  mutant may have moved what follows it in the file.
         First : Positive;
         Sev   : constant String := Severity_Of (Message, First);
      begin
         for K in Message'Range loop
            if Message (K) = ':' then
               return Message (Message'First .. K) & " " & Sev & ": "
                 & Message (First .. Message'Last);
            end if;
         end loop;
         return Message;
      end Without_Place;

      procedure Run_Tests
        (Slot : Positive; M : in out Mutant; In_Combined : Boolean)
      is
         --  Runs the tests with M in the sandbox: all of them, or, where
         --  it is known which tests execute the place of M, only those.
         --  M stays Pending when no test detects it.
         Rel      : constant String := To_String (R.Files (M.File).Path);
         Failed   : Boolean := False;
         Timed    : Boolean := False;
         Reason   : Unbounded_String;
      begin
         for T in 1 .. N_Tests loop
            if M.Reached /= Covered or else Covers (T, M.Id) then
               declare
                  Result : constant Run_Result :=
                    Run (Test_Command (T), Slot_Dir (Slot),
                         Join (Logs, "mutant-" & Image (M.Id) & "-"
                                     & Test_Step (T) & ".log"),
                         M.Id,
                         (if In_Combined then Combined_Test_TO (T)
                          else Test_TO (T)),
                         S.Test_Memory_Limit_Mb, Rel);
                  Who    : constant String :=
                    (if S.Named_Tests then "test " & Test_Name (T)
                     else "tests");
               begin
                  M.Tests_Run := M.Tests_Run + 1;
                  if Result.Timed_Out or else Result.Exit_Code /= 0 then
                     M.Killers.Append (Test_Name (T));
                     --  The reason is that of the first test that failed,
                     --  or else of the first that did not finish.
                     if Result.Timed_Out then
                        if Length (Reason) = 0 then
                           Reason := To_Unbounded_String
                             (Who & " did not finish within the timeout");
                        end if;
                        Timed := True;
                     else
                        if not Failed then
                           Reason := To_Unbounded_String
                             (Who & " failed with exit status"
                              & Result.Exit_Code'Image);
                        end if;
                        Failed := True;
                     end if;
                     exit when S.Bail;
                  end if;
               end;
            end if;
         end loop;
         if Failed or else Timed then
            M.Status := (if Failed then Killed else Timeout);
            M.Killed_By := Tests;
            M.Status_Reason := Reason;
         end if;
      end Run_Tests;

      procedure Test_Mutant
        (Slot : Positive; M : in out Mutant; Built, Skip_Tests : Boolean)
      is
         --  Built: the build that contains the mutants has compiled M.
         --  Skip_Tests: the tests have run with M there and passed, or
         --  they do not execute the place of M.
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
                 Mutant_File => Rel));
      begin
         Write_Changed (Path, Apply (Original, M.Mutation));
         if not Built then
            Wait_For_Libraries (Slot);
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
         if M.Status = Pending and then Has_Test and then not Skip_Tests
         then
            Run_Tests (Slot, M, In_Combined => False);
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
                  --  What the log says is an addition: when it cannot be
                  --  read, the mutant is detected all the same.
                  begin
                     declare
                        Failures : String_Vectors.Vector;
                        Known    : String_Vectors.Vector := Baseline_Failures;
                     begin
                        --  A message that the unmodified project has as
                        --  well is not what stops the mutant: each of
                        --  those accounts for one message of the mutant
                        --  with the same text in the same file.
                        for F of Proof_Failures (Read (Log_Base & "-prove.log"))
                        loop
                           declare
                              Found : constant Natural :=
                                Known.Find_Index (Without_Place (F));
                           begin
                              if Found = 0 then
                                 Failures.Append (F);
                              else
                                 Known.Delete (Found);
                              end if;
                           end;
                        end loop;
                        for F of Failures loop
                           if not M.Failed_Checks.Contains (Check_Kind (F))
                           then
                              M.Failed_Checks.Append (Check_Kind (F));
                           end if;
                        end loop;
                        if not Failures.Is_Empty then
                           M.Status_Reason := To_Unbounded_String
                             ("proof failed: " & Failures.First_Element
                              & (if Natural (Failures.Length) > 1
                                 then " (and" & Natural'Image
                                        (Natural (Failures.Length) - 1)
                                      & " more)"
                                 else ""));
                        end if;
                     end;
                  exception
                     when E : others =>
                        M.Failed_Checks.Clear;
                        if Warn /= null then
                           Output.Seize;
                           begin
                              Warn ("cannot read the proof log of mutant "
                                    & Image (M.Id) & " ("
                                    & Ada.Exceptions.Exception_Message (E)
                                    & "); the failed checks are not reported");
                           exception
                              when others =>
                                 Output.Release;
                                 raise;
                           end;
                           Output.Release;
                        end if;
                  end;
               end if;
            end;
         end if;
         if M.Status = Pending then
            M.Status := Survived;
            M.Status_Reason := To_Unbounded_String
              (if M.Reached = Not_Covered then
                  "no test executes this code, and the proof passed"
               elsif Has_Test and then Has_Prove then "tests and proof passed"
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
      begin
         Run_Tests (Slot, M, In_Combined => True);
         if M.Status /= Pending then
            null;
         elsif Has_Prove then
            Tested (Index) := True;
         else
            M.Status := Survived;
            M.Status_Reason := To_Unbounded_String ("tests passed");
         end if;
         M.Elapsed := Clock - T0;
      end Test_Combined;

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
               Test_Mutant (Slot, Work_Items (Index),
                            Built      => Combined (Index),
                            Skip_Tests => Tested (Index));
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
         Main_Texts : String_Vectors.Vector;
         --  The sources of the mains as they are in the sandbox, which is
         --  a copy made when the run started.  The project itself may have
         --  been edited since.
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

         --  The files other than the mains that hold the text of a schema
         --  in the first sandbox.
         Holds_Schema : array (R.Files.First_Index .. R.Files.Last_Index)
           of Boolean := [others => False];

         procedure Generate (F : Positive) is
            Candidates : AdaMutant.Schemata.Candidate_Vectors.Vector;
         begin
            --  A deleted statement stays out.  Where the statement was the
            --  first assignment to a variable, the variable has no value
            --  in the mutant, and an optimizing compiler may then give it
            --  the value that the original statement assigns in the other
            --  alternative: the mutant would do what the original does.
            --  With coverage analysis the build still watches whether the
            --  statement is executed.
            for M of Work_Items.all loop
               if M.File = F and then M.Status = Pending
                 and then
                   (M.Mutation.Kind /= Statement_Deletion
                    or else (S.Coverage_Analysis
                             and then not Unwatched (M.Id)))
               then
                  Candidates.Append
                    (AdaMutant.Schemata.Candidate'
                       (Id          => M.Id,
                        First       => M.Mutation.First,
                        Last        => M.Mutation.Last,
                        Replacement => M.Mutation.Replacement,
                        Probe       =>
                          M.Mutation.Kind = Statement_Deletion));
               end if;
            end loop;
            Schemas (F) := AdaMutant.Schemata.Build
              (To_String (R.Files (F).Source), Candidates, Tag => F);
         end Generate;

         procedure Write_Sources (Slot : Positive; Restore : Boolean) is
            --  The sources of the combined build, or the original ones
            --  again.  A file whose last mutant has left the combined
            --  build gets its original source back at once: its schema
            --  needs the support unit, which later builds do not have.
            Dir : constant String := Slot_Dir (Slot);
         begin
            for F in Schemas'Range loop
               if Is_Main (Rel (F)) then
                  null;
               elsif not Restore and then Length (Schemas (F).Text) > 0 then
                  Write_Changed
                    (Join (Dir, Rel (F)), To_String (Schemas (F).Text));
                  Holds_Schema (F) := True;
               elsif Holds_Schema (F) then
                  --  The other sandboxes are copies of the first.
                  Write_Changed
                    (Join (Dir, Rel (F)), To_String (R.Files (F).Source));
                  if Slot = Slots or else not Restore then
                     Holds_Schema (F) := False;
                  end if;
               end if;
            end loop;
            for K in Mains.First_Index .. Mains.Last_Index loop
               declare
                  Main     : constant String := Mains (K);
                  Original : constant String := Main_Texts (K);
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
                       and then Length (Schemas (F).Text) > 0
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
                     Write (Body_File,
                            AdaMutant.Schemata.Support_Body
                              (Last_Site    => Natural (R.Mutants.Length),
                               Coverage_Dir =>
                                 (if S.Coverage_Analysis then Coverage_Dir
                                  else "")));
                  end if;
               end;
            end loop;
         end Write_Sources;

         function Drop_Compile_Errors return Natural is
            --  Mutants whose own lines the compiler complained about do
            --  not compile; they leave the combined build.  So do the
            --  places that are only watched, without a verdict on their
            --  mutants.
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
                        if M.Mutation.Kind = Statement_Deletion then
                           if not Unwatched (M.Id) then
                              Unwatched (M.Id) := True;
                              Dropped := Dropped + 1;
                           end if;
                        elsif M.Status = Pending then
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

         --  Hit (T, P): test T executed place P.  Recorded (T): a program of
         --  the combined build has written its record.
         Hit      : Cover_Matrix_Access;
         Recorded : array (1 .. N_Tests) of Boolean := [others => False];

         --  The record of a test could not be removed before the next
         --  test ran, so that test seems to execute what the one before
         --  executed.
         Stale : Boolean := False;

         procedure Collect (T : Positive) is
            --  Test T has just run in the combined build with no mutant
            --  active: read what its programs recorded.
            Records : constant String_Vectors.Vector :=
              (if Ada.Directories.Exists (Coverage_Dir)
               then Find_Files (Coverage_Dir, String_Vectors.Empty_Vector)
               else String_Vectors.Empty_Vector);
            Merged  : Unbounded_String;
         begin
            for Name of Records loop
               declare
                  Text  : constant String := Read (Join (Coverage_Dir, Name));
                  Value : Natural := 0;
                  Valid : Boolean := False;
               begin
                  for C of Text loop
                     if C in '0' .. '9' then
                        if Value <= Work_Items'Last then
                           Value := Value * 10
                             + (Character'Pos (C) - Character'Pos ('0'));
                        end if;
                        Valid := True;
                     else
                        if Valid then
                           --  0 is the line that every process writes.
                           Recorded (T) := True;
                           if Value in Work_Items'Range then
                              Hit (T, Value) := True;
                           end if;
                        end if;
                        Value := 0;
                        Valid := False;
                     end if;
                  end loop;
               end;
            end loop;
            for K in Work_Items'Range loop
               if Hit (T, K) then
                  Append (Merged, Image (K) & ASCII.LF);
               end if;
            end loop;
            Write (Join (Logs,
                         (if S.Named_Tests
                          then "coverage-" & Test_Name (T) & ".txt"
                          else "coverage.txt")),
                   To_String (Merged));
            --  A program that the test command left running may still
            --  hold its file open, which stops the deletion on Windows.
            --  After the last test the directory does no harm where it
            --  is.  Before another test it does: that test would seem to
            --  have recorded what this one recorded.
            begin
               Delete_Tree (Coverage_Dir);
            exception
               when File_Error =>
                  Stale := Stale or else T < N_Tests;
            end;
         end Collect;

         procedure Skip_Uncovered is
            --  The tests of the unmodified project have run in the
            --  combined build.  They cannot detect a mutant in a place that
            --  they do not execute.
            Silent : Unbounded_String;
         begin
            --  A test that has recorded nothing ran no program that
            --  contains the support unit, or none that could write its
            --  file.  What it executes is not known then, and neither is
            --  what it needs of the other tests, so no test is left out
            --  for any mutant.
            for T in 1 .. N_Tests loop
               if not Recorded (T) then
                  Append (Silent, (if Length (Silent) > 0 then ", " else "")
                          & "'" & Test_Name (T) & "'");
               end if;
            end loop;
            if Length (Silent) > 0 or else Stale then
               if Warn /= null then
                  Warn ((if Length (Silent) = 0 then
                            "the record of the code that a test executes"
                            & " could not be removed before the next test"
                         elsif not S.Named_Tests then
                            "the test programs recorded nothing about the"
                            & " code that they execute"
                         else
                            "the programs of the tests " & To_String (Silent)
                            & " recorded nothing about the code that they"
                            & " execute")
                        & "; coverage analysis is off for this run");
               end if;
               Free (Hit);
               return;
            end if;
            Covers := new Cover_Matrix'
              [1 .. N_Tests => [1 .. Work_Items'Last => False]];
            for K in Work_Items'Range loop
               declare
                  M    : Mutant renames Work_Items (K);
                  Done : Natural;
               begin
                  if M.Status = Pending and then Place (K) /= 0 then
                     for T in 1 .. N_Tests loop
                        if Hit (T, Place (K)) then
                           Covers (T, K) := True;
                           M.Covered_By.Append (Test_Name (T));
                        end if;
                     end loop;
                     if not M.Covered_By.Is_Empty then
                        M.Reached := Covered;
                     else
                        M.Reached := Not_Covered;
                        if Has_Prove then
                           Tested (K) := True;
                        else
                           M.Status := No_Coverage;
                           M.Status_Reason := To_Unbounded_String
                             ("no test executes this code");
                           Queue.Finished (Done);
                           if Progress /= null then
                              Progress (Done, Pending_Count, M, Rel (M.File));
                           end if;
                        end if;
                     end if;
                  end if;
               end;
            end loop;
            Free (Hit);
         end Skip_Uncovered;

         Any : Boolean;
      begin
         for Main of Mains loop
            Main_Texts.Append (Read (Join (Slot_Dir (1), Main)));
         end loop;
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
               Any := Any or else Length (Schemas (F).Text) > 0;
            end loop;
            exit when not Any;
            Write_Sources (1, Restore => False);
            Wait_For_Libraries (1);
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
               for Site of Schemas (F).Sites loop
                  Place (Site.Id) := Site.Number;
               end loop;
            end loop;
            for Slot in 2 .. Slots loop
               Delete_Tree (Slot_Dir (Slot));
               Copy_Tree (Slot_Dir (1), Slot_Dir (Slot),
                          String_Vectors.Empty_Vector);
            end loop;
            --  With no mutant switched on the tests must pass as before.
            --  This run also measures them: the combined build is slower.
            if S.Coverage_Analysis then
               Hit := new Cover_Matrix'
                 [1 .. N_Tests => [1 .. Work_Items'Last => False]];
            end if;
            for T in 1 .. N_Tests loop
               declare
                  Elapsed : Duration;
               begin
                  if S.Coverage_Analysis then
                     Ada.Directories.Create_Path (Coverage_Dir);
                  end if;
                  Baseline_Step ("combined-" & Test_Step (T),
                                 Test_Command (T), 0.0,
                                 Elapsed, S.Test_Memory_Limit_Mb, Slots);
                  Combined_Test_TO (T) :=
                    Elapsed * Duration (S.Timeout_Factor) + Ms (S.Timeout_Ms);
                  if S.Coverage_Analysis then
                     Collect (T);
                  end if;
               end;
            end loop;
            if S.Coverage_Analysis then
               Skip_Uncovered;
            end if;
            Run_Workers (Combined_Build => True);
         end if;
         for Slot in 1 .. Slots loop
            Write_Sources (Slot, Restore => True);
         end loop;
         Free (Schemas);
      end Run_Combined;
      procedure Find_Equivalent is
         --  A survivor that the equivalence_build command compiles to the
         --  object files of the unmodified project is the same program as
         --  the unmodified project: no test can tell the two apart.
         package Digest_Maps is new Ada.Containers.Indefinite_Ordered_Maps
           (String, String);
         use type Digest_Maps.Map;

         Command : constant String := To_String (S.Equivalence_Build);
         Log     : constant String := Join (Logs, "equivalence-build.log");

         function Has_Extension (Path, Extension : String) return Boolean is
           (Path'Length > Extension'Length
            and then Ada.Characters.Handling.To_Lower
                       (Path (Path'Last - Extension'Length + 1 .. Path'Last))
                     = Extension);

         function Is_Object (Path : String) return Boolean is
           ((Has_Extension (Path, ".o") or else Has_Extension (Path, ".obj"))
            and then
              --  Not what the binder makes ("b__main.o", "b~main.o"): it
              --  holds a version of every unit, which differs for every
              --  mutant.  No unit has such a name ("b_utils.o" is one).
              not (Base_Name (Path)'Length > 3
                   and then (Base_Name (Path) (1 .. 3) = "b__"
                             or else Base_Name (Path) (1 .. 2) = "b~")));

         function Dependents (Dir, Source : String) return Digest_Maps.Map is
            --  What each GNAT ALI file under Dir says about the time stamp
            --  and the checksum of Source, a base name in lower case: its
            --  line "D source stamp checksum".  A unit that is compiled
            --  after Source has changed gets another line.
            Result : Digest_Maps.Map;
         begin
            for Path of Find_Files (Dir, String_Vectors.Empty_Vector) loop
               if Has_Extension (Path, ".ali") then
                  declare
                     Text  : constant String := Read (Join (Dir, Path));
                     First : Positive := Text'First;
                     Last  : Natural;
                  begin
                     while First <= Text'Last loop
                        Last := First;
                        while Last <= Text'Last and then Text (Last) /= ASCII.LF
                        loop
                           Last := Last + 1;
                        end loop;
                        if Last - First > 2 + Source'Length
                          and then Text (First .. First + 1) = "D "
                          and then Ada.Characters.Handling.To_Lower
                                     (Text (First + 2
                                            .. First + 1 + Source'Length))
                                   = Source
                          and then Text (First + 2 + Source'Length)
                                   in ' ' | ASCII.HT
                        then
                           Result.Include (Path, Text (First .. Last - 1));
                        end if;
                        First := Last + 1;
                     end loop;
                  end;
               end if;
            end loop;
            return Result;
         end Dependents;

         function Objects (Dir : String) return Digest_Maps.Map is
            Result : Digest_Maps.Map;
         begin
            for Path of Find_Files (Dir, String_Vectors.Empty_Vector) loop
               if Is_Object (Path) then
                  Result.Insert (Path, Digest (Join (Dir, Path)));
               end if;
            end loop;
            return Result;
         end Objects;

         procedure Remove_Objects (Dir : String) is
            --  The objects in Dir come from the build command, and a
            --  builder may take them to be up to date although the
            --  equivalence_build command has other switches (gprbuild
            --  does, without -s).  Without them, and without the ALI
            --  files that describe them, everything is compiled anew.
         begin
            for Path of Find_Files (Dir, String_Vectors.Empty_Vector) loop
               if Is_Object (Path) or else Has_Extension (Path, ".ali") then
                  Ada.Directories.Delete_File (Join (Dir, Path));
               end if;
            end loop;
         end Remove_Objects;

         Survivors : Natural := 0;
         Base      : Digest_Maps.Map;

         function Examined (M : Mutant) return Boolean is
           (M.Status = Survived and then not M.Mutation.Contract
            and then not M.Reused);
         --  The survivors that can be equivalent mutants by their object
         --  code.  A mutant of a contract leaves no trace in the objects
         --  unless assertions are enabled, and is another contract all the
         --  same.  A result taken from an earlier run stays as it is.

         --  Copies of the object files of the unmodified project.
         Store : constant String := Join (Sandbox, "equivalence-base");

         procedure Keep_Objects (Dir : String) is
         begin
            for C in Base.Iterate loop
               declare
                  Target : constant String :=
                    Join (Store, Digest_Maps.Key (C));
               begin
                  Ada.Directories.Create_Path
                    (Ada.Directories.Containing_Directory (Target));
                  Ada.Directories.Copy_File
                    (Join (Dir, Digest_Maps.Key (C)), Target,
                     "mode=overwrite,preserve=all_attributes");
               end;
            end loop;
         end Keep_Objects;

         procedure Copy_Back (Dir, Name : String) is
         begin
            Ada.Directories.Create_Path
              (Ada.Directories.Containing_Directory (Join (Dir, Name)));
            Ada.Directories.Copy_File
              (Join (Store, Name), Join (Dir, Name),
               "mode=overwrite,preserve=all_attributes");
         end Copy_Back;

         procedure Reset_Objects (Dir : String; Now : Digest_Maps.Map) is
            --  Now is what a build with a mutant has left in Dir.  A
            --  command that only compiles what has changed since its last
            --  run (gprbuild) replaces the objects of the mutant by itself
            --  once the source is the original again, but a command that
            --  only compiles the mutated file does not, and the objects
            --  of this mutant would make the next one look different.
         begin
            for C in Now.Iterate loop
               declare
                  Name : constant String := Digest_Maps.Key (C);
               begin
                  if not Base.Contains (Name) then
                     Ada.Directories.Delete_File (Join (Dir, Name));
                  elsif Base (Name) /= Digest_Maps.Element (C) then
                     Copy_Back (Dir, Name);
                  end if;
               end;
            end loop;
            for C in Base.Iterate loop
               declare
                  Name : constant String := Digest_Maps.Key (C);
               begin
                  if not Now.Contains (Name) then
                     Copy_Back (Dir, Name);
                  end if;
               end;
            end loop;
         end Reset_Objects;

         --  The files that the command is known to compile.
         Compiled : array (R.Files.First_Index .. R.Files.Last_Index)
           of Boolean := [others => False];

         type Outcome is (Failed, Not_Rebuilt, Same, Different);

         function Build_With
           (Slot : Positive; M : Mutant; Log_Name : String) return Outcome
         is
            --  What the command makes of the sources with M: nothing, not
            --  every unit that depends on the file of M anew, the object
            --  files of the unmodified project, or other ones.
            Dir      : constant String := Slot_Dir (Slot);
            Rel      : constant String := To_String (R.Files (M.File).Path);
            Path     : constant String := Join (Dir, Rel);
            Original : constant String := To_String (R.Files (M.File).Source);
            B        : Run_Result;
            Now      : Digest_Maps.Map;
            Result   : Outcome;
            --  The units that depend on the file, as they were compiled
            --  before.
            Before   : constant Digest_Maps.Map :=
              Dependents (Dir, Base_Name (Rel));
            After    : Digest_Maps.Map;
            Rebuilt  : Boolean;
         begin
            Write_Changed (Path, Apply (Original, M.Mutation));
            B := Run (Command, Dir, Join (Logs, Log_Name), M.Id, Build_TO,
                      Mutant_File => Rel);
            Now := Objects (Dir);
            After := Dependents (Dir, Base_Name (Rel));
            --  The mutant can show in the object of any unit that depends
            --  on the file (a constant of a specification, a generic or
            --  inlined body).  A command that has not compiled all of them
            --  again says nothing about the mutant.
            Rebuilt := not After.Is_Empty;
            for C in After.Iterate loop
               Rebuilt := Rebuilt
                 and then (not Before.Contains (Digest_Maps.Key (C))
                           or else Before (Digest_Maps.Key (C))
                                   /= Digest_Maps.Element (C));
            end loop;
            --  A unit that depended on the file before still does.
            for C in Before.Iterate loop
               Rebuilt := Rebuilt and then After.Contains (Digest_Maps.Key (C));
            end loop;
            Result :=
              (if B.Timed_Out or else B.Exit_Code /= 0 then Failed
               elsif not Rebuilt then Not_Rebuilt
               elsif Now = Base then Same else Different);
            Write_Changed (Path, Original);
            if Now /= Base then
               Reset_Objects (Dir, Now);
            end if;
            return Result;
         end Build_With;

         procedure Check_Command (F : Positive; Why : out Outcome) is
            --  A mutant that the tests or the proof detect is not the
            --  program that the unmodified project is, so the command has
            --  to make other object files of it.  Where it does not, it
            --  does not compile the file (or leaves its objects somewhere
            --  else), and identical object files would mean nothing.  A
            --  few mutants are tried, those that the tests detect first;
            --  not the mutants of contracts, which leave no trace in the
            --  objects unless assertions are enabled.  Why is the outcome
            --  of the last one, Same when there is none to try.
            Tried : Natural := 0;
         begin
            Why := Same;
            for By in Tests .. Proof loop
               for M of Work_Items.all loop
                  exit when Tried = 3;
                  if M.File = F and then M.Status = Killed
                    and then M.Killed_By = By
                    and then not M.Mutation.Contract
                  then
                     Tried := Tried + 1;
                     Why := Build_With
                       (1, M, "equivalence-check-" & Image (M.Id) & ".log");
                     if Why = Different then
                        Compiled (F) := True;
                        return;
                     end if;
                  end if;
               end loop;
            end loop;
         end Check_Command;

         protected Survivor_Queue is
            procedure Next (Index : out Natural);
            procedure Fail (Message : String);
            function Failure return String;
         private
            Cursor  : Natural := 0;
            Problem : Unbounded_String;
         end Survivor_Queue;

         protected body Survivor_Queue is
            procedure Next (Index : out Natural) is
            begin
               Index := 0;
               if Length (Problem) > 0 then
                  return;
               end if;
               while Cursor < Work_Items'Last loop
                  Cursor := Cursor + 1;
                  if Examined (Work_Items (Cursor))
                    and then Compiled (Work_Items (Cursor).File)
                  then
                     Index := Cursor;
                     return;
                  end if;
               end loop;
            end Next;

            procedure Fail (Message : String) is
            begin
               if Length (Problem) = 0 then
                  Problem := To_Unbounded_String (Message);
               end if;
            end Fail;

            function Failure return String is (To_String (Problem));
         end Survivor_Queue;

         procedure Compare (Slot : Positive; M : in out Mutant) is
            T0 : constant Time := Clock;
         begin
            if Build_With
              (Slot, M, "mutant-" & Image (M.Id) & "-equivalence.log") = Same
            then
               M.Status := Ignored;
               M.Equivalent := True;
               M.Status_Reason := To_Unbounded_String
                 ("equivalent mutant: the object code is the same as that of"
                  & " the unmodified project");
            end if;
            M.Elapsed := M.Elapsed + (Clock - T0);
         end Compare;

         task type Comparer (Slot : Positive)
           with Storage_Size => 64 * 1024 * 1024;

         task body Comparer is
            Index : Natural;
         begin
            loop
               Survivor_Queue.Next (Index);
               exit when Index = 0;
               Compare (Slot, Work_Items (Index));
            end loop;
         exception
            when E : others =>
               Survivor_Queue.Fail
                 ("sandbox" & Slot'Image & ": "
                  & Ada.Exceptions.Exception_Information (E));
         end Comparer;

         type Comparer_Access is access Comparer;
      begin
         --  The survivors of this run: a result taken from an earlier run
         --  stays as it is.
         for M of Work_Items.all loop
            if Examined (M) then
               Survivors := Survivors + 1;
            end if;
         end loop;
         if Survivors = 0 then
            return;
         end if;
         if Note /= null then
            Note ("Looking for equivalent mutants among" & Survivors'Image
                  & (if Survivors = 1 then " survivor..." else " survivors..."));
         end if;

         --  Every sandbox holds the unmodified sources again.  The objects
         --  in them are what the last mutants left: the command makes
         --  those of the first sandbox anew, and the other sandboxes start
         --  as copies of it.
         Remove_Objects (Slot_Dir (1));
         declare
            B : constant Run_Result :=
              Run (Command, Slot_Dir (1), Log, 0, Build_TO);
         begin
            if B.Timed_Out or else B.Exit_Code /= 0 then
               if Warn /= null then
                  Warn ("the equivalence_build command "
                        & (if B.Timed_Out then "timed out"
                           else "fails (exit status" & B.Exit_Code'Image & ")")
                        & " on the unmodified project (log " & Log
                        & "); equivalent mutants are not looked for");
               end if;
               return;
            end if;
         end;
         Base := Objects (Slot_Dir (1));
         if Base.Is_Empty then
            if Warn /= null then
               Warn ("the equivalence_build command leaves no object file;"
                     & " equivalent mutants are not looked for");
            end if;
            return;
         end if;
         Keep_Objects (Slot_Dir (1));

         Survivors := 0;
         for F in Compiled'Range loop
            declare
               Here : Natural := 0;
               Why  : Outcome;
            begin
               for M of Work_Items.all loop
                  if M.File = F and then Examined (M) then
                     Here := Here + 1;
                  end if;
               end loop;
               if Here > 0 then
                  Check_Command (F, Why);
                  if Compiled (F) then
                     Survivors := Survivors + Here;
                  elsif Warn /= null then
                     Warn ("the equivalence_build command "
                           & (case Why is
                                 when Failed      =>
                                   "fails for detected mutants of ",
                                 when Not_Rebuilt =>
                                   "does not compile every unit that depends"
                                   & " on the file again for detected"
                                   & " mutants of ",
                                 when others      =>
                                   "makes the same object files of detected"
                                   & " mutants of ")
                           & To_String (R.Files (F).Path)
                           & (if Why = Same
                              then ", or there is none to try" else "")
                           & "; its survivors are not examined");
                  end if;
               end if;
            end;
         end loop;
         if Survivors = 0 then
            return;
         end if;

         declare
            Comparers : array (1 .. Natural'Min (Slots, Survivors))
              of Comparer_Access;
         begin
            for Slot in 2 .. Comparers'Last loop
               Delete_Tree (Slot_Dir (Slot));
               Copy_Tree (Slot_Dir (1), Slot_Dir (Slot),
                          String_Vectors.Empty_Vector);
            end loop;
            for K in Comparers'Range loop
               Comparers (K) := new Comparer (K);
            end loop;
            for C of Comparers loop
               while not C'Terminated loop
                  delay 0.05;
               end loop;
            end loop;
         end;
         if Survivor_Queue.Failure /= "" then
            raise Run_Error with Survivor_Queue.Failure;
         end if;
      end Find_Equivalent;
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
         for T in 1 .. N_Tests loop
            Baseline_Step (Test_Step (T), Test_Command (T), 0.0, Elapsed,
                           S.Test_Memory_Limit_Mb, Slots);
            Test_TO (T) :=
              Elapsed * Duration (S.Timeout_Factor) + Ms (S.Timeout_Ms);
         end loop;
         if Has_Prove then
            Baseline_Step ("prove", To_String (S.Prove), 0.0, Elapsed,
                           Slots => Slots);
            Prove_Ended := [others => Clock];
            Prove_TO :=
              Elapsed * Duration (S.Timeout_Factor) + Ms (S.Timeout_Ms);
            for F of Proof_Failures (Read (Join (Logs, "baseline-prove.log")))
            loop
               Baseline_Failures.Append (Without_Place (F));
            end loop;
         end if;
      end;

      --  The libraries, after the tests too: a test command may build one.
      for Path of Find_Files (Slot_Dir (1), String_Vectors.Empty_Vector) loop
         declare
            Name : constant String := Base_Name (Path);

            function Ends_With (Extension : String) return Boolean is
              (Name'Length > Extension'Length
               and then Name (Name'Last - Extension'Length + 1 .. Name'Last)
                        = Extension);
         begin
            --  A shared library may have a version after ".so".
            if Ends_With (".a") or else Ends_With (".lib")
              or else Ends_With (".so") or else Ends_With (".dll")
              or else Ends_With (".dylib")
              or else Ada.Strings.Fixed.Index (Name, ".so.") > 0
            then
               Libraries.Append (Path);
            end if;
         end;
      end loop;

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
         if Length (S.Equivalence_Build) > 0 then
            --  Whatever goes wrong here, the mutants have run: their
            --  results stay, and so do the equivalent mutants found so far.
            begin
               Find_Equivalent;
            exception
               when E : others =>
                  if Warn /= null then
                     Warn ("the search for equivalent mutants has stopped: "
                           & Ada.Exceptions.Exception_Name (E) & ": "
                           & Ada.Exceptions.Exception_Message (E));
                  end if;
            end;
         end if;
      end if;

      for K in Work_Items'Range loop
         R.Mutants.Replace_Element (K, Work_Items (K));
      end loop;
      Free (Work_Items);
      Free (Covers);
      R.Elapsed := Clock - Started;
      if not Keep_Sandbox then
         Delete_Tree (Sandbox);
      end if;
   end Execute;

end AdaMutant.Runner;
