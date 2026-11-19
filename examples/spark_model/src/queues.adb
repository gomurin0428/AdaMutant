package body Queues with SPARK_Mode is

   --  Where the I-th element of Q is in Data.  The model wraps around with
   --  mod, the operations below with comparisons.
   function Position (Q : Queue; I : Positive) return Index is
     ((Q.First + I - 1) mod Capacity)
   with Ghost, Pre => I <= Q.Len;

   --  Refined_Post says what the model is to the proofs in this body;
   --  outside, only the Post of the spec is known.
   function Model (Q : Queue) return Sequence
   with Refined_Post =>
     Last (Model'Result) = Q.Len
     and then (for all I in 1 .. Q.Len =>
                 Get (Model'Result, I) = Q.Data (Position (Q, I)))
   is
      M : Sequence;
   begin
      for I in 1 .. Q.Len loop
         M := Add (M, Q.Data (Position (Q, I)));
         pragma Loop_Invariant (Last (M) = I);
         pragma Loop_Invariant
           (for all J in 1 .. I => Get (M, J) = Q.Data (Position (Q, J)));
      end loop;
      return M;
   end Model;

   procedure Clear (Q : in out Queue) is
   begin
      Q.Len := 0;
   end Clear;

   procedure Enqueue (Q : in out Queue; X : Integer) is
      Next : constant Natural := Q.First + Q.Len;  --  before wrapping around
   begin
      if Next < Capacity then
         Q.Data (Next) := X;
      else
         Q.Data (Next - Capacity) := X;
      end if;
      Q.Len := Q.Len + 1;
   end Enqueue;

   procedure Dequeue (Q : in out Queue; X : out Integer) is
   begin
      X := Q.Data (Q.First);
      if Q.First = Index'Last then
         Q.First := 0;
      else
         Q.First := Q.First + 1;
      end if;
      Q.Len := Q.Len - 1;
   end Dequeue;

   function Front (Q : Queue) return Integer is (Q.Data (Q.First));

   procedure Transfer (From, To : in out Queue) is
      X : Integer;
   begin
      Dequeue (From, X);
      Enqueue (To, X);
   end Transfer;

end Queues;
