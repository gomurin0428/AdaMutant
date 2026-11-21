package body Finite_Pragma is
   function Guarded (A : Boolean) return Boolean is (A xor False);
end Finite_Pragma;
