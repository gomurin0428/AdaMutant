with Ada.Containers.Vectors;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with AdaMutant.Mutators;

--  The subprograms of an Ada source, so that a prover can be limited to
--  the one that a mutant is in.
package AdaMutant.Subprograms is

   type Subprogram is record
      Name       : Unbounded_String;
      --  As written ("Saturating_Add", or """+""" for an operator).
      Line       : Positive := 1;
      --  The line of "procedure", "function" or "entry".
      First      : Positive := 1;
      Last       : Natural := 0;
      --  The bytes of the body, or of the expression function up to its
      --  closing parenthesis.
      Expression : Boolean := False;
      --  An expression function: the provers see its body in the callers.
      Contract   : Boolean := False;
      --  Pre, Post or Contract_Cases on the declaration that starts here.
      Parent     : Natural := 0;
      --  The index of the subprogram that this one is declared in, or 0.
   end record;

   package Subprogram_Vectors is new Ada.Containers.Vectors
     (Positive, Subprogram);

   function Find (Source : String) return Subprogram_Vectors.Vector;
   --  The subprogram bodies, entry bodies and expression functions of
   --  Source.  Propagates AdaMutant.Lexer.Lexical_Error.

   function Visible_Names
     (Spec : String) return AdaMutant.Mutators.Name_Sets.Set;
   --  Lower-case names of the subprograms that the visible part of the
   --  package specification Spec declares.  Propagates Lexical_Error.

   type Place is record
      Name  : Unbounded_String;
      --  The innermost subprogram around the place, or "".
      Limit : Natural := 0;
      --  The line of the subprogram that a proof of a change at the place
      --  can be limited to, or 0 when the whole unit has to be proved.
   end record;

   function Place_Of
     (Subs    : Subprogram_Vectors.Vector;
      Offset  : Positive;
      Visible : AdaMutant.Mutators.Name_Sets.Set) return Place;
   --  Where Offset of the source of Subs is.  GNATprove analyses the
   --  callers of an expression function, and of a subprogram without a
   --  contract that the unit does not make visible, with its body: a
   --  change there can only fail in the callers.  The limit is therefore
   --  the innermost subprogram around Offset that is neither, unless only
   --  the subprograms around it call it; it is 0 when the change can fail
   --  anywhere in the unit.

end AdaMutant.Subprograms;
