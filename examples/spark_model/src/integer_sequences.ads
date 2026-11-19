with SPARK.Containers.Functional.Vectors;

--  Sequences of integers indexed from 1, for the model of a queue.  "=" on
--  Integer is the logical equality, so GNATprove may take it as such.
package Integer_Sequences is new SPARK.Containers.Functional.Vectors
  (Index_Type           => Positive,
   Element_Type         => Integer,
   Use_Logical_Equality => True);
