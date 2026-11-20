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

   function Name (S : Suggestion_Status) return String is
     (case S is
         when No_Suggestion => "none",
         when Ineligible   => "ineligible",
         when Unsupported  => "unsupported",
         when Failed       => "failed",
         when Verified     => "verified");

   function Name (S : Verification_Outcome) return String is
     (case S is
         when Not_Run       => "not_run",
         when Passed        => "passed",
         when Failed        => "failed",
         when Build_Failed  => "build_failed",
         when Timed_Out     => "timed_out",
         when Spawn_Failed  => "spawn_failed",
         when Invalid_Output => "invalid_output");

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

   function Proof_Timed_Out (M : Mutant) return Boolean is
     (M.Status = Survived
      and then Index (M.Status_Reason, Proof_Unfinished) > 0);

end AdaMutant.Results;
