with Integer_Sequences; use Integer_Sequences;

--  A bounded FIFO queue of integers, stored in a ring buffer.  The
--  contracts speak of a queue only through Model, the sequence of its
--  elements with the next to leave at index 1: where the ring buffer keeps
--  them stays in the body.
package Queues with SPARK_Mode is

   Capacity : constant := 8;

   subtype Count is Natural range 0 .. Capacity;

   type Queue is private;

   function Length (Q : Queue) return Count;

   function Is_Empty (Q : Queue) return Boolean is (Length (Q) = 0);

   function Is_Full (Q : Queue) return Boolean is (Length (Q) = Capacity);

   --  The elements of Q, the next to leave at index 1.  The body builds
   --  it from the ring buffer.
   function Model (Q : Queue) return Sequence
   with Ghost,
        Post => Last (Model'Result) = Length (Q);

   procedure Clear (Q : in out Queue)
   with Post => Is_Empty (Q);

   procedure Enqueue (Q : in out Queue; X : Integer)
   with Pre  => not Is_Full (Q),
        Post => Model (Q) = Add (Model (Q'Old), X);

   procedure Dequeue (Q : in out Queue; X : out Integer)
   with Pre  => not Is_Empty (Q),
        Post => X = Get (Model (Q'Old), 1)
                and then Model (Q) = Remove (Model (Q'Old), 1);

   function Front (Q : Queue) return Integer
   with Pre  => not Is_Empty (Q),
        Post => Front'Result = Get (Model (Q), 1);

   --  Moves the first element of From to the end of To.
   procedure Transfer (From, To : in out Queue)
   with Pre  => not Is_Empty (From) and then not Is_Full (To),
        Post => Model (From) = Remove (Model (From'Old), 1)
                and then Model (To)
                         = Add (Model (To'Old), Get (Model (From'Old), 1));

private

   subtype Index is Natural range 0 .. Capacity - 1;

   type Ring is array (Index) of Integer
   with Default_Component_Value => 0;

   type Queue is record
      Data  : Ring;
      First : Index := 0;  --  where the next element to leave is
      Len   : Count := 0;
   end record;

   function Length (Q : Queue) return Count is (Q.Len);

end Queues;
