package Finite_Domain is
   Global_State : Boolean := False;

   function Identity (A, B : Boolean) return Boolean;
   function Different_Last (A, B : Boolean) return Boolean;
   function Single_Return (A, B : Boolean) return Boolean;
   function External (A : Boolean) return Boolean;
   function Call_In_Dead_Branch (A : Boolean) return Boolean;
   function Shadowed_True (True : Boolean) return Boolean;
   function Has_Default (A : Boolean := False) return Boolean;
   function Aliased_Input (A : aliased Boolean) return Boolean;
   subtype Pred_Boolean is Boolean with Static_Predicate => Pred_Boolean;
   function Has_Predicate (A : Pred_Boolean) return Boolean;
   function Has_Pre (A : Boolean) return Boolean with Pre => A;
   function With_Declaration (A : Boolean) return Boolean;
   function With_Handler (A : Boolean) return Boolean;
   function Exception_Expression (A : Boolean) return Boolean;
   function Eight
     (A1, A2, A3, A4, A5, A6, A7, A8 : Boolean) return Boolean;
   function Nine
     (A1, A2, A3, A4, A5, A6, A7, A8, A9 : Boolean) return Boolean;
   function Read_Global return Boolean;
   function Overloaded (A : Boolean) return Boolean;
   function Overloaded (A : Integer) return Boolean;

   package Shadowed is
      type Boolean is new Standard.Boolean;
      function Derived (A : Boolean) return Boolean;
   end Shadowed;

   package User_Operators is
      function "or" (Left, Right : Boolean) return Boolean;
      function Apply (A, B : Boolean) return Boolean;
   end User_Operators;
end Finite_Domain;
