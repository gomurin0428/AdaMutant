with Ada.Containers.Vectors;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

--  Reading JSON text (RFC 8259), for the reports of earlier runs.
package AdaMutant.Json is

   type Kind is (Null_Value, Boolean_Value, Number, Text, List, Object);

   type Value is private;
   --  A value of a parsed text.  The values of a text stay allocated until
   --  the program ends.

   No_Value : constant Value;
   --  What Field returns for a member that an object does not have.

   Syntax_Error : exception;

   function Parse (Source : String) return Value;
   --  Raises Syntax_Error with "offset N: reason" for text that is not one
   --  JSON value.  Strings come out in UTF-8.

   function Kind_Of (V : Value) return Kind
     with Pre => V /= No_Value;

   function Is_Text (V : Value) return Boolean;
   function Is_List (V : Value) return Boolean;
   function Is_Object (V : Value) return Boolean;
   --  False for No_Value.

   function Text_Of (V : Value) return String
     with Pre => Is_Text (V);

   function Integer_Of (V : Value; Default : Integer) return Integer;
   --  The number V when it is a whole number that fits, else Default.

   function Length (V : Value) return Natural
     with Pre => Is_List (V) or else Is_Object (V);
   --  The number of elements or members.

   function Element (V : Value; Index : Positive) return Value
     with Pre => (Is_List (V) or else Is_Object (V)) and then Index <= Length (V);
   --  An element of a list, or the value of a member of an object, in the
   --  order of the text.

   function Name (V : Value; Index : Positive) return String
     with Pre => Is_Object (V) and then Index <= Length (V);

   function Field (V : Value; Name : String) return Value;
   --  The value of the first member Name of an object, or No_Value when
   --  there is none or V is not an object.

private

   type Node;
   type Value is access Node;

   No_Value : constant Value := null;

   package Value_Vectors is new Ada.Containers.Vectors (Positive, Value);
   package Name_Vectors is new Ada.Containers.Vectors
     (Positive, Unbounded_String);

   type Node is record
      What  : Kind := Null_Value;
      Flag  : Boolean := False;
      Image : Unbounded_String;      --  a string, or the text of a number
      Items : Value_Vectors.Vector;  --  elements, or the values of members
      Names : Name_Vectors.Vector;   --  the names of members
   end record;

end AdaMutant.Json;
