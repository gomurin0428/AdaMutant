with Ada.Command_Line;
with Queues; use Queues;

--  A deliberately small test: a few elements in and out, which never
--  reach the end of the ring buffer.  The contracts are checked as the
--  test runs (-gnata); what happens when the buffer wraps around is left
--  to the proof.
procedure Test_Queues is
   Q : Queue;
   X : Integer;
begin
   Enqueue (Q, 10);
   Enqueue (Q, 20);
   Enqueue (Q, 30);
   Dequeue (Q, X);
   if X /= 10 or else Front (Q) /= 20 or else Length (Q) /= 2 then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end Test_Queues;
