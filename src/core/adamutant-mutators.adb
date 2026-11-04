with Ada.Characters.Handling; use Ada.Characters.Handling;
with Ada.Containers.Ordered_Maps;
with Ada.Strings.Fixed;
with AdaMutant.Lexer; use AdaMutant.Lexer;

package body AdaMutant.Mutators is

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
         when String_Literal         => "StringLiteral");

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

   package Line_Maps is new Ada.Containers.Ordered_Maps
     (Positive, Mutator_Set);

   type Word is access constant String;

   Operator_Symbols : constant array (1 .. 19) of Word :=
     [new String'("and"), new String'("or"), new String'("xor"),
      new String'("="), new String'("/="), new String'("<"),
      new String'("<="), new String'(">"), new String'(">="),
      new String'("+"), new String'("-"), new String'("&"),
      new String'("*"), new String'("/"), new String'("mod"),
      new String'("rem"), new String'("**"), new String'("abs"),
      new String'("not")];

   type Byte_Range is record
      First, Last : Natural := 0;
   end record;

   package Range_Vectors is new Ada.Containers.Vectors (Positive, Byte_Range);

   --  Finds the declarations of Source that carry the Ghost aspect: adds
   --  their names to Names and their extents (from the declaration start
   --  to its ";") to Ranges.
   procedure Scan_Ghost
     (Source : String;
      Names  : in out Name_Sets.Set;
      Ranges : in out Range_Vectors.Vector)
   is
      All_Tokens : constant Token_Vectors.Vector := Tokenize (Source);
      type Token_Array is array (Positive range <>) of Token;
      S : Token_Array (1 .. Natural (All_Tokens.Length));
      N : Natural := 0;
   begin
      for T of All_Tokens loop
         if T.Kind /= Comment then
            N := N + 1;
            S (N) := T;
         end if;
      end loop;
      declare
         Depth : array (1 .. N) of Natural := [others => 0];
         D     : Natural := 0;

         function Txt (K : Positive) return String is
           (Source (S (K).First .. S (K).Last));

         function Is_Kw (K : Integer; W : String) return Boolean is
           (K in 1 .. N and then S (K).Kind = Reserved_Word
            and then Lower (Txt (K)) = W);

         function Is_Del (K : Integer; W : String) return Boolean is
           (K in 1 .. N and then S (K).Kind = Delimiter and then Txt (K) = W);

         function At_Top (K : Integer; W : String) return Boolean is
           (K in 1 .. N and then Depth (K) = 0
            and then (Is_Kw (K, W) or else Is_Del (K, W)));
      begin
         for K in 1 .. N loop
            Depth (K) := D;
            if Is_Del (K, "(") or else Is_Del (K, "[") then
               D := D + 1;
            elsif Is_Del (K, ")") or else Is_Del (K, "]") then
               D := (if D > 0 then D - 1 else 0);
            end if;
         end loop;
         for K in 1 .. N loop
            if S (K).Kind = Identifier and then Lower (Txt (K)) = "ghost"
              and then Depth (K) = 0
              and then (Is_Kw (K - 1, "with") or else Is_Del (K - 1, ","))
              and then not (Is_Del (K + 1, "=>") and then K + 2 <= N
                            and then Lower (Txt (K + 2)) = "false")
            then
               declare
                  W       : Natural := K - 1;
                  J       : Natural;
                  First   : Natural := 0;
                  Last    : Positive := K;
               begin
                  while W >= 1 and then not At_Top (W, "with")
                    and then not At_Top (W, ";")
                  loop
                     W := W - 1;
                  end loop;
                  if W >= 1 and then Is_Kw (W, "with") then
                     J := W - 1;
                     while J >= 1 loop
                        exit when At_Top (J, ";") or else At_Top (J, "begin")
                          or else At_Top (J, "declare")
                          or else At_Top (J, "private")
                          or else At_Top (J, "generic")
                          or else At_Top (J, "package")
                          or else (At_Top (J, "is")
                                   and then not Is_Del (J + 1, "("));
                        if At_Top (J, "procedure") or else At_Top (J, "function")
                          or else At_Top (J, "type")
                          or else At_Top (J, "subtype")
                        then
                           First := J;
                           exit;
                        end if;
                        J := J - 1;
                     end loop;
                     if First = 0 and then not At_Top (J, "package") then
                        First := J + 1;
                     end if;
                     while Last < N and then not At_Top (Last, ";") loop
                        Last := Last + 1;
                     end loop;
                     declare
                        Name_At : constant Positive :=
                          (if Is_Kw (First, "procedure")
                             or else Is_Kw (First, "function")
                             or else Is_Kw (First, "type")
                             or else Is_Kw (First, "subtype")
                           then First + 1 else First);
                     begin
                        if First > 0 and then Name_At < K
                          and then S (Name_At).Kind in Identifier
                                                     | String_Literal
                        then
                           Names.Include (Lower (Txt (Name_At)));
                           if Name_At = First then
                              --  "A, B : T with Ghost" declares every name.
                              declare
                                 I : Positive := First + 2;
                              begin
                                 while I < K and then Is_Del (I - 1, ",") loop
                                    Names.Include (Lower (Txt (I)));
                                    I := I + 2;
                                 end loop;
                              end;
                           end if;
                           Ranges.Append
                             (Byte_Range'(S (First).First, S (Last).Last));
                        end if;
                     end;
                  end if;
               end;
            end if;
         end loop;
      end;
   end Scan_Ghost;

   function Ghost_Names (Source : String) return Name_Sets.Set is
      Names  : Name_Sets.Set;
      Ranges : Range_Vectors.Vector;
   begin
      Scan_Ghost (Source, Names, Ranges);
      return Names;
   end Ghost_Names;

   function Find
     (Source : String; Options : Scan_Options) return Mutation_Vectors.Vector
   is
      All_Tokens : constant Token_Vectors.Vector := Tokenize (Source);
      Result     : Mutation_Vectors.Vector;

      --  Significant (non-comment) tokens.
      N : Natural := 0;
      type Token_Array is array (Positive range <>) of Token;
      S : Token_Array (1 .. Natural (All_Tokens.Length));

      --  Disabled mutators per significant token, from directive comments.
      type Set_Array is array (Positive range <>) of Mutator_Set;
      Disabled : Set_Array (1 .. Natural (All_Tokens.Length));
      Next_Line : Line_Maps.Map;
   begin
      declare
         Current : Mutator_Set := [others => False];

         function Parse_Set (Args : String; Line : Positive) return Mutator_Set
         is
            R     : Mutator_Set := [others => False];
            Rest  : constant String := Ada.Strings.Fixed.Trim
              (Args, Ada.Strings.Both);
            Start : Positive := Rest'First;
            K     : Mutator_Kind;
         begin
            if Rest = "" or else To_Lower (Rest) = "all" then
               return [others => True];
            end if;
            for J in Rest'First .. Rest'Last + 1 loop
               if J > Rest'Last or else Rest (J) = ',' then
                  declare
                     Item : constant String := Ada.Strings.Fixed.Trim
                       (Rest (Start .. J - 1), Ada.Strings.Both);
                  begin
                     if To_Lower (Item) = "all" then
                        R := [others => True];
                     elsif Parse (Item, K) then
                        R (K) := True;
                     else
                        raise Directive_Error with
                          "line" & Line'Image & ": unknown mutator '"
                          & Item & "' in adamutant directive";
                     end if;
                  end;
                  Start := J + 1;
               end if;
            end loop;
            return R;
         end Parse_Set;

         procedure Directive (Text : String; Line : Positive) is
            Body_Text : constant String := Ada.Strings.Fixed.Trim
              (Text (Text'First + 2 .. Text'Last), Ada.Strings.Both);
            Prefix    : constant String := "adamutant:";
         begin
            if Body_Text'Length <= Prefix'Length
              or else To_Lower
                (Body_Text (Body_Text'First
                            .. Body_Text'First + Prefix'Length - 1)) /= Prefix
            then
               return;
            end if;
            declare
               Cmd_Full : constant String :=
                 Body_Text (Body_Text'First + Prefix'Length .. Body_Text'Last);
               Colon    : constant Natural :=
                 Ada.Strings.Fixed.Index (Cmd_Full, ":");
               Cmd      : constant String :=
                 (if Colon = 0 then Cmd_Full
                  else Cmd_Full (Cmd_Full'First .. Colon - 1));
               Space    : Natural := Ada.Strings.Fixed.Index (Cmd, " ");
               Verb     : constant String := To_Lower
                 (if Space = 0 then Cmd else Cmd (Cmd'First .. Space - 1));
               Args     : constant String :=
                 (if Space = 0 then "" else Cmd (Space + 1 .. Cmd'Last));
               Set      : constant Mutator_Set := Parse_Set (Args, Line);
            begin
               Space := 0;
               if Verb = "disable" then
                  for K in Mutator_Kind loop
                     Current (K) := Current (K) or Set (K);
                  end loop;
               elsif Verb = "enable" then
                  for K in Mutator_Kind loop
                     Current (K) := Current (K) and not Set (K);
                  end loop;
               elsif Verb = "disable-next-line" then
                  Next_Line.Include (Line + 1, Set);
               else
                  raise Directive_Error with
                    "line" & Line'Image & ": unknown adamutant directive '"
                    & Verb & "'";
               end if;
            end;
         end Directive;
      begin
         for T of All_Tokens loop
            if T.Kind = Comment then
               Directive (Source (T.First .. T.Last), T.Line);
            else
               N := N + 1;
               S (N) := T;
               Disabled (N) := Current;
            end if;
         end loop;
      end;

      declare
         function Txt (K : Positive) return String is
           (Source (S (K).First .. S (K).Last));

         function Is_Kw (K : Integer; W : String) return Boolean is
           (K in 1 .. N and then S (K).Kind = Reserved_Word
            and then Lower (Txt (K)) = W);

         function Is_Del (K : Integer; D : String) return Boolean is
           (K in 1 .. N and then S (K).Kind = Delimiter and then Txt (K) = D);

         function Is_Operand_End (K : Integer) return Boolean is
           (K in 1 .. N
            and then (S (K).Kind in Identifier | Numeric_Literal
                        | Character_Literal | String_Literal
                      or else Is_Del (K, ")") or else Is_Del (K, "]")
                      or else Is_Kw (K, "all")));

         Depth      : array (1 .. N) of Natural := [others => 0];
         Seg_Start  : array (1 .. N) of Positive := [others => 1];
         In_Aspect  : array (1 .. N) of Boolean := [others => False];
         Seg_Skip   : array (1 .. N) of Boolean := [others => False];
         Seg_Pragma : array (1 .. N) of Boolean := [others => False];
         In_Default : array (1 .. N) of Boolean := [others => False];
         In_Ghost   : array (1 .. N) of Boolean := [others => False];

         function Skipped (K : Positive) return Boolean is
           (Seg_Skip (Seg_Start (K)) or else Seg_Pragma (Seg_Start (K))
            or else In_Default (K)
            or else (not Options.Mutate_Contracts
                     and then (In_Aspect (K) or else In_Ghost (K))));

         function Is_Declared_Bound (K : Positive) return Boolean;
         --  K is a bound of a range in the subtype of an object, component,
         --  type or subtype declaration ("X : String (1 .. 6)",
         --  "subtype S is Integer range 1 .. 4"). Changing such a bound
         --  either leaves values out of the subtype (a compile error) or
         --  only widens it (an equivalent mutant).

         function Is_Declared_Bound (K : Positive) return Boolean is
            First : constant Positive := Seg_Start (K);
            Colon : Boolean := False;
         begin
            if not (Is_Del (K - 1, "..") or else Is_Del (K + 1, "..")) then
               return False;
            end if;
            for J in First .. K - 1 loop
               if Is_Del (J, ":=") or else Is_Kw (J, "renames") then
                  return False;
               elsif Is_Del (J, ":") and then Depth (J) = 0
                 and then not (Is_Kw (J + 1, "for") or else Is_Kw (J + 1, "while")
                               or else Is_Kw (J + 1, "loop")
                               or else Is_Kw (J + 1, "declare")
                               or else Is_Kw (J + 1, "begin"))
               then
                  Colon := True;
               end if;
            end loop;
            return Colon
              or else (First > 2 and then Is_Kw (First - 1, "is")
                       and then (Is_Kw (Seg_Start (First - 1), "type")
                                 or else Is_Kw (Seg_Start (First - 1),
                                                "subtype")));
         end Is_Declared_Bound;

         procedure Add
           (Kind        : Mutator_Kind;
            From, To    : Positive;
            Replacement : String;
            Anchor      : Natural := 0)
         is
            A       : constant Positive := (if Anchor = 0 then From else Anchor);
            Ignored : Boolean := Disabled (A) (Kind);
            Line    : constant Positive := S (A).Line;
         begin
            if not Options.Enabled (Kind) or else Skipped (A) then
               return;
            end if;
            if Next_Line.Contains (Line) and then Next_Line (Line) (Kind) then
               Ignored := True;
            end if;
            Result.Append
              (Mutation'(Kind        => Kind,
                First       => S (From).First,
                Last        => S (To).Last,
                Replacement => To_Unbounded_String (Replacement),
                Ignored     => Ignored));
         end Add;

         function Same_Case (Model, Word : String) return String is
           (if Model = To_Upper (Model) then To_Upper (Word)
            elsif Model = To_Lower (Model) then To_Lower (Word)
            else Word);

         --  Tokens that end an expression at their own nesting depth.
         function Is_Boundary (J : Positive) return Boolean is
           (Is_Del (J, ",") or else Is_Del (J, ";") or else Is_Del (J, "=>")
            or else Is_Del (J, ":=") or else Is_Del (J, "|")
            or else Is_Del (J, ")") or else Is_Del (J, "]")
            or else Is_Del (J, "<<") or else Is_Del (J, ">>")
            or else (S (J).Kind = Reserved_Word
                     and then not
                       (Is_Kw (J, "and") or else Is_Kw (J, "or")
                        or else Is_Kw (J, "xor") or else Is_Kw (J, "not")
                        or else Is_Kw (J, "in") or else Is_Kw (J, "mod")
                        or else Is_Kw (J, "rem") or else Is_Kw (J, "abs")
                        or else Is_Kw (J, "null") or else Is_Kw (J, "new")
                        or else Is_Kw (J, "all")
                        or else (Is_Kw (J, "then") and then Is_Kw (J - 1, "and"))
                        or else (Is_Kw (J, "else") and then Is_Kw (J - 1, "or")))));

         --  Ada does not allow different logical operators side by side
         --  without parentheses, so in a chain such as "A and then B and then
         --  C" the operands around the mutated operator are parenthesised:
         --  "(A or else B) and then C", "((A and then B) or else C)".
         procedure Add_Logical
           (K : Positive; Width : Positive; New_Op : String)
         is
            D : constant Natural := Depth (K);
            L : Positive := K;
            R : Natural := K + Width - 1;

            function Op_Width (J : Positive) return Natural is
              (if (Is_Kw (J, "and") and then Is_Kw (J + 1, "then"))
                 or else (Is_Kw (J, "or") and then Is_Kw (J + 1, "else"))
               then 2
               elsif Is_Kw (J, "and") or else Is_Kw (J, "or")
                 or else Is_Kw (J, "xor")
               then 1
               else 0);

            function Membership_Bar (J : Positive) return Boolean;
            --  J is a "|" between the choices of a membership test
            --  ("X in 1 | 3"), which belongs to the operand.

            function Membership_Bar (J : Positive) return Boolean is
               I : Natural := J - 1;
            begin
               if not Is_Del (J, "|") then
                  return False;
               end if;
               while I >= 1
                 and then (Depth (I) > D
                           or else (Depth (I) = D and then Op_Width (I) = 0
                                    and then (Is_Del (I, "|")
                                              or else not Is_Boundary (I))))
               loop
                  if Depth (I) = D and then Is_Kw (I, "in") then
                     return True;
                  end if;
                  I := I - 1;
               end loop;
               return False;
            end Membership_Bar;

            function Inside (J : Positive) return Boolean is
              (Depth (J) > D
               or else (Depth (J) = D
                        and then (not Is_Boundary (J)
                                  or else Membership_Bar (J))));

            Before, After : Natural := 0;
            Next          : Natural;
         begin
            while L > 1 and then Inside (L - 1) loop
               L := L - 1;
            end loop;
            while R < N and then Inside (R + 1) loop
               R := R + 1;
            end loop;
            declare
               J : Positive := L;
            begin
               while J <= R loop
                  if Depth (J) = D and then Op_Width (J) > 0 then
                     if J < K then
                        Before := Before + 1;
                     elsif J > K and then After = 0 then
                        After := J;
                     end if;
                     J := J + Op_Width (J);
                  else
                     J := J + 1;
                  end if;
               end loop;
            end;
            Next := (if After = 0 then R + 1 else After);
            if (Before = 0 and then After = 0) or else L >= K
              or else Next <= K + Width
            then
               Add (Logical_Operator, K, K + Width - 1, New_Op);
               return;
            end if;
            declare
               Left  : constant String :=
                 Source (S (L).First .. S (K - 1).Last);
               Right : constant String :=
                 Source (S (K + Width).First .. S (Next - 1).Last);
            begin
               Add (Logical_Operator, L, Next - 1,
                    "(" & (if Before > 0 then "(" & Left & ")" else Left)
                    & " " & New_Op & " " & Right & ")",
                    Anchor => K);
            end;
         end Add_Logical;
      begin
         --  Pass 1: nesting depth, segments (statements, declarations,
         --  alternatives) and aspect specifications.
         declare
            D      : Natural := 0;
            Start  : Positive := 1;
            Aspect : Boolean := False;
         begin
            for K in 1 .. N loop
               Depth (K) := D;
               Seg_Start (K) := Start;
               In_Aspect (K) := Aspect;
               if Is_Del (K, "(") or else Is_Del (K, "[") then
                  D := D + 1;
               elsif Is_Del (K, ")") or else Is_Del (K, "]") then
                  D := (if D > 0 then D - 1 else 0);
               elsif D = 0 then
                  if Aspect then
                     if Is_Del (K, ";") or else Is_Kw (K, "is") then
                        Aspect := False;
                        Start := K + 1;
                     end if;
                  elsif Is_Kw (K, "with") and then K /= Start
                    and then not (Is_Kw (K + 1, "record")
                                  or else Is_Kw (K + 1, "null")
                                  or else Is_Kw (K + 1, "private"))
                  then
                     Aspect := True;
                     In_Aspect (K) := True;
                  elsif Is_Del (K, ";") or else Is_Del (K, "=>")
                    or else Is_Del (K, ">>")
                    or else Is_Kw (K, "is") or else Is_Kw (K, "begin")
                    or else (Is_Kw (K, "then") and then not Is_Kw (K - 1, "and"))
                    or else (Is_Kw (K, "else") and then not Is_Kw (K - 1, "or"))
                    or else Is_Kw (K, "loop") or else Is_Kw (K, "do")
                    or else Is_Kw (K, "declare") or else Is_Kw (K, "private")
                    or else Is_Kw (K, "generic") or else Is_Kw (K, "record")
                    or else Is_Kw (K, "select") or else Is_Kw (K, "exception")
                    or else (Is_Kw (K, "or") and then Is_Del (K - 1, ";"))
                  then
                     Start := K + 1;
                  end if;
               end if;
            end loop;
         end;

         --  Pass 2: segments that are never mutated (context clauses,
         --  representation clauses) and pragmas.
         for K in 1 .. N loop
            if Seg_Start (K) = K then
               declare
                  Has_Use : Boolean := False;
                  Has_At  : Boolean := False;
                  J       : Positive := K;
               begin
                  while J <= N and then Seg_Start (J) = K loop
                     if Depth (J) = 0 then
                        Has_Use := Has_Use or else Is_Kw (J, "use");
                        Has_At := Has_At or else Is_Kw (J, "at");
                     end if;
                     J := J + 1;
                  end loop;
                  Seg_Skip (K) :=
                    (Is_Kw (K, "with")
                     and then not (Is_Kw (K + 1, "procedure")
                                   or else Is_Kw (K + 1, "function")
                                   or else Is_Kw (K + 1, "package")))
                    or else Is_Kw (K, "use")
                    or else (Is_Kw (K, "limited") and then Is_Kw (K + 1, "with"))
                    or else (Is_Kw (K, "for") and then Has_Use)
                    or else Has_At;
                  Seg_Pragma (K) := Is_Kw (K, "pragma");
               end;
            end if;
         end loop;

         --  Pass 2b: default expressions of formal parameters.  A
         --  subprogram declaration and its body must repeat the same
         --  defaults (full conformance), so changing one side never
         --  compiles.  Profiles that need no completion (is null, is
         --  abstract, expression functions, generic formal subprograms)
         --  stay mutable.
         for K in 1 .. N loop
            if (Is_Kw (K, "procedure") or else Is_Kw (K, "function")
                or else Is_Kw (K, "entry"))
              and then not Is_Kw (K - 1, "with")
            then
               declare
                  J : Positive := K + 1;
               begin
                  while J < N
                    and then (S (J).Kind in Identifier | String_Literal
                              or else Is_Del (J, "."))
                  loop
                     J := J + 1;
                  end loop;
                  if J > K + 1 and then J < N and then Is_Del (J, "(") then
                     declare
                        D     : constant Natural := Depth (J);
                        Close : Positive := J + 1;
                        After : Positive;
                     begin
                        while Close < N
                          and then not (Is_Del (Close, ")")
                                        and then Depth (Close) = D + 1)
                        loop
                           Close := Close + 1;
                        end loop;
                        After := Close + 1;
                        while After < N and then Depth (After) >= D
                          and then not (Depth (After) = D
                                        and then (Is_Kw (After, "is")
                                                  or else Is_Del (After, ";")
                                                  or else Is_Kw (After, "with")
                                                  or else Is_Kw (After, "do")))
                        loop
                           After := After + 1;
                        end loop;
                        if not (Is_Kw (After, "is") and then After < N
                                and then (Is_Kw (After + 1, "null")
                                          or else Is_Kw (After + 1, "abstract")
                                          or else Is_Del (After + 1, "(")
                                          or else Is_Del (After + 1, "<>")))
                        then
                           declare
                              Mark : Boolean := False;
                           begin
                              for I in J + 1 .. Close - 1 loop
                                 if Depth (I) = D + 1 then
                                    if Is_Del (I, ":=") then
                                       Mark := True;
                                    elsif Is_Del (I, ";") then
                                       Mark := False;
                                    end if;
                                 end if;
                                 if Mark then
                                    In_Default (I) := True;
                                 end if;
                              end loop;
                           end;
                        end if;
                     end;
                  end if;
               end;
            end if;
         end loop;

         --  Pass 2c: ghost code (declarations and bodies of ghost entities
         --  and statements calling or assigning them).  It only exists for
         --  proof, so like contracts it is mutated only with
         --  mutate_contracts.
         declare
            Names  : Name_Sets.Set := Options.Ghost_Names;
            Ranges : Range_Vectors.Vector;

            function Ghost (K : Positive) return Boolean is
              (K <= N and then S (K).Kind in Identifier | String_Literal
               and then Names.Contains (Lower (Txt (K))));

            function Semicolon (From : Positive) return Positive is
               J : Positive := From;
            begin
               while J < N and then not (Depth (J) = 0 and then Is_Del (J, ";"))
               loop
                  J := J + 1;
               end loop;
               return J;
            end Semicolon;

            procedure Mark (From, To : Positive) is
            begin
               for I in From .. To loop
                  In_Ghost (I) := True;
               end loop;
            end Mark;
         begin
            Scan_Ghost (Source, Names, Ranges);
            for R of Ranges loop
               for I in 1 .. N loop
                  if S (I).First in R.First .. R.Last then
                     In_Ghost (I) := True;
                  end if;
               end loop;
            end loop;
            for K in 1 .. N loop
               if (Is_Kw (K, "procedure") or else Is_Kw (K, "function"))
                 and then Depth (K) = 0 and then not Is_Kw (K - 1, "with")
                 and then Ghost (K + 1)
               then
                  declare
                     J : Positive := K + 1;
                  begin
                     while J < N and then not (Depth (J) = 0
                                               and then (Is_Kw (J, "is")
                                                         or else Is_Del (J, ";")))
                     loop
                        J := J + 1;
                     end loop;
                     if Is_Kw (J, "is")
                       and then not (Is_Del (J + 1, "(")
                                     or else Is_Kw (J + 1, "null")
                                     or else Is_Kw (J + 1, "abstract")
                                     or else Is_Kw (J + 1, "separate")
                                     or else Is_Kw (J + 1, "new"))
                     then
                        --  The body ends at the "end" of its own "begin";
                        --  "end if", "end loop" and the like close other
                        --  constructs.
                        declare
                           Level : Natural := 0;
                        begin
                           while J < N loop
                              J := J + 1;
                              if Is_Kw (J, "begin") or else Is_Kw (J, "do") then
                                 Level := Level + 1;
                              elsif Is_Kw (J, "end")
                                and then not (Is_Kw (J + 1, "if")
                                              or else Is_Kw (J + 1, "loop")
                                              or else Is_Kw (J + 1, "case")
                                              or else Is_Kw (J + 1, "record")
                                              or else Is_Kw (J + 1, "select")
                                              or else Is_Kw (J + 1, "return"))
                                and then Level > 0
                              then
                                 Level := Level - 1;
                                 exit when Level = 0;
                              end if;
                           end loop;
                        end;
                        Mark (K, Semicolon (J));
                     else
                        Mark (K, Semicolon (J));
                     end if;
                  end;
               elsif Seg_Start (K) = K and then S (K).Kind = Identifier then
                  declare
                     J    : Positive := K;
                     Name : Positive := K;
                  begin
                     while J < N and then (S (J).Kind = Identifier
                                           or else Is_Del (J, "."))
                     loop
                        if S (J).Kind = Identifier then
                           Name := J;
                        end if;
                        J := J + 1;
                     end loop;
                     if Ghost (Name)
                       and then (Is_Del (J, "(") or else Is_Del (J, ";")
                                 or else Is_Del (J, ":="))
                     then
                        Mark (K, Semicolon (K));
                     end if;
                  end;
               end if;
            end loop;
         end;

         --  Pass 3: mutations.
         for K in 1 .. N loop
            declare
               T     : constant Token := S (K);
               Lw    : constant String := Lower (Txt (K));
               Binary : constant Boolean := Is_Operand_End (K - 1);
            begin
               case T.Kind is
                  when Delimiter =>
                     if Lw = "+" or else Lw = "-" then
                        if Binary then
                           Add (Arithmetic_Operator, K, K,
                                (if Lw = "+" then "-" else "+"));
                        else
                           Add (Unary_Operator, K, K,
                                (if Lw = "+" then "-" else "+"));
                        end if;
                     elsif Lw = "*" and then Binary then
                        Add (Arithmetic_Operator, K, K, "/");
                     elsif Lw = "/" and then Binary then
                        Add (Arithmetic_Operator, K, K, "*");
                     elsif Lw = "**" then
                        Add (Arithmetic_Operator, K, K, "*");
                     elsif Lw = "=" then
                        Add (Equality_Operator, K, K, "/=");
                     elsif Lw = "/=" then
                        Add (Equality_Operator, K, K, "=");
                     elsif Lw = "<" then
                        Add (Equality_Operator, K, K, "<=");
                        Add (Equality_Operator, K, K, ">=");
                     elsif Lw = "<=" then
                        Add (Equality_Operator, K, K, "<");
                        Add (Equality_Operator, K, K, ">");
                     elsif Lw = ">" then
                        Add (Equality_Operator, K, K, ">=");
                        Add (Equality_Operator, K, K, "<=");
                     elsif Lw = ">=" then
                        Add (Equality_Operator, K, K, ">");
                        Add (Equality_Operator, K, K, "<");
                     end if;

                  when Reserved_Word =>
                     --  mod and rem differ only for operands of opposite
                     --  signs, so swapping them is nearly always equivalent.
                     if (Lw = "mod" or else Lw = "rem") and then Binary then
                        Add (Arithmetic_Operator, K, K, "*");

                     elsif Lw = "and" then
                        if Is_Kw (K + 1, "then") then
                           Add_Logical (K, 2, Same_Case (Txt (K), "or else"));
                        elsif not (Is_Kw (Seg_Start (K), "new")
                                   or else Is_Kw (Seg_Start (K), "interface")
                                   or else Is_Kw (Seg_Start (K), "limited")
                                   or else Is_Kw (Seg_Start (K), "synchronized")
                                   or else Is_Kw (Seg_Start (K), "task")
                                   or else Is_Kw (Seg_Start (K), "protected"))
                        then
                           Add_Logical (K, 1, Same_Case (Txt (K), "or"));
                        end if;

                     elsif Lw = "or" and then not Is_Del (K - 1, ";") then
                        if Is_Kw (K + 1, "else") then
                           Add_Logical (K, 2, Same_Case (Txt (K), "and then"));
                        else
                           Add_Logical (K, 1, Same_Case (Txt (K), "and"));
                        end if;

                     elsif Lw = "xor" then
                        Add_Logical (K, 1, Same_Case (Txt (K), "or"));

                     elsif Lw = "not" then
                        if Is_Kw (K + 1, "in") then
                           if Is_Operand_End (K - 1) then
                              Add (Membership_Operator, K, K + 1,
                                   Same_Case (Txt (K + 1), "in"));
                           end if;
                        elsif not (Is_Kw (K + 1, "null")
                                   or else Is_Kw (K + 1, "overriding"))
                        then
                           Add (Unary_Operator, K, K, "");
                        end if;

                     elsif Lw = "abs" then
                        Add (Unary_Operator, K, K, "");

                     elsif Lw = "in" and then Binary
                       and then not Is_Kw (K - 1, "not")
                       and then not (Is_Kw (K - 2, "for")
                                     or else Is_Kw (K - 2, "all")
                                     or else Is_Kw (K - 2, "some"))
                     then
                        Add (Membership_Operator, K, K,
                             Same_Case (Txt (K), "not in"));

                     elsif (Lw = "if" and then not Is_Kw (K - 1, "end"))
                       or else Lw = "elsif" or else Lw = "while"
                       or else (Lw = "when"
                                and then (Is_Kw (K - 1, "exit")
                                          or else (S (K - 1).Kind = Identifier
                                                   and then Is_Kw (K - 2, "exit"))))
                     then
                        --  Find the end of the condition at the same depth.
                        declare
                           J    : Positive := K + 1;
                           Stop : Natural := 0;
                        begin
                           while J <= N and then Depth (J) >= Depth (K) loop
                              if Depth (J) = Depth (K) then
                                 if Lw = "while" then
                                    exit when Is_Kw (J, "loop") or else Is_Del (J, ";");
                                 elsif Lw = "when" then
                                    exit when Is_Del (J, ";");
                                 else
                                    exit when (Is_Kw (J, "then")
                                               and then not Is_Kw (J - 1, "and"))
                                      or else Is_Del (J, ";");
                                 end if;
                              end if;
                              J := J + 1;
                           end loop;
                           if J <= N and then J > K + 1
                             and then Depth (J) = Depth (K)
                             and then Is_Del (J, ";") = (Lw = "when")
                           then
                              Stop := J - 1;
                           end if;
                           if Stop > 0 then
                              declare
                                 Single : constant String :=
                                   (if Stop = K + 1 then Lower (Txt (K + 1)) else "");
                              begin
                                 if Lw = "while" then
                                    if Single /= "false" then
                                       Add (Conditional_Expression, K + 1, Stop, "False");
                                    end if;
                                 elsif Lw = "when" then
                                    if Single /= "true" then
                                       Add (Conditional_Expression, K + 1, Stop, "True");
                                    end if;
                                 else
                                    if Single /= "true" then
                                       Add (Conditional_Expression, K + 1, Stop, "True");
                                    end if;
                                    if Single /= "false" then
                                       Add (Conditional_Expression, K + 1, Stop, "False");
                                    end if;
                                 end if;
                              end;
                           end if;
                        end;
                     end if;

                  when Identifier =>
                     if (Lw = "true" or else Lw = "false")
                       and then not Is_Del (K - 1, "'")
                     then
                        Add (Boolean_Literal, K, K,
                             Same_Case (Txt (K),
                                        (if Lw = "true" then "False" else "True")));
                     end if;

                     --  Statement deletion: a call or an assignment.
                     if Seg_Start (K) = K and then Depth (K) = 0
                       and then not In_Aspect (K)
                       and then not Is_Del (K + 1, "'")
                       and then not Is_Kw (K - 1, "is")
                       and then not (Is_Kw (K - 1, "loop")
                                     and then Is_Kw (K - 2, "end"))
                     then
                        declare
                           J : Positive := K + 1;
                           Is_Statement : Boolean := False;
                        begin
                           while J <= N and then Seg_Start (J) = K loop
                              if Depth (J) = 0 then
                                 exit when Is_Del (J, ":") or else Is_Del (J, ",");
                                 if Is_Del (J, ";") then
                                    Is_Statement := True;
                                    exit;
                                 end if;
                                 exit when S (J).Kind = Reserved_Word
                                   and then not Is_Kw (J, "all");
                              end if;
                              J := J + 1;
                           end loop;
                           if Is_Statement and then J <= N
                             and then Is_Del (J, ";")
                           then
                              Add (Statement_Deletion, K, J, "null;");
                           end if;
                        end;
                     end if;

                  when Numeric_Literal =>
                     declare
                        R : constant String := Numeric_Mutation (Txt (K));
                     begin
                        if Is_Del (K - 1, "(") and then Is_Del (K - 3, "'") then
                           null;
                        elsif Is_Kw (K - 1, "digits") or else Is_Kw (K - 1, "delta") then
                           null;
                        elsif Is_Declared_Bound (K) then
                           null;
                        elsif R /= "" then
                           Add (Numeric_Literal, K, K, R);
                        end if;
                     end;

                  when String_Literal =>
                     declare
                        Content : constant String :=
                          Lower (Source (T.First + 1 .. T.Last - 1));
                        Is_Op   : Boolean := False;
                     begin
                        for Op of Operator_Symbols loop
                           Is_Op := Is_Op or else Op.all = Content;
                        end loop;
                        if not Is_Op and then not Is_Kw (K - 1, "function")
                          and then not Is_Kw (K - 1, "end")
                          and then not Is_Del (K - 1, ".")
                        then
                           Add (String_Literal, K, K,
                                (if Content = "" then """AdaMutant was here!"""
                                 else """"""));
                        end if;
                     end;

                  when Character_Literal | Comment =>
                     null;
               end case;
            end;
         end loop;
      end;
      return Result;
   end Find;

end AdaMutant.Mutators;
