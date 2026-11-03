package body Calculator is

   function Add (A, B : Integer) return Integer is
   begin
      return A + B;
   end Add;

   function Max (A, B : Integer) return Integer is
   begin
      if A > B then
         return A;
      else
         return B;
      end if;
   end Max;

   function Clamp (X, Low, High : Integer) return Integer is
   begin
      if X < Low then
         return Low;
      elsif X > High then
         return High;
      end if;
      return X;
   end Clamp;

   function Grade (Score : Natural) return String is
   begin
      if Score >= 80 then
         return "A";
      elsif Score >= 60 then
         return "B";
      end if;
      return "C";
   end Grade;

   function Sum_To (N : Natural) return Natural is
      Total : Natural := 0;
      I     : Natural := 0;
   begin
      while I < N loop
         I := I + 1;
         Total := Total + I;
      end loop;
      return Total;
   end Sum_To;

end Calculator;
