with Ada.Characters.Handling;
with AdaMutant.Lexer; use AdaMutant.Lexer;

package body AdaMutant.Schemata is

   LF : constant Character := ASCII.LF;

   Symbol    : constant String := "adamutant_schemata_active";
   Unit_Name : constant String := "AdaMutant_Schemata_Support";
   Style_Off : constant String := "pragma Style_Checks (Off);";

   function Image (N : Natural) return String is
      S : constant String := N'Image;
   begin
      return S (S'First + 1 .. S'Last);
   end Image;

   type Region_Kind is (Statement, Condition, Expression);

   type Region is record
      Kind  : Region_Kind := Statement;
      First : Positive := 1;
      Last  : Natural := 0;
   end record;
   --  Source (First .. Last) is a whole simple statement with its
   --  semicolon, a whole condition, or the parenthesized expression of an
   --  expression function.

   package Region_Vectors is new Ada.Containers.Vectors (Positive, Region);

   type Token_Array is array (Positive range <>) of Token;

   function Significant (Source : String) return Token_Array;
   --  The tokens of Source without the comments.

   function Significant (Source : String) return Token_Array is
      All_Tokens : constant Token_Vectors.Vector := Tokenize (Source);
      S : Token_Array (1 .. Natural (All_Tokens.Length));
      N : Natural := 0;
   begin
      for T of All_Tokens loop
         if T.Kind /= Comment then
            N := N + 1;
            S (N) := T;
         end if;
      end loop;
      return S (1 .. N);
   end Significant;

   procedure Find_Regions
     (Source  : String;
      S       : Token_Array;
      Anchor  : out Natural;
      Regions : out Region_Vectors.Vector);
   --  Anchor is the last byte of the "is" that opens the unit of Source,
   --  after which a declaration can be inserted, or 0 when Source is not a
   --  unit that a schema can be made of.  Regions are in source order and
   --  do not overlap.

   procedure Find_Regions
     (Source  : String;
      S       : Token_Array;
      Anchor  : out Natural;
      Regions : out Region_Vectors.Vector)
   is
      N : constant Natural := S'Last;

      function Txt (K : Positive) return String is
        (Source (S (K).First .. S (K).Last));

      function Is_Kw (K : Integer; W : String) return Boolean is
        (K in 1 .. N and then S (K).Kind = Reserved_Word
         and then Lower (Txt (K)) = W);

      function Is_Del (K : Integer; D : String) return Boolean is
        (K in 1 .. N and then S (K).Kind = Delimiter and then Txt (K) = D);

      --  Nesting in parentheses and brackets.  An opening and a closing
      --  delimiter have the depth of what surrounds them.
      Depth : array (1 .. N) of Natural := [others => 0];

      function Next_At_Depth_0 (From : Positive; D : String) return Natural;
      --  The first delimiter D at depth 0 at or after From, or 0.

      function Next_At_Depth_0 (From : Positive; D : String) return Natural is
      begin
         for J in From .. N loop
            if Depth (J) = 0 and then Is_Del (J, D) then
               return J;
            end if;
         end loop;
         return 0;
      end Next_At_Depth_0;

      function Closing (Open : Positive) return Natural;
      --  The delimiter that closes the parenthesis at Open, or 0.

      function Closing (Open : Positive) return Natural is
      begin
         for J in Open + 1 .. N loop
            if Depth (J) = Depth (Open)
              and then (Is_Del (J, ")") or else Is_Del (J, "]"))
            then
               return J;
            end if;
         end loop;
         return 0;
      end Closing;

      function Is_Unit_Word (K : Integer) return Boolean is
        (Is_Kw (K, "package") or else Is_Kw (K, "procedure")
         or else Is_Kw (K, "function"));

      --  What follows an "is" that does not open a declarative part.
      function Ends_Without_Body (K : Integer) return Boolean is
        (Is_Kw (K, "new") or else Is_Kw (K, "abstract")
         or else Is_Kw (K, "null") or else Is_Kw (K, "separate")
         or else Is_Del (K, "<>"));

      procedure Find_Anchor;

      procedure Find_Anchor is
         K : Positive := 1;
         J : Natural;
      begin
         --  Context clause and configuration pragmas.
         loop
            exit when K > N;
            exit when not
              (Is_Kw (K, "with") or else Is_Kw (K, "use")
               or else Is_Kw (K, "pragma") or else Is_Kw (K, "limited")
               or else (Is_Kw (K, "private") and then Is_Kw (K + 1, "with")));
            J := Next_At_Depth_0 (K, ";");
            if J = 0 then
               return;
            end if;
            K := J + 1;
         end loop;
         if Is_Kw (K, "private") then
            K := K + 1;
         end if;
         if Is_Kw (K, "separate") and then Is_Del (K + 1, "(") then
            J := Closing (K + 1);
            if J = 0 then
               return;
            end if;
            K := J + 1;
         end if;
         if Is_Kw (K, "generic") then
            --  The formal part: formal subprograms and packages follow a
            --  "with".
            loop
               K := K + 1;
               if K > N then
                  return;
               end if;
               exit when Depth (K) = 0 and then Is_Unit_Word (K)
                 and then not Is_Kw (K - 1, "with");
            end loop;
         end if;
         if not Is_Unit_Word (K) then
            return;
         end if;
         for I in K + 1 .. N loop
            if Depth (I) = 0 then
               if Is_Del (I, ";") or else Is_Kw (I, "renames") then
                  return;
               elsif Is_Kw (I, "is") then
                  if not Ends_Without_Body (I + 1)
                    and then not Is_Del (I + 1, "(")
                  then
                     Anchor := S (I).Last;
                  end if;
                  return;
               end if;
            end if;
         end loop;
      end Find_Anchor;

      --  Declarative parts and sequences of statements that are open at
      --  the current token: True for a sequence of statements.
      Stack : array (1 .. N + 1) of Boolean := [others => False];
      Top   : Natural := 0;

      function In_Statements return Boolean is (Top > 0 and then Stack (Top));

      type Pending_Unit is (None, A_Package, A_Subprogram);
      Pending : Pending_Unit := None;
      --  A package or subprogram heading has been seen, and what follows
      --  it ("is", a semicolon, "renames") has not.

      Seg       : Natural := 0;
      Seg_Colon : Boolean := False;
      --  The first token of the statement, or of the heading of a compound
      --  statement, that is being read; whether it has a colon at depth 0
      --  (a statement name, or the object of an extended return).

      procedure Close_Segment (T : Positive);
      --  T is the token that ends the segment.

      procedure Close_Segment (T : Positive) is
      begin
         if Seg /= 0 and then not Seg_Colon then
            if Is_Del (T, ";") then
               if S (Seg).Kind = Identifier
                 or else Is_Kw (Seg, "return") or else Is_Kw (Seg, "exit")
                 or else Is_Kw (Seg, "raise") or else Is_Kw (Seg, "goto")
                 or else Is_Kw (Seg, "delay")
               then
                  Regions.Append
                    (Region'(Statement, S (Seg).First, S (T).Last));
               end if;
            elsif T - 1 > Seg
              and then
                ((Is_Kw (T, "then")
                  and then (Is_Kw (Seg, "if") or else Is_Kw (Seg, "elsif")))
                 or else (Is_Kw (T, "loop") and then Is_Kw (Seg, "while")))
            then
               Regions.Append
                 (Region'(Condition, S (Seg + 1).First, S (T - 1).Last));
            end if;
         end if;
         Seg := 0;
         Seg_Colon := False;
      end Close_Segment;

      K : Positive := 1;
      J : Natural;
   begin
      Anchor := 0;
      Regions.Clear;

      declare
         D : Natural := 0;
      begin
         for I in 1 .. N loop
            if Is_Del (I, "(") or else Is_Del (I, "[") then
               Depth (I) := D;
               D := D + 1;
            elsif Is_Del (I, ")") or else Is_Del (I, "]") then
               D := (if D > 0 then D - 1 else 0);
               Depth (I) := D;
            else
               Depth (I) := D;
            end if;
         end loop;
      end;

      --  Tasking constructs have their own block structure, which is not
      --  followed here.
      for I in 1 .. N loop
         if Is_Kw (I, "task") or else Is_Kw (I, "protected")
           or else Is_Kw (I, "entry") or else Is_Kw (I, "accept")
           or else Is_Kw (I, "select")
         then
            return;
         end if;
      end loop;

      Find_Anchor;
      if Anchor = 0 then
         return;
      end if;

      while K <= N loop
         if Depth (K) /= 0 then
            null;

         elsif Is_Unit_Word (K) and then not In_Statements then
            if not (Is_Kw (K - 1, "with") or else Is_Kw (K - 1, "access")) then
               Pending := (if Is_Kw (K, "package") then A_Package
                           else A_Subprogram);
            end if;

         elsif Is_Kw (K, "is") then
            if Pending /= None then
               if Ends_Without_Body (K + 1) then
                  null;
               elsif Is_Del (K + 1, "(") and then Pending = A_Subprogram then
                  --  An expression function.
                  J := Closing (K + 1);
                  if J /= 0 then
                     Regions.Append
                       (Region'(Expression, S (K + 1).First, S (J).Last));
                  end if;
               else
                  Top := Top + 1;
                  Stack (Top) := False;
                  Seg := 0;
               end if;
               Pending := None;
            elsif In_Statements then
               Close_Segment (K);  --  "case ... is"
            end if;

         elsif Is_Kw (K, "renames") then
            Pending := None;

         elsif Is_Kw (K, "begin") then
            if Top > 0 and then not Stack (Top) then
               Stack (Top) := True;
            else
               Top := Top + 1;
               Stack (Top) := True;
            end if;
            Seg := 0;
            Seg_Colon := False;

         elsif Is_Kw (K, "declare") then
            Top := Top + 1;
            Stack (Top) := False;
            Seg := 0;
            Seg_Colon := False;

         elsif Is_Kw (K, "end")
           and then not (Is_Kw (K + 1, "if") or else Is_Kw (K + 1, "loop")
                         or else Is_Kw (K + 1, "case")
                         or else Is_Kw (K + 1, "record")
                         or else Is_Kw (K + 1, "return"))
         then
            --  The end of a package, subprogram body or block.
            if Top > 0 then
               Top := Top - 1;
            end if;
            Seg := 0;
            Seg_Colon := False;
            J := Next_At_Depth_0 (K, ";");
            exit when J = 0;
            K := J;

         elsif Is_Del (K, ";") then
            Pending := None;
            if In_Statements then
               Close_Segment (K);
            end if;

         elsif In_Statements
           and then
             ((Is_Kw (K, "then") and then not Is_Kw (K - 1, "and"))
              or else (Is_Kw (K, "else") and then not Is_Kw (K - 1, "or"))
              or else (Is_Kw (K, "loop") and then not Is_Kw (K - 1, "end"))
              or else Is_Kw (K, "do") or else Is_Kw (K, "exception")
              or else Is_Del (K, "=>"))
         then
            Close_Segment (K);

         elsif In_Statements then
            if Seg = 0 then
               Seg := K;
               Seg_Colon := False;
            elsif Is_Del (K, ":") then
               Seg_Colon := True;
            end if;
         end if;
         K := K + 1;
      end loop;
   end Find_Regions;

   -----------
   -- Build --
   -----------

   function Build
     (Source     : String;
      Candidates : Candidate_Vectors.Vector;
      Tag        : Positive) return Schema
   is
      S       : constant Token_Array := Significant (Source);
      Anchor  : Natural;
      Regions : Region_Vectors.Vector;
      Result  : Schema;
      Name    : constant String := "ADAMUTANT_ACTIVE_" & Image (Tag);
      Line    : Positive := 1;
      Pos     : Positive := Source'First;

      function Region_Of (C : Candidate) return Natural;
      --  The index of the region that contains the whole of C, or 0.

      function Region_Of (C : Candidate) return Natural is
      begin
         for R in Regions.First_Index .. Regions.Last_Index loop
            if C.First >= Regions (R).First and then C.Last <= Regions (R).Last
              and then C.First <= Regions (R).Last
            then
               return R;
            end if;
         end loop;
         return 0;
      end Region_Of;

      procedure Put (Text : String; Owner : Natural := 0);
      --  Appends Text; the lines it writes on belong to mutant Owner.

      procedure Put (Text : String; Owner : Natural := 0) is
      begin
         for C of Text loop
            if C = LF then
               Line := Line + 1;
            elsif Owner /= 0 then
               while Natural (Result.Owners.Length) < Line loop
                  Result.Owners.Append (0);
               end loop;
               Result.Owners.Replace_Element (Line, Owner);
            end if;
         end loop;
         Append (Result.Text, Text);
      end Put;

      function Variant (R : Region; C : Candidate) return String is
        (Source (R.First .. C.First - 1) & To_String (C.Replacement)
         & Source (C.Last + 1 .. R.Last));
   begin
      if Candidates.Is_Empty then
         return Result;
      end if;
      Find_Regions (Source, S, Anchor, Regions);
      if Anchor = 0 then
         return Result;
      end if;
      for C of Candidates loop
         if Region_Of (C) /= 0 then
            Result.Included.Append (C.Id);
         end if;
      end loop;
      if Result.Included.Is_Empty then
         return Result;
      end if;

      Put (Style_Off & LF);
      Put (Source (Pos .. Anchor));
      --  In a pure unit GNAT warns about the import, and about calls that
      --  it may leave out.  Leaving out a repeated call is fine: the
      --  result is the same for the whole run of the program.
      Put (LF & "pragma Warnings (Off); "
           & "function " & Name & " return Standard.Integer; "
           & "pragma Import (C, " & Name & ", """ & Symbol & """); "
           & "pragma Warnings (On);" & LF);
      Pos := Anchor + 1;

      for R in Regions.First_Index .. Regions.Last_Index loop
         declare
            Reg  : constant Region := Regions (R);
            Used : Boolean := False;
            Text : constant String := Source (Reg.First .. Reg.Last);
         begin
            for C of Candidates loop
               Used := Used or else Region_Of (C) = R;
            end loop;
            if Used then
               Put (Source (Pos .. Reg.First - 1));
               Pos := Reg.Last + 1;
               case Reg.Kind is
                  when Statement =>
                     Put (LF & "case " & Name & " is" & LF);
                     for C of Candidates loop
                        if Region_Of (C) = R then
                           Put ("when " & Image (C.Id) & " =>" & LF, C.Id);
                           Put (Variant (Reg, C) & LF, C.Id);
                        end if;
                     end loop;
                     Put ("when others =>" & LF & Text & LF
                          & "end case;" & LF);

                  when Condition =>
                     Put ("(case " & Name & " is" & LF);
                     for C of Candidates loop
                        if Region_Of (C) = R then
                           Put ("when " & Image (C.Id) & " => (" & LF, C.Id);
                           Put (Variant (Reg, C) & LF, C.Id);
                           Put (")," & LF, C.Id);
                        end if;
                     end loop;
                     Put ("when others => (" & LF & Text & LF & "))");

                  when Expression =>
                     Put ("(case " & Name & " is" & LF);
                     for C of Candidates loop
                        if Region_Of (C) = R then
                           Put ("when " & Image (C.Id) & " =>" & LF, C.Id);
                           Put (Variant (Reg, C) & LF, C.Id);
                           Put ("," & LF, C.Id);
                        end if;
                     end loop;
                     Put ("when others =>" & LF & Text & LF & ")");
               end case;
            end if;
         end;
      end loop;
      Put (Source (Pos .. Source'Last));

      while Natural (Result.Owners.Length) < Line loop
         Result.Owners.Append (0);
      end loop;
      return Result;
   end Build;

   ------------------
   -- Support unit --
   ------------------

   function Support_Spec return String is
     (Style_Off & LF
      & "pragma Warnings (Off);" & LF
      & "package " & Unit_Name & " is" & LF
      & "   pragma SPARK_Mode (Off);" & LF
      & "   function Active return Standard.Integer;" & LF
      & "   pragma Export (C, Active, """ & Symbol & """);" & LF
      & "end " & Unit_Name & ";" & LF);

   --  The number is read on the first call and not when the unit is
   --  elaborated: a mutant can be in code that runs during the elaboration
   --  of a unit that comes first.  Nothing here needs elaboration.
   function Support_Body return String is
     (Style_Off & LF
      & "pragma Warnings (Off);" & LF
      & "with System;" & LF
      & "with System.Storage_Elements;" & LF
      & "package body " & Unit_Name & " is" & LF
      & "   pragma SPARK_Mode (Off);" & LF
      & "   use type System.Address;" & LF
      & "   Loaded : Boolean := False;" & LF
      & "   Value  : Standard.Integer := 0;" & LF
      & "   function Getenv (Name : System.Address) return System.Address;"
      & LF
      & "   pragma Import (C, Getenv, ""getenv"");" & LF
      & "   function Active return Standard.Integer is" & LF
      & "   begin" & LF
      & "      if not Loaded then" & LF
      & "         declare" & LF
      & "            Name  : aliased constant String :=" & LF
      & "              ""ADAMUTANT_MUTANT_ID"" & ASCII.NUL;" & LF
      & "            Where : System.Address := Getenv (Name'Address);" & LF
      & "            Found : Standard.Integer := 0;" & LF
      & "         begin" & LF
      & "            if Where /= System.Null_Address then" & LF
      & "               loop" & LF
      & "                  declare" & LF
      & "                     Digit : Character;" & LF
      & "                     for Digit'Address use Where;" & LF
      & "                     pragma Import (Ada, Digit);" & LF
      & "                  begin" & LF
      & "                     exit when Digit not in '0' .. '9'" & LF
      & "                       or else Found > 99_999_999;" & LF
      & "                     Found := Found * 10" & LF
      & "                       + (Character'Pos (Digit) - Character'Pos ('0'));"
      & LF
      & "                  end;" & LF
      & "                  Where := System.Storage_Elements.""+"" (Where, 1);"
      & LF
      & "               end loop;" & LF
      & "            end if;" & LF
      & "            Value := Found;" & LF
      & "            Loaded := True;" & LF
      & "         end;" & LF
      & "      end if;" & LF
      & "      return Value;" & LF
      & "   end Active;" & LF
      & "end " & Unit_Name & ";" & LF);

   function With_Support (Source : String) return String is
      Prefix : constant String := Style_Off & LF;
      Text   : constant String :=
        (if Source'Length >= Prefix'Length
           and then Source (Source'First .. Source'First + Prefix'Length - 1)
                    = Prefix
         then Source else Prefix & Source);
      S      : constant Token_Array := Significant (Text);
      Clause : constant String :=
        "with " & Unit_Name & "; pragma Unreferenced (" & Unit_Name & "); ";
      K      : Positive := 1;
      Depth  : Natural := 0;
   begin
      --  Configuration pragmas have to stay in front of the context
      --  clause.
      while K <= S'Last
        and then S (K).Kind = Reserved_Word
        and then Lower (Text (S (K).First .. S (K).Last)) = "pragma"
      loop
         loop
            K := K + 1;
            exit when K > S'Last;
            declare
               T : constant String := Text (S (K).First .. S (K).Last);
            begin
               if T = "(" then
                  Depth := Depth + 1;
               elsif T = ")" and then Depth > 0 then
                  Depth := Depth - 1;
               end if;
               exit when T = ";" and then Depth = 0;
            end;
         end loop;
         K := K + 1;
      end loop;
      if K > S'Last then
         return Text;
      end if;
      return Text (Text'First .. S (K).First - 1) & Clause
        & Text (S (K).First .. Text'Last);
   end With_Support;

   -----------------
   -- Diagnostics --
   -----------------

   function Diagnostics (Log : String) return Diagnostic_Vectors.Vector is
      Result : Diagnostic_Vectors.Vector;
      First  : Positive := Log'First;

      procedure Line_Of_Log (L : String);

      procedure Line_Of_Log (L : String) is
         function Digits_From (From : Positive) return Natural;
         --  The last of the digits that start at From, or 0.

         function Digits_From (From : Positive) return Natural is
            E : Natural := From;
         begin
            while E <= L'Last and then L (E) in '0' .. '9' loop
               E := E + 1;
            end loop;
            return (if E > From then E - 1 else 0);
         end Digits_From;

         A, B  : Natural;
         Start : Positive;
      begin
         for I in L'Range loop
            if L (I) = ':' and then I > L'First and then I < L'Last then
               A := Digits_From (I + 1);
               if A /= 0 and then A < L'Last and then L (A + 1) = ':'
                 and then A - I <= 7
               then
                  B := (if A + 2 <= L'Last then Digits_From (A + 2) else 0);
                  if B /= 0 and then B < L'Last and then L (B + 1) = ':' then
                     Start := L'First;
                     for J in reverse L'First .. I - 1 loop
                        if L (J) = '/' or else L (J) = '\'
                          or else L (J) = ' '
                        then
                           Start := J + 1;
                           exit;
                        end if;
                     end loop;
                     --  A source file name has an extension; a time of
                     --  day ("12:30:15:") has none.
                     if Start < I
                       and then (for some C of L (Start .. I - 1) => C = '.')
                     then
                        Result.Append
                          (Diagnostic'
                             (File => To_Unbounded_String
                                (Ada.Characters.Handling.To_Lower
                                   (L (Start .. I - 1))),
                              Line => Positive'Value (L (I + 1 .. A)),
                              Text => To_Unbounded_String (L)));
                     end if;
                     return;
                  end if;
               end if;
            end if;
         end loop;
      end Line_Of_Log;
   begin
      for K in Log'Range loop
         if Log (K) = LF or else K = Log'Last then
            declare
               Last : Natural := (if Log (K) = LF then K - 1 else K);
            begin
               if Last >= First and then Log (Last) = ASCII.CR then
                  Last := Last - 1;
               end if;
               if Last >= First then
                  Line_Of_Log (Log (First .. Last));
               end if;
            end;
            First := K + 1;
         end if;
      end loop;
      return Result;
   end Diagnostics;

   function Main_Source (Ali : String) return String is
      Is_Main : Boolean := False;
      File    : Unbounded_String;
      First   : Positive := Ali'First;
      Last    : Natural;
   begin
      while First <= Ali'Last loop
         Last := First;
         while Last <= Ali'Last and then Ali (Last) /= LF loop
            Last := Last + 1;
         end loop;
         --  Ali (First .. Last - 1) is a line.
         if Last - First >= 2 and then Ali (First + 1) = ' ' then
            if Ali (First) = 'M' then
               Is_Main := True;
            elsif Ali (First) = 'U' and then Length (File) = 0 then
               declare
                  function Is_Blank (C : Character) return Boolean is
                    (C = ' ' or else C = ASCII.HT or else C = ASCII.CR);
                  I : Positive := First + 2;
                  F : Positive;
               begin
                  while I < Last and then not Is_Blank (Ali (I)) loop
                     I := I + 1;
                  end loop;
                  while I < Last and then Is_Blank (Ali (I)) loop
                     I := I + 1;
                  end loop;
                  F := I;
                  while I < Last and then not Is_Blank (Ali (I)) loop
                     I := I + 1;
                  end loop;
                  if I > F then
                     File := To_Unbounded_String
                       (Ada.Characters.Handling.To_Lower (Ali (F .. I - 1)));
                  end if;
               end;
            end if;
         end if;
         First := Last + 1;
      end loop;
      return (if Is_Main then To_String (File) else "");
   end Main_Source;

end AdaMutant.Schemata;
