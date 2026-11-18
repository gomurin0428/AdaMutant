with Ada.Command_Line;
with Counters;

--  A deliberately small test: it only calls Increment.  The mutants of
--  Saturating_Add are left to the proof.
procedure Test_Counters is
begin
   if Counters.Increment (4) not in 5 then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end Test_Counters;
