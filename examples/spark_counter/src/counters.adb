package body Counters with SPARK_Mode is

   function Increment (C : Count) return Count is
   begin
      return C + 1;
   end Increment;

   function Saturating_Add (A, B : Count) return Count is
   begin
      if A + B > Max then
         return Max;
      else
         return A + B;
      end if;
   end Saturating_Add;

end Counters;
