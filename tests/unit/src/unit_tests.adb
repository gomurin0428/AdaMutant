with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO; use Ada.Text_IO;
with AdaMutant.Baselines;
with AdaMutant.Changes;
with AdaMutant.Config;
with AdaMutant.Files;
with AdaMutant.Json;
with AdaMutant.Lexer;
with AdaMutant.Mutators; use AdaMutant.Mutators;
with Ada.Directories;
with GNAT.OS_Lib;
with Ada.Environment_Variables;
with AdaMutant.Positions;
with AdaMutant.Processes;

with AdaMutant.Reports;
with AdaMutant.Results;
with AdaMutant.Runner;
with AdaMutant.Schemata;
with Ada.Strings.Fixed;

procedure Unit_Tests is

   LF : constant Character := ASCII.LF;

   Passed, Failed : Natural := 0;

   procedure Check (Condition : Boolean; Name : String; Detail : String := "") is
   begin
      if Condition then
         Passed := Passed + 1;
      else
         Failed := Failed + 1;
         Put_Line ("FAIL: " & Name);
         if Detail /= "" then
            Put_Line ("  " & Detail);
         end if;
      end if;
   end Check;

   --  "Kind original->replacement" for every mutation, separated by "|".
   function Describe
     (Source : String; Options : Scan_Options := (others => <>)) return String
   is
      R : Unbounded_String;
   begin
      for M of Find (Source, Options) loop
         if Length (R) > 0 then
            Append (R, "|");
         end if;
         Append (R, Name (M.Kind) & " "
                 & Source (M.First .. M.Last) & "->" & To_String (M.Replacement));
      end loop;
      return To_String (R);
   end Describe;

   procedure Expect (Source, Expected : String; Name : String;
                     Options : Scan_Options := (others => <>)) is
      Actual : constant String := Describe (Source, Options);
   begin
      Check (Actual = Expected, Name,
             "expected: " & Expected & LF & "  actual:   " & Actual);
   end Expect;

   procedure Test_Lexer is
      use AdaMutant.Lexer;
      S : constant String :=
        "X := 16#FF#; -- c" & LF & "C : Character := '''; S := ""a""""b"";"
        & " Q := T'First;";
      T : constant Token_Vectors.Vector := Tokenize (S);
   begin
      Check (Image (S, T (3)) = "16#FF#" and then T (3).Kind = Numeric_Literal,
             "lexer: based literal");
      Check (T (5).Kind = Comment and then T (5).Line = 1, "lexer: comment");
      Check (Image (S, T (10)) = "'''" and then T (10).Kind = Character_Literal,
             "lexer: quote character literal");
      Check (Image (S, T (14)) = """a""""b"""
             and then T (14).Kind = String_Literal, "lexer: doubled quote");
      Check (Image (S, T (19)) = "'" and then T (19).Kind = Delimiter
             and then Image (S, T (20)) = "First", "lexer: attribute tick");
      Check (T (6).Line = 2, "lexer: line numbers");
      begin
         declare
            Bad : constant Token_Vectors.Vector := Tokenize ("X := ""open");
         begin
            Check (Bad.Is_Empty and then False, "lexer: unterminated string");
         end;
      exception
         when Lexical_Error =>
            Check (True, "lexer: unterminated string");
      end;
   end Test_Lexer;

   procedure Test_Operators is
   begin
      Expect ("X := A + B;",
              "StatementDeletion X := A + B;->null;|ArithmeticOperator +->-",
              "arithmetic in assignment");
      Expect ("package P is X : Integer := 2 ** 3; end P;",
              "NumericLiteral 2->3|ArithmeticOperator **->*|NumericLiteral 3->4",
              "exponent and literals");
      Expect ("package P is B : Boolean := X and then Y; end P;",
              "LogicalOperator and then->or else", "short circuit");
      Expect ("package P is B : Boolean := X and then Y and then Z; end P;",
              "LogicalOperator X and then Y->(X or else Y)"
              & "|LogicalOperator X and then Y and then Z->"
              & "((X and then Y) or else Z)",
              "short circuit chain is parenthesised");
      Expect ("package body P is procedure Q is begin "
              & "if A or else B or else C not in 1 | 3 then null; end if; "
              & "end Q; end P;",
              "ConditionalExpression A or else B or else C not in 1 | 3->True"
              & "|ConditionalExpression A or else B or else C not in 1 | 3->False"
              & "|LogicalOperator A or else B->(A and then B)"
              & "|LogicalOperator A or else B or else C not in 1 | 3->"
              & "((A or else B) and then C not in 1 | 3)"
              & "|MembershipOperator not in->in|NumericLiteral 1->0"
              & "|NumericLiteral 3->4",
              "membership choices stay in the operand of a logical chain");
      Expect ("package P is C : constant T := "
              & "(X and then Y and then Z | W => 1, others => 0); end P;",
              "LogicalOperator X and then Y->(X or else Y)"
              & "|LogicalOperator X and then Y and then Z->"
              & "((X and then Y) or else Z)"
              & "|NumericLiteral 1->0|NumericLiteral 0->1",
              "other choice bars still end a logical chain");
      Expect ("package P is procedure Q (X : in out Integer) with "
              & "Pre => (X > 0 and then X < 9), "
              & "Post => X > 1 and then (if X = 2 then X'Old = 1); end P;",
              "", "parenthesised parts of aspects are not mutated");
      Expect ("package P is subtype S is Integer range 1 .. 4; "
              & "type A is array (1 .. 3) of S; "
              & "C : S range 2 .. 3; end P;",
              "", "bounds of declared subtypes are not mutated");
      Expect ("package body P is procedure Q is "
              & "B : String (1 .. 6) := (1 .. 6 => 'x'); begin "
              & "for I in 1 .. 2 loop null; end loop; end Q; end P;",
              "NumericLiteral 1->0|NumericLiteral 6->7|NumericLiteral 1->0"
              & "|NumericLiteral 2->3",
              "bounds in expressions and loops are mutated");
      Expect ("package body P is procedure Q is "
              & "S : String renames B (1 .. 4); begin "
              & "L : for I in 2 .. 3 loop null; end loop L; end Q; end P;",
              "NumericLiteral 1->0|NumericLiteral 4->5|NumericLiteral 2->3"
              & "|NumericLiteral 3->4",
              "bounds of renamed slices and labelled loops are mutated");
      Expect ("package body P is procedure Q is begin "
              & "Y := A mod B; Z := A rem B; end Q; end P;",
              "ArithmeticOperator mod->*|ArithmeticOperator rem->*",
              "mod and rem become multiplication");
      Expect ("package P is procedure Q (X : Integer := 1; B : Boolean := "
              & "not True); function F (S : String := """") return T; end P;",
              "", "parameter defaults of completed subprograms are kept");
      Expect ("package P is procedure Q (B : Boolean := True) is null; "
              & "function F (X : Integer := 0) return Integer is (X); end P;",
              "BooleanLiteral True->False|NumericLiteral 0->1",
              "parameter defaults of self-completing profiles are mutated");
      Expect ("generic with procedure Q (X : Integer := 1) is R; "
              & "package P is end P;",
              "NumericLiteral 1->0",
              "parameter defaults of generic formal subprograms are mutated");
      Expect ("package body P is procedure Q (X : Integer := 1) is begin "
              & "Y := X + 2; end Q; end P;",
              "StatementDeletion Y := X + 2;->null;|ArithmeticOperator +->-"
              & "|NumericLiteral 2->3",
              "body statements after a default are still mutated");
      Expect ("package P is B : Boolean := F (A or B, (C or D) or E); end P;",
              "LogicalOperator or->and"
              & "|LogicalOperator or->and"
              & "|LogicalOperator or->and",
              "chain only spans operators at the same depth");
      Expect ("package P is B : Boolean := X not in 1 .. 3; end P;",
              "MembershipOperator not in->in|NumericLiteral 1->0|NumericLiteral 3->4",
              "not in");
      Expect ("package P is B : Boolean := not X; end P;",
              "UnaryOperator not->", "not");
      Expect ("package P is B : Boolean := True; S : String := ""hi""; end P;",
              "BooleanLiteral True->False|StringLiteral ""hi""->""""",
              "boolean and string literals");
      Expect ("package P is S : String := """"; end P;",
              "StringLiteral """"->""AdaMutant was here!""", "empty string literal");
      Expect ("package P is X : Float := 2.5; Y : Float := 1.0E3; Z : Integer := 0; end P;",
              "NumericLiteral 2.5->0.0|NumericLiteral 1.0E3->0.0"
              & "|NumericLiteral 0->1",
              "reals and zero");
      Expect ("package P is A : Integer := 16#FF# + 2#1010# + 16#fe#;"
              & " B : Integer := 1E6 + 8#7#E1 + 16#0#;"
              & " C : Integer := 16#FFFF_FFFF_FFFF_FFFF#;"
              & " D : Long_Long_Integer := 9223372036854775806;"
              & " E : Long_Long_Integer := 9223372036854775807; end P;",
              "NumericLiteral 16#FF#->16#100#|ArithmeticOperator +->-"
              & "|NumericLiteral 2#1010#->2#1011#|ArithmeticOperator +->-"
              & "|NumericLiteral 16#fe#->16#ff#"
              & "|NumericLiteral 1E6->1000001|ArithmeticOperator +->-"
              & "|NumericLiteral 8#7#E1->8#71#|ArithmeticOperator +->-"
              & "|NumericLiteral 16#0#->16#1#"
              & "|NumericLiteral 9223372036854775806->9223372036854775807",
              "based and exponent integer literals");
   end Test_Operators;

   procedure Test_Conditions is
   begin
      Expect ("procedure P is begin if A = B then null; end if; end P;",
              "ConditionalExpression A = B->True|ConditionalExpression A = B->False"
              & "|EqualityOperator =->/=",
              "if condition");
      Expect ("procedure P is begin while A < B loop null; end loop; end P;",
              "ConditionalExpression A < B->False|EqualityOperator <-><="
              & "|EqualityOperator <->/=",
              "while condition never becomes True");
      --  Each relational operator: two operators and a constant, which
      --  differ from it in one of A < B, A = B, A > B each.
      declare
         O : Scan_Options;
      begin
         O.Enabled := [others => False];
         O.Enabled (Equality_Operator) := True;
         Expect ("X := A < B; Y := A <= B; Z := A > B; W := A >= B;"
                 & " V := A = B; U := A /= B;",
                 "EqualityOperator <-><=|EqualityOperator <->/="
                 & "|EqualityOperator A < B->False"
                 & "|EqualityOperator <=-><|EqualityOperator <=->="
                 & "|EqualityOperator A <= B->True"
                 & "|EqualityOperator >->>=|EqualityOperator >->/="
                 & "|EqualityOperator A > B->False"
                 & "|EqualityOperator >=->>|EqualityOperator >=->="
                 & "|EqualityOperator A >= B->True"
                 & "|EqualityOperator =->/=|EqualityOperator A = B->False"
                 & "|EqualityOperator /=->=|EqualityOperator A /= B->True",
                 "relational operators: the sufficient set", O);
         --  The whole relation, between the operators around it.
         Expect ("X := not F (A) + 1 < B (2) * C and then D or else"
                 & " (for all I in R => G (I) = H) and then (if P = Q then 1"
                 & " else 2) > 0;",
                 "EqualityOperator <-><=|EqualityOperator <->/="
                 & "|EqualityOperator not F (A) + 1 < B (2) * C->False"
                 & "|EqualityOperator =->/=|EqualityOperator G (I) = H->False"
                 & "|EqualityOperator =->/=|EqualityOperator P = Q->False"
                 & "|EqualityOperator >->>=|EqualityOperator >->/="
                 & "|EqualityOperator (if P = Q then 1 else 2) > 0->False",
                 "relational operators: the extent of the relation", O);
         --  The whole condition of a loop: never the constant, which
         --  would not end it; with ConditionalExpression off, the other
         --  one.
         Expect ("while A < B loop null; end loop; exit when A >= B;"
                 & " exit Outer when A /= B; if A = B then null; end if;",
                 "EqualityOperator <-><=|EqualityOperator <->/="
                 & "|EqualityOperator A < B->False"
                 & "|EqualityOperator >=->>|EqualityOperator >=->="
                 & "|EqualityOperator A >= B->True"
                 & "|EqualityOperator /=->=|EqualityOperator A /= B->True"
                 & "|EqualityOperator =->/=|EqualityOperator A = B->False",
                 "relational operators: whole conditions without"
                 & " ConditionalExpression", O);
         O.Enabled (Conditional_Expression) := True;
         Expect ("while A < B loop null; end loop; exit when A >= B;"
                 & " if A = B then null; end if;",
                 "ConditionalExpression A < B->False"
                 & "|EqualityOperator <-><=|EqualityOperator <->/="
                 & "|ConditionalExpression A >= B->True"
                 & "|EqualityOperator >=->>|EqualityOperator >=->="
                 & "|ConditionalExpression A = B->True"
                 & "|ConditionalExpression A = B->False"
                 & "|EqualityOperator =->/=",
                 "relational operators: no constant for a whole condition",
                 O);
      end;
      Expect ("procedure P is begin exit when Done; end P;",
              "ConditionalExpression Done->True",
              "exit when only becomes True (False would hang the loop)");
   end Test_Conditions;

   procedure Test_Skipped is
   begin
      Expect ("with Ada.Text_IO; use Ada.Text_IO;" & LF
              & "package P is pragma Pure (P); end P;",
              "", "context clauses and pragmas");
      Expect ("package P is type T is range 0 .. 255; for T'Size use 8; "
              & "X : constant T := 3; end P;",
              "NumericLiteral 3->4",
              "representation clause");
      Expect ("package P is function F (X : Integer) return Integer"
              & " with Pre => X > 0; end P;",
              "", "aspects are not mutated by default");
      Expect ("package P is function F (X : Integer) return Integer"
              & " with Pre => X > 0; end P;",
              "EqualityOperator >->>=|EqualityOperator >->/="
              & "|EqualityOperator X > 0->False|NumericLiteral 0->1",
              "aspects with mutate_contracts",
              (Mutate_Contracts => True, others => <>));
      Expect ("package body P is "
              & "function G (X : Integer) return Integer is (X + 1) with Ghost; "
              & "procedure L (X : Integer) with Ghost; "
              & "procedure L (X : Integer) is begin X := X - 1; end L; "
              & "procedure Q (X : in out Integer) is begin "
              & "L (X * 2); S.M (X * 3); X := X + 1; end Q; end P;",
              "StatementDeletion X := X + 1;->null;|ArithmeticOperator +->-"
              & "|NumericLiteral 1->0",
              "ghost code is not mutated by default",
              (Ghost_Names => Ghost_Names
                 ("package S is procedure M (X : Integer) with Ghost; end S;"),
               others => <>));
      Expect ("package body P is "
              & "function G (X : Integer) return Integer is (X + 1) with Ghost; "
              & "procedure L (X : Integer) with Ghost; "
              & "procedure L (X : Integer) is begin X := X - 1; end L; "
              & "procedure Q (X : in out Integer) is begin "
              & "L (X * 2); S.M (X * 3); X := X + 1; end Q; end P;",
              "ArithmeticOperator +->-|NumericLiteral 1->0"
              & "|StatementDeletion X := X - 1;->null;|ArithmeticOperator -->+"
              & "|NumericLiteral 1->0|StatementDeletion L (X * 2);->null;"
              & "|ArithmeticOperator *->/|NumericLiteral 2->3"
              & "|StatementDeletion S.M (X * 3);->null;|ArithmeticOperator *->/"
              & "|NumericLiteral 3->4|StatementDeletion X := X + 1;->null;"
              & "|ArithmeticOperator +->-|NumericLiteral 1->0",
              "ghost code with mutate_contracts",
              (Mutate_Contracts => True, others => <>));
      Expect ("package body P is procedure G with Ghost; "
              & "procedure G is begin if A then null; end if; end; "
              & "A, B : Integer with Ghost; C : Integer with Ghost => False; "
              & "procedure Q is begin B := 1; C := 2; end Q; end P;",
              "StatementDeletion C := 2;->null;|NumericLiteral 2->3",
              "unnamed ghost body end, ghost object lists, Ghost => False");
      Expect ("package body P is" & LF
              & "   function Gh (X : Integer) return Integer with Ghost is" & LF
              & "   begin" & LF
              & "      return R : Integer do R := X + 1; end return;" & LF
              & "   end Gh;" & LF
              & "   procedure After (Y : in out Integer) is" & LF
              & "   begin" & LF
              & "      Y := Y + 2;" & LF
              & "   end After;" & LF
              & "end P;",
              "StatementDeletion Y := Y + 2;->null;|ArithmeticOperator +->-"
              & "|NumericLiteral 2->3",
              "a ghost body with an extended return ends at its own end");
      Expect ("function F return T is begin" & LF
              & "   return R : T with Relaxed_Initialization do" & LF
              & "      R := 1;" & LF
              & "   end return;" & LF
              & "end F;",
              "StatementDeletion R := 1;->null;|NumericLiteral 1->0",
              "the aspects of an extended return end at do");
      Expect ("package P is pragma Assert (X > 0); end P;",
              "AssertionDeletion pragma Assert (X > 0);->",
              "an assertion pragma is only deleted",
              (Mutate_Contracts => True, others => <>));
      Expect ("package P is type T is new Parent and Iface with null record;"
              & " end P;",
              "", "interface list and");
      Expect ("procedure P is begin return; end P;", "",
              "a return before the end of the body and null are not deleted");
   end Test_Skipped;

   procedure Test_Attributes is
      O : Scan_Options;
   begin
      O.Enabled := [others => False];
      O.Enabled (Attribute_Swap) := True;
      --  Not in the subtype of a declaration; in its initial value, in a
      --  loop range and in expressions, with the case kept.
      Expect ("procedure P is" & LF
              & "   S : String (1 .. A'Last);" & LF
              & "   L : constant Natural := A'Last;" & LF
              & "   subtype R is Integer range T'First .. T'Last;" & LF
              & "   type V is array (T'First .. T'Last) of R;" & LF
              & "begin" & LF
              & "   for I in A'First .. A'Last loop" & LF
              & "      X := Integer'Max (X, T'Succ (I)) + A'Length;" & LF
              & "   end loop;" & LF
              & "   Y := Float'FLOOR (Z) + Float'ceiling (Z);" & LF
              & "   V := Even'First_Valid + Even'First_Bit;" & LF
              & "   for X'Size use 32;" & LF
              & "end P;",
              "AttributeSwap Last->First|AttributeSwap First->Last"
              & "|AttributeSwap Last->First|AttributeSwap Max->Min"
              & "|AttributeSwap Succ->Pred|AttributeSwap FLOOR->CEILING"
              & "|AttributeSwap ceiling->floor"
              & "|AttributeSwap First_Valid->Last_Valid",
              "attribute swaps", O);
      --  A predicate is a contract: mutated with mutate_contracts only,
      --  also in a subtype declaration.  So are the bounds of a range in
      --  it (NumericLiteral).
      declare
         Pred : constant String :=
           "package P is" & LF
           & "   subtype S is Integer range 0 .. T'Last" & LF
           & "     with Dynamic_Predicate => S <= Integer'Max (10, 20);" & LF
           & "   subtype U is Integer with Static_Predicate => U in 1 .. 5;" & LF
           & "end P;";
         C : Scan_Options := O;
      begin
         Expect (Pred, "", "attribute swaps: not in a predicate by default", O);
         C.Mutate_Contracts := True;
         C.Enabled (Numeric_Literal) := True;
         Expect (Pred,
                 --  The first argument of an attribute is never mutated.
                 "AttributeSwap Max->Min"
                 & "|NumericLiteral 20->21|NumericLiteral 1->0"
                 & "|NumericLiteral 5->6",
                 "attribute swaps and bounds in a predicate", C);
      end;
      declare
         K : Mutator_Kind;
      begin
         Check (Parse ("AttributeSwap", K) and then K = Attribute_Swap
                and then Parse ("attribute_swap", K),
                "attribute swap by name");
      end;
   end Test_Attributes;

   procedure Test_Loop_Direction is
      O : Scan_Options;
      Loops : constant String :=
        "procedure P is" & LF
        & "   subtype Index is Positive range 1 .. 9;" & LF
        & "begin" & LF
        & "   for I in 1 .. N loop X := X + I; end loop;" & LF
        & "   Outer : for J in reverse A'Range loop null; end loop;" & LF
        & "   for K in Index loop null; end loop;" & LF
        & "   for L in A'Range (2) loop null; end loop;" & LF
        & "   for M in Small range 1 .. 3 loop null; end loop;" & LF
        & "   FOR Q IN 1 .. 2 LOOP null; END LOOP;" & LF
        & "   for C in V.Iterate loop null; end loop;" & LF
        & "   for D in reverse V.Iterate loop null; end loop;" & LF
        & "   for S in Types.Index loop null; end loop;" & LF
        & "   for B in Boolean loop null; end loop;" & LF
        & "   for F in Index when F > 1 loop null; end loop;" & LF
        & "   for G in Ext loop null; end loop;" & LF
        & "   for H in L loop null; end loop;" & LF
        & "   for M in Mp.Iterate when Key (M) in 1 .. 3 loop null; end loop;" & LF
        & "   for E of A loop null; end loop;" & LF
        & "   X := (for all I in 1 .. N => A (I) > 0);" & LF
        & "   Y := [for I in 1 .. 3 => I];" & LF
        & "   for T'Size use 8;" & LF
        & "end P;";
   begin
      O.Enabled := [others => False];
      O.Enabled (Loop_Direction) := True;
      O.Type_Names.Include ("ext");
      --  Over a range or a declared subtype (of the source, of the spec
      --  through Type_Names, or of Standard), both ways, also before an
      --  iterator filter; not over another name (a container, an
      --  iterator or a qualified name), in a quantified expression or an
      --  aggregate.  Removing "reverse" always compiles, also for an
      --  iterator.
      Expect (Loops,
              "LoopDirection in->in reverse|LoopDirection in reverse->in"
              & "|LoopDirection in->in reverse|LoopDirection in->in reverse"
              & "|LoopDirection in->in reverse|LoopDirection IN->IN REVERSE"
              & "|LoopDirection in reverse->in"
              & "|LoopDirection in->in reverse|LoopDirection in->in reverse"
              & "|LoopDirection in->in reverse",
              "loop direction", O);
      --  Off by default.
      Check (Ada.Strings.Fixed.Index (Describe (Loops), "LoopDirection") = 0,
             "loop direction is off by default");
      Check (Type_Names ("package Q is type T is (A, B); subtype S is T;"
                         & " task type Worker; X : Integer; end Q;").Contains ("s")
             and then not Type_Names ("package Q is X : Integer; end Q;")
                            .Contains ("x"),
             "type names of a spec");
   end Test_Loop_Direction;

   procedure Test_Deletions is
      O : Scan_Options;
   begin
      O.Enabled := [others => False];
      O.Enabled (Statement_Deletion) := True;
      --  Raise and return without a value, besides calls and
      --  assignments; not a return right before "exception" or the end
      --  of a body, nor an exit or delay statement.
      Expect ("procedure P is begin" & LF
              & "   loop exit when X > 3; X := X + 1; end loop;" & LF
              & "   if Bad then raise Constraint_Error with ""bad""; else Y := 1; end if;" & LF
              & "   if Done then Y := 2; return; end if;" & LF
              & "   delay 0.1;" & LF
              & "   <<L>> exit Outer;" & LF
              & "   Y := (if B then 1 else raise E);" & LF
              & "   return;" & LF
              & "exception when others => raise;" & LF
              & "end P;",
              "StatementDeletion X := X + 1;->null;"
              & "|StatementDeletion raise Constraint_Error with ""bad"";->null;"
              & "|StatementDeletion Y := 1;->null;"
              & "|StatementDeletion Y := 2;->null;"
              & "|StatementDeletion return;->null;"
              & "|StatementDeletion Y := (if B then 1 else raise E);->null;"
              & "|StatementDeletion raise;->null;",
              "statement deletion of raise and return", O);
      --  A return with a value stays.
      Expect ("function F return Integer is begin return 1; end F;", "",
              "statement deletion keeps a return with a value", O);
      --  The whole branch of an if without an else is condition -> False,
      --  which ConditionalExpression makes; without it, it is deleted.
      declare
         Guard : constant String :=
           "procedure P is begin" & LF
           & "   if Bad then raise E; end if;" & LF
           & "   if A then null; elsif Done then return; end if;" & LF
           & "end P;";
         C : Scan_Options := O;
      begin
         C.Enabled (Conditional_Expression) := True;
         Check (Ada.Strings.Fixed.Index (Describe (Guard, C),
                                         "StatementDeletion") = 0,
                "statement deletion leaves guard clauses",
                Describe (Guard, C));
         Expect (Guard, "StatementDeletion raise E;->null;"
                 & "|StatementDeletion return;->null;",
                 "statement deletion of guard clauses without"
                 & " ConditionalExpression", O);
      end;
      --  A raise or return at the very end of a file.
      Expect ("procedure P is begin raise", "",
              "statement deletion: raise at the end of a file", O);
   end Test_Deletions;

   procedure Test_Contract_Aspects is
      --  Only the aspects that are contracts are mutated (with
      --  Mutate_Contracts); the others never are, like representation
      --  clauses.
      O : Scan_Options := (Mutate_Contracts => True, others => <>);
   begin
      O.Enabled := [others => False];
      O.Enabled (Numeric_Literal) := True;
      O.Enabled (Boolean_Literal) := True;
      Expect ("package P is" & LF
              & "   procedure Q (X : Integer) with" & LF
              & "     Pre => X > 1, Inline => True, Global => null," & LF
              & "     Annotate => (GNATprove, Intentional, ""a"", ""b"")," & LF
              & "     Post'Class => X < 2;" & LF
              & "   type T is new Integer with Size => 32, Default_Value => 3;" & LF
              & "   subtype S is Integer with Static_Predicate => S in 4 .. 5;" & LF
              & "   X : Integer with Volatile => True, Alignment => 16;" & LF
              & "   function F return Boolean is (True)" & LF
              & "     with Subprogram_Variant => (Decreases => 6);" & LF
              & "end P;",
              "NumericLiteral 1->0|NumericLiteral 2->3|NumericLiteral 4->5"
              & "|NumericLiteral 5->6|BooleanLiteral True->False"
              & "|NumericLiteral 6->7",
              "only contract aspects are mutated", O);
      --  Aspects after "end record", "null record" and a private type.
      O.Enabled (Statement_Deletion) := True;
      Expect ("package Q is" & LF
              & "   type R is record" & LF
              & "      C : Integer := 7;" & LF
              & "   end record with Size => 64, Dynamic_Predicate => R.C > 8;" & LF
              & "   type E is null record with Size => 0;" & LF
              & "   type T is private with Type_Invariant => Valid (T)," & LF
              & "     Size => 32;" & LF
              & "   type L is limited private with Size => 16;" & LF
              & "   type D is new R with private with Size => 128;" & LF
              & "   procedure Go;" & LF
              & "private" & LF
              & "   type T is new Integer;" & LF
              & "end Q;",
              "NumericLiteral 7->8|NumericLiteral 8->9",
              "aspects after end record and private", O);
   end Test_Contract_Aspects;

   procedure Test_Weakening is
      --  ConjunctDeletion and AssertionDeletion change only contracts.
      O : Scan_Options := (Mutate_Contracts => True, others => <>);
   begin
      O.Enabled := [others => False];
      O.Enabled (Conjunct_Deletion) := True;
      O.Enabled (Assertion_Deletion) := True;
      Expect ("procedure Q (X, Y : Integer)" & LF
              & "  with Pre => X > 0 and then Y > 0," & LF
              & "       Post => (X > 1 and Y > 1 and X /= Y)," & LF
              & "       Inline => A and B" & LF
              & "is" & LF
              & "   Z : Integer := X and Y;" & LF
              & "   pragma Assert (X /= 3);" & LF
              & "begin" & LF
              & "   pragma Assert (X > 0 and then Y > 0, ""both"");" & LF
              & "   for I in 1 .. X loop" & LF
              & "      pragma Loop_Invariant (I > 0);" & LF
              & "      pragma Loop_Invariant (Y > 0);" & LF
              & "      Z := I;" & LF
              & "   end loop;" & LF
              & "   if Z > 0 and Y > 0 then" & LF
              & "      pragma Assume (Z > 0);" & LF
              & "   end if;" & LF
              & "   pragma Annotate (GNATprove, False_Positive, ""a"", ""b"");" & LF
              & "   pragma Assert_And_Cut (Z > 0);" & LF
              & "end Q;",
              "ConjunctDeletion X > 0 and then Y > 0->Y > 0"
              & "|ConjunctDeletion X > 0 and then Y > 0->X > 0"
              & "|ConjunctDeletion X > 1 and Y > 1 and X /= Y->Y > 1 and X /= Y"
              & "|ConjunctDeletion X > 1 and Y > 1 and X /= Y->X > 1 and X /= Y"
              & "|ConjunctDeletion X > 1 and Y > 1 and X /= Y->X > 1 and Y > 1"
              & "|AssertionDeletion pragma Assert (X /= 3);->"
              & "|AssertionDeletion pragma Assert (X > 0 and then Y > 0, ""both"");->"
              & "|ConjunctDeletion X > 0 and then Y > 0->Y > 0"
              & "|ConjunctDeletion X > 0 and then Y > 0->X > 0"
              & "|AssertionDeletion pragma Loop_Invariant (I > 0);->"
              & "|AssertionDeletion pragma Loop_Invariant (Y > 0);->"
              & "|AssertionDeletion pragma Assume (Z > 0);->null;"
              & "|AssertionDeletion pragma Assert_And_Cut (Z > 0);->",
              "contract weakening", O);
      --  The line breaks of what is left out stay.
      Expect ("procedure R with" & LF
              & "  Post => A" & LF
              & "    and then B;",
              "ConjunctDeletion A" & LF & "    and then B->B" & LF
              & "|ConjunctDeletion A" & LF & "    and then B->A" & LF,
              "contract weakening: line breaks", O);
      --  Applied, every mutant keeps the lines of the source, so the
      --  lines after it do not move.
      declare
         Source : constant String :=
           "procedure R with" & LF
           & "  Post => A" & LF
           & "    and then B" & LF
           & "    and then C;" & LF
           & "procedure Q is begin" & LF
           & "   pragma Assert (X > 0" & LF
           & "                  and Y > 0);" & LF
           & "   null;" & LF
           & "end Q;" & LF;

         function Lines (S : String) return Natural is
            N : Natural := 0;
         begin
            for C of S loop
               if C = ASCII.LF then
                  N := N + 1;
               end if;
            end loop;
            return N;
         end Lines;

         Same  : Boolean := True;
         Count : Natural := 0;
      begin
         for M of Find (Source, O) loop
            Count := Count + 1;
            Same := Same and then Lines (Apply (Source, M)) = Lines (Source);
         end loop;
         Check (Same and then Count = 6,
                "contract weakening: applied mutants keep the lines",
                Count'Image);
      end;
      --  Ghost code; not with Mutate_Contracts off.
      Expect ("procedure Lemma (X : Integer) with Ghost is" & LF
              & "begin" & LF
              & "   pragma Assert (X > 0 and X < 5);" & LF
              & "end Lemma;",
              "AssertionDeletion pragma Assert (X > 0 and X < 5);->null;"
              & "|ConjunctDeletion X > 0 and X < 5->X < 5"
              & "|ConjunctDeletion X > 0 and X < 5->X > 0",
              "contract weakening: a lemma", O);
      --  Not a list of interfaces of a ghost type; "null;" before a label
      --  at the end of a sequence.
      Expect ("package body Q is" & LF
              & "   type GT is new Root and I1 with null record with Ghost;" & LF
              & "   type I3 is interface and I1 with Ghost;" & LF
              & "   procedure P is begin pragma Assert (X > 1); <<L2>> end P;" & LF
              & "end Q;",
              "AssertionDeletion pragma Assert (X > 1);->null;",
              "contract weakening: interfaces and labels", O);
      O.Mutate_Contracts := False;
      Expect ("procedure P with Pre => A and B is begin" & LF
              & "pragma Assert (C and D); X := Y; end P;",
              "", "contract weakening: not with Mutate_Contracts off", O);
   end Test_Weakening;

   procedure Test_Proof_Warnings is
      --  The output of GNATprove 16.1 with --proof-warnings=on, and the one
      --  line format of earlier versions.
      Log : constant String :=
        "Phase 3 of 3: flow analysis and proof ..." & LF
        & " warning: unreachable code" & LF
        & "--> v.adb:8:10" & LF
        & "    8 |             return 200;" & LF
        & "      |             ^~~~~~~~~~" & LF & LF
        & " medium: loop invariant might fail in first iteration" & LF
        & "--> v.adb:15:33" & LF
        & " warning: pragma Assume is always False" & LF
        & "--> /home/x/src/v.adb:21:07" & LF
        & " warning: statement has no effect" & LF
        & "--> v.adb:30:7" & LF
        & "v.ads:4:14: warning: precondition is always False" & LF
        & "v.adb:25:21: warning: unreachable branch" & LF;
      W : constant AdaMutant.Files.String_Vectors.Vector :=
        AdaMutant.Runner.Proof_Warnings (Log);
      All_Of : Unbounded_String;
   begin
      for X of W loop
         Append (All_Of, X & "|");
      end loop;
      Check (To_String (All_Of) =
               "v.adb:8:10: warning: unreachable code"
               & "|v.adb:21:07: warning: pragma Assume is always False"
               & "|v.ads:4:14: warning: precondition is always False"
               & "|v.adb:25:21: warning: unreachable branch|",
             "proof warnings: always False and unreachable only",
             To_String (All_Of));
   end Test_Proof_Warnings;

   procedure Test_Never_Reached is
      Source : constant String :=
        "procedure P (X : Integer) is" & LF
        & "begin" & LF
        & "   if X > 0 then return; end if; Y := 1; Z := 2;" & LF
        & "end P;" & LF;
      --  Line 3 starts at byte 36.
      W : constant String := "p.adb:3:34: warning: unreachable code";

      function At_Col (C : Positive) return Boolean is
        (AdaMutant.Reports.Never_Reached (W, Source, "p.adb", 35 + C, 35 + C));

      --  GNAT counts a tab up to the next multiple of 8.
      Tabbed : constant String :=
        "begin" & LF & ASCII.HT & "Y := 1; Z := 2;" & LF & "end;" & LF;
   begin
      Check (At_Col (39), "never reached: in the statement of the warning");
      Check (not At_Col (47), "never reached: not the next statement");
      Check (not At_Col (11), "never reached: not before it on the line");
      Check (not AdaMutant.Reports.Never_Reached (W, Source, "q.adb", 74, 74),
             "never reached: not in another file");
      Check (not AdaMutant.Reports.Never_Reached
                   ("unreachable.adb:3:34: warning: precondition is always"
                    & " False", Source, "unreachable.adb", 74, 74),
             "never reached: only unreachable code");
      Check (not AdaMutant.Reports.Never_Reached
                   ("p.adb:3:35: warning: unreachable code", Source, "p.adb",
                    74, 74),
             "never reached: the warning must point at a token");
      Check (AdaMutant.Reports.Never_Reached
               ("p.adb:2:9: warning: unreachable code", Tabbed, "p.adb",
                13, 13)
             and then not AdaMutant.Reports.Never_Reached
               ("p.adb:2:9: warning: unreachable code", Tabbed, "p.adb",
                21, 21),
             "never reached: a tab");
   end Test_Never_Reached;

   procedure Test_Assertions_Check is
      use AdaMutant.Files;
      Tmp     : constant String :=
        Ada.Directories.Current_Directory & "/obj/ali";
      Sources : String_Vectors.Vector;
      Ali     : constant String :=
        "V ""GNAT Lib v16""" & LF & "A -gnat2022" & LF;
   begin
      if Ada.Directories.Exists (Tmp) then
         Ada.Directories.Delete_Tree (Tmp);
      end if;
      Ada.Directories.Create_Path (Tmp & "/src");
      Ada.Directories.Create_Path (Tmp & "/obj/gnatprove");
      Write (Tmp & "/src/counters.adb", "package body Counters is end;");
      Sources.Append ("src/counters.adb");
      Check (AdaMutant.Runner.Without_Assertions (Tmp, Sources) = "",
             "assertions: no ALI file, no warning");
      Write (Tmp & "/obj/counters.ali", Ali & "A -O2" & LF);
      Write (Tmp & "/obj/gnatprove/counters.ali", Ali & "A -gnata" & LF);
      Check (AdaMutant.Runner.Without_Assertions (Tmp, Sources) = "src/counters.adb",
             "assertions: compiled without -gnata",
             AdaMutant.Runner.Without_Assertions (Tmp, Sources));
      Write (Tmp & "/obj/counters.ali", Ali & "A -gnata" & LF & "A -O2" & LF);
      Check (AdaMutant.Runner.Without_Assertions (Tmp, Sources) = "",
             "assertions: compiled with -gnata");
      Write (Tmp & "/obj/counters.ali", Ali);
      Write (Tmp & "/gnat.adc", "pragma Assertion_Policy (Ignore);" & LF);
      Check (AdaMutant.Runner.Without_Assertions (Tmp, Sources)
               = "src/counters.adb",
             "assertions: an Assertion_Policy that ignores them");
      Write (Tmp & "/gnat.adc",
             "pragma Assertion_Policy (Ignore);  --  Check later" & LF
             & "pragma Assertion_Policy (Unchecked_Name => Ignore);" & LF
             & "--  pragma Assertion_Policy (Check);" & LF);
      Check (AdaMutant.Runner.Without_Assertions (Tmp, Sources)
               = "src/counters.adb",
             "assertions: Check in a comment or in another word");
      Write (Tmp & "/gnat.adc",
             "pragma Assertion_Policy (Pre => Ignore, Post => CHECK);" & LF);
      Check (AdaMutant.Runner.Without_Assertions (Tmp, Sources) = "",
             "assertions: turned on by a configuration pragma");
      Write (Tmp & "/gnat.adc",
             "pragma  --  turn assertions on" & LF
             & "  Assertion_Policy (Check);" & LF);
      Check (AdaMutant.Runner.Without_Assertions (Tmp, Sources) = "",
             "assertions: a comment between pragma and its name");
      --  Not Ada (gnatprep input): a word search.
      Write (Tmp & "/gnat.adc",
             "#if DEBUG then" & LF & "pragma Assertion_Policy (Check);" & LF
             & "#end if;" & LF);
      Check (AdaMutant.Runner.Without_Assertions (Tmp, Sources) = "",
             "assertions: Check in a file that is not Ada");
      Write (Tmp & "/gnat.adc",
             "#if DEBUG then" & LF
             & "pragma Assertion_Policy (Unchecked_Thing => Ignore);" & LF
             & "#end if;" & LF);
      Check (AdaMutant.Runner.Without_Assertions (Tmp, Sources)
               = "src/counters.adb",
             "assertions: no word Check in a file that is not Ada");
   end Test_Assertions_Check;

   procedure Test_Comments is
   begin
      --  A comment changes nothing, whatever it says.
      Expect ("procedure P is begin" & LF
              & "--  adamutant:disable-next-line ArithmeticOperator: reason" & LF
              & "X := A + 1;" & LF
              & "--  adamutant:disable Nonsense" & LF
              & "Y := 2;" & LF & "end P;",
              "StatementDeletion X := A + 1;->null;|ArithmeticOperator +->-"
              & "|NumericLiteral 1->0|StatementDeletion Y := 2;->null;"
              & "|NumericLiteral 2->3",
              "comments do not disable mutants");
      declare
         O : Scan_Options;
      begin
         O.Enabled := [others => False];
         O.Enabled (Numeric_Literal) := True;
         Expect ("procedure P is begin X := A + 1; end P;",
                 "NumericLiteral 1->0", "enabled mutator set", O);
      end;
   end Test_Comments;

   procedure Test_Ghost_Names is
      Names : constant Name_Sets.Set := Ghost_Names
        ("package P is" & LF
         & "   procedure Note (C : Integer) is null with Ghost;" & LF
         & "   procedure Plain (C : Integer) is null;" & LF
         & "   function Twice (X : Integer) return Integer is (X * 2)"
         & " with Ghost;" & LF
         & "   procedure Mark with Ghost;" & LF
         & "   function Old return Integer is abstract with Ghost;" & LF
         & "end P;" & LF);
   begin
      Check (Names.Contains ("note") and then Names.Contains ("twice")
             and then Names.Contains ("mark") and then Names.Contains ("old")
             and then not Names.Contains ("plain")
             and then Natural (Names.Length) = 4,
             "ghost names: null procedures and abstract subprograms too",
             Names.Length'Image);
      --  Ghost types: their declarations are ghost, but their names are
      --  not ghost names (no statement calls or assigns a type, and a
      --  component of the same name is not ghost).
      declare
         Source : constant String :=
           "package body T is" & LF
           & "   type Model is record" & LF
           & "      V : Integer := 0;" & LF
           & "   end record with Ghost;" & LF
           & "   type Index is range 1 .. 10 with Ghost;" & LF
           & "   subtype Small is Integer range 0 .. 5 with Ghost;" & LF
           & "   type Pair (D : Integer) is tagged private with Ghost;" & LF
           & "   type Plain is range 1 .. 3;" & LF
           & "   procedure P is" & LF
           & "   begin" & LF
           & "      S.Index := 7;" & LF
           & "      Log.Model (8);" & LF
           & "   end P;" & LF
           & "end T;" & LF;
         O      : Scan_Options := (Mutate_Contracts => True, others => <>);
         Marked : Unbounded_String;
      begin
         O.Enabled := [others => False];
         O.Enabled (Numeric_Literal) := True;
         O.Enabled (Statement_Deletion) := True;
         for M of Find (Source, O) loop
            Append (Marked, (if M.Contract then "C" else "-"));
         end loop;
         Check (Ghost_Names (Source).Is_Empty
                and then To_String (Marked) = "C----",
                "ghost types: declarations, not names", To_String (Marked));
      end;
      --  "end record with Ghost" at the start of malformed text.
      Check (Ghost_Names ("end record with Ghost;").Is_Empty,
             "ghost types: no declaration before end record");
   end Test_Ghost_Names;

   procedure Test_Contract_Flag is
      --  Mutations in aspects and in ghost code are marked, also in the
      --  body of a subprogram that only its specification declares ghost.
      Source : constant String :=
        "package body P is" & LF
        & "   function F (X : Integer) return Integer" & LF
        & "     with Post => F'Result > 1 is" & LF
        & "   begin" & LF
        & "      return X + 2;" & LF
        & "   end F;" & LF
        & "   procedure G (X : in out Integer) is" & LF
        & "   begin" & LF
        & "      X := X * 3;" & LF
        & "   end G;" & LF
        & "end P;" & LF;
      Options : Scan_Options := (Mutate_Contracts => True, others => <>);
      Marked  : Unbounded_String;
   begin
      Options.Ghost_Names.Insert ("g");
      for M of Find (Source, Options) loop
         Append (Marked, (if M.Contract then "C" else "-"));
      end loop;
      --  > and 1 (two mutations of > and one of 1) in the aspect; + and 2
      --  in F; the deletion, * and 3 in G.
      Check (To_String (Marked) = "CCCC--CCC",
             "mutations of contracts and ghost code are marked",
             To_String (Marked) & " " & Describe (Source, Options));
   end Test_Contract_Flag;

   procedure Test_Apply is
      S : constant String := "X := A + B;";
      M : Mutation;
   begin
      for Each of Find ("procedure P is begin " & S & " end P;", (others => <>)) loop
         if Each.Kind = Arithmetic_Operator then
            M := Each;
         end if;
      end loop;
      Check (Apply ("procedure P is begin " & S & " end P;", M)
             = "procedure P is begin X := A - B; end P;", "apply");
      --  A deleted statement over two lines keeps its line breaks.
      declare
         T : constant String :=
           "procedure P is begin" & LF & "X := F" & ASCII.CR & LF
           & "  (A);  -- c" & LF & "Y := 1; end P;";
      begin
         M := (others => <>);
         for Each of Find (T, (others => <>)) loop
            if Each.Kind = Statement_Deletion and then M.Last = 0 then
               M := Each;
            end if;
         end loop;
         Check (Apply (T, M) = "procedure P is begin" & LF & "null;"
                & ASCII.CR & LF & "  -- c" & LF & "Y := 1; end P;",
                "apply keeps the line breaks", Apply (T, M));
      end;
   end Test_Apply;

   procedure Test_Files is
      use AdaMutant.Files;
   begin
      Check (AdaMutant.Runner.Build_Error
               ("a.adb:1:1: warning: w" & ASCII.CR & ASCII.LF
                & "a.adb:2:3: error: bad" & ASCII.CR & ASCII.LF
                & "gprbuild: *** compilation phase failed")
             = "a.adb:2:3: error: bad", "build error line");
      Check (AdaMutant.Runner.Build_Error ("x.adb:4:5: error: last")
             = "x.adb:4:5: error: last", "build error on last line");
      Check (AdaMutant.Runner.Build_Error ("gprbuild: failed" & ASCII.LF)
             = "", "no build error line");
      declare
         use AdaMutant.Runner;
         Log : constant String :=
           "Phase 3 of 3: flow analysis and proof ..." & LF
           & LF
           & "counters.adb:10:07: warning: statement has no effect" & LF
           & "   10 |      if False then" & LF
           & "counters.adb:5:16: medium: range check might fail, cannot prove"
           & " lower bound for C - 1" & ASCII.CR & LF
           & "    5 |      return C - 1;" & LF
           & "  possible fix: add precondition (C >= 1) to subprogram at"
           & " counters.ads:7" & LF
           & "counters.ads:9:17: medium: postcondition might fail" & LF
           & "p.adb:3:4: info: overflow check proved" & LF
           & "C:\work\p.adb:8:9: high: ""X"" is not initialized" & LF
           & "p.adb:2:1: error: missing "";""" & LF
           & "counters.ali:0:0: note: a line number 0 is not a message" & LF
           & "2026-11-17T08:00:00 q.adb:5:16: medium: overflow check might"
           & " fail" & LF
           & "gnatprove: unproved check messages considered as errors" & LF;
         F : constant String_Vectors.Vector := Proof_Failures (Log);
      begin
         Check (Natural (F.Length) = 5, "proof failures: count",
                F.Length'Image);
         Check (F (3) = "p.adb:8:9: high: ""X"" is not initialized",
                "proof failures: without the directories", F (3));
         Check (F (5) = "q.adb:5:16: medium: overflow check might fail"
                and then Check_Kind (F (5)) = "overflow check",
                "proof failures: a line with something in front", F (5));
         Check (F (1) = "counters.adb:5:16: medium: range check might fail,"
                        & " cannot prove lower bound for C - 1",
                "proof failures: the line of the message", F (1));
         Check (Check_Kind (F (1)) = "range check", "check kind: range check",
                Check_Kind (F (1)));
         Check (Check_Kind (F (2)) = "postcondition",
                "check kind: postcondition", Check_Kind (F (2)));
         Check (Check_Kind (F (3)) = "initialization",
                "check kind: flow analysis, Windows path", Check_Kind (F (3)));
         Check (Check_Kind (F (4)) = "error", "check kind: error",
                Check_Kind (F (4)));
         Check (Check_Kind
                  ("p.adb:7:8: medium: loop invariant might not be preserved"
                   & " by an arbitrary iteration") = "loop invariant",
                "check kind: loop invariant");
         Check (Check_Kind ("p.adb:7:8: medium: ""X"" might not be"
                            & " initialized, in call") = "initialization"
                and then Check_Kind
                  ("p.adb:7:8: high: ""Y"" is not initialized in ""Init""")
                  = "initialization"
                and then Check_Kind
                  ("p.adb:7:8: medium: ""X"" might not be initialized in"
                   & " ""Cond_Init""") = "initialization"
                and then Check_Kind
                  ("p.adb:7:8: high: ""B"" constituent of ""State"" is not"
                   & " initialized") = "initialization",
                "check kind: initialization");
         --  The names that a message quotes are not part of the kind.
         Check (Check_Kind
                  ("p.adb:1:2: high: ""G"" must be listed in the Global"
                   & " aspect of ""Use_Global"" (SPARK RM 6.1.4(15))")
                = "Global aspect",
                "check kind: Global aspect",
                Check_Kind
                  ("p.adb:1:2: high: ""G"" must be listed in the Global"
                   & " aspect of ""Use_Global"" (SPARK RM 6.1.4(15))"));
         Check (Check_Kind ("p.ads:1:2: medium: missing dependency"
                            & " ""Z => X""") = "missing dependency"
                and then Check_Kind ("p.ads:1:2: medium: incorrect dependency"
                                     & " ""Y => X""") = "incorrect dependency"
                and then Check_Kind ("p.ads:1:2: low: unused global"
                                     & " ""Total""") = "unused global",
                "check kind: dependencies and globals");
         Check (Check_Kind
                  ("p.adb:1:2: high: formal parameter ""X"" and global ""G"""
                   & " are aliased (SPARK RM 6.4.2)")
                = "aliasing"
                and then Check_Kind
                  ("p.adb:1:2: medium: formal parameters ""X"" and ""Y"" might"
                   & " be aliased (SPARK RM 6.4.2)") = "aliasing",
                "check kind: aliasing",
                Check_Kind
                  ("p.adb:1:2: high: formal parameter ""X"" and global ""G"""
                   & " are aliased (SPARK RM 6.4.2)"));
         Check (Check_Kind
                  ("p.adb:1:2: medium: aspect Always_Terminates on ""Loops"""
                   & " could be incorrect, loop might be nonterminating")
                = "termination"
                and then Check_Kind
                  ("p.adb:1:2: medium: all paths in ""Asserts"" raise"
                   & " exceptions or do not terminate normally")
                  = "termination",
                "check kind: termination");
         Check (Check_Kind ("p.adb:1:2: medium: , x") = "unknown"
                and then Check_Kind ("p.adb:1:2: medium:") = "unknown"
                and then Check_Kind ("p.adb:1:2: medium: ""X""") = "unknown",
                "check kind: nothing left");
         --  GNATprove 16 puts the place on the next line.  The place in
         --  "possible fix" belongs to the fix, and a warning is no failure.
         declare
            Log16 : constant String :=
              "Phase 2 of 3: analysis of data and information flow ..." & LF
              & " warning: statement has no effect" & LF
              & "--> weak.adb:10:07" & LF
              & " medium: range check might fail, cannot prove upper bound"
              & " for A + B" & LF
              & "--> counters.adb:13:19" & LF
              & "   13 |         return A + B;" & LF
              & "      + e.g. when A = Count'Last" & LF
              & "      + possible fix: add precondition (A <= Count'Last - B)"
              & " to subprogram at counters.ads:11" & LF
              & "      --> counters.ads:11:13" & LF
              & " high: postcondition might fail, cannot prove"
              & " Saturating_Add'Result = A + B" & ASCII.CR & LF
              & "--> /x/y/counters.ads:13:28" & ASCII.CR & LF
              & " medium: postcondition might fail" & LF
              & "gnatprove: unproved check messages considered as errors" & LF
              & " medium: overflow check might fail" & LF
              & "--> q.adb:5:16";
            F16 : constant String_Vectors.Vector := Proof_Failures (Log16);
         begin
            Check (Natural (F16.Length) = 3
                   and then F16 (1) = "counters.adb:13:19: medium: range check"
                                      & " might fail, cannot prove upper bound"
                                      & " for A + B"
                   and then F16 (2) = "counters.ads:13:28: high: postcondition"
                                      & " might fail, cannot prove"
                                      & " Saturating_Add'Result = A + B"
                   and then F16 (3) = "q.adb:5:16: medium: overflow check"
                                      & " might fail"
                   and then Check_Kind (F16 (1)) = "range check"
                   and then Check_Kind (F16 (2)) = "postcondition",
                   "proof failures: GNATprove 16",
                   F16.Length'Image
                   & (if F16.Is_Empty then "" else " " & F16 (1)));
         end;
         --  A long error keeps all its text in Details.
         begin
            Fail ([1 .. 300 => 'x']);
         exception
            when E : Run_Error =>
               Check (Ada.Exceptions.Exception_Message (E)'Length <= 200
                      and then Details = [1 .. 300 => 'x'],
                      "run error: a long message",
                      Ada.Exceptions.Exception_Message (E)'Length'Image);
         end;
         --  Not inside a character of UTF-8 ("é" is 2 bytes, at 180).
         begin
            Fail ([1 .. 179 => 'x'] & Character'Val (16#C3#)
                  & Character'Val (16#A9#) & [1 .. 100 => 'y']);
         exception
            when E : Run_Error =>
               Check (Ada.Exceptions.Exception_Message (E)
                      = [1 .. 179 => 'x'] & " ... (below)",
                      "run error: cut before a character",
                      Ada.Exceptions.Exception_Message (E));
         end;
         begin
            Fail ("short");
         exception
            when E : Run_Error =>
               Check (Ada.Exceptions.Exception_Message (E) = "short"
                      and then Details = "", "run error: a short message");
         end;
         --  The counterexample under a message, in both formats; a
         --  message without one, and one that a warning follows.
         declare
            use AdaMutant.Runner.Proof_Message_Vectors;
            Log : constant String :=
              "counters.adb:13:19: high: range check might fail" & LF
              & "   13 |         return A + B;" & LF
              & "  e.g. when A = Count'Last" & LF
              & "        and B = 1" & LF
              & "  reason for check: returned value must fit" & LF
              & " medium: range check might fail, cannot prove upper bound"
              & " for H * 2" & LF
              & "--> weak.adb:13:19" & LF
              & "      + e.g. when H = 51" & LF
              & "      + reason for check: returned value must fit" & LF
              & "      and so on" & LF
              & "      + possible fix: add or complete related loop invariants"
              & " or postconditions" & LF
              & " medium: postcondition might fail" & LF
              & "--> hard.ads:4:19" & LF
              & "      + provers reached time limit before completing the"
              & " proof" & LF
              & " warning: statement has no effect" & LF
              & "--> weak.adb:10:07" & LF
              & "      + e.g. when X = 3" & LF;
            P : constant Vector := Proof_Messages (Log);
         begin
            Check (Natural (P.Length) = 3
                   and then To_String (P (1).Example)
                            = "e.g. when A = Count'Last and B = 1"
                   and then To_String (P (2).Text)
                            = "weak.adb:13:19: medium: range check might"
                              & " fail, cannot prove upper bound for H * 2"
                   and then To_String (P (2).Example) = "e.g. when H = 51"
                   and then To_String (P (3).Example) = ""
                   and then not P (1).Weak_Contract
                   and then P (2).Weak_Contract
                   and then not P (3).Weak_Contract,
                   "proof messages: counterexamples",
                   P.Length'Image
                   & (if P.Is_Empty then ""
                      else " [" & To_String (P (P.Last_Index).Example) & "]"));
         end;
         --  "--output=oneline": all in the message.
         declare
            use AdaMutant.Runner.Proof_Message_Vectors;
            P : constant Vector := Proof_Messages
              ("w.adb:13:19: medium: range check might fail (e.g. when"
               & " R = (A => 1, B => (2, 3))) [reason for check: x]"
               & " [possible fix: add or complete related loop invariants or"
               & " postconditions]" & LF
               & "w.adb:14:1: medium: overflow check might fail (e.g. when"
               & " X = 1" & LF);
         begin
            Check (Natural (P.Length) = 2
                   and then To_String (P (1).Text)
                            = "w.adb:13:19: medium: range check might fail"
                   and then To_String (P (1).Example)
                            = "e.g. when R = (A => 1, B => (2, 3))"
                   and then P (1).Weak_Contract
                   and then To_String (P (2).Example) = ""
                   and then not P (2).Weak_Contract,
                   "proof messages: one line each",
                   (if P.Is_Empty then "none"
                    else To_String (P (1).Example)));
         end;
         --  Parentheses in characters and strings are not those of the
         --  counterexample; an attribute is not a character.
         declare
            use AdaMutant.Runner.Proof_Message_Vectors;
            P : constant Vector := Proof_Messages
              ("p.adb:4:7: high: assertion might fail (e.g. when C = ')')"
               & " [x]" & LF
               & "p.adb:5:7: high: assertion might fail (e.g. when C = '('"
               & " and S = ""a("""")b"" and N = Count'Last)" & LF
               & "p.adb:6:7: high: assertion might fail (e.g. when C = '''"
               & " and D = (1, 2))" & LF);
         begin
            Check (Natural (P.Length) = 3
                   and then To_String (P (1).Example) = "e.g. when C = ')'"
                   and then To_String (P (2).Example)
                            = "e.g. when C = '(' and S = ""a("""")b"" and"
                              & " N = Count'Last"
                   and then To_String (P (3).Example)
                            = "e.g. when C = ''' and D = (1, 2)",
                   "proof messages: parentheses in characters and strings",
                   (if P.Is_Empty then "none"
                    else To_String (P (1).Example) & " | "
                      & To_String (P (P.Last_Index).Example)));
         end;
         Check (Proof_Failures ("gnatprove: error" & LF).Is_Empty,
                "proof failures: none");
      end;
      Check (Glob_Match ("src/**/*.adb", "src/a.adb"), "glob ** empty");
      Check (Glob_Match ("src/**/*.adb", "src/x/y/a.adb"), "glob ** deep");
      Check (not Glob_Match ("src/*.adb", "src/x/a.adb"), "glob * no slash");
      Check (Glob_Match ("?.ads", "p.ads"), "glob ?");
      Check (not Glob_Match ("*.adb", "a.ads"), "glob extension");
      Check (Join ("a", "b/c") = "a/b/c", "join");
      declare
         use GNAT.OS_Lib;
         Path : constant String := "write_changed.tmp";
         Stamp : OS_Time;
         Deleted : Boolean;
      begin
         Write (Path, "original");
         --  An odd second ahead of the clock, which the rewrite cannot pass
         --  by itself: one second later would round to the same even
         --  second in the ALI files GNAT writes on Windows.  (The type of
         --  To_C is not named: it is time_t up to GNAT 15 and
         --  Long_Long_Integer from GNAT 16 on.)
         Stamp := File_Time_Stamp (Path);
         Stamp := To_Ada
           (To_C (Stamp) + (if To_C (Stamp) mod 2 = 0 then 1001 else 1002));
         Set_File_Last_Modify_Time_Stamp (Path, Stamp);
         Write_Changed (Path, "mutant");
         Check (File_Time_Stamp (Path) = To_Ada (To_C (Stamp) + 2),
                "rewrite moves the time stamp two seconds");
         Check (Read (Path) = "mutant", "rewrite content");
         --  A wait for the time stamp of a file: none for an old file or
         --  a file that does not exist, two seconds for a new one, and a
         --  time stamp in the future counts as now.
         declare
            Names : String_Vectors.Vector;
            Start : OS_Time;
         begin
            Names.Append (Path);
            Names.Append ("none.txt");
            Write (Path, "x");
            Set_File_Last_Modify_Time_Stamp
              (Path, To_Ada (To_C (Current_Time) - 100));
            Start := Current_Time;
            Wait_Past_Stamps (".", Names);
            Check (To_C (Current_Time) - To_C (Start) <= 1,
                   "no wait for an old file");
            --  The clock before the write: a new file may get a time stamp
            --  in the next second while the clock still shows this one.
            Start := Current_Time;
            Write (Path, "y");
            Wait_Past_Stamps (".", Names);
            Check (To_C (Current_Time) - To_C (Start) in 2 .. 3,
                   "a wait of two seconds for a new file");
            Set_File_Last_Modify_Time_Stamp
              (Path, To_Ada (To_C (Current_Time) + 1000));
            Start := Current_Time;
            Wait_Past_Stamps (".", Names);
            Check (To_C (Current_Time) - To_C (Start) in 2 .. 3,
                   "a time stamp in the future counts as now");
            Names.Clear;
            Names.Append ("none.txt");
            Start := Current_Time;
            Wait_Past_Stamps (".", Names);
            Check (To_C (Current_Time) - To_C (Start) <= 1,
                   "no wait for a file that does not exist");
         end;
         Write (Path, "abc");
         Check (Digest (Path)
                = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f"
                  & "20015ad", "digest of a file", Digest (Path));
         Write (Path, [1 .. 70_000 => 'a']);
         Check (Digest (Path)
                = "66915c0872933db504e7578828dd85b7e74a4e0a061f9756793b89c41"
                  & "51bd4b5", "digest of a file longer than the buffer",
                Digest (Path));
         Delete_File (Path, Deleted);
      end;
   end Test_Files;

   --  POSIX only: uses /bin/sh commands.
   procedure Test_Processes is
      use AdaMutant.Files;
      use AdaMutant.Processes;
      Tmp  : constant String := Ada.Directories.Current_Directory & "/obj/proc";
      Log  : constant String := Tmp & "/log.txt";
      None : String_Vectors.Vector;
      R    : Run_Result;
   begin
      if Ada.Directories.Exists (Tmp) then
         Ada.Directories.Delete_Tree (Tmp);
      end if;
      Ada.Directories.Create_Path (Tmp & "/a");
      Write (Tmp & "/a/t.sh", "#!/bin/sh" & LF & "exit 0" & LF);
      R := Run ("chmod +x t.sh", Tmp & "/a", Log, 0, 10.0);
      Check (R.Exit_Code = 0, "chmod");
      Copy_Tree (Tmp & "/a", Tmp & "/b", None);
      R := Run ("./t.sh", Tmp & "/b", Log, 0, 10.0);
      Check (R.Exit_Code = 0, "Copy_Tree keeps the executable bit");

      Ada.Environment_Variables.Set ("ADAMUTANT_MUTANT_ID", "42");
      R := Run ("test ""$ADAMUTANT_MUTANT_ID"" = 7", Tmp, Log, 7, 10.0);
      Check (R.Exit_Code = 0, "mutant id overrides the parent environment");
      Ada.Environment_Variables.Clear ("ADAMUTANT_MUTANT_ID");

      Ada.Environment_Variables.Set ("ADAMUTANT_MUTANT_FILE", "old.adb");
      R := Run ("test ""$ADAMUTANT_MUTANT_ID:$ADAMUTANT_MUTANT_FILE"""
                & " = ""7:src/a b.adb""",
                Tmp, Log, 7, 10.0, Mutant_File => "src/a b.adb");
      Check (R.Exit_Code = 0, "mutant file and id are both set");
      R := Run ("test ""$ADAMUTANT_MUTANT_FILE"" = 'src/a" & ASCII.LF & "b.adb'",
                Tmp, Log, 7, 10.0, Mutant_File => "src/a" & ASCII.LF & "b.adb");
      Check (R.Exit_Code = 0, "a line feed in the mutant file is kept");
      R := Run ("test -z ""$ADAMUTANT_MUTANT_FILE""", Tmp, Log, 0, 10.0);
      Check (R.Exit_Code = 0, "no mutant file empties the variable");
      Ada.Environment_Variables.Clear ("ADAMUTANT_MUTANT_FILE");

      R := Run ("sleep 5", Tmp, Log, 0, 0.3);
      Check (R.Timed_Out, "timeout");
   end Test_Processes;

   procedure Test_Positions is
      use AdaMutant.Positions;
      S : constant String := "ab" & LF & Character'Val (16#C3#)
        & Character'Val (16#A9#) & "x";
      P : constant Position := Of_Offset (S, S'Last);
   begin
      Check (P.Line = 2 and then P.Column = 2, "position counts UTF-8 once",
             P.Line'Image & P.Column'Image);
   end Test_Positions;

   procedure Test_Changes is
      use AdaMutant.Changes;
      Diff : constant String :=
        "diff --git src/a.adb src/a.adb" & LF
        & "index 1..2 100644" & LF
        & "--- src/a.adb" & LF
        & "+++ src/a.adb" & LF
        & "@@ -3 +3 @@ procedure P is" & LF
        & "-   X := 1;" & LF
        & "+   X := 2;" & LF
        & "@@ -10,2 +10,0 @@" & LF
        & "---  removed comment" & LF
        & "-+++ removed" & LF
        & "@@ -20,0 +19,3 @@" & LF
        & "+++ added" & LF
        & "+" & LF
        & "+   Y := 3;" & ASCII.CR & LF
        & "diff --git src/gone.adb src/gone.adb" & LF
        & "deleted file mode 100644" & LF
        & "--- src/gone.adb" & LF
        & "+++ /dev/null" & LF
        & "@@ -1,2 +0,0 @@" & LF
        & "-a" & LF
        & "-b" & LF
        & "diff --git ""src/b c.adb"" ""src/b c.adb""" & LF
        & "--- ""src/b c.adb""" & LF
        & "+++ ""src/b c.adb""" & LF
        & "@@ -1 +1,2 @@" & LF
        & "-x" & LF
        & "+y" & LF
        & "+z" & LF
        & "--- ""src/q\""\\\303\251.adb""" & LF
        & "+++ ""src/q\""\\\303\251.adb""" & LF
        & "@@ -1 +1 @@" & LF
        & "-x" & LF
        & "+y";
      M : constant Change_Maps.Map := Parse_Diff (Diff);
   begin
      Check (Natural (M.Length) = 3 and then M.Contains ("src/a.adb")
             and then M.Contains ("src/b c.adb")
             and then M.Contains ("src/q""\" & Character'Val (16#C3#)
                                  & Character'Val (16#A9#) & ".adb"),
             "diff files: changed ones, not deleted ones, quotes removed",
             M.Length'Image);
      Check (Touches (M, "src/a.adb", 3, 3)
             and then Touches (M, "src/a.adb", 1, 3)
             and then not Touches (M, "src/a.adb", 4, 18)
             and then Touches (M, "src/a.adb", 21, 25)
             and then not Touches (M, "src/a.adb", 22, 25)
             and then Touches (M, "src/b c.adb", 2, 2)
             and then not Touches (M, "src/b c.adb", 3, 3)
             and then not Touches (M, "src/other.adb", 1, 100),
             "diff lines: modified and added, not removed");
   end Test_Changes;

   procedure Test_Config is
      use AdaMutant.Config;

      procedure Rejects (Text, Name : String) is
      begin
         declare
            C : constant Configuration := Parse (Text, "/r");
         begin
            Check (To_String (C.Build) = "" and then False, Name, "accepted");
         end;
      exception
         when Config_Error =>
            Check (True, Name);
      end Rejects;

      C : constant Configuration := Parse
        ("# comment" & LF
         & "mutate = [""src/**/*.adb"", 'x.ads']" & LF
         & "build = ""gprbuild -P \""p.gpr\""""" & LF
         & "test = ""bin/t""  # trailing" & LF
         & "prove = ""gnatprove -P p.gpr""" & LF
         & "concurrency = 3" & LF
         & "timeout_factor = 2.5" & LF
         & "mutators = [""ArithmeticOperator""]" & LF
         & "[thresholds]" & LF & "high = 90" & LF & "break = 10" & LF,
         "/r");
   begin
      Check (Natural (C.Mutate.Length) = 2 and then C.Mutate (2) = "x.ads",
             "config arrays");
      Check (To_String (C.Build) = "gprbuild -P ""p.gpr""", "config escapes");
      Check (C.Concurrency = 3 and then C.Timeout_Factor = 2.5,
             "config numbers");
      Check (C.Scan.Enabled (Arithmetic_Operator)
             and then not C.Scan.Enabled (Numeric_Literal), "config mutators");
      declare
         Base : constant String :=
           "build = ""b""" & LF & "prove = ""p""" & LF & "test = ""t""" & LF;
         D : constant Configuration := Parse (Base, "/r");
         I : constant Configuration := Parse
           (Base & "include_mutators = [""LoopDirection""]" & LF
            & "exclude_mutators = [""StringLiteral""]" & LF, "/r");
         M : constant Configuration := Parse
           (Base & "mutators = [""LoopDirection""]" & LF, "/r");
      begin
         Check (not D.Scan.Enabled (Loop_Direction)
                and then D.Scan.Enabled (Attribute_Swap)
                and then I.Scan.Enabled (Loop_Direction)
                and then I.Scan.Enabled (Numeric_Literal)
                and then not I.Scan.Enabled (String_Literal)
                and then M.Scan.Enabled (Loop_Direction)
                and then not M.Scan.Enabled (Numeric_Literal),
                "config: include_mutators adds to the default mutators");
      end;
      Rejects ("build = ""b""" & LF & "prove = ""p""" & LF & "test = ""t""" & LF
               & "include_mutators = [""Nonsense""]",
               "config: an unknown mutator to include");
      --  Contracts are always mutated; "mutate_contracts = false" is
      --  refused, "true" accepted.
      Check (C.Scan.Mutate_Contracts
             and then Parse ("build = ""b""" & LF & "prove = ""p""" & LF
                             & "test = ""t""" & LF
                             & "mutate_contracts = true" & LF, "/r")
                        .Scan.Mutate_Contracts,
             "config: contracts are always mutated");
      Rejects ("build = ""b""" & LF & "prove = ""p""" & LF & "test = ""t""" & LF
               & "mutate_contracts = false",
               "config: mutate_contracts = false");
      Check (C.High = 90 and then C.Break = 10, "config thresholds");
      Check (Natural (C.Tests.Length) = 1
             and then To_String (C.Tests (1).Name) = "tests"
             and then To_String (C.Tests (1).Command) = "bin/t"
             and then not C.Named_Tests and then C.Bail,
             "config: the test command is the test ""tests""");
      declare
         N : constant Configuration := Parse
           ("build = ""b""" & LF & "prove = ""p""" & LF & "bail = false" & LF
            & "[thresholds]" & LF & "high = 90" & LF
            & "[tests]" & LF & "parser = ""bin/p --all""  # first" & LF
            & "lexer-2.x = 'bin/l'" & LF, "/r");
      begin
         Check (Natural (N.Tests.Length) = 2
                and then To_String (N.Tests (1).Name) = "parser"
                and then To_String (N.Tests (1).Command) = "bin/p --all"
                and then To_String (N.Tests (2).Name) = "lexer-2.x"
                and then N.Named_Tests and then not N.Bail
                and then N.High = 90,
                "config: tests table");
      end;
      Rejects ("build = ""b""" & LF & "prove = ""p""" & LF & "test = ""t""" & LF
               & "[tests]" & LF & "a = ""x""",
               "config: test and tests table");
      Rejects ("build = ""b""" & LF & "prove = ""p""" & LF & "[tests]" & LF & "a = ""x""" & LF
               & "a = ""y""", "config: duplicate test name");
      Rejects ("build = ""b""" & LF & "prove = ""p""" & LF & "[tests]" & LF & "a = """"",
               "config: empty test command");
      Rejects ("build = ""b""" & LF & "prove = ""p""" & LF & "[tests]" & LF & "a = ""x""" & LF
               & "prove = ""gnatprove""", "config: a setting after [tests]");
      Rejects ("build = ""b""" & LF & "prove = ""p""" & LF & "[tests]" & LF & "a = ""x""" & LF
               & "bail = false", "config: bail after [tests]");
      Rejects ("build = ""b""" & LF & "prove = ""p""" & LF & "[tests]" & LF & "Unit = ""x""" & LF
               & "unit = ""y""", "config: test names that differ in case");
      Rejects ("build = ""b""" & LF & "prove = ""p""" & LF & "[tests]" & LF
               & "t" & Character'Val (233) & " = ""x""",
               "config: a test name with other characters");
      begin
         declare
            C2 : constant Configuration := Parse
              ("build = ""b""" & LF & "prove = ""p""" & LF & "[tests]" & LF
               & "t" & Character'Val (16#C3#) & Character'Val (16#AA#)
               & " = ""x""", "/r");
         begin
            Check (Length (C2.Build) = 0 and then False,
                   "config: a test name in UTF-8", "accepted");
         end;
      exception
         when E : Config_Error =>
            Check (Ada.Strings.Fixed.Index
                     (Ada.Exceptions.Exception_Message (E),
                      "the name of a test") > 0,
                   "config: a test name in UTF-8",
                   Ada.Exceptions.Exception_Message (E));
      end;
      Rejects ("build = ""b""" & LF & "prove = ""p""" & LF & "[tests]" & LF,
               "config: empty tests table");
      Rejects ("build = ""b""" & LF & "prove = ""p""" & LF & "[tests]" & LF
               & "Proof = ""x""" & LF,
               "config: a test with the name of the proof");
      Check (Length (C.Equivalence_Build) = 0
             and then To_String
               (Parse
                  ("build = ""b""" & LF & "prove = ""p""" & LF & "test = ""t""" & LF
                   & "equivalence_build = ""b -cargs -O2""", "/r")
                  .Equivalence_Build) = "b -cargs -O2",
             "config equivalence build");
      Check (C.Coverage_Analysis
             and then not Parse
               ("build = ""b""" & LF & "prove = ""p""" & LF & "test = ""t""" & LF
                & "coverage_analysis = false", "/r").Coverage_Analysis,
             "config coverage analysis");
      Rejects ("build = ""b""" & LF & "prove = ""p""" & LF & "test = ""t""" & LF & "colour = 1",
               "config unknown key");
      Rejects ("test = ""t""" & LF & "prove = ""p""", "config missing build");
      Rejects ("build = ""b""" & LF & "prove = ""p""", "config missing test");
      Rejects ("build = ""b""" & LF & "test = ""t""", "config missing prove");
      Rejects ("build = ""b""" & LF & "[tests]" & LF & "a = ""x""",
               "config missing prove, with a tests table");
      Rejects ("build = ""b""" & LF & "prove = ""p""" & LF & "build = ""c""" & LF & "test = ""t""",
               "config duplicate key");
      Rejects ("build = ""b""" & LF & "prove = ""p""" & LF & "test = ""t""" & LF
               & "[thresholds]" & LF & "high = 50" & LF & "low = 70",
               "config low above high");
      declare
         T : constant Configuration :=
           Parse (Template, "/r");
      begin
         Check (Length (T.Build) > 0, "config template parses");
      end;
   end Test_Config;

   procedure Test_Json is
      use AdaMutant.Reports;
   begin
      Check (Json_String ("a""\" & LF & "</") = """a\""\\\n\u003c/""",
             "json escapes");
      Check (Json_String ("" & Character'Val (16#E9#)) = """\u00e9""",
             "json invalid UTF-8 as Latin-1");
      Check (Json_String ("" & Character'Val (16#C3#) & Character'Val (16#A9#))
             = """" & Character'Val (16#C3#) & Character'Val (16#A9#) & """",
             "json keeps valid UTF-8");
      Check (One_Line ("A  " & ASCII.CR & LF & "     or else B" & LF
                       & "  and C  D") = "A or else B and C  D",
             "one line joins lines, keeps other blanks");
      Check (Has_Steps_Limit ("gnatprove -P p.gpr --level=1 --steps=2000 -j1")
             and then Has_Steps_Limit ("gnatprove --steps 5")
             and then Has_Steps_Limit ("gnatprove --steps=0 --steps=10")
             and then not Has_Steps_Limit ("gnatprove --level=2")
             and then not Has_Steps_Limit ("gnatprove --steps=0")
             and then not Has_Steps_Limit ("gnatprove --steps=10 --steps=0")
             and then not Has_Steps_Limit ("x --steps")
             and then not Has_Steps_Limit (""),
             "a steps limit in the prove command");
   end Test_Json;

   procedure Test_Json_Reader is
      use AdaMutant.Json;

      procedure Rejects (Text, Name : String) is
      begin
         declare
            V : constant Value := Parse (Text);
         begin
            Check (V = No_Value and then False, Name, "accepted");
         end;
      exception
         when Syntax_Error =>
            Check (True, Name);
      end Rejects;

      function Member (V : Value; Name : String) return Value
        renames AdaMutant.Json.Field;

      V : constant Value := Parse
        (" { ""a"" : [1, -20, 3.5, true, false, null, ""x\ny""] ,"
         & " ""b"":{""c"":""\u00e9\ud83d\ude00\""\\\/""},"
         & " ""a"":7, ""e"":[] , ""o"":{} }" & LF);
      A : constant Value := Member (V, "a");
   begin
      Check (Is_Object (V) and then Length (V) = 5
             and then Name (V, 2) = "b", "json: object");
      Check (Is_List (A) and then Length (A) = 7, "json: list");
      Check (Integer_Of (Element (A, 1), 0) = 1
             and then Integer_Of (Element (A, 2), 0) = -20
             and then Integer_Of (Element (A, 3), 9) = 9
             and then Integer_Of (Element (A, 7), 9) = 9
             and then Integer_Of (No_Value, 4) = 4, "json: numbers");
      Check (Kind_Of (Element (A, 4)) = Boolean_Value
             and then Kind_Of (Element (A, 6)) = Null_Value, "json: literals");
      Check (Text_Of (Element (A, 7)) = "x" & LF & "y", "json: escape");
      Check (Text_Of (Member (Member (V, "b"), "c"))
             = Character'Val (16#C3#) & Character'Val (16#A9#)
               & Character'Val (16#F0#) & Character'Val (16#9F#)
               & Character'Val (16#98#) & Character'Val (16#80#) & """\/",
             "json: \u escapes and a surrogate pair become UTF-8");
      Check (Member (V, "none") = No_Value and then not Is_Text (No_Value)
             and then Member (A, "a") = No_Value, "json: missing member");
      Check (Length (Member (V, "e")) = 0 and then Length (Member (V, "o")) = 0,
             "json: empty list and object");
      --  What the report writer escapes comes back as it was.
      Check (Text_Of (Parse (AdaMutant.Reports.Json_String
                               ("a<b""c\" & LF & ASCII.HT & "d")))
             = "a<b""c\" & LF & ASCII.HT & "d", "json: round trip");
      Rejects ("{""a"":1,}", "json: trailing comma");
      Rejects ("[1 2]", "json: missing comma");
      Rejects ("""abc", "json: unterminated string");
      Rejects ("{} x", "json: text after the value");
      Rejects ("", "json: empty text");
      Rejects ("{""x"":-}", "json: a sign without digits");
      Rejects ("1e", "json: an exponent without digits");
      Rejects ("[1e+]", "json: an exponent with a sign only");
      Rejects ("01", "json: a digit after a leading zero");
      Rejects ("1..2", "json: two points");
      Rejects ("1.", "json: a point without digits");
      Rejects ("[.5]", "json: a point without a digit before");
      Rejects ("[+1]", "json: a plus sign");
      Rejects ("[1-2]", "json: a sign inside");
      declare
         N : Value := Parse ("[0, -0, 10, 1.5, 0.25e+1, 2E-3, 1e5]");
      begin
         Check (Length (N) = 7 and then Integer_Of (Element (N, 1), 9) = 0
                and then Integer_Of (Element (N, 3), 9) = 10
                and then Kind_Of (Element (N, 7)) = Number,
                "json: the forms of a number");
         Free (N);
         Check (N = No_Value, "json: free");
      end;
   end Test_Json_Reader;

   procedure Test_Baselines is
      use AdaMutant.Baselines;
      use AdaMutant.Results;

      function Map (Old_Text, New_Text : String) return String is
         R : Unbounded_String;
      begin
         for N of Line_Map (Lines (Old_Text), Lines (New_Text)) loop
            Append (R, N'Image);
         end loop;
         return To_String (R);
      end Map;

      Old_Source : constant String :=
        "procedure P is" & LF          --  1
        & "begin" & LF                 --  2
        & "   X := X + 1;" & LF        --  3
        & "   Y := Y - 1;" & LF        --  4
        & "   Z := 2;" & LF            --  5
        & "end P;" & LF;               --  6
      New_Source : constant String :=
        "--  A comment." & LF          --  1
        & "procedure P is" & LF        --  2
        & "begin" & LF                 --  3
        & "   X := X + 1;" & LF        --  4
        & "   Y := Y - 2;" & LF        --  5  changed
        & "   Z := 2;" & LF            --  6
        & "end P;" & LF;               --  7

      function Old_Mutant
        (Line, Column, End_Column : Positive;
         Mutator, Replacement, Status, More : String) return String is
        ("{""id"":""9"",""mutatorName"":""" & Mutator & """,""replacement"":"""
         & Replacement & """,""location"":{""start"":{""line"":" & Line'Image
         & ",""column"":" & Column'Image & "},""end"":{""line"":" & Line'Image
         & ",""column"":" & End_Column'Image & "}},""status"":""" & Status
         & """" & More & "}");

      Baseline : constant String :=
        "{""schemaVersion"":""2"",""files"":{""src/p.adb"":{""language"":"
        & """ada"",""source"":"
        & AdaMutant.Reports.Json_String (Old_Source) & ",""mutants"":["
        & Old_Mutant (3, 11, 12, "ArithmeticOperator", "-", "Killed",
                      ",""statusReason"":""test a failed with exit status 1"""
                      & ",""killedBy"":[""a"",""b""],""coveredBy"":[""a"",""b"","
                      & """c""],""testsCompleted"":2") & ","
        & Old_Mutant (3, 13, 14, "NumericLiteral", "0", "Survived",
                      ",""statusReason"":""the tests and the proof passed""")
        & ","
        & Old_Mutant (4, 11, 12, "ArithmeticOperator", "+", "Killed", "") & ","
        & Old_Mutant (5, 9, 10, "NumericLiteral", "3", "Killed",
                      ",""killedBy"":[""proof: postcondition"",""proof: range"
                      & " check""],""statusReason"":""proof failed: x (from the"
                      & " baseline report)"",""testsCompleted"":1") & ","
        & Old_Mutant (5, 4, 11, "StatementDeletion", "null;", "Ignored",
                      ",""statusReason"":""equivalent mutant: same code""")
        & "]}}}";

      function Report_Of (Unchanged : Boolean) return Report is
         R : Report;

         procedure Add (Line, Column, End_Column : Positive;
                        Kind : Mutator_Kind; Replacement : String) is
         begin
            R.Mutants.Append
              (Mutant'
                 (Id        => Natural (R.Mutants.Length) + 1,
                  File      => 1,
                  Mutation  => (Kind        => Kind,
                                Replacement =>
                                  To_Unbounded_String (Replacement),
                                others      => <>),
                  Start_Pos => (Line, Column),
                  End_Pos   => (Line, End_Column),
                  Status    => (if Unchanged then Ignored else Pending),
                  Unchanged => Unchanged,
                  others    => <>));
         end Add;
      begin
         R.Files.Append
           (Source_File'(Path   => To_Unbounded_String ("src/p.adb"),
                         Source => To_Unbounded_String (New_Source)));
         Add (4, 11, 12, Arithmetic_Operator, "-");   --  1: was Killed
         Add (4, 13, 14, Numeric_Literal, "0");       --  2: was Survived
         Add (5, 11, 12, Arithmetic_Operator, "+");   --  3: line changed
         Add (6, 9, 10, Numeric_Literal, "3");        --  4: was Killed
         Add (6, 4, 11, Statement_Deletion, "null;"); --  5: was equivalent
         Add (6, 9, 10, Numeric_Literal, "4");        --  6: not in the report
         return R;
      end Report_Of;

      function Statuses (R : Report) return String is
         S : Unbounded_String;
      begin
         for M of R.Mutants loop
            Append (S, " " & Name (M.Status) & (if M.Reused then "*" else ""));
         end loop;
         return To_String (S);
      end Statuses;

      R      : Report;
      Reused : Natural;
   begin
      Check (Map ("a" & LF & "b" & LF & "c" & LF, "a" & LF & "b" & LF & "c")
             = " 1 2 3", "line map: the same text");
      Check (Map (Old_Source, New_Source) = " 0 1 2 3 0 5 6",
             "line map: a line added and a line changed",
             Map (Old_Source, New_Source));
      Check (Map (New_Source, Old_Source) = " 2 3 4 0 6 7",
             "line map: a line removed and a line changed",
             Map (New_Source, Old_Source));
      Check (Map ("a" & LF & "x" & LF & "b" & LF & "y" & LF & "c" & LF,
                  "c" & LF & "a" & LF & "b" & LF & "x" & LF & "c" & LF)
             = " 0 1 0 2 5", "line map: lines keep their order",
             Map ("a" & LF & "x" & LF & "b" & LF & "y" & LF & "c" & LF,
                  "c" & LF & "a" & LF & "b" & LF & "x" & LF & "c" & LF));
      Check (Map ("", "a" & LF) = " 0" and then Map ("a" & LF, "") = "",
             "line map: empty texts");
      --  Two blocks change places.  The lines that both have ("begin",
      --  the return statement) are not taken for those of the other
      --  block: the block that keeps its place among the lines that occur
      --  once maps, the other one counts as changed.
      Check (Map ("function Add" & LF & "begin" & LF & "   return A + B;" & LF
                  & "end Add;" & LF & LF
                  & "function Plus" & LF & "begin" & LF & "   return A + B;"
                  & LF & "end Plus;" & LF,
                  "function Plus" & LF & "begin" & LF & "   return A + B;" & LF
                  & "end Plus;" & LF & LF
                  & "function Add" & LF & "begin" & LF & "   return A + B;"
                  & LF & "end Add;" & LF)
             = " 0 0 0 0 0 1 2 3 4", "line map: blocks that change places",
             Map ("function Add" & LF & "begin" & LF & "   return A + B;" & LF
                  & "end Add;" & LF & LF
                  & "function Plus" & LF & "begin" & LF & "   return A + B;"
                  & LF & "end Plus;" & LF,
                  "function Plus" & LF & "begin" & LF & "   return A + B;" & LF
                  & "end Plus;" & LF & LF
                  & "function Add" & LF & "begin" & LF & "   return A + B;"
                  & LF & "end Add;" & LF));
      --  Texts with no line that occurs once: only the equal lines at the
      --  beginning and at the end map.
      Check (Map ("x" & LF & "x" & LF & "y" & LF & "y" & LF,
                  "x" & LF & "y" & LF & "x" & LF & "y" & LF) = " 1 0 0 4",
             "line map: repeated lines only",
             Map ("x" & LF & "x" & LF & "y" & LF & "y" & LF,
                  "x" & LF & "y" & LF & "x" & LF & "y" & LF));
      --  A long text is no problem: nothing is compared pair by pair.
      declare
         Long_Old, Long_New : Unbounded_String;
         Count : Natural := 0;
      begin
         for K in 1 .. 6000 loop
            Append (Long_Old, "line" & K'Image & LF);
            Append (Long_New, (if K in 4 | 5990 then "changed" & K'Image
                               else "line" & K'Image) & LF);
         end loop;
         for N of Line_Map (Lines (To_String (Long_Old)),
                            Lines (To_String (Long_New)))
         loop
            Count := Count + (if N /= 0 then 1 else 0);
         end loop;
         Check (Count = 5998, "line map: two changes far apart in a long text",
                Count'Image);
      end;

      --  A plain run: what was detected is taken over, the rest runs.
      R := Report_Of (Unchanged => False);
      Apply (R, Baseline, Reused);
      Check (Reused = 2 and then Statuses (R)
             = " Killed* Pending Pending Killed* Pending Pending",
             "baseline: detected mutants on unchanged lines are reused",
             Reused'Image & Statuses (R));
      Check (To_String (R.Mutants (1).Status_Reason)
             = "test a failed with exit status 1 (from the baseline report)"
             and then R.Mutants (1).Killed_By = Tests
             and then Natural (R.Mutants (1).Killers.Length) = 2
             and then R.Mutants (1).Killers (2) = "b"
             and then R.Mutants (1).Reached = Covered
             and then Natural (R.Mutants (1).Covered_By.Length) = 3
             and then R.Mutants (1).Tests_Run = 2,
             "baseline: the tests of a reused result");
      Check (To_String (R.Mutants (4).Status_Reason)
             = "proof failed: x (from the baseline report)"
             and then R.Mutants (4).Killed_By = Proof
             and then Natural (R.Mutants (4).Failed_Checks.Length) = 2
             and then R.Mutants (4).Failed_Checks (2) = "range check"
             and then R.Mutants (4).Reached = Unknown,
             "baseline: the checks of a reused result, the note once",
             To_String (R.Mutants (4).Status_Reason));

      --  With --since: every result on an unchanged line is taken over.
      R := Report_Of (Unchanged => True);
      Apply (R, Baseline, Reused);
      Check (Reused = 4 and then Statuses (R)
             = " Killed* Survived* Ignored Killed* Ignored* Ignored",
             "baseline: with --since every result is reused",
             Reused'Image & Statuses (R));
      Check (R.Mutants (5).Equivalent and then not R.Mutants (5).Unchanged
             and then R.Mutants (3).Unchanged
             and then not R.Mutants (3).Equivalent,
             "baseline: an equivalent mutant stays one");

      --  A mutant that spans lines is the same only when all its lines
      --  are unchanged and still together; odd values in a report do no
      --  harm; "proof" is the proof, never a test.
      declare
         Before : constant String :=
           "begin" & LF & "   Call (1," & LF & "         2);" & LF & "end;" & LF;

         function Report_With (Source, More : String) return String is
           ("{""files"":{""src/p.adb"":{""source"":"
            & AdaMutant.Reports.Json_String (Source) & ",""mutants"":["
            & "{""mutatorName"":""StatementDeletion"",""replacement"":""null;"","
            & """location"":{""start"":{""line"":2,""column"":4},"
            & """end"":{""line"":3,""column"":13}},""status"":""Killed"""
            & More & "}]}}}");

         function One (Source : String; Line : Positive) return Report is
            R : Report;
         begin
            R.Files.Append
              (Source_File'(Path   => To_Unbounded_String ("src/p.adb"),
                            Source => To_Unbounded_String (Source)));
            R.Mutants.Append
              (Mutant'
                 (Id        => 1,
                  File      => 1,
                  Mutation  => (Kind        => Statement_Deletion,
                                Replacement => To_Unbounded_String ("null;"),
                                others      => <>),
                  Start_Pos => (Line, 4),
                  End_Pos   => (Line + 1, 13),
                  others    => <>));
            return R;
         end One;
      begin
         R := One ("--  new" & LF & Before, 3);
         Apply (R, Report_With
                     (Before, ",""killedBy"":[""proof"",""unit""],"
                      & """testsCompleted"":-3"), Reused);
         Check (Reused = 1 and then R.Mutants (1).Status = Killed
                and then R.Mutants (1).Killed_By = Tests
                and then Natural (R.Mutants (1).Killers.Length) = 1
                and then R.Mutants (1).Killers (1) = "unit"
                and then R.Mutants (1).Tests_Run = 0,
                "baseline: a mutant of two lines, moved down",
                Reused'Image & Statuses (R));
         R := One (Before, 2);
         Apply (R, Report_With (Before, ",""killedBy"":[""proof""]"), Reused);
         Check (Reused = 1 and then R.Mutants (1).Killed_By = Proof
                and then R.Mutants (1).Killers.Is_Empty
                and then R.Mutants (1).Evidence = Undecided,
                "baseline: ""proof"" alone is the proof");
         --  What GNATprove gave with the failure comes back from the
         --  reason.
         R := One (Before, 2);
         Apply (R, Report_With
                     (Before, ",""killedBy"":[""proof: range check""],"
                      & """statusReason"":""" & Weak_Contract_Failure
                      & "weak.adb:13:19: medium: x (e.g. when H = (1, 2))"
                      & " (and 1 more) (from the baseline report)"",""testsCompleted"":1"),
                Reused);
         Check (Reused = 1 and then R.Mutants (1).Evidence = Weak_Contract
                and then To_String (R.Mutants (1).Example)
                         = "e.g. when H = (1, 2)",
                "baseline: a counterexample that the real code does not"
                & " reach", To_String (R.Mutants (1).Example));
         R := One (Before, 2);
         Apply (R, Report_With
                     (Before, ",""killedBy"":[""proof: postcondition""],"
                      & """statusReason"":""" & Confirmed_Failure
                      & "p.ads:9:17: high: postcondition might fail"
                      & " (e.g. when A = 0)"",""testsCompleted"":1"),
                Reused);
         Check (Reused = 1 and then R.Mutants (1).Evidence = Confirmed
                and then To_String (R.Mutants (1).Example)
                         = "e.g. when A = 0",
                "baseline: a confirmed failure",
                To_String (R.Mutants (1).Example));
         --  A reason of an earlier version: its severity tells.
         R := One (Before, 2);
         Apply (R, Report_With
                     (Before, ",""killedBy"":[""proof: postcondition""],"
                      & """statusReason"":""proof failed: p.ads:9:17: high:"
                      & " postcondition might fail"",""testsCompleted"":1"),
                Reused);
         Check (Reused = 1 and then R.Mutants (1).Evidence = Confirmed,
                "baseline: an old reason with a high message");
         R := One ("begin" & LF & "   Call (1," & LF & "         3);" & LF
                   & "end;" & LF, 2);
         Apply (R, Report_With (Before, ""), Reused);
         Check (Reused = 0, "baseline: its second line changed");
         R := One ("begin" & LF & "   Call (1," & LF & "         --  why" & LF
                   & "         2);" & LF & "end;" & LF, 2);
         Apply (R, Report_With (Before, ""), Reused);
         Check (Reused = 0, "baseline: a line added inside it");
      end;
      --  A replacement with a byte that is not UTF-8: the report holds
      --  it as Latin-1 text, and it is still found.
      declare
         E_Acute : constant String := "" & Character'Val (16#E9#);
         Source  : constant String :=
           "X := S = """ & E_Acute & """ and then A and then B;" & LF;
         Changed : constant String :=
           "S = """ & E_Acute & """ or else A";
         Latin   : Report;
      begin
         Latin.Files.Append
           (Source_File'(Path   => To_Unbounded_String ("src/p.adb"),
                         Source => To_Unbounded_String (Source)));
         Latin.Mutants.Append
           (Mutant'
              (Id        => 1,
               File      => 1,
               Mutation  => (Kind        => Logical_Operator,
                             Replacement => To_Unbounded_String (Changed),
                             others      => <>),
               Start_Pos => (1, 6),
               End_Pos   => (1, 23),
               others    => <>));
         Apply (Latin,
                "{""files"":{""src/p.adb"":{""source"":"
                & AdaMutant.Reports.Json_String (Source) & ",""mutants"":["
                & "{""mutatorName"":""LogicalOperator"",""replacement"":"
                & AdaMutant.Reports.Json_String (Changed)
                & ",""location"":{""start"":{""line"":1,""column"":6},"
                & """end"":{""line"":1,""column"":23}},""status"":""Killed""}"
                & "]}}}", Reused);
         Check (Reused = 1 and then Latin.Mutants (1).Status = Killed,
                "baseline: a replacement in Latin-1 is found", Reused'Image);
      end;
      declare
         Slow : Report := Report_Of (Unchanged => False);
      begin
         Apply (Slow,
                "{""files"":{""src/p.adb"":{""source"":"
                & AdaMutant.Reports.Json_String (New_Source) & ",""mutants"":["
                & Old_Mutant (4, 11, 12, "ArithmeticOperator", "-",
                              "CompileError",
                              ",""statusReason"":""build timed out""") & ","
                & Old_Mutant (4, 13, 14, "NumericLiteral", "0",
                              "CompileError",
                              ",""statusReason"":""build failed: x""")
                & "]}}}", Reused);
         Check (Reused = 1 and then Statuses (Slow)
                = " Pending CompileError* Pending Pending Pending Pending",
                "baseline: a build that timed out runs again",
                Reused'Image & Statuses (Slow));
      end;
      --  An earlier version counted a proof that did not finish as a
      --  detection.  It runs again; with --since it becomes a survivor.
      declare
         Old_Report : constant String :=
           "{""files"":{""src/p.adb"":{""source"":"
           & AdaMutant.Reports.Json_String (New_Source) & ",""mutants"":["
           & Old_Mutant (4, 11, 12, "ArithmeticOperator", "-", "Timeout",
                         ",""killedBy"":[""proof""],""statusReason"":"
                         & """proof did not finish within the timeout""")
           & "," & Old_Mutant (4, 13, 14, "NumericLiteral", "0", "Timeout",
                               ",""killedBy"":[""a""],""statusReason"":"
                               & """test a did not finish""")
           & "]}}}";
         Slow : Report := Report_Of (Unchanged => False);
      begin
         Apply (Slow, Old_Report, Reused);
         Check (Reused = 1 and then Statuses (Slow)
                = " Pending Timeout* Pending Pending Pending Pending",
                "baseline: a proof that timed out runs again",
                Reused'Image & Statuses (Slow));
         Slow := Report_Of (Unchanged => True);
         Apply (Slow, Old_Report, Reused);
         Check (Reused = 2 and then Statuses (Slow)
                = " Survived* Timeout* Ignored Ignored Ignored Ignored"
                and then Slow.Mutants (1).Killed_By = None
                and then Proof_Timed_Out (Slow.Mutants (1))
                --  No test ran in that version: the reason does not say so.
                and then Index (Slow.Mutants (1).Status_Reason,
                                "the proof did not finish") = 1
                and then not Proof_Timed_Out (Slow.Mutants (2)),
                "baseline: with --since a proof that timed out survives",
                Reused'Image & Statuses (Slow));
      end;
      --  The results of an earlier version that ran the tests alone or the
      --  proof alone run again, even with --since.  A proof that did not
      --  finish where no test executes the code says so.
      declare
         Old_Report : constant String :=
           "{""files"":{""src/p.adb"":{""source"":"
           & AdaMutant.Reports.Json_String (New_Source) & ",""mutants"":["
           & Old_Mutant (4, 11, 12, "ArithmeticOperator", "-", "NoCoverage",
                         ",""statusReason"":""no test executes this code""")
           & "," & Old_Mutant (4, 13, 14, "NumericLiteral", "0", "Survived",
                               ",""statusReason"":""tests passed""")
           & "," & Old_Mutant (5, 11, 12, "ArithmeticOperator", "+", "Killed",
                               ",""killedBy"":[""proof""],""statusReason"":"
                               & """proof failed with exit status 1""")
           & "," & Old_Mutant (6, 9, 10, "NumericLiteral", "3", "Timeout",
                               ",""coveredBy"":[],""statusReason"":"
                               & """proof did not finish within the timeout""")
           & "]}}}";
         Old : Report := Report_Of (Unchanged => True);
      begin
         Apply (Old, Old_Report, Reused);
         Check (Reused = 1 and then Statuses (Old)
                = " Ignored Ignored Ignored Survived* Ignored Ignored"
                and then Index
                  (Old.Mutants (4).Status_Reason,
                   "no test executes this code, and the proof did not") = 1,
                "baseline: results of the tests alone or the proof alone",
                Reused'Image & Statuses (Old));
      end;

      R := Report_Of (Unchanged => False);
      Apply (R, "{""files"":{""src/other.adb"":{""source"":"""","
             & """mutants"":[]}}}", Reused);
      Check (Reused = 0, "baseline: a report without the file");
      begin
         Apply (R, "[1, 2", Reused);
         Check (False, "baseline: malformed text is refused");
      exception
         when Baseline_Error =>
            Check (True, "baseline: malformed text is refused");
      end;
      begin
         Apply (R, "{""schemaVersion"":""2""}", Reused);
         Check (False, "baseline: a text without files is refused");
      exception
         when Baseline_Error =>
            Check (True, "baseline: a text without files is refused");
      end;
   end Test_Baselines;

   procedure Test_Schemata is
      use AdaMutant.Schemata;

      Decl : constant String :=
        "pragma Warnings (Off); function ADAMUTANT_ACTIVE_7 (Site :"
        & " Standard.Integer) return Standard.Integer; pragma Import (C,"
        & " ADAMUTANT_ACTIVE_7, ""adamutant_schemata_active"");"
        & " pragma Warnings (On);";

      Candidates : Candidate_Vectors.Vector;

      procedure Mutate (Source, Pattern, Replacement : String) is
         --  One more candidate: the first Pattern in Source becomes
         --  Replacement.  Candidates are numbered from 1.
         At_Index : constant Natural :=
           Ada.Strings.Fixed.Index (Source, Pattern);
      begin
         Check (At_Index > 0, "schemata: test pattern " & Pattern);
         Candidates.Append
           (Candidate'(Id          => Natural (Candidates.Length) + 1,
                       First       => At_Index,
                       Last        => At_Index + Pattern'Length - 1,
                       Replacement => To_Unbounded_String (Replacement),
                       Probe       => False));
      end Mutate;

      function Ids (S : Schema) return String is
         R : Unbounded_String;
      begin
         for Id of S.Included loop
            Append (R, Id'Image);
         end loop;
         return To_String (R);
      end Ids;

      function Owners (S : Schema) return String is
         R : Unbounded_String;
      begin
         for Owner of S.Owners loop
            Append (R, Owner'Image);
         end loop;
         return To_String (R);
      end Owners;

      procedure Expect_None (Source, Pattern, Name : String) is
         S : Schema;
      begin
         Candidates.Clear;
         Mutate (Source, Pattern, "0");
         S := Build (Source, Candidates, 7);
         Check (S.Included.Is_Empty and then Length (S.Text) = 0,
                "schemata: not included, " & Name, To_String (S.Text));
      end Expect_None;
   begin
      --  A simple statement becomes a case statement.
      declare
         Source : constant String :=
           "package body P is" & LF
           & "   procedure Q (X : in out Integer) is" & LF
           & "   begin" & LF
           & "      X := X + 1;  --  why" & LF
           & "   end Q;" & LF
           & "end P;" & LF;
         S : Schema;
      begin
         Candidates.Clear;
         Mutate (Source, "+", "-");
         Mutate (Source, "1", "0");
         S := Build (Source, Candidates, 7);
         Check (To_String (S.Text) =
                  "pragma Style_Checks (Off);" & LF
                  & "package body P is" & LF
                  & Decl & LF
                  & LF
                  & "   procedure Q (X : in out Integer) is" & LF
                  & "   begin" & LF
                  & "      " & LF
                  & "case ADAMUTANT_ACTIVE_7 (1) is" & LF
                  & "when 1 =>" & LF
                  & "X := X - 1;" & LF
                  & "when 2 =>" & LF
                  & "X := X + 0;" & LF
                  & "when others =>" & LF
                  & "X := X + 1;" & LF
                  & "end case;" & LF
                  & "  --  why" & LF
                  & "   end Q;" & LF
                  & "end P;" & LF,
                "schemata: statement", To_String (S.Text));
         Check (Ids (S) = " 1 2", "schemata: statement, included");
         Check (Owners (S) = " 0 0 0 0 0 0 0 0 1 1 2 2 0 0 0 0 0 0 0",
                "schemata: statement, owners of the lines", Owners (S));
      end;

      --  Conditions become case expressions.
      declare
         Source : constant String :=
           "procedure Q (X : in out Integer) is" & LF
           & "begin" & LF
           & "   if X > 0 and then X < 9 then" & LF
           & "      null;" & LF
           & "   elsif X = 0 then" & LF
           & "      null;" & LF
           & "   end if;" & LF
           & "   while X > 5 loop" & LF
           & "      exit when X = 7;" & LF
           & "   end loop;" & LF
           & "end Q;" & LF;
         S : Schema;
      begin
         Candidates.Clear;
         Mutate (Source, "X > 0 and then X < 9", "True");
         Mutate (Source, "X = 0", "X /= 0");
         Mutate (Source, "X > 5", "False");
         Mutate (Source, "X = 7", "True");
         S := Build (Source, Candidates, 7);
         Check (To_String (S.Text) =
                  "pragma Style_Checks (Off);" & LF
                  & "procedure Q (X : in out Integer) is" & LF
                  & Decl & LF
                  & LF
                  & "begin" & LF
                  & "   if (case ADAMUTANT_ACTIVE_7 (1) is" & LF
                  & "when 1 => (" & LF
                  & "True" & LF
                  & ")," & LF
                  & "when others => (" & LF
                  & "X > 0 and then X < 9" & LF
                  & ")) then" & LF
                  & "      null;" & LF
                  & "   elsif (case ADAMUTANT_ACTIVE_7 (2) is" & LF
                  & "when 2 => (" & LF
                  & "X /= 0" & LF
                  & ")," & LF
                  & "when others => (" & LF
                  & "X = 0" & LF
                  & ")) then" & LF
                  & "      null;" & LF
                  & "   end if;" & LF
                  & "   while (case ADAMUTANT_ACTIVE_7 (3) is" & LF
                  & "when 3 => (" & LF
                  & "False" & LF
                  & ")," & LF
                  & "when others => (" & LF
                  & "X > 5" & LF
                  & ")) loop" & LF
                  & "      " & LF
                  & "case ADAMUTANT_ACTIVE_7 (4) is" & LF
                  & "when 4 =>" & LF
                  & "exit when True;" & LF
                  & "when others =>" & LF
                  & "exit when X = 7;" & LF
                  & "end case;" & LF
                  & LF
                  & "   end loop;" & LF
                  & "end Q;" & LF,
                "schemata: conditions", To_String (S.Text));
         Check (S.Owners (7) = 1 and then S.Owners (8) = 1
                and then S.Owners (9) = 1 and then S.Owners (10) = 0
                and then S.Owners (6) = 0,
                "schemata: condition, owners of the lines", Owners (S));
      end;

      --  The expression of an expression function, in a specification
      --  with aspects and a generic formal part in front.
      declare
         Source : constant String :=
           "generic" & LF
           & "   with function F (X : Integer) return Integer is <>;" & LF
           & "package P with Pure is" & LF
           & "   Limit : constant := 10;" & LF
           & "   function Twice (X : Integer) return Integer is (X * 2)" & LF
           & "     with Pre => X < Limit;" & LF
           & "   function Pair (X : Integer) return R is (A => X, B => 1);"
           & LF
           & "end P;" & LF;
         S : Schema;
      begin
         Candidates.Clear;
         Mutate (Source, "10", "11");       --  a named number
         Mutate (Source, "*", "/");
         Mutate (Source, "X < Limit", "X <= Limit");  --  an aspect
         Mutate (Source, "B => 1", "B => 0");
         S := Build (Source, Candidates, 7);
         Check (To_String (S.Text) =
                  "pragma Style_Checks (Off);" & LF
                  & "generic" & LF
                  & "   with function F (X : Integer) return Integer is <>;"
                  & LF
                  & "package P with Pure is" & LF
                  & Decl & LF
                  & LF
                  & "   Limit : constant := 10;" & LF
                  & "   function Twice (X : Integer) return Integer is "
                  & "(case ADAMUTANT_ACTIVE_7 (2) is" & LF
                  & "when 2 =>" & LF
                  & "(X / 2)" & LF
                  & "," & LF
                  & "when others =>" & LF
                  & "(X * 2)" & LF
                  & ")" & LF
                  & "     with Pre => X < Limit;" & LF
                  & "   function Pair (X : Integer) return R is "
                  & "(case ADAMUTANT_ACTIVE_7 (4) is" & LF
                  & "when 4 =>" & LF
                  & "(A => X, B => 0)" & LF
                  & "," & LF
                  & "when others =>" & LF
                  & "(A => X, B => 1)" & LF
                  & ");" & LF
                  & "end P;" & LF,
                "schemata: expression functions", To_String (S.Text));
         Check (Ids (S) = " 2 4",
                "schemata: declarations and aspects stay out", Ids (S));
      end;

      --  Blocks, nested subprograms and what comes after them.
      declare
         Source : constant String :=
           "package body P is" & LF
           & "   type T is record" & LF
           & "      A : Integer := 1;" & LF
           & "   end record;" & LF
           & "   procedure Q is" & LF
           & "      procedure Inner is" & LF
           & "      begin" & LF
           & "         G := 2;" & LF
           & "      end Inner;" & LF
           & "      V : Integer := 3;" & LF
           & "   begin" & LF
           & "      declare" & LF
           & "         W : Integer := 4;" & LF
           & "      begin" & LF
           & "         G := 5;" & LF
           & "      end;" & LF
           & "      case G is" & LF
           & "         when 6 => G := 7;" & LF
           & "         when others => null;" & LF
           & "      end case;" & LF
           & "      for I in 8 .. 9 loop" & LF
           & "         G := 10;" & LF
           & "      end loop;" & LF
           & "      Named : loop" & LF
           & "         exit Named when G = 11;" & LF
           & "      end loop Named;" & LF
           & "   exception" & LF
           & "      when others => G := 12;" & LF
           & "   end Q;" & LF
           & "begin" & LF
           & "   G := 13;" & LF
           & "end P;" & LF;
         S : Schema;
      begin
         Candidates.Clear;
         for N in 1 .. 13 loop
            declare
               Image : constant String := Ada.Strings.Fixed.Trim
                 (N'Image, Ada.Strings.Both);
               Sep   : constant String :=
                 (case N is when 6 => " =>", when 8 => " ..",
                            when 9 => " loop", when others => ";");
            begin
               Mutate (Source, " " & Image & Sep, " 0" & Sep);
            end;
         end loop;
         S := Build (Source, Candidates, 7);
         Check (Ids (S) = " 2 5 7 10 11 12 13",
                "schemata: only statements, in every kind of block",
                Ids (S));
      end;

      --  A probe: its place is watched, the mutant is not built in.
      declare
         Source : constant String :=
           "procedure Q (X : in out Integer) is" & LF
           & "begin" & LF
           & "   X := X + 1;" & LF
           & "   Log;" & LF
           & "   if X > 2 then" & LF
           & "      null;" & LF
           & "   end if;" & LF
           & "end Q;" & LF;
         S : Schema;

         function Sites (S : Schema) return String is
            R : Unbounded_String;
         begin
            for Site of S.Sites loop
               Append (R, Site.Id'Image & " at" & Site.Number'Image & ";");
            end loop;
            return To_String (R);
         end Sites;
      begin
         Candidates.Clear;
         Mutate (Source, "X := X + 1;", "null;");
         Candidates (1).Probe := True;
         Mutate (Source, "+", "-");
         Mutate (Source, "Log;", "null;");
         Candidates (3).Probe := True;
         Mutate (Source, "2", "3");
         Mutate (Source, "Integer", "Float");  --  in no place
         S := Build (Source, Candidates, 7);
         Check (To_String (S.Text) =
                  "pragma Style_Checks (Off);" & LF
                  & "procedure Q (X : in out Integer) is" & LF
                  & Decl & LF
                  & LF
                  & "begin" & LF
                  & "   " & LF
                  & "case ADAMUTANT_ACTIVE_7 (1) is" & LF
                  & "when 2 =>" & LF
                  & "X := X - 1;" & LF
                  & "when others =>" & LF
                  & "X := X + 1;" & LF
                  & "end case;" & LF
                  & LF
                  & "   " & LF
                  & "case ADAMUTANT_ACTIVE_7 (3) is" & LF
                  & "when -1 => null;" & LF
                  & "when others =>" & LF
                  & "Log;" & LF
                  & "end case;" & LF
                  & LF
                  & "   if (case ADAMUTANT_ACTIVE_7 (4) is" & LF
                  & "when 4 => (" & LF
                  & "X > 3" & LF
                  & ")," & LF
                  & "when others => (" & LF
                  & "X > 2" & LF
                  & ")) then" & LF
                  & "      null;" & LF
                  & "   end if;" & LF
                  & "end Q;" & LF,
                "schemata: probes", To_String (S.Text));
         Check (Ids (S) = " 2 4", "schemata: probes are not included",
                Ids (S));
         Check (Sites (S) = " 1 at 1; 2 at 1; 3 at 3; 4 at 4;",
                "schemata: places of the candidates", Sites (S));
         --  Only the lines of the place that has no mutant belong to the
         --  probe.
         Check (Owners (S)
                = " 0 0 0 0 0 0 0 2 2 0 0 0 0 0 3 3 3 3 3 0 0 4 4 4 0 0 0"
                  & " 0 0 0 0",
                "schemata: probes, owners of the lines", Owners (S));

         --  Probes alone make a schema too.
         Candidates.Clear;
         Mutate (Source, "Log;", "null;");
         Candidates (1).Probe := True;
         S := Build (Source, Candidates, 7);
         Check (S.Included.Is_Empty and then Natural (S.Sites.Length) = 1
                and then Ada.Strings.Fixed.Index
                           (To_String (S.Text),
                            "case ADAMUTANT_ACTIVE_7 (1) is" & LF
                            & "when -1 => null;" & LF
                            & "when others =>" & LF & "Log;") > 0,
                "schemata: only a probe", To_String (S.Text));
      end;

      Expect_None
        ("procedure Q is begin <<L>> X := 1; end Q;", "1",
         "a labelled statement");
      Expect_None
        ("function Q return T is begin return R : T := 1 do null;"
         & " end return; end Q;", "1",
         "the object of an extended return");
      Expect_None
        ("package body P is task body T is begin X := 1; end T; end P;",
         "1", "a unit with tasking");
      Expect_None
        ("function Q (X : Integer) return Integer is (X + 1);", "1",
         "an expression function that is a unit");
      Expect_None
        ("package P is new G (1);", "1", "an instantiation");
      Expect_None
        ("package P is function F (X : Integer) return Integer is"
         & " (Integer'Max (X, 1)) with Static; end P;", "1",
         "a static expression function");
      Expect_None
        ("package P is function F (X : Integer) return Integer is"
         & " (X + 1) with Inline, Static => True; end P;", "1",
         "a static expression function with other aspects");
      Expect_None
        ("procedure Q is X : constant Integer := 1; begin null; end Q;",
         "1", "a declaration");
      Check (Build ("procedure Q is begin X := 1; end Q;",
                    Candidate_Vectors.Empty_Vector, 7).Included.Is_Empty,
             "schemata: no candidates");

      --  The with clause for the support unit.
      Check (With_Support ("procedure Main is begin null; end Main;" & LF)
             = "pragma Style_Checks (Off);" & LF
               & "with AdaMutant_Schemata_Support; pragma Unreferenced"
               & " (AdaMutant_Schemata_Support); "
               & "procedure Main is begin null; end Main;" & LF,
             "schemata: with clause in a plain main");
      Check (With_Support
               ("pragma Style_Checks (Off);" & LF
                & "pragma Ada_2022; pragma Profile (X);" & LF
                & "with Ada.Text_IO;" & LF & "procedure Main is")
             = "pragma Style_Checks (Off);" & LF
               & "pragma Ada_2022; pragma Profile (X);" & LF
               & "with AdaMutant_Schemata_Support; pragma Unreferenced"
               & " (AdaMutant_Schemata_Support); with Ada.Text_IO;" & LF
               & "procedure Main is",
             "schemata: with clause after pragmas, no line added");
      Check (Ada.Strings.Fixed.Index (Support_Body, "ADAMUTANT_MUTANT_ID") > 0
             and then Ada.Strings.Fixed.Index
                        (Support_Body (Last_Site => 41), "range 0 .. 41)") > 0
             and then Ada.Strings.Fixed.Index
                        (Support_Body, "Folder : constant String :=" & LF
                         & "     """";") > 0
             and then Ada.Strings.Fixed.Index
                        (Support_Body
                           (Coverage_Dir => "/a b/""q""/" & Character'Val (233)
                            & "/logs"),
                         "     ""/a b/"" & Character'Val (34) & ""q"""
                         & " & Character'Val (34) & ""/"""
                         & " & Character'Val (233) & ""/logs"";") > 0
             and then Ada.Strings.Fixed.Index
                        (Support_Spec, "adamutant_schemata_active") > 0,
             "schemata: support unit");

      --  Compiler messages.
      declare
         D : constant Diagnostic_Vectors.Vector := Diagnostics
           ("Compile" & LF
            & "   [Ada]          p.adb" & LF
            & "p.adb:12:05: error: expected type ""Integer""" & ASCII.CR & LF
            & "p.adb:12:05: error: found type ""Float""" & LF
            & "/tmp/x/src/Q-R.ads:7:1: warning: unused" & LF
            & "C:\work\src\w.adb:3:4: (style) bad" & LF
            & "gprbuild: *** compilation phase failed" & LF
            & "time 12:30:15: nothing");
      begin
         Check (Natural (D.Length) = 4, "diagnostics: count",
                D.Length'Image);
         Check (To_String (D (1).File) = "p.adb" and then D (1).Line = 12
                and then To_String (D (1).Text)
                         = "p.adb:12:05: error: expected type ""Integer""",
                "diagnostics: error line");
         Check (To_String (D (3).File) = "q-r.ads" and then D (3).Line = 7,
                "diagnostics: path and case");
         Check (To_String (D (4).File) = "w.adb" and then D (4).Line = 3,
                "diagnostics: Windows path");
      end;

      Check (Main_Source
               ("V ""GNAT Lib v16""" & LF & "M P W=b" & LF & "A -O1" & LF
                & "U unit_tests%b" & ASCII.HT & ASCII.HT & "Unit_Tests.adb"
                & ASCII.HT & ASCII.HT & "68fb1a26 NE OO SU" & LF
                & "U other%s" & ASCII.HT & "other.ads" & LF)
             = "unit_tests.adb", "ali: main subprogram");
      Check (Main_Source
               ("V ""GNAT Lib v16""" & LF & "A -O1" & LF
                & "U p%b" & ASCII.HT & ASCII.HT & "p.adb" & LF) = "",
             "ali: not a main subprogram");
   end Test_Schemata;

begin
   Test_Lexer;
   Test_Operators;
   Test_Conditions;
   Test_Skipped;
   Test_Comments;
   Test_Assertions_Check;
   Test_Contract_Aspects;
   Test_Weakening;
   Test_Proof_Warnings;
   Test_Never_Reached;
   Test_Attributes;
   Test_Loop_Direction;
   Test_Deletions;
   Test_Ghost_Names;
   Test_Contract_Flag;
   Test_Apply;
   Test_Files;
   if GNAT.OS_Lib.Directory_Separator = '/' then
      Test_Processes;
   end if;
   Test_Positions;
   Test_Changes;
   Test_Config;
   Test_Json;
   Test_Json_Reader;
   Test_Baselines;
   Test_Schemata;
   Put_Line (Passed'Image & " passed," & Failed'Image & " failed");
   if Failed > 0 then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
exception
   when E : others =>
      Put_Line ("unexpected exception: " & Ada.Exceptions.Exception_Information (E));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end Unit_Tests;
