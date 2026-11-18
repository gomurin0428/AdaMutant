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
      String_Literal,
      Attribute_Swap,
      Loop_Direction,
      Conjunct_Deletion,
      Assertion_Deletion);
   --  Conjunct_Deletion and Assertion_Deletion only change contracts:
   --  the first leaves out an operand of "and" or "and then" in a
   --  contract aspect, in ghost code or in an assertion pragma, the
   --  second deletes an assertion pragma (Assert, Assert_And_Cut, Assume,
   --  Loop_Invariant, Loop_Variant).

   type Mutator_Set is array (Mutator_Kind) of Boolean;

   All_Mutators : constant Mutator_Set := [others => True];

   Default_Mutators : constant Mutator_Set :=
     [Loop_Direction => False, others => True];
   --  The mutators that run unless the configuration says otherwise.
   --  LoopDirection is left out: in many loops the order does not matter,
   --  and its mutants are then equivalent.

   function Name (Kind : Mutator_Kind) return String;
   --  Report name, for example "ArithmeticOperator".

   function Parse (Text : String; Kind : out Mutator_Kind) return Boolean;
   --  Accepts the report name or the Ada identifier, case-insensitively.

   package Name_Sets is new Ada.Containers.Indefinite_Ordered_Sets (String);

   type Scan_Options is record
      Enabled          : Mutator_Set := Default_Mutators;
      Mutate_Contracts : Boolean := False;
      --  Lower-case names of ghost entities declared outside the scanned
      --  source (usually in its spec).
      Ghost_Names      : Name_Sets.Set;
      --  Lower-case names of types and subtypes declared outside the
      --  scanned source (usually in its spec): LoopDirection takes a loop
      --  over one of these names for a loop over a range.
      Type_Names       : Name_Sets.Set;
   end record;

   function Ghost_Names (Source : String) return Name_Sets.Set;
   --  Lower-case names of the subprograms, objects and types that Source
   --  declares with the Ghost aspect.

   function Type_Names (Source : String) return Name_Sets.Set;
   --  Lower-case names of the types and subtypes that Source declares.

   type Mutation is record
      Kind        : Mutator_Kind := Arithmetic_Operator;
      First       : Positive := 1;
      Last        : Natural := 0;
      Replacement : Unbounded_String;
      Contract    : Boolean := False;
   end record;
   --  Source (First .. Last) is replaced by Replacement.  Contract is set
   --  when the mutation is in an aspect or in ghost code (which the
   --  program only contains when assertions are enabled).

   package Mutation_Vectors is new Ada.Containers.Vectors (Positive, Mutation);

   function Find
     (Source : String; Options : Scan_Options) return Mutation_Vectors.Vector;
   --  Propagates AdaMutant.Lexer.Lexical_Error.

   function Apply (Source : String; M : Mutation) return String;
   --  Source with the mutation made.  The line breaks of the text that it
   --  replaces follow the replacement, so the lines after it stay where
   --  they were: GNATprove's goals carry their lines, and a goal that only
   --  moves would miss the cache of proof results.

end AdaMutant.Mutators;
