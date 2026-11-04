with Ada.Containers.Indefinite_Ordered_Sets;
with Ada.Containers.Vectors;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

--  Generation of mutations from Ada source text.
package AdaMutant.Mutators is

   type Mutator_Kind is
     (Arithmetic_Operator,
      Equality_Operator,
      Logical_Operator,
      Unary_Operator,
      Boolean_Literal,
      Membership_Operator,
      Conditional_Expression,
      Statement_Deletion,
      Numeric_Literal,
      String_Literal);

   type Mutator_Set is array (Mutator_Kind) of Boolean;

   All_Mutators : constant Mutator_Set := [others => True];

   function Name (Kind : Mutator_Kind) return String;
   --  Report name, for example "ArithmeticOperator".

   function Parse (Text : String; Kind : out Mutator_Kind) return Boolean;
   --  Accepts the report name or the Ada identifier, case-insensitively.

   package Name_Sets is new Ada.Containers.Indefinite_Ordered_Sets (String);

   type Scan_Options is record
      Enabled          : Mutator_Set := All_Mutators;
      Mutate_Contracts : Boolean := False;
      --  Lower-case names of ghost entities declared outside the scanned
      --  source (usually in its spec).
      Ghost_Names      : Name_Sets.Set;
   end record;

   function Ghost_Names (Source : String) return Name_Sets.Set;
   --  Lower-case names of the subprograms, objects and types that Source
   --  declares with the Ghost aspect.

   type Mutation is record
      Kind        : Mutator_Kind := Arithmetic_Operator;
      First       : Positive := 1;
      Last        : Natural := 0;
      Replacement : Unbounded_String;
      Ignored     : Boolean := False;
   end record;
   --  Source (First .. Last) is replaced by Replacement.  Ignored is set when
   --  an "adamutant:disable" comment covers the mutation.

   package Mutation_Vectors is new Ada.Containers.Vectors (Positive, Mutation);

   function Find
     (Source : String; Options : Scan_Options) return Mutation_Vectors.Vector;
   --  Propagates AdaMutant.Lexer.Lexical_Error and raises Directive_Error
   --  for malformed adamutant comments.

   Directive_Error : exception;

   function Apply (Source : String; M : Mutation) return String is
     (Source (Source'First .. M.First - 1) & To_String (M.Replacement)
      & Source (M.Last + 1 .. Source'Last));

end AdaMutant.Mutators;
