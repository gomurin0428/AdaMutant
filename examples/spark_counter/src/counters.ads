package Counters with SPARK_Mode is

   Max : constant := 100;

   subtype Count is Natural range 0 .. Max;

   function Increment (C : Count) return Count
   with Pre  => C < Max,
        Post => Increment'Result = C + 1;

   function Saturating_Add (A, B : Count) return Count
   with Post =>
     (if A + B <= Max then Saturating_Add'Result = A + B
      else Saturating_Add'Result = Max);

end Counters;
