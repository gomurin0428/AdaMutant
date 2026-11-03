with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO; use Ada.Text_IO;
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
              "NumericLiteral 2.5->0.0|NumericLiteral 0->1",
              "plain reals and zero; exponent literals are kept");
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
      Expect ("package P is type T is range 0 .. 255; for T'Size use 8; end P;",
              "NumericLiteral 0->1|NumericLiteral 255->256",
              "representation clause");
      Expect ("package P is function F (X : Integer) return Integer"
              & " with Pre => X > 0; end P;",
              "", "aspects are not mutated by default");
      Expect ("package P is function F (X : Integer) return Integer"
              & " with Pre => X > 0; end P;",
              "EqualityOperator >->>=|EqualityOperator >-><=|NumericLiteral 0->1",
              "aspects with mutate_contracts",
              (Mutate_Contracts => True, others => <>));
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
      Check (Glob_Match ("src/**/*.adb", "src/a.adb"), "glob ** empty");
      Check (Glob_Match ("src/**/*.adb", "src/x/y/a.adb"), "glob ** deep");
      Check (not Glob_Match ("src/*.adb", "src/x/a.adb"), "glob * no slash");
      Check (Glob_Match ("?.ads", "p.ads"), "glob ?");
      Check (not Glob_Match ("*.adb", "a.ads"), "glob extension");
      Check (Join ("a", "b/c") = "a/b/c", "join");
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
