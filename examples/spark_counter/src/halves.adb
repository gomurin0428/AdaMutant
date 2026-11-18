package body Halves with SPARK_Mode is

   function Half (X : Count) return Count is
   begin
      return X / 2;
   end Half;

   function Even_Down (X : Count) return Count is
      H : constant Count := Half (X);
   begin
      --  Never true, as Half returns X / 2.  The proof of H * 2 needs it,
      --  because the contract of Half does not say so.
      if H > 50 then
         return 100;
      end if;
      return H * 2;
   end Even_Down;

end Halves;
