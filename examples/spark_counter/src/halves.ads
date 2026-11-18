package Halves with SPARK_Mode is

   subtype Count is Natural range 0 .. 100;

   --  The body returns X / 2; the contract only says that the result is
   --  not greater than X.
   function Half (X : Count) return Count
   with Post => Half'Result <= X;

   --  X rounded down to an even number.
   function Even_Down (X : Count) return Count;

end Halves;
