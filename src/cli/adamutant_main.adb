with Ada.Command_Line; use Ada.Command_Line;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO; use Ada.Text_IO;
with AdaMutant.Config;
with AdaMutant.Files;
with AdaMutant.Mutators;
with AdaMutant.Reports;
with AdaMutant.Results; use AdaMutant.Results;
with AdaMutant.Runner;

procedure AdaMutant_Main is

   Exit_Error     : constant Exit_Status := 1;
   Exit_Threshold : constant Exit_Status := 2;

   Usage_Error : exception;

   procedure Usage is
   begin
      Put_Line ("Usage: adamutant <command> [options]");
      New_Line;
      Put_Line ("Commands:");
      Put_Line ("  run    build and test every mutant, write the reports");
      Put_Line ("  list   list the mutants without running anything");
      Put_Line ("  init   write a commented " & AdaMutant.Config.Default_File_Name);
      New_Line;
      Put_Line ("Options:");
      Put_Line ("  --config FILE       configuration file (default "
                & AdaMutant.Config.Default_File_Name & ")");
      Put_Line ("  --mutate GLOB       only mutate matching files (repeatable)");
      Put_Line ("  --concurrency N     number of parallel sandboxes");
      Put_Line ("  --keep-sandbox      keep .adamutant/sandbox after the run");
      Put_Line ("  --help, --version");
   end Usage;

   function Image (N : Integer) return String is
     (Ada.Strings.Fixed.Trim (N'Image, Ada.Strings.Both));

   Command      : Unbounded_String;
   Config_Path  : Unbounded_String :=
     To_Unbounded_String (AdaMutant.Config.Default_File_Name);
   Only         : AdaMutant.Files.String_Vectors.Vector;
   Concurrency  : Natural := 0;
   Keep_Sandbox : Boolean := False;

   procedure Parse_Arguments is
      K : Positive := 1;

      function Value return String is
      begin
         if K = Argument_Count then
            raise Usage_Error with Argument (K) & " needs a value";
         end if;
         K := K + 1;
         return Argument (K);
      end Value;
   begin
      while K <= Argument_Count loop
         declare
            A : constant String := Argument (K);
         begin
            if A = "--config" then
               Config_Path := To_Unbounded_String (Value);
            elsif A = "--mutate" then
               Only.Append (Value);
            elsif A = "--concurrency" then
               begin
                  Concurrency := Natural'Value (Value);
               exception
                  when Constraint_Error =>
                     Concurrency := 0;
               end;
               if Concurrency = 0 then
                  raise Usage_Error with "--concurrency needs a positive number";
               end if;
            elsif A = "--keep-sandbox" then
               Keep_Sandbox := True;
            elsif A'Length > 0 and then A (A'First) = '-' then
               raise Usage_Error with "unknown option " & A;
            elsif Length (Command) = 0 then
               Command := To_Unbounded_String (A);
            else
               raise Usage_Error with "unexpected argument " & A;
            end if;
         end;
         K := K + 1;
      end loop;
   end Parse_Arguments;

   procedure Warn (Message : String) is
   begin
      Put_Line ("warning: " & Message);
   end Warn;

   procedure Progress
     (Done, Total : Natural; M : AdaMutant.Results.Mutant; File : String) is
   begin
      Put_Line ("[" & Image (Done) & "/" & Image (Total) & "] "
                & Name (M.Status) & " #" & Image (M.Id) & " " & File & ":"
                & Image (M.Start_Pos.Line) & " "
                & AdaMutant.Mutators.Name (M.Mutation.Kind));
   end Progress;

   function Load return AdaMutant.Config.Configuration is
      C : AdaMutant.Config.Configuration :=
        AdaMutant.Config.Load (To_String (Config_Path));
   begin
      if Concurrency > 0 then
         C.Concurrency := Concurrency;
      end if;
      return C;
   end Load;

   procedure Do_List is
      R : constant Report := AdaMutant.Runner.Discover (Load, Only);
   begin
      for M of R.Mutants loop
         Put_Line ("#" & Image (M.Id) & " "
                   & To_String (R.Files (M.File).Path) & ":"
                   & Image (M.Start_Pos.Line) & ":"
                   & Image (M.Start_Pos.Column) & " "
                   & AdaMutant.Mutators.Name (M.Mutation.Kind) & " "
                   & To_String (M.Original) & " -> "
                   & To_String (M.Mutation.Replacement)
                   & (if M.Status = Ignored then " (ignored)" else ""));
      end loop;
      Put_Line (Image (Natural (R.Mutants.Length)) & " mutants in"
                & Natural (R.Files.Length)'Image & " files");
   end Do_List;

   procedure Do_Run is
      R : Report := AdaMutant.Runner.Discover (Load, Only);
      Report_Dir : constant String := AdaMutant.Files.Join
        (To_String (R.Settings.Root), To_String (R.Settings.Report_Dir));
   begin
      Put_Line ("AdaMutant " & AdaMutant.Version & ": "
                & Image (Natural (R.Mutants.Length)) & " mutants in"
                & Natural (R.Files.Length)'Image & " files, concurrency"
                & R.Settings.Concurrency'Image);
      Put_Line ("Building and testing the unmodified project...");
      AdaMutant.Runner.Execute (R, Keep_Sandbox, Progress'Access, Warn'Access);

      if R.Settings.Json_Report or else R.Settings.Html_Report then
         Ada.Directories.Create_Path (Report_Dir);
      end if;
      if R.Settings.Json_Report then
         AdaMutant.Files.Write (AdaMutant.Files.Join (Report_Dir,
                                "mutation-report.json"),
                                AdaMutant.Reports.Json (R));
      end if;
      if R.Settings.Html_Report then
         AdaMutant.Files.Write (AdaMutant.Files.Join (Report_Dir,
                                "mutation-report.html"),
                                AdaMutant.Reports.Html (R));
      end if;
      if R.Settings.Console_Report then
         AdaMutant.Reports.Print_Console (R);
      end if;

      declare
         C : constant Status_Counts := AdaMutant.Results.Count (R);
      begin
         New_Line;
         Put_Line ("Mutation score: " & Score_Image (C) & "% ("
                   & Image (Detected (C)) & " detected, "
                   & Image (Undetected (C)) & " undetected, "
                   & Image (C (Compile_Error)) & " compile errors, "
                   & Image (C (Ignored)) & " ignored) in"
                   & Integer (R.Elapsed)'Image & " s");
         if R.Settings.Json_Report or else R.Settings.Html_Report then
            Put_Line ("Reports: " & Report_Dir);
         end if;
         if Has_Score (C) and then Score (C) < Float (R.Settings.Break) then
            Put_Line (Standard_Error,
                      "error: the mutation score is below the break threshold"
                      & R.Settings.Break'Image & "%");
            Set_Exit_Status (Exit_Threshold);
         end if;
      end;
   end Do_Run;

   procedure Do_Init is
      Path : constant String := To_String (Config_Path);
   begin
      if Ada.Directories.Exists (Path) then
         raise Usage_Error with Path & " already exists";
      end if;
      AdaMutant.Files.Write (Path, AdaMutant.Config.Template);
      Put_Line ("Wrote " & Path);
   end Do_Init;

begin
   for K in 1 .. Argument_Count loop
      if Argument (K) in "--help" | "-h" then
         Usage;
         return;
      elsif Argument (K) = "--version" then
         Put_Line ("AdaMutant " & AdaMutant.Version);
         return;
      end if;
   end loop;

   Parse_Arguments;
   if Command = "run" then
      Do_Run;
   elsif Command = "list" then
      Do_List;
   elsif Command = "init" then
      Do_Init;
   elsif Length (Command) = 0 then
      Usage;
      Set_Exit_Status (Exit_Error);
   else
      raise Usage_Error with "unknown command " & To_String (Command);
   end if;
exception
   when E : Usage_Error =>
      Put_Line (Standard_Error, "error: " & Ada.Exceptions.Exception_Message (E));
      Put_Line (Standard_Error, "Run 'adamutant --help' for usage.");
      Set_Exit_Status (Exit_Error);
   when E : AdaMutant.Config.Config_Error
      | AdaMutant.Runner.Run_Error
      | AdaMutant.Files.File_Error =>
      Put_Line (Standard_Error, "error: " & Ada.Exceptions.Exception_Message (E));
      Set_Exit_Status (Exit_Error);
end AdaMutant_Main;
