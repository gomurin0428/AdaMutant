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
      Stub         : Boolean := False;
      --  A completion without a body here: a renaming, "is separate",
      --  "is null", "is abstract" or an instantiation (First > Last).
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
   --  The subprogram bodies, entry bodies, expression functions and other
   --  completions of Source; nothing for a subunit ("separate").  The
   --  subprograms in the bodies of the generic units that Source
   --  declares, or that Generics names (those of the spec), get
   --  Generic_Unit.  Propagates AdaMutant.Lexer.Lexical_Error.

   function Declared_Names
     (Spec : String; With_Globals : Boolean := False) return Name_Counts.Map;
   --  How many subprograms of each lower-case name the package
   --  specification Spec declares for a body to complete (not expression
   --  functions, null procedures, renamings or imported ones); with
   --  With_Globals, only those that have Global or Depends.  Propagates
   --  Lexical_Error.

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
     (Subs          : Subprogram_Vectors.Vector;
      Offset        : Positive;
      Declared      : Name_Counts.Map;
      Declared_With : Name_Counts.Map) return Place;
   --  Where Offset of the source of Subs is; Declared and Declared_With
   --  come from Declared_Names of the spec.  GNATprove proves an
   --  expression function, and a subprogram without a contract or other
   --  aspect, inlined in its callers, and a subprogram declared in another
   --  one may be inlined in any subprogram around or beside it: a change
   --  there can fail elsewhere.  The limit is therefore only a subprogram
   --  of the package itself (not declared in another subprogram) that the
   --  spec declares, or that has an aspect after which GNATprove analyses
   --  it on its own (Own), and only when Offset is in its own code, not in
   --  a subprogram or expression function declared in it.  It is 0 in a
   --  generic unit and in a subunit.

end AdaMutant.Subprograms;
