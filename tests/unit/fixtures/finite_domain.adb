package body Finite_Domain is
   function Identity (A, B : Boolean) return Boolean is
     (A and then (B or not B));

   function Different_Last (A, B : Boolean) return Boolean is
   begin
      return A or else B;
   end Different_Last;

   function Single_Return (A, B : Boolean) return Boolean is
   begin
      return A and then (B xor not B);
   end Single_Return;

   function External (A : Boolean) return Boolean is
     (A and then Global_State);

   function Call_In_Dead_Branch (A : Boolean) return Boolean is
     (False and then Read_Global);

   function Shadowed_True (True : Boolean) return Boolean is
     (True xor False);

   function Has_Default (A : Boolean) return Boolean is (A xor A);

   function Aliased_Input (A : aliased Boolean) return Boolean is
     (A xor (not False));

   function Has_Predicate (A : Pred_Boolean) return Boolean is
     (A xor (A and then False));

   function Has_Pre (A : Boolean) return Boolean is (A and then True);

   function With_Declaration (A : Boolean) return Boolean is
      Local : constant Boolean := A;
   begin
      return Local;
   end With_Declaration;

   function With_Handler (A : Boolean) return Boolean is
   begin
      return not A;
   exception
      when others =>
         return False;
   end With_Handler;

   function Exception_Expression (A : Boolean) return Boolean is
     (if A then raise Program_Error else A);

   function Eight
     (A1, A2, A3, A4, A5, A6, A7, A8 : Boolean) return Boolean is
     (A1 and then A2 and then A3 and then A4 and then A5 and then A6
        and then A7 and then A8);

   function Nine
     (A1, A2, A3, A4, A5, A6, A7, A8, A9 : Boolean) return Boolean is
     (A1 and then A2 and then A3 and then A4 and then A5 and then A6
        and then A7 and then A8 and then A9);

   function Read_Global return Boolean is (Global_State);

   function Overloaded (A : Boolean) return Boolean is (A xor not A);

   function Overloaded (A : Integer) return Boolean is (True);

   package body Shadowed is
      function Derived (A : Boolean) return Boolean is (A xor False);
   end Shadowed;

   package body User_Operators is
      function "or" (Left, Right : Boolean) return Boolean is (Left);

      function Apply (A, B : Boolean) return Boolean is (A or B);
   end User_Operators;

   function Without_Previous (A : Boolean) return Boolean is (A xor True);
end Finite_Domain;
