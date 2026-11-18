with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Containers.Vectors;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

--  The subprograms of an Ada source, so that a prover can be limited to
--  the one that a mutant is in.
package AdaMutant.Subprograms is

   package Name_Counts is new Ada.Containers.Indefinite_Ordered_Maps
     (String, Positive);

   type Subprogram is record
      Name         : Unbounded_String;
      --  As written ("Saturating_Add", or """+""" for an operator).
      Line         : Positive := 1;
      --  The line of the name, which is where GNATprove's --limit-subp
      --  looks for the subprogram.
      First        : Positive := 1;
      Last         : Natural := 0;
      --  The bytes of the body, or of the expression function up to its
      --  closing parenthesis or bracket.
      Expression   : Boolean := False;
      --  An expression function: the provers see its body in the callers.
      Own          : Boolean := False;
      --  An aspect after which GNATprove analyses the subprogram on its
      --  own, not inlined in its callers: Pre, Post, Contract_Cases,
      --  Global, Depends, Subprogram_Variant, Always_Terminates or
      --  Exceptional_Cases.
      Other        : Boolean := False;
      --  Another aspect, of which it is not known whether it does.
      Globals      : Boolean := False;
      --  Global or Depends: GNATprove does not generate them from the body.
      Recursive    : Boolean := False;
      --  The body names the subprogram (a call to itself).
      Generic_Unit : Boolean := False;
      --  In a generic unit, whose instances GNATprove analyses.
      Parent       : Natural := 0;
      --  The index of the subprogram that this one is declared in, or 0.
   end record;

   package Subprogram_Vectors is new Ada.Containers.Vectors
     (Positive, Subprogram);

   function Generic_Names (Source : String) return Name_Counts.Map;
   --  The lower-case names of the generic units that Source declares (as
   --  keys; the counts mean nothing).  Propagates Lexer.Lexical_Error.

   function Find
     (Source   : String;
      Generics : Name_Counts.Map := Name_Counts.Empty_Map)
      return Subprogram_Vectors.Vector;
   --  The subprogram bodies, entry bodies and expression functions of
   --  Source.  The subprograms in the bodies of the generic units that
   --  Source declares, or that Generics names (those of the spec), get
   --  Generic_Unit.  Propagates AdaMutant.Lexer.Lexical_Error.

   function Declared_Names (Spec : String) return Name_Counts.Map;
   --  How many subprograms of each lower-case name the package
   --  specification Spec declares without completing them (no expression
   --  functions, null procedures or renamings).  Propagates Lexical_Error.

   type Place is record
      Name    : Unbounded_String;
      --  The innermost subprogram around the place, or "".
      Limit   : Natural := 0;
      --  The line of the subprogram that a proof of a change at the place
      --  can be limited to, or 0 when the whole unit has to be proved.
      Globals : Boolean := False;
      --  The subprogram of Limit has Global or Depends.
   end record;

   function Place_Of
     (Subs     : Subprogram_Vectors.Vector;
      Offset   : Positive;
      Declared : Name_Counts.Map) return Place;
   --  Where Offset of the source of Subs is.  GNATprove proves the callers
   --  of an expression function, and of a subprogram without a contract
   --  or other aspect, with its body: a change there can fail in the
   --  callers only.  The limit is the innermost subprogram around Offset
   --  that GNATprove analyses on its own and that callers outside do not
   --  see the body of: one with such an aspect, a recursive one, or one
   --  that the spec declares.  A plain subprogram declared in another one
   --  takes the limit of that one.  The limit is 0 in a generic unit, and
   --  where it is not clear.

end AdaMutant.Subprograms;
