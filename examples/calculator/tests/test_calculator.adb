with Ada.Command_Line;
with Ada.Text_IO;
with Calculator; use Calculator;

--  Deliberately incomplete tests: boundaries of Clamp and Grade are not
--  checked, so AdaMutant reports surviving mutants there.
procedure Test_Calculator is
   Failures : Natural := 0;

   procedure Check (Condition : Boolean; Name : String) is
   begin
      if not Condition then
         Ada.Text_IO.Put_Line ("FAIL: " & Name);
         Failures := Failures + 1;
      end if;
   end Check;
begin
   Check (Add (2, 3) = 5, "Add");
   Check (Max (1, 7) = 7, "Max right");
   Check (Max (9, 4) = 9, "Max left");
   Check (Clamp (-5, 0, 10) = 0, "Clamp low");
   Check (Clamp (50, 0, 10) = 10, "Clamp high");
   Check (Clamp (5, 0, 10) = 5, "Clamp inside");
   Check (Is_Even (4), "Is_Even");
   Check (Grade (95) = "A", "Grade A");
   Check (Grade (10) = "C", "Grade C");
   Check (Sum_To (4) = 10, "Sum_To");

   if Failures > 0 then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   else
      Ada.Text_IO.Put_Line ("all tests passed");
   end if;
end Test_Calculator;
