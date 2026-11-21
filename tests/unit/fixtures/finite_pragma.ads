package Finite_Pragma is
   function Guarded (A : Boolean) return Boolean;
   pragma Precondition (False);
end Finite_Pragma;
