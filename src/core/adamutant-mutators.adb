with Ada.Characters.Handling; use Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Ada.Strings.Wide_Wide_Unbounded;
with Langkit_Support.Diagnostics;
with Langkit_Support.Slocs;
with Langkit_Support.Text;
with Libadalang.Analysis;
with Libadalang.Common;
with AdaMutant.Lexer; use AdaMutant.Lexer;

package body AdaMutant.Mutators is

   --  Find works on the syntax tree of Libadalang, without name
   --  resolution.

   package LAL renames Libadalang.Analysis;
   package LC renames Libadalang.Common;
   use all type LC.Ada_Node_Kind_Type;
   use type LC.Token_Kind;
   use type LC.Token_Reference;

   function Name (Kind : Mutator_Kind) return String is
     (case Kind is
         when Arithmetic_Operator    => "ArithmeticOperator",
         when Equality_Operator      => "EqualityOperator",
         when Logical_Operator       => "LogicalOperator",
         when Unary_Operator         => "UnaryOperator",
         when Boolean_Literal        => "BooleanLiteral",
         when Membership_Operator    => "MembershipOperator",
         when Conditional_Expression => "ConditionalExpression",
         when Statement_Deletion     => "StatementDeletion",
         when Numeric_Literal        => "NumericLiteral",
         when String_Literal         => "StringLiteral",
         when Attribute_Swap         => "AttributeSwap",
         when Loop_Direction         => "LoopDirection",
         when Conjunct_Deletion      => "ConjunctDeletion",
         when Assertion_Deletion     => "AssertionDeletion");

   function Squash (S : String) return String is
      R    : String (1 .. S'Length);
      Last : Natural := 0;
   begin
      for C of S loop
         if C /= '_' then
            Last := Last + 1;
            R (Last) := To_Lower (C);
         end if;
      end loop;
      return R (1 .. Last);
   end Squash;

   function Numeric_Mutation (Text : String) return String is
      subtype Big is Long_Long_Integer;
      Clean   : constant String := Squash (Text);
      Open    : Natural := 0;
      Close   : Natural := 0;
      Mark    : Natural := 0;
      Is_Real : Boolean := False;
      Upper   : Boolean := True;

      function Digit (C : Character) return Natural is
        (case C is
            when '0' .. '9' => Character'Pos (C) - Character'Pos ('0'),
            when 'a' .. 'f' => Character'Pos (C) - Character'Pos ('a') + 10,
            when others     => 16);

      function Value (S : String; Base : Big; V : out Big) return Boolean is
      begin
         V := 0;
         if S'Length = 0 then
            return False;
         end if;
         for C of S loop
            if Big (Digit (C)) >= Base
              or else V > (Big'Last - Big (Digit (C))) / Base
            then
               return False;
            end if;
            V := V * Base + Big (Digit (C));
         end loop;
         return True;
      end Value;

      function Image (V : Big; Base : Big) return String is
         Hex : constant String :=
           (if Upper then "0123456789ABCDEF" else "0123456789abcdef");
      begin
         if V < Base then
            return [1 => Hex (Hex'First + Natural (V))];
         end if;
         return Image (V / Base, Base)
           & Hex (Hex'First + Natural (V mod Base));
      end Image;
   begin
      for C of Text loop
         if C in 'a' .. 'f' then
            Upper := False;
         end if;
      end loop;
      for I in Clean'Range loop
         case Clean (I) is
            when '#' =>
               if Open = 0 then
                  Open := I;
               elsif Close = 0 then
                  Close := I;
               end if;
            when '.' =>
               Is_Real := True;
            when 'e' =>
               if Mark = 0 and then (Open = 0 or else Close /= 0) then
                  Mark := I;
               end if;
            when others =>
               null;
         end case;
      end loop;
      if Open /= 0 and then Close = 0 then
         return "";
      end if;
      declare
         Mantissa : constant String :=
           (if Open /= 0 then Clean (Open + 1 .. Close - 1)
            elsif Mark /= 0 then Clean (Clean'First .. Mark - 1)
            else Clean);
         Exponent : constant String :=
           (if Mark = 0 then ""
            elsif Mark < Clean'Last and then Clean (Mark + 1) = '+'
            then Clean (Mark + 2 .. Clean'Last)
            else Clean (Mark + 1 .. Clean'Last));
         Base  : Big := 10;
         Power : Big := 0;
         V     : Big;
      begin
         if Is_Real then
            return (if (for all C of Mantissa => C in '0' | '.') then "1.0"
                    else "0.0");
         end if;
         if (Open /= 0
             and then (not Value (Clean (Clean'First .. Open - 1), 10, Base)
                       or else Base not in 2 .. 16))
           or else (Exponent /= "" and then not Value (Exponent, 10, Power))
           or else (Mark /= 0 and then Exponent = "")
           or else not Value (Mantissa, Base, V)
         then
            return "";
         end if;
         for I in 1 .. Power loop
            if V > Big'Last / Base then
               return "";
            end if;
            exit when V = 0;
            V := V * Base;
         end loop;
         V := (if V = 0 then 1 elsif V = 1 then 0
               elsif V = Big'Last then -1 else V + 1);
         if V < 0 then
            return "";
         elsif Open /= 0 then
            return Clean (Clean'First .. Open - 1) & "#" & Image (V, Base) & "#";
         else
            return Image (V, 10);
         end if;
      end;
   end Numeric_Mutation;

   function Parse (Text : String; Kind : out Mutator_Kind) return Boolean is
   begin
      for K in Mutator_Kind loop
         if Squash (Name (K)) = Squash (Text) then
            Kind := K;
            return True;
         end if;
      end loop;
      Kind := Mutator_Kind'First;
      return False;
   end Parse;

   type Word is access constant String;

   Operator_Symbols : constant array (1 .. 19) of Word :=
     [new String'("and"), new String'("or"), new String'("xor"),
      new String'("="), new String'("/="), new String'("<"),
      new String'("<="), new String'(">"), new String'(">="),
      new String'("+"), new String'("-"), new String'("&"),
      new String'("*"), new String'("/"), new String'("mod"),
      new String'("rem"), new String'("**"), new String'("abs"),
      new String'("not")];

   Standard_Discrete : constant array (1 .. 11) of Word :=
     [new String'("boolean"), new String'("character"),
      new String'("wide_character"), new String'("wide_wide_character"),
      new String'("integer"), new String'("natural"), new String'("positive"),
      new String'("short_integer"), new String'("short_short_integer"),
      new String'("long_integer"), new String'("long_long_integer")];

   function Same_Case (Model, Word : String) return String is
     (if Model = To_Upper (Model) then To_Upper (Word)
      elsif Model = To_Lower (Model) then To_Lower (Word)
      else Word);
   --  Word in the case of Model: all upper case, all lower case, or as
   --  given.

   function Same (Left, Right : LAL.Ada_Node'Class) return Boolean
     renames LAL."=";

   function Has_Kind
     (N : LAL.Ada_Node'Class; Kind : LC.Ada_Node_Kind_Type) return Boolean
   is (not N.Is_Null and then N.Kind = Kind);
   --  N is a node (not null) of that kind.

   type Line_Starts is array (Positive range <>) of Positive;

   --  Source text parsed by Libadalang: the syntax tree only, without
   --  name resolution.  Libadalang places a token by its line and column.
   --  Decoded as Latin-1, every byte is one character and a tab is one
   --  column, so the byte offset of a token is the start of its line plus
   --  its column.  UTF-8 text with letters beyond ASCII in an identifier
   --  or a character literal does not parse as Latin-1, and is decoded as
   --  UTF-8: a column is then a character of one to four bytes.
   type Syntax_Tree (First : Positive; Last : Natural; Lines : Positive)
   is record
      Context : LAL.Analysis_Context;
      Root    : LAL.Ada_Node;
      UTF_8   : Boolean := False;
      Text    : String (First .. Last);
      --  The text that Libadalang parsed: the source with a byte order
      --  mark replaced by blanks (see also Bracket_Strings).
      Starts  : Line_Starts (1 .. Lines);
      --  The offset of the first byte of each line (lines end at LF).
   end record;

   function Sequence_Length (C : Character) return Positive is
     (case Character'Pos (C) is
         when 16#C0# .. 16#DF# => 2,
         when 16#E0# .. 16#EF# => 3,
         when 16#F0# .. 16#F7# => 4,
         when others           => 1);
   --  The number of bytes of the UTF-8 character that starts with C.

   --  S has characters beyond ASCII, and all of them are well-formed
   --  UTF-8.
   function Is_UTF_8 (S : String) return Boolean is
      I      : Positive := S'First;
      Beyond : Boolean := False;
   begin
      while I <= S'Last loop
         declare
            Length : constant Positive := Sequence_Length (S (I));
         begin
            if Length > 1 then
               if I > S'Last - Length + 1 then
                  return False;
               end if;
               for J in I + 1 .. I + Length - 1 loop
                  if Character'Pos (S (J)) not in 16#80# .. 16#BF# then
                     return False;
                  end if;
               end loop;
               Beyond := True;
            elsif Character'Pos (S (I)) >= 16#80# then
               return False;
            end if;
            I := I + Length;
         end;
      end loop;
      return Beyond;
   end Is_UTF_8;

   --  Libadalang reads '["' as the start of a character in the brackets
   --  notation of GNAT ("["03C0"]"), so a bracket aggregate that starts
   --  with a string literal (["a", "b"]) does not parse.  Text gets such
   --  brackets as parentheses, which give the same mutations.
   procedure Bracket_Strings (Text : in out String) is
   begin
      if Ada.Strings.Fixed.Index (Text, "[""") = 0 then
         return;
      end if;
      declare
         Tokens : constant Token_Vectors.Vector := Tokenize (Text);
         Opened : array (1 .. Natural (Tokens.Length)) of Natural;
         --  The offsets of the open brackets, or 0 for one that stays.
         Depth  : Natural := 0;
      begin
         for I in 1 .. Natural (Tokens.Length) loop
            declare
               Token : constant AdaMutant.Lexer.Token := Tokens (I);
            begin
               if Token.Kind = Delimiter and then Image (Text, Token) = "["
               then
                  Depth := Depth + 1;
                  Opened (Depth) :=
                    (if I < Natural (Tokens.Length)
                       and then Tokens (I + 1).Kind = String_Literal
                       and then Tokens (I + 1).First = Token.Last + 1
                     then Token.First else 0);
               elsif Token.Kind = Delimiter and then Image (Text, Token) = "]"
                 and then Depth > 0
               then
                  if Opened (Depth) /= 0 then
                     Text (Opened (Depth)) := '(';
                     Text (Token.First) := ')';
                  end if;
                  Depth := Depth - 1;
               end if;
            end;
         end loop;
      end;
   exception
      when Lexical_Error =>
         null;
   end Bracket_Strings;

   Rules : constant array (Positive range <>) of LC.Grammar_Rule :=
     [LC.Compilation_Rule, LC.Stmts_Rule, LC.Basic_Decls_Rule,
      LC.Expr_Rule];
   --  A file is a compilation.  The other rules take fragments, such as
   --  the statements or the declarations that the unit tests pass.

   --  Source parsed with the first of Rules that has no diagnostics, as
   --  Latin-1 and then, when that fails, as UTF-8.  When nothing parses,
   --  raises Lexical_Error with the first diagnostic of the compilation
   --  rule, or with Tolerant, gives the tree that Libadalang recovered
   --  from the errors.
   function Parse_Tree (Source : String; Tolerant : Boolean) return Syntax_Tree
   is
      BOM   : constant String :=
        Character'Val (16#EF#) & Character'Val (16#BB#)
        & Character'Val (16#BF#);
      Lines : Positive := 1;
      Line  : Positive := 1;
   begin
      for C of Source loop
         if C = ASCII.LF then
            Lines := Lines + 1;
         end if;
      end loop;
      return T : Syntax_Tree (Source'First, Source'Last, Lines) do
         T.Text := Source;
         if Source'Length >= 3
           and then Source (Source'First .. Source'First + 2) = BOM
         then
            T.Text (Source'First .. Source'First + 2) := "   ";
         end if;
         Bracket_Strings (T.Text);
         T.Starts (1) := Source'First;
         for I in Source'Range loop
            if Source (I) = ASCII.LF then
               Line := Line + 1;
               T.Starts (Line) := I + 1;
            end if;
         end loop;
         for UTF_8 in Boolean loop
            exit when UTF_8 and then not Is_UTF_8 (Source);
            declare
               Charset : constant String :=
                 (if UTF_8 then "utf-8" else "iso-8859-1");
            begin
               T.Context :=
                 LAL.Create_Context (Charset => Charset, Tab_Stop => 1);
               for Rule of Rules loop
                  declare
                     Unit : constant LAL.Analysis_Unit :=
                       T.Context.Get_From_Buffer
                         (Filename => Rule'Image & ".adb",
                          Charset  => Charset,
                          Buffer   => T.Text,
                          Rule     => Rule);
                  begin
                     if not Unit.Has_Diagnostics then
                        T.Root := Unit.Root;
                        T.UTF_8 := UTF_8;
                        return;
                     end if;
                  end;
               end loop;
            end;
         end loop;
         T.Context :=
           LAL.Create_Context (Charset => "iso-8859-1", Tab_Stop => 1);
         declare
            Unit : constant LAL.Analysis_Unit :=
              T.Context.Get_From_Buffer
                (Filename => "source.adb",
                 Charset  => "iso-8859-1",
                 Buffer   => T.Text,
                 Rule     => LC.Compilation_Rule);
            D    : constant Langkit_Support.Diagnostics.Diagnostic :=
              Unit.Diagnostics (Unit.Diagnostics'First);
         begin
            if not Tolerant then
               raise Lexical_Error with
                 "line" & Positive (D.Sloc_Range.Start_Line)'Image & ": "
                 & Langkit_Support.Text.To_UTF8
                     (Ada.Strings.Wide_Wide_Unbounded.To_Wide_Wide_String
                        (D.Message));
            end if;
            T.Root := Unit.Root;
         end;
      end return;
   end Parse_Tree;

   function Offset (T : Syntax_Tree; Line, Column : Positive) return Positive
   is
      I : Positive := T.Starts (Line);
   begin
      if not T.UTF_8 then
         return I + Column - 1;
      end if;
      for C in 2 .. Column loop
         I := I + Sequence_Length (T.Text (I));
      end loop;
      return I;
   end Offset;

   function First
     (T : Syntax_Tree; R : Langkit_Support.Slocs.Source_Location_Range)
      return Positive
   is (Offset (T, Positive (R.Start_Line), Positive (R.Start_Column)));

   function Last
     (T : Syntax_Tree; R : Langkit_Support.Slocs.Source_Location_Range)
      return Natural
   is (Offset (T, Positive (R.End_Line), Positive (R.End_Column)) - 1);
   --  The end of a range is the place after its last character.

   function First (T : Syntax_Tree; N : LAL.Ada_Node'Class) return Positive is
     (First (T, N.Sloc_Range));

   function Last (T : Syntax_Tree; N : LAL.Ada_Node'Class) return Natural is
     (Last (T, N.Sloc_Range));

   function First
     (T : Syntax_Tree; Token : LC.Token_Reference) return Positive
   is (First (T, LC.Sloc_Range (LC.Data (Token))));

   function Last (T : Syntax_Tree; Token : LC.Token_Reference) return Natural
   is (Last (T, LC.Sloc_Range (LC.Data (Token))));

   function Text (T : Syntax_Tree; N : LAL.Ada_Node'Class) return String is
     (T.Text (First (T, N) .. Last (T, N)));

   function Text (T : Syntax_Tree; Token : LC.Token_Reference) return String
   is (T.Text (First (T, Token) .. Last (T, Token)));

   function Lower_Text (T : Syntax_Tree; N : LAL.Ada_Node'Class) return String
   is (if N.Is_Null then "" else Lower (Text (T, N)));

   function Simple_Name (T : Syntax_Tree; N : LAL.Ada_Node'Class) return String
   is (if N.Is_Null then ""
       elsif N.Kind = Ada_Defining_Name
       then Simple_Name (T, N.As_Defining_Name.F_Name)
       elsif N.Kind = Ada_Dotted_Name
       then Simple_Name (T, N.As_Dotted_Name.F_Suffix)
       else Lower_Text (T, N));
   --  The lower-case name of an entity without its prefix: "q" for "P.Q".

   --  The name that the declaration or the body of a subprogram N
   --  defines, or no node.
   function Subprogram_Name (N : LAL.Ada_Node'Class) return LAL.Ada_Node is
      Spec : LAL.Subp_Spec;
   begin
      case N.Kind is
         when Ada_Abstract_Subp_Decl | Ada_Subp_Decl =>
            Spec := N.As_Classic_Subp_Decl.F_Subp_Spec;
         when Ada_Expr_Function | Ada_Null_Subp_Decl | Ada_Subp_Body
            | Ada_Subp_Renaming_Decl =>
            Spec := N.As_Base_Subp_Body.F_Subp_Spec;
         when Ada_Subp_Body_Stub =>
            Spec := N.As_Subp_Body_Stub.F_Subp_Spec;
         when Ada_Generic_Subp_Internal =>
            Spec := N.As_Generic_Subp_Internal.F_Subp_Spec;
         when Ada_Generic_Subp_Instantiation =>
            return N.As_Generic_Subp_Instantiation.F_Subp_Name.As_Ada_Node;
         when others =>
            return LAL.No_Ada_Node;
      end case;
      return (if Spec.Is_Null then LAL.No_Ada_Node
              else Spec.F_Subp_Name.As_Ada_Node);
   end Subprogram_Name;

   --  N is a declaration with the aspect Ghost (and not "Ghost => False"):
   --  of a subprogram, an object, a type or a subtype.
   function Has_Ghost_Aspect
     (T : Syntax_Tree; N : LAL.Ada_Node'Class) return Boolean
   is
      Aspects : LAL.Aspect_Spec;
   begin
      if N.Kind not in Ada_Abstract_Subp_Decl | Ada_Subp_Decl
        | Ada_Expr_Function | Ada_Null_Subp_Decl | Ada_Subp_Body
        | Ada_Subp_Renaming_Decl | Ada_Generic_Subp_Internal
        | Ada_Object_Decl | Ada_Concrete_Type_Decl | Ada_Subtype_Decl
      then
         return False;
      end if;
      Aspects := N.As_Basic_Decl.F_Aspects;
      if Aspects.Is_Null then
         return False;
      end if;
      declare
         Assocs : constant LAL.Aspect_Assoc_List := Aspects.F_Aspect_Assocs;
      begin
         for I in 1 .. Assocs.Children_Count loop
            if Has_Kind (Assocs.Child (I), Ada_Aspect_Assoc)
              and then Lower_Text
                (T, Assocs.Child (I).As_Aspect_Assoc.F_Id) = "ghost"
              and then Lower_Text
                (T, Assocs.Child (I).As_Aspect_Assoc.F_Expr) /= "false"
            then
               return True;
            end if;
         end loop;
      end;
      return False;
   end Has_Ghost_Aspect;

   --  Adds to Ghosts the names of the subprograms and objects that the
   --  tree declares with the aspect Ghost, and to Types the names of its
   --  types and subtypes.  Not the name of a ghost type: no statement
   --  calls or assigns it, and a component or subprogram of the same name
   --  elsewhere would be taken for ghost code.  The declaration itself is
   --  ghost (see Find).
   procedure Scan_Declarations
     (T : Syntax_Tree; Ghosts, Types : in out Name_Sets.Set)
   is
      procedure Include (Names : in out Name_Sets.Set; Name : String) is
      begin
         if Name /= "" then
            Names.Include (Name);
         end if;
      end Include;

      procedure Walk (N : LAL.Ada_Node) is
      begin
         if not Has_Ghost_Aspect (T, N) then
            null;
         elsif N.Kind = Ada_Object_Decl then
            --  "A, B : T with Ghost" declares every name.
            declare
               Ids : constant LAL.Defining_Name_List :=
                 N.As_Object_Decl.F_Ids;
            begin
               for I in 1 .. (if Ids.Is_Null then 0 else Ids.Children_Count)
               loop
                  Include (Ghosts, Simple_Name (T, Ids.Child (I)));
               end loop;
            end;
         elsif N.Kind not in Ada_Concrete_Type_Decl | Ada_Subtype_Decl then
            Include (Ghosts, Simple_Name (T, Subprogram_Name (N)));
         end if;
         if N.Kind in Ada_Concrete_Type_Decl | Ada_Formal_Type_Decl
           | Ada_Subtype_Decl | Ada_Incomplete_Type_Decl
           | Ada_Incomplete_Formal_Type_Decl | Ada_Incomplete_Tagged_Type_Decl
           | Ada_Protected_Type_Decl | Ada_Task_Type_Decl
         then
            Include (Types, Simple_Name (T, N.As_Base_Type_Decl.F_Name));
         end if;
         for I in 1 .. N.Children_Count loop
            declare
               Child : constant LAL.Ada_Node := N.Child (I);
            begin
               if not Child.Is_Null then
                  Walk (Child);
               end if;
            end;
         end loop;
      end Walk;
   begin
      if not T.Root.Is_Null then
         Walk (T.Root);
      end if;
   end Scan_Declarations;

   --  Ghost_Names and Type_Names read the spec of the scanned unit, which
   --  may not parse (it is not the file being mutated): they take what
   --  Libadalang recovered from its errors.

   function Ghost_Names (Source : String) return Name_Sets.Set is
      T             : constant Syntax_Tree := Parse_Tree (Source, True);
      Ghosts, Types : Name_Sets.Set;
   begin
      Scan_Declarations (T, Ghosts, Types);
      return Ghosts;
   end Ghost_Names;

   function Type_Names (Source : String) return Name_Sets.Set is
      T             : constant Syntax_Tree := Parse_Tree (Source, True);
      Ghosts, Types : Name_Sets.Set;
   begin
      Scan_Declarations (T, Ghosts, Types);
      return Types;
   end Type_Names;

   function Same_Node (Left, Right : LAL.Ada_Node) return Boolean is
     (Same (Left, Right));

   package Node_Vectors is new Ada.Containers.Vectors
     (Positive, LAL.Ada_Node, Same_Node);

   function Find
     (Source : String; Options : Scan_Options) return Mutation_Vectors.Vector
   is
      T : constant Syntax_Tree := Parse_Tree (Source, Tolerant => False);

      --  The ghost names of the spec and of Source.
      Ghosts : Name_Sets.Set := Options.Ghost_Names;

      --  The types and subtypes that a loop can run over backwards when
      --  it names one of them alone ("for I in Index loop"): those of
      --  the spec, of Source and the discrete ones of Standard.  Any
      --  other name may be a container or an iterator, which need not
      --  go backwards.
      Types : Name_Sets.Set := Options.Type_Names;

      --  A mutation, the offset of the token that it belongs to (an
      --  operator, the keyword of a condition, the first token of a
      --  statement...) and its number among the mutations found.  The
      --  result lists the mutations in the order of their tokens and,
      --  for one token, in the order they were found.
      type Found_Mutation is record
         Key, Number : Positive;
         Change      : Mutation;
      end record;

      function Before (A, B : Found_Mutation) return Boolean is
        (A.Key < B.Key or else (A.Key = B.Key and then A.Number < B.Number));

      package Found_Vectors is new Ada.Containers.Vectors
        (Positive, Found_Mutation);
      package Sorting is new Found_Vectors.Generic_Sorting (Before);

      Found : Found_Vectors.Vector;

      --  Where a node is.
      type Context is record
         Skip      : Boolean := False;
         --  Never mutated: a context clause, a representation clause, a
         --  pragma, an aspect that is no contract (Size, Inline, Import,
         --  Global, Annotate...), the default expression of a formal
         --  parameter, digits or delta.
         Aspect    : Boolean := False;
         --  In a contract aspect.
         Assertion : Boolean := False;
         --  In an assertion pragma (Assert, Assert_And_Cut, Assume,
         --  Loop_Invariant, Loop_Variant), which is a contract: only
         --  ConjunctDeletion changes it, and AssertionDeletion deletes
         --  the pragma.
         Ghost     : Boolean := False;
         --  In ghost code: the declaration or the body of a ghost entity,
         --  or a statement that calls or assigns one.  It only exists for
         --  proof and in builds with assertions, so like contracts it is
         --  marked (Contract) and mutated only with Mutate_Contracts.
         Declared  : Boolean := False;
         --  In the subtype of an object, component, type or subtype
         --  declaration ("X : String (1 .. 6)", "subtype S is Integer
         --  range 1 .. 4"), not in its initial value nor in its aspects
         --  (a predicate is a contract).
      end record;

      function Skipped (C : Context) return Boolean is
        (C.Skip
         or else (not Options.Mutate_Contracts
                  and then (C.Aspect or else C.Ghost)));

      function In_Contract (C : Context) return Boolean is
        (C.Assertion
         or else ((C.Aspect or else C.Ghost) and then not Skipped (C)));
      --  In a contract that may be mutated: a contract aspect, ghost code
      --  or an assertion pragma.

      --  Source (First .. Last) replaced by Replacement, at the token at
      --  Key.
      procedure Add
        (Kind        : Mutator_Kind;
         C           : Context;
         Key, First  : Positive;
         Last        : Natural;
         Replacement : String) is
      begin
         if not Options.Enabled (Kind) then
            return;
         elsif Kind in Conjunct_Deletion | Assertion_Deletion then
            if not Options.Mutate_Contracts or else not In_Contract (C) then
               return;
            end if;
         elsif Skipped (C) then
            return;
         end if;
         Found.Append
           (Found_Mutation'
              (Key    => Key,
               Number => Natural (Found.Length) + 1,
               Change =>
                 (Kind        => Kind,
                  First       => First,
                  Last        => Last,
                  Replacement => To_Unbounded_String (Replacement),
                  Contract    =>
                    C.Aspect or else C.Ghost or else C.Assertion)));
      end Add;

      --  N replaced as a whole, at its first token.
      procedure Replace
        (Kind : Mutator_Kind; C : Context; N : LAL.Ada_Node'Class;
         Replacement : String) is
      begin
         Add (Kind, C, First (T, N), First (T, N), Last (T, N), Replacement);
      end Replace;

      function Next (Token : LC.Token_Reference) return LC.Token_Reference
      is (LC.Next (Token, Exclude_Trivia => True));

      function Previous
        (Token : LC.Token_Reference) return LC.Token_Reference
      is (LC.Previous (Token, Exclude_Trivia => True));

      function Is_Kind
        (Token : LC.Token_Reference; Kind : LC.Token_Kind) return Boolean
      is (Token /= LC.No_Token and then LC.Kind (LC.Data (Token)) = Kind);

      --  The operands and the operators of the chain of one logical
      --  operator that the operator of B belongs to: "A and B and C" is
      --  "(A and B) and C" in the tree.
      procedure Chain
        (B : LAL.Bin_Op; Operands, Operators : in out Node_Vectors.Vector)
      is
         Kind : constant LC.Ada_Op := B.F_Op;
         Top  : LAL.Ada_Node := B.As_Ada_Node;

         function Is_Link (N : LAL.Ada_Node) return Boolean is
           (Has_Kind (N, Ada_Bin_Op)
            and then LC.Ada_Op'(N.As_Bin_Op.F_Op) = Kind);

         procedure Flatten (N : LAL.Ada_Node) is
         begin
            if Is_Link (N) then
               Flatten (N.As_Bin_Op.F_Left.As_Ada_Node);
               Operators.Append (LAL.Op'(N.As_Bin_Op.F_Op).As_Ada_Node);
               Flatten (N.As_Bin_Op.F_Right.As_Ada_Node);
            else
               Operands.Append (N);
            end if;
         end Flatten;
      begin
         while Is_Link (Top.Parent) loop
            Top := Top.Parent;
         end loop;
         Operands.Clear;
         Operators.Clear;
         Flatten (Top);
      end Chain;

      --  LogicalOperator.  Ada does not allow different logical operators
      --  side by side without parentheses, so in a chain such as "A and
      --  then B and then C" the operands around the mutated operator are
      --  parenthesised: "(A or else B) and then C", "((A and then B) or
      --  else C)".
      procedure Add_Logical (B : LAL.Bin_Op; New_Op : String; C : Context)
      is
         Op                  : constant LAL.Op := B.F_Op;
         Operands, Operators : Node_Vectors.Vector;
         I                   : Positive := 1;
      begin
         Chain (B, Operands, Operators);
         while First (T, Operators (I)) /= First (T, Op) loop
            I := I + 1;
         end loop;
         if Natural (Operators.Length) = 1 then
            Add (Logical_Operator, C,
                 First (T, Op), First (T, Op), Last (T, Op), New_Op);
            return;
         end if;
         declare
            L     : constant Positive := First (T, Operands (1));
            R     : constant Natural := Last (T, Operands (I + 1));
            Left  : constant String := Source (L .. Last (T, Operands (I)));
            Right : constant String :=
              Source (First (T, Operands (I + 1)) .. R);
         begin
            Add (Logical_Operator, C, First (T, Op), L, R,
                 "(" & (if I > 1 then "(" & Left & ")" else Left)
                 & " " & New_Op & " " & Right & ")");
         end;
      end Add_Logical;

      --  ConjunctDeletion: the chain "A and B and C" (or with "and then")
      --  of B, its first operator, without one of its operands, for each
      --  operand: "B and C", "A and C", "A and B".  The line breaks of
      --  what is left out follow the replacement (see Apply).
      procedure Add_Conjuncts (B : LAL.Bin_Op; C : Context) is
         Operands, Operators : Node_Vectors.Vector;
      begin
         Chain (B, Operands, Operators);
         if First (T, Operators.First_Element) /= First (T, LAL.Op'(B.F_Op))
         then
            return;
         end if;
         declare
            Count : constant Positive := Natural (Operators.Length);
            L     : constant Positive := First (T, Operands (1));
            R     : constant Natural := Last (T, Operands (Count + 1));
         begin
            for I in 1 .. Count + 1 loop
               declare
                  First_Out : constant Positive :=
                    (if I = Count + 1 then Last (T, Operands (Count)) + 1
                     else First (T, Operands (I)));
                  --  What is left out: the operand and the operator
                  --  after it, or for the last operand, the operator
                  --  before it.
                  Last_Out  : constant Natural :=
                    (if I = Count + 1 then R
                     else First (T, Operands (I + 1)) - 1);
                  Breaks    : Unbounded_String;
               begin
                  for Ch of Source (First_Out .. Last_Out) loop
                     if Ch in ASCII.CR | ASCII.LF then
                        Append (Breaks, Ch);
                     end if;
                  end loop;
                  Add (Conjunct_Deletion, C, First (T, Operators (1)), L, R,
                       Source (L .. First_Out - 1)
                       & Source (Last_Out + 1 .. R) & To_String (Breaks));
               end;
            end loop;
         end;
      end Add_Conjuncts;

      type Place is
        (If_Condition, While_Condition, Exit_Condition, Barrier,
         And_Operand, Elsewhere);

      --  Where the expression N is: the condition of an if (statement or
      --  expression) or elsif, of a while or of an exit when, an entry
      --  barrier, an operand of "and" or "and then", or elsewhere.
      function Place_Of (N : LAL.Ada_Node) return Place is
         P : constant LAL.Ada_Node := N.Parent;
      begin
         if P.Is_Null then
            return Elsewhere;
         end if;
         case P.Kind is
            when Ada_If_Stmt =>
               if Same (N, P.As_If_Stmt.F_Cond_Expr) then
                  return If_Condition;
               end if;
            when Ada_Elsif_Stmt_Part =>
               if Same (N, P.As_Elsif_Stmt_Part.F_Cond_Expr) then
                  return If_Condition;
               end if;
            when Ada_If_Expr =>
               if Same (N, P.As_If_Expr.F_Cond_Expr) then
                  return If_Condition;
               end if;
            when Ada_Elsif_Expr_Part =>
               if Same (N, P.As_Elsif_Expr_Part.F_Cond_Expr) then
                  return If_Condition;
               end if;
            when Ada_While_Loop_Spec =>
               return While_Condition;
            when Ada_Exit_Stmt =>
               if Same (N, P.As_Exit_Stmt.F_Cond_Expr) then
                  return Exit_Condition;
               end if;
            when Ada_Entry_Body =>
               if Same (N, P.As_Entry_Body.F_Barrier) then
                  return Barrier;
               end if;
            when Ada_Bin_Op =>
               if LC.Ada_Op'(P.As_Bin_Op.F_Op) in Ada_Op_And | Ada_Op_And_Then
               then
                  return And_Operand;
               end if;
            when others =>
               null;
         end case;
         return Elsewhere;
      end Place_Of;

      --  EqualityOperator: the relation B, such as "A < B", replaced as a
      --  whole by Value ("False" or "True").  Not when it is the whole
      --  condition of an if, elsif, while or exit when, also in
      --  parentheses or under "not": ConditionalExpression makes the same
      --  mutant, or the loop would never end ("while True", "exit when
      --  False").  Not "False" for an entry barrier, which would never
      --  open.  Not "True" for an operand of an "and" in a contract, where
      --  ConjunctDeletion leaves the operand out.
      procedure Add_Constant (B : LAL.Bin_Op; Value : String; C : Context)
      is
         Whole : LAL.Ada_Node := B.As_Ada_Node;
         --  The relation with the parentheses and "not" around it.
         Holds : Boolean := Value = "True";
         --  What the mutant makes of Whole.
         CE    : constant Boolean :=
           Options.Enabled (Conditional_Expression);
      begin
         loop
            declare
               P : constant LAL.Ada_Node := Whole.Parent;
            begin
               exit when P.Is_Null;
               if P.Kind = Ada_Paren_Expr then
                  Whole := P;
               elsif P.Kind = Ada_Un_Op
                 and then LC.Ada_Op'(P.As_Un_Op.F_Op) = Ada_Op_Not
               then
                  Whole := P;
                  Holds := not Holds;
               else
                  exit;
               end if;
            end;
         end loop;
         case Place_Of (Whole) is
            when While_Condition =>
               if Holds or else CE then
                  return;
               end if;
            when Exit_Condition =>
               if not Holds or else CE then
                  return;
               end if;
            when If_Condition =>
               if CE then
                  return;
               end if;
            when Barrier =>
               if not Holds then
                  return;
               end if;
            when And_Operand =>
               if Holds and then Options.Enabled (Conjunct_Deletion)
                 and then Options.Mutate_Contracts and then In_Contract (C)
               then
                  return;
               end if;
            when Elsewhere =>
               null;
         end case;
         Add (Equality_Operator, C, First (T, LAL.Op'(B.F_Op)),
              First (T, B), Last (T, B), Value);
      end Add_Constant;

      function Zero (N : LAL.Ada_Node) return Boolean is
        (N.Kind = Ada_Int_Literal and then Squash (Text (T, N)) = "0");
      --  The integer literal 0.  In "X > 0" and "0 < X", the mutant "/="
      --  differs from the relation only when X < 0, which a count, a
      --  length or a Natural never is: it would mostly be equivalent.

      procedure Mutate_Binary (B : LAL.Bin_Op; C : Context) is
         Op   : constant LAL.Op := B.F_Op;
         Word : constant String := Text (T, Op.Token_Start);

         procedure Swap (Kind : Mutator_Kind; Replacement : String) is
         begin
            Replace (Kind, C, Op, Replacement);
         end Swap;
      begin
         case LC.Ada_Op'(B.F_Op) is
            when Ada_Op_Plus =>
               Swap (Arithmetic_Operator, "-");
            when Ada_Op_Minus =>
               Swap (Arithmetic_Operator, "+");
            when Ada_Op_Mult =>
               Swap (Arithmetic_Operator, "/");
            when Ada_Op_Div | Ada_Op_Pow =>
               Swap (Arithmetic_Operator, "*");
            --  mod and rem differ only for operands of opposite signs, so
            --  swapping them is nearly always equivalent.
            when Ada_Op_Mod | Ada_Op_Rem =>
               Swap (Arithmetic_Operator, "*");
            --  A relation splits its inputs in three: A < B, A = B and A
            --  > B.  Each mutant differs from it in one of them only, so
            --  killing all three takes a test that checks the result in
            --  each (the sufficient set of Kaminski, Ammann and Offutt,
            --  2011).  "=" and "/=" may compare records, which have no
            --  "<".
            when Ada_Op_Eq =>
               Swap (Equality_Operator, "/=");
               Add_Constant (B, "False", C);
            when Ada_Op_Neq =>
               Swap (Equality_Operator, "=");
               Add_Constant (B, "True", C);
            when Ada_Op_Lt =>
               Swap (Equality_Operator, "<=");
               if not Zero (B.F_Left.As_Ada_Node) then
                  Swap (Equality_Operator, "/=");
               end if;
               Add_Constant (B, "False", C);
            when Ada_Op_Lte =>
               Swap (Equality_Operator, "<");
               Swap (Equality_Operator, "=");
               Add_Constant (B, "True", C);
            when Ada_Op_Gt =>
               Swap (Equality_Operator, ">=");
               if not Zero (B.F_Right.As_Ada_Node) then
                  Swap (Equality_Operator, "/=");
               end if;
               Add_Constant (B, "False", C);
            when Ada_Op_Gte =>
               Swap (Equality_Operator, ">");
               Swap (Equality_Operator, "=");
               Add_Constant (B, "True", C);
            when Ada_Op_And | Ada_Op_And_Then =>
               if Options.Enabled (Conjunct_Deletion) and then In_Contract (C)
               then
                  Add_Conjuncts (B, C);
               end if;
               Add_Logical
                 (B,
                  Same_Case (Word,
                             (if Op.Kind = Ada_Op_And then "or" else "or else")),
                  C);
            when Ada_Op_Or =>
               Add_Logical (B, Same_Case (Word, "and"), C);
            when Ada_Op_Or_Else =>
               Add_Logical (B, Same_Case (Word, "and then"), C);
            when Ada_Op_Xor =>
               Add_Logical (B, Same_Case (Word, "or"), C);
            when others =>
               null;
         end case;
      end Mutate_Binary;

      --  ConditionalExpression: the condition of an if or elsif becomes
      --  True and False, that of a while False (True would never end the
      --  loop) and that of an exit when True.  Not into what it already
      --  is.
      procedure Add_Condition
        (Condition : LAL.Expr; To_True, To_False : Boolean; C : Context)
      is
         Key  : constant Positive :=
           First (T, Previous (Condition.Token_Start));
         --  The keyword: if, elsif, while or when.
         Word : constant String :=
           (if Condition.Kind = Ada_Identifier
            then Lower_Text (T, Condition) else "");
      begin
         if To_True and then Word /= "true" then
            Add (Conditional_Expression, C, Key,
                 First (T, Condition), Last (T, Condition), "True");
         end if;
         if To_False and then Word /= "false" then
            Add (Conditional_Expression, C, Key,
                 First (T, Condition), Last (T, Condition), "False");
         end if;
      end Add_Condition;

      function Discrete (N : LAL.Ada_Node) return Boolean is
        (case N.Kind is
            when Ada_Bin_Op =>
              LC.Ada_Op'(N.As_Bin_Op.F_Op) = Ada_Op_Double_Dot,
            when Ada_Attribute_Ref =>
              Lower_Text (T, N.As_Attribute_Ref.F_Attribute) = "range",
            when Ada_Subtype_Indication | Ada_Constrained_Subtype_Indication
               | Ada_Discrete_Subtype_Indication =>
              not N.As_Subtype_Indication.F_Constraint.Is_Null,
            when others => False);
      --  N is a range: "A .. B", "X'Range", "T range A .. B".

      --  LoopDirection: the direction of a loop over a range ("for I in A
      --  .. B loop", "for I in X'Range loop") or over a subtype ("for I in
      --  Index loop").  Not over an iterator ("for C in V.Iterate", "for
      --  E of A"), which need not go backwards; nor in a quantified
      --  expression or an aggregate, which have no loop statement.
      procedure Add_Direction (Loop_Stmt : LAL.For_Loop_Stmt; C : Context) is
         Spec : constant LAL.For_Loop_Spec :=
           Loop_Stmt.F_Spec.As_For_Loop_Spec;
         Over : constant LAL.Ada_Node := Spec.F_Iter_Expr;
         Into : constant LAL.Iter_Type := Spec.F_Loop_Type;
         --  The "in" of the loop.
         Key  : constant Positive := First (T, Loop_Stmt);
      begin
         if Into.Kind /= Ada_Iter_Type_In then
            null;
         elsif Spec.F_Has_Reverse then
            Add (Loop_Direction, C, Key, First (T, Into),
                 Last (T, LAL.Reverse_Node'(Spec.F_Has_Reverse)),
                 Same_Case (Text (T, Into), "in"));
         elsif Discrete (Over)
           or else (Over.Kind = Ada_Identifier
                    and then Types.Contains (Lower_Text (T, Over)))
         then
            Add (Loop_Direction, C, Key, First (T, Into), Last (T, Into),
                 Same_Case (Text (T, Into), "in reverse"));
         end if;
      end Add_Direction;

      --  A return statement right before "exception" or an "end" (not of
      --  an if, loop, case or select), where it changes nothing in a
      --  body.
      function Ends_Body (N : LAL.Ada_Node) return Boolean is
         After : constant LC.Token_Reference := Next (N.Token_End);
      begin
         return Is_Kind (After, LC.Ada_Exception)
           or else (Is_Kind (After, LC.Ada_End)
                    and then not (Is_Kind (Next (After), LC.Ada_If)
                                  or else Is_Kind (Next (After), LC.Ada_Loop)
                                  or else Is_Kind (Next (After), LC.Ada_Case)
                                  or else Is_Kind (Next (After),
                                                   LC.Ada_Select)));
      end Ends_Body;

      --  The statement N is the whole branch of an if or elsif without an
      --  else after it: deleting it is ConditionalExpression's condition
      --  -> False.
      function Whole_Branch (N : LAL.Ada_Node) return Boolean is
         List : constant LAL.Ada_Node := N.Parent;
      begin
         if not Has_Kind (List, Ada_Stmt_List) or else List.Children_Count /= 1
           or else List.Parent.Is_Null
         then
            return False;
         end if;
         declare
            Branch : constant LAL.Ada_Node := List.Parent;
         begin
            case Branch.Kind is
               when Ada_If_Stmt =>
                  return Branch.As_If_Stmt.F_Alternatives.Children_Count = 0
                    and then Branch.As_If_Stmt.F_Else_Part.Is_Null;
               when Ada_Elsif_Stmt_Part =>
                  declare
                     Parts : constant LAL.Ada_Node := Branch.Parent;
                  begin
                     return Same (Parts.Child (Parts.Children_Count), Branch)
                       and then Parts.Parent.As_If_Stmt.F_Else_Part.Is_Null;
                  end;
               when others =>
                  return False;
            end case;
         end;
      end Whole_Branch;

      --  The pragma N is the only statement of its sequence, apart from
      --  labels ("begin pragma Assert (X); end;"): deleting it would leave
      --  the sequence empty.
      function Only_Statement (N : LAL.Ada_Node) return Boolean is
         List : constant LAL.Ada_Node := N.Parent;
      begin
         if not Has_Kind (List, Ada_Stmt_List) then
            return False;
         end if;
         for I in 1 .. List.Children_Count loop
            if not Same (List.Child (I), N)
              and then List.Child (I).Kind /= Ada_Label
            then
               return False;
            end if;
         end loop;
         return True;
      end Only_Statement;

      --  The last identifier of the dotted name that starts the statement
      --  N, followed by "(", ";" or ":=": the subprogram that it calls or
      --  the object that it assigns ("m" for "S.M (X);"), or "".
      function Statement_Name (N : LAL.Ada_Node) return String is
         Token : LC.Token_Reference := N.Token_Start;
         Name  : LC.Token_Reference := LC.No_Token;
      begin
         while Is_Kind (Token, LC.Ada_Identifier)
           or else Is_Kind (Token, LC.Ada_Dot)
         loop
            if Is_Kind (Token, LC.Ada_Identifier) then
               Name := Token;
            end if;
            Token := Next (Token);
         end loop;
         if Name /= LC.No_Token
           and then (Is_Kind (Token, LC.Ada_Par_Open)
                     or else Is_Kind (Token, LC.Ada_Semicolon)
                     or else Is_Kind (Token, LC.Ada_Assign))
         then
            return Lower (Text (T, Name));
         end if;
         return "";
      end Statement_Name;

      --  N starts ghost code: a declaration with the aspect Ghost, the
      --  declaration or the body of a subprogram with a ghost name, or a
      --  statement that calls or assigns a ghost entity.
      function Ghost_Code (N : LAL.Ada_Node) return Boolean is
        (Has_Ghost_Aspect (T, N)
         or else (N.Kind in Ada_Abstract_Subp_Decl | Ada_Subp_Decl
                    | Ada_Expr_Function | Ada_Null_Subp_Decl | Ada_Subp_Body
                    | Ada_Subp_Renaming_Decl | Ada_Subp_Body_Stub
                    | Ada_Generic_Subp_Internal
                    | Ada_Generic_Subp_Instantiation
                  and then Ghosts.Contains
                             (Simple_Name (T, Subprogram_Name (N))))
         or else (N.Kind in Ada_Assign_Stmt | Ada_Call_Stmt
                  and then Ghosts.Contains (Statement_Name (N))));

      --  The literal N is the whole first argument of an attribute
      --  ("A'Range (2)", "T'Max (10, X)").  The number of a dimension must
      --  be one of the array, so its mutant would hardly compile.
      function First_Argument (N : LAL.Ada_Node) return Boolean is
         Assoc : constant LAL.Ada_Node := N.Parent;
      begin
         if not Has_Kind (Assoc, Ada_Param_Assoc)
           or else not Has_Kind (Assoc.Parent, Ada_Assoc_List)
           or else not Same (Assoc.Parent.Child (1), Assoc)
         then
            return False;
         end if;
         declare
            Owner : constant LAL.Ada_Node := Assoc.Parent.Parent;
         begin
            return Has_Kind (Owner, Ada_Attribute_Ref)
              or else (Has_Kind (Owner, Ada_Call_Expr)
                       and then Owner.As_Call_Expr.F_Name.Kind
                                  = Ada_Attribute_Ref);
         end;
      end First_Argument;

      --  The literal N is a bound of a range, also with a sign ("-1 ..
      --  1").
      function Bound (N : LAL.Ada_Node) return Boolean is
         P : LAL.Ada_Node := N.Parent;
      begin
         if Has_Kind (P, Ada_Un_Op)
           and then LC.Ada_Op'(P.As_Un_Op.F_Op) in Ada_Op_Plus | Ada_Op_Minus
         then
            P := P.Parent;
         end if;
         return Has_Kind (P, Ada_Bin_Op)
           and then LC.Ada_Op'(P.As_Bin_Op.F_Op) = Ada_Op_Double_Dot;
      end Bound;

      --  An attribute and its counterpart, which gives a value of the
      --  same type: the other bound, the other extreme, the other
      --  neighbour, the other rounding.
      function Counterpart (Attribute : String) return String is
        (if Attribute = "first" then "Last"
         elsif Attribute = "last" then "First"
         elsif Attribute = "min" then "Max"
         elsif Attribute = "max" then "Min"
         elsif Attribute = "succ" then "Pred"
         elsif Attribute = "pred" then "Succ"
         elsif Attribute = "floor" then "Ceiling"
         elsif Attribute = "ceiling" then "Floor"
         elsif Attribute = "first_valid" then "Last_Valid"
         elsif Attribute = "last_valid" then "First_Valid"
         else "");

      --  The mutations of the node N itself (its children are visited
      --  apart).
      procedure Mutate (N : LAL.Ada_Node; C : Context) is
      begin
         case N.Kind is
            when Ada_Bin_Op | Ada_Relation_Op =>
               Mutate_Binary (N.As_Bin_Op, C);

            when Ada_Un_Op =>
               declare
                  Op : constant LAL.Op := N.As_Un_Op.F_Op;
               begin
                  case Op.Kind is
                     when Ada_Op_Plus =>
                        Replace (Unary_Operator, C, Op, "-");
                     when Ada_Op_Minus =>
                        Replace (Unary_Operator, C, Op, "+");
                     when Ada_Op_Not | Ada_Op_Abs =>
                        Replace (Unary_Operator, C, Op, "");
                     when others =>
                        null;
                  end case;
               end;

            when Ada_Membership_Expr =>
               declare
                  Op : constant LAL.Op := N.As_Membership_Expr.F_Op;
               begin
                  if Op.Kind = Ada_Op_In then
                     Replace (Membership_Operator, C, Op,
                              Same_Case (Text (T, Op), "not in"));
                  else
                     Replace (Membership_Operator, C, Op,
                              Same_Case (Text (T, Op.Token_End), "in"));
                  end if;
               end;

            when Ada_If_Stmt =>
               Add_Condition (N.As_If_Stmt.F_Cond_Expr, True, True, C);
            when Ada_Elsif_Stmt_Part =>
               Add_Condition
                 (N.As_Elsif_Stmt_Part.F_Cond_Expr, True, True, C);
            when Ada_If_Expr =>
               Add_Condition (N.As_If_Expr.F_Cond_Expr, True, True, C);
            when Ada_Elsif_Expr_Part =>
               Add_Condition
                 (N.As_Elsif_Expr_Part.F_Cond_Expr, True, True, C);
            when Ada_While_Loop_Spec =>
               Add_Condition (N.As_While_Loop_Spec.F_Expr, False, True, C);
            when Ada_Exit_Stmt =>
               if not N.As_Exit_Stmt.F_Cond_Expr.Is_Null then
                  Add_Condition (N.As_Exit_Stmt.F_Cond_Expr, True, False, C);
               end if;

            when Ada_For_Loop_Stmt =>
               Add_Direction (N.As_For_Loop_Stmt, C);

            --  StatementDeletion: a raise statement, or a return statement
            --  without a value, except where it changes nothing in a body
            --  (see Ends_Body).  Not the whole branch of an if or elsif
            --  without an else: that is ConditionalExpression's condition
            --  -> False.  Not an exit statement, which could make the loop
            --  run for ever (see exit when), nor a delay statement, whose
            --  only effect (time) tests and proof rarely observe.
            when Ada_Raise_Stmt | Ada_Return_Stmt =>
               if (N.Kind = Ada_Raise_Stmt
                   or else (N.As_Return_Stmt.F_Return_Expr.Is_Null
                            and then not Ends_Body (N)))
                 and then not (Options.Enabled (Conditional_Expression)
                               and then Whole_Branch (N))
               then
                  Replace (Statement_Deletion, C, N, "null;");
               end if;

            --  StatementDeletion: an assignment or a procedure call (not a
            --  code statement, which is a qualified expression).
            when Ada_Assign_Stmt =>
               Replace (Statement_Deletion, C, N, "null;");
            when Ada_Call_Stmt =>
               if N.As_Call_Stmt.F_Call.Kind /= Ada_Qual_Expr then
                  Replace (Statement_Deletion, C, N, "null;");
               end if;

            --  AssertionDeletion: an assertion pragma, which leaves
            --  nothing, or "null;" where the sequence of statements would
            --  be empty ("begin pragma Assert (X); end;").  Not "null;"
            --  anywhere: it would split a group of loop invariants, which
            --  GNAT rejects.
            when Ada_Pragma_Node =>
               if C.Assertion then
                  Replace (Assertion_Deletion, C, N,
                           (if Only_Statement (N) then "null;" else ""));
               end if;

            --  BooleanLiteral, not the name of an attribute or the
            --  declaration of an enumeration literal.
            when Ada_Identifier =>
               declare
                  Word : constant String := Lower_Text (T, N);
               begin
                  if Word in "true" | "false"
                    and then not Has_Kind (N.Parent, Ada_Defining_Name)
                    and then not (Has_Kind (N.Parent, Ada_Attribute_Ref)
                                  and then Same
                                    (N, N.Parent.As_Attribute_Ref.F_Attribute))
                  then
                     Replace (Boolean_Literal, C, N,
                              Same_Case (Text (T, N),
                                         (if Word = "true" then "False"
                                          else "True")));
                  end if;
               end;

            --  AttributeSwap.  Not in the subtype of a declaration, like
            --  the bounds of NumericLiteral.
            when Ada_Attribute_Ref =>
               declare
                  Attribute : constant LAL.Identifier :=
                    N.As_Attribute_Ref.F_Attribute;
                  Other     : constant String :=
                    Counterpart (Lower_Text (T, Attribute));
               begin
                  if Other /= "" and then not C.Declared then
                     Replace (Attribute_Swap, C, Attribute,
                              Same_Case (Text (T, Attribute), Other));
                  end if;
               end;

            --  NumericLiteral.  Not the first argument of an attribute, nor
            --  a bound of a range in the subtype of a declaration: changing
            --  it either leaves values out of the subtype (a compile error)
            --  or only widens it (an equivalent mutant).
            when Ada_Int_Literal | Ada_Real_Literal =>
               declare
                  R : constant String := Numeric_Mutation (Text (T, N));
               begin
                  if R /= "" and then not First_Argument (N)
                    and then not (C.Declared and then Bound (N))
                  then
                     Replace (Numeric_Literal, C, N, R);
                  end if;
               end;

            --  StringLiteral, not an operator symbol ("+" (A, B)).
            when Ada_String_Literal =>
               declare
                  Content : constant String :=
                    Lower (Source (First (T, N) + 1 .. Last (T, N) - 1));
                  Is_Op   : Boolean := False;
               begin
                  for Op of Operator_Symbols loop
                     Is_Op := Is_Op or else Op.all = Content;
                  end loop;
                  if not Is_Op then
                     Replace (String_Literal, C, N,
                              (if Content = "" then """AdaMutant was here!"""
                               else """"""));
                  end if;
               end;

            when others =>
               null;
         end case;
      end Mutate;

      function Contract_Aspect (A : LAL.Aspect_Assoc) return Boolean is
         Id : LAL.Ada_Node := A.F_Id.As_Ada_Node;
      begin
         if Id.Kind = Ada_Attribute_Ref then
            Id := Id.As_Attribute_Ref.F_Prefix.As_Ada_Node;
         end if;
         return Lower_Text (T, Id) in
           "pre" | "post" | "contract_cases" | "type_invariant"
           | "invariant" | "static_predicate" | "dynamic_predicate"
           | "predicate" | "ghost_predicate"
           | "default_initial_condition" | "initial_condition"
           | "subprogram_variant" | "refined_post"
           | "exceptional_cases" | "exit_cases" | "program_exit"
           | "always_terminates";
      end Contract_Aspect;
      --  A is a contract aspect, also in its 'Class form.

      --  A formal parameter P of a subprogram or an entry whose
      --  declaration and body must repeat the same defaults (full
      --  conformance): changing one side never compiles.  Profiles that
      --  need no completion (is null, is abstract, expression functions,
      --  generic formal subprograms) stay mutable, and so do the profiles
      --  of an access to a subprogram and of an accept statement.
      function Conforms (P : LAL.Ada_Node) return Boolean is
         Owner : constant LAL.Ada_Node := P.Parent.Parent.Parent;
         --  Param_Spec_List, Params, and what has the parameters.
      begin
         case Owner.Kind is
            when Ada_Subp_Spec =>
               return Owner.Parent.Kind in Ada_Subp_Decl | Ada_Subp_Body
                 | Ada_Subp_Renaming_Decl | Ada_Subp_Body_Stub
                 | Ada_Generic_Subp_Internal;
            when Ada_Entry_Spec =>
               return True;
            when Ada_Entry_Completion_Formal_Params =>
               return Owner.Parent.Kind = Ada_Entry_Body;
            when others =>
               return False;
         end case;
      end Conforms;

      --  The context of Child, a child of Parent in the context C.
      function Inner (Parent, Child : LAL.Ada_Node; C : Context) return Context
      is
         R : Context := C;
      begin
         case Parent.Kind is
            when Ada_Object_Decl | Ada_Extended_Return_Stmt_Object_Decl =>
               R.Declared := Same (Child, Parent.As_Object_Decl.F_Type_Expr);
            when Ada_Component_Decl =>
               R.Declared :=
                 Same (Child, Parent.As_Component_Decl.F_Component_Def);
            when Ada_Concrete_Type_Decl =>
               R.Declared := Same (Child, Parent.As_Type_Decl.F_Type_Def);
            when Ada_Subtype_Decl =>
               R.Declared := Same (Child, Parent.As_Subtype_Decl.F_Subtype);
            when Ada_Param_Spec =>
               R.Skip := C.Skip
                 or else (Same (Child, Parent.As_Param_Spec.F_Default_Expr)
                          and then Conforms (Parent));
            when Ada_Floating_Point_Def =>
               R.Skip := C.Skip
                 or else Same (Child,
                               Parent.As_Floating_Point_Def.F_Num_Digits);
            when Ada_Ordinary_Fixed_Point_Def =>
               R.Skip := C.Skip
                 or else Same (Child,
                               Parent.As_Ordinary_Fixed_Point_Def.F_Delta);
            when Ada_Decimal_Fixed_Point_Def =>
               R.Skip := C.Skip
                 or else Same (Child, Parent.As_Decimal_Fixed_Point_Def.F_Delta)
                 or else Same (Child,
                               Parent.As_Decimal_Fixed_Point_Def.F_Digits);
            when Ada_Digits_Constraint =>
               R.Skip := C.Skip
                 or else Same (Child, Parent.As_Digits_Constraint.F_Digits);
            when Ada_Delta_Constraint =>
               R.Skip := C.Skip
                 or else Same (Child, Parent.As_Delta_Constraint.F_Delta);
            when others =>
               null;
         end case;
         return R;
      end Inner;

      procedure Visit (N : LAL.Ada_Node; Outer : Context) is
         C : Context := Outer;
      begin
         case N.Kind is
            --  Context clauses and representation clauses are never
            --  mutated.
            when Ada_With_Clause | Ada_Use_Package_Clause
               | Ada_Use_Type_Clause | Ada_Attribute_Def_Clause
               | Ada_Enum_Rep_Clause | Ada_Record_Rep_Clause | Ada_At_Clause
            =>
               C.Skip := True;
            when Ada_Pragma_Node =>
               C.Skip := True;
               C.Assertion :=
                 Lower_Text (T, N.As_Pragma_Node.F_Id) in
                   "assert" | "assert_and_cut" | "assume"
                   | "loop_invariant" | "loop_variant";
            --  Other aspects (Size, Inline, Import, External_Name, Global,
            --  Annotate...) are never mutated, like representation
            --  clauses.
            when Ada_Aspect_Assoc =>
               C.Declared := False;
               if Contract_Aspect (N.As_Aspect_Assoc) then
                  C.Aspect := True;
               else
                  C.Skip := True;
               end if;
            when Ada_Record_Def | Ada_Null_Record_Def =>
               C.Declared := False;
            when others =>
               null;
         end case;
         C.Ghost := C.Ghost or else Ghost_Code (N);
         Mutate (N, C);
         for I in 1 .. N.Children_Count loop
            declare
               Child : constant LAL.Ada_Node := N.Child (I);
            begin
               if not Child.Is_Null then
                  Visit (Child, Inner (N, Child, C));
               end if;
            end;
         end loop;
      end Visit;
   begin
      Scan_Declarations (T, Ghosts, Types);
      for Name of Standard_Discrete loop
         Types.Include (Name.all);
      end loop;
      if not T.Root.Is_Null then
         Visit (T.Root, (others => False));
      end if;
      Sorting.Sort (Found);
      return Result : Mutation_Vectors.Vector do
         for F of Found loop
            Result.Append (F.Change);
         end loop;
      end return;
   end Find;

   function Apply (Source : String; M : Mutation) return String is
      Replacement : constant String := To_String (M.Replacement);
      Breaks      : Unbounded_String;
   begin
      if Ada.Strings.Fixed.Index (Replacement, [ASCII.LF]) = 0 then
         for C of Source (M.First .. M.Last) loop
            if C in ASCII.CR | ASCII.LF then
               Append (Breaks, C);
            end if;
         end loop;
      end if;
      return Source (Source'First .. M.First - 1) & Replacement
        & To_String (Breaks) & Source (M.Last + 1 .. Source'Last);
   end Apply;

end AdaMutant.Mutators;
