package Calculator is

   function Add (A, B : Integer) return Integer;

   function Max (A, B : Integer) return Integer;

   function Clamp (X, Low, High : Integer) return Integer;

   function Is_Even (N : Integer) return Boolean is (N mod 2 = 0);

   function Grade (Score : Natural) return String;

   function Sum_To (N : Natural) return Natural;
   --  1 + 2 + ... + N

end Calculator;
