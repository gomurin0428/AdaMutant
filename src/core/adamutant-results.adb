package body AdaMutant.Results is

   function Name (S : Mutant_Status) return String is
     (case S is
         when Pending       => "Pending",
         when Killed        => "Killed",
         when Survived      => "Survived",
         when No_Coverage   => "NoCoverage",
         when Timeout       => "Timeout",
         when Compile_Error => "CompileError",
         when Runtime_Error => "RuntimeError",
         when Ignored       => "Ignored");

   function Count (R : Report) return Status_Counts is
      C : Status_Counts := [others => 0];
   begin
      for M of R.Mutants loop
         C (M.Status) := C (M.Status) + 1;
      end loop;
      return C;
   end Count;

   function Count (R : Report; File : Positive) return Status_Counts is
      C : Status_Counts := [others => 0];
   begin
      for M of R.Mutants loop
         if M.File = File then
            C (M.Status) := C (M.Status) + 1;
         end if;
      end loop;
      return C;
   end Count;

   function Score_Image (C : Status_Counts) return String is
   begin
      if not Has_Score (C) then
         return "n/a";
      end if;
      declare
         Hundredths : constant Natural := Natural (Score (C) * 100.0);
         Whole      : constant String := Natural'Image (Hundredths / 100);
         Frac       : constant String :=
           Natural'Image (100 + Hundredths mod 100);
      begin
         return Whole (Whole'First + 1 .. Whole'Last) & "."
           & Frac (Frac'Last - 1 .. Frac'Last);
      end;
   end Score_Image;

end AdaMutant.Results;
