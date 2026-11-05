with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO; use Ada.Text_IO;
with AdaMutant.Changes;
with AdaMutant.Config;
with AdaMutant.Files;
with AdaMutant.Lexer;
with AdaMutant.Mutators; use AdaMutant.Mutators;
with Ada.Directories;
with GNAT.OS_Lib;
with Ada.Environment_Variables;
with AdaMutant.Positions;
with AdaMutant.Processes;

with AdaMutant.Reports;
with AdaMutant.Runner;

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

   --  "Kind original->replacement" for every mutation, separated by "|";
   --  ignored mutations get a leading "!".
   function Describe
     (Source : String; Options : Scan_Options := (others => <>)) return String
   is
      R : Unbounded_String;
   begin
      for M of Find (Source, Options) loop
         if Length (R) > 0 then
            Append (R, "|");
         end if;
         Append (R, (if M.Ignored then "!" else "") & Name (M.Kind) & " "
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
              & "|EqualityOperator <->>=",
              "while condition never becomes True");
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
              "EqualityOperator >->>=|EqualityOperator >-><=|NumericLiteral 0->1",
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
      Expect ("package P is pragma Assert (X > 0); end P;", "",
              "pragmas are skipped even with mutate_contracts",
              (Mutate_Contracts => True, others => <>));
      Expect ("package P is type T is new Parent and Iface with null record;"
              & " end P;",
              "", "interface list and");
      Expect ("procedure P is begin return; end P;", "",
              "return and null are not deleted");
   end Test_Skipped;

   procedure Test_Directives is
   begin
      Expect ("procedure P is begin" & LF
              & "--  adamutant:disable-next-line ArithmeticOperator: reason" & LF
              & "X := A + 1;" & LF
              & "Y := B - 1;" & LF & "end P;",
              "StatementDeletion X := A + 1;->null;|!ArithmeticOperator +->-"
              & "|NumericLiteral 1->0|StatementDeletion Y := B - 1;->null;"
              & "|ArithmeticOperator -->+|NumericLiteral 1->0",
              "disable-next-line with a mutator name");
      Expect ("procedure P is begin" & LF
              & "--  adamutant:disable" & LF
              & "X := 1;" & LF
              & "--  adamutant:enable" & LF
              & "Y := 2;" & LF & "end P;",
              "!StatementDeletion X := 1;->null;|!NumericLiteral 1->0"
              & "|StatementDeletion Y := 2;->null;|NumericLiteral 2->3",
              "disable and enable");
      begin
         Expect ("--  adamutant:disable Nonsense" & LF & "X := 1;", "?",
                 "unknown mutator name");
      exception
         when Directive_Error =>
            Check (True, "unknown mutator name");
      end;
      declare
         O : Scan_Options;
      begin
         O.Enabled := [others => False];
         O.Enabled (Numeric_Literal) := True;
         Expect ("procedure P is begin X := A + 1; end P;",
                 "NumericLiteral 1->0", "enabled mutator set", O);
      end;
   end Test_Directives;

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
      Check (Glob_Match ("src/**/*.adb", "src/a.adb"), "glob ** empty");
      Check (Glob_Match ("src/**/*.adb", "src/x/y/a.adb"), "glob ** deep");
      Check (not Glob_Match ("src/*.adb", "src/x/a.adb"), "glob * no slash");
      Check (Glob_Match ("?.ads", "p.ads"), "glob ?");
      Check (not Glob_Match ("*.adb", "a.ads"), "glob extension");
      Check (Join ("a", "b/c") = "a/b/c", "join");
      declare
         use GNAT.OS_Lib;
         Path : constant String := "write_changed.tmp";
         Stamp : time_t;
         Deleted : Boolean;
      begin
         Write (Path, "original");
         --  An odd second ahead of the clock, which the rewrite cannot pass
         --  by itself: one second later would round to the same even
         --  second in the ALI files GNAT writes on Windows.
         Stamp := To_C (File_Time_Stamp (Path)) + 1001;
         if Stamp mod 2 = 0 then
            Stamp := Stamp + 1;
         end if;
         Set_File_Last_Modify_Time_Stamp (Path, To_Ada (Stamp));
         Write_Changed (Path, "mutant");
         Check (To_C (File_Time_Stamp (Path)) = Stamp + 2,
                "rewrite moves the time stamp two seconds");
         Check (Read (Path) = "mutant", "rewrite content");
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
      Check (C.High = 90 and then C.Break = 10, "config thresholds");
      Rejects ("build = ""b""" & LF & "test = ""t""" & LF & "colour = 1",
               "config unknown key");
      Rejects ("test = ""t""", "config missing build");
      Rejects ("build = ""b""", "config missing test and prove");
      Rejects ("build = ""b""" & LF & "build = ""c""" & LF & "test = ""t""",
               "config duplicate key");
      Rejects ("build = ""b""" & LF & "test = ""t""" & LF
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
   end Test_Json;

begin
   Test_Lexer;
   Test_Operators;
   Test_Conditions;
   Test_Skipped;
   Test_Directives;
   Test_Apply;
   Test_Files;
   if GNAT.OS_Lib.Directory_Separator = '/' then
      Test_Processes;
   end if;
   Test_Positions;
   Test_Changes;
   Test_Config;
   Test_Json;
   Put_Line (Passed'Image & " passed," & Failed'Image & " failed");
   if Failed > 0 then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
exception
   when E : others =>
      Put_Line ("unexpected exception: " & Ada.Exceptions.Exception_Information (E));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end Unit_Tests;
