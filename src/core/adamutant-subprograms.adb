with AdaMutant.Lexer; use AdaMutant.Lexer;

package body AdaMutant.Subprograms is

   type Token_Array is array (Positive range <>) of Token;

   function Significant (Source : String) return Token_Array is
      All_Tokens : constant Token_Vectors.Vector := Tokenize (Source);
      Result     : Token_Array (1 .. Natural (All_Tokens.Length));
      N          : Natural := 0;
   begin
      for T of All_Tokens loop
         if T.Kind /= Comment then
            N := N + 1;
            Result (N) := T;
         end if;
      end loop;
      return Result (1 .. N);
   end Significant;

   function Find (Source : String) return Subprogram_Vectors.Vector is
      S      : constant Token_Array := Significant (Source);
      Result : Subprogram_Vectors.Vector;

      function Txt (K : Positive) return String is
        (Source (S (K).First .. S (K).Last));

      function Word (K : Integer) return String is
        (if K in S'Range and then S (K).Kind = Reserved_Word
         then Lower (Txt (K)) else "");

      function Is_Del (K : Integer; D : String) return Boolean is
        (K in S'Range and then S (K).Kind = Delimiter and then Txt (K) = D);

      --  The constructs that a plain "end" closes: bodies, package and
      --  task specifications, blocks and accept statements.
      type Frame is record
         Name      : Unbounded_String;
         --  Lower case; "" for a block without a label.
         Sub       : Natural := 0;
         --  The index in Result of a subprogram body.
         Has_Begin : Boolean := False;
         Begun     : Boolean := False;
      end record;

      package Frame_Vectors is new Ada.Containers.Vectors (Positive, Frame);
      Stack : Frame_Vectors.Vector;

      function Enclosing return Natural is
      begin
         for F of reverse Stack loop
            if F.Sub /= 0 then
               return F.Sub;
            end if;
         end loop;
         return 0;
      end Enclosing;

      function Name_At (K : Integer) return String is
         --  A name (identifiers and dots) or an operator symbol, in lower
         --  case, or "".
         Last : Integer := K;
      begin
         if K not in S'Range then
            return "";
         elsif S (K).Kind = String_Literal then
            return Lower (Txt (K));
         elsif S (K).Kind /= Identifier then
            return "";
         end if;
         while Is_Del (Last + 1, ".") and then Last + 2 in S'Range
           and then S (Last + 2).Kind = Identifier
         loop
            Last := Last + 2;
         end loop;
         return Lower (Source (S (K).First .. S (Last).Last));
      end Name_At;

      function Label (K : Positive) return String is
        (if Is_Del (K - 1, ":") and then K - 2 in S'Range
           and then S (K - 2).Kind = Identifier
         then Lower (Txt (K - 2)) else "");

      procedure Scan (From : Positive; Stop : out Natural;
                      Contract : out Boolean) is
         --  The first ";", "is", "renames" or "do" outside parentheses
         --  from From on, or 0; whether the aspect Pre, Post or
         --  Contract_Cases comes before it (not a name or a type that is
         --  called so).
         Depth   : Natural := 0;
         Aspects : Boolean := False;
      begin
         Stop := 0;
         Contract := False;
         for J in From .. S'Last loop
            if Is_Del (J, "(") then
               Depth := Depth + 1;
            elsif Is_Del (J, ")") then
               Depth := (if Depth > 0 then Depth - 1 else 0);
            elsif Depth = 0 then
               if Is_Del (J, ";") or else Word (J) in "is" | "renames" | "do"
               then
                  Stop := J;
                  return;
               elsif Word (J) = "with" then
                  Aspects := True;
               elsif Aspects and then S (J).Kind = Identifier
                 and then Lower (Txt (J)) in "pre" | "post" | "contract_cases"
                 and then (Is_Del (J + 1, "=>") or else Is_Del (J + 1, "'"))
               then
                  Contract := True;
               end if;
            end if;
         end loop;
      end Scan;

      function Closing (Open : Positive) return Natural is
         --  The parenthesis that closes the one at Open, or 0.
         Depth : Natural := 0;
      begin
         for J in Open .. S'Last loop
            if Is_Del (J, "(") then
               Depth := Depth + 1;
            elsif Is_Del (J, ")") then
               Depth := Depth - 1;
               if Depth = 0 then
                  return J;
               end if;
            end if;
         end loop;
         return 0;
      end Closing;

      function With_Before_End (From : Positive) return Boolean is
         --  "task type T is new I with ... end T;": a "with" comes before
         --  the ";" of the declaration.
      begin
         for J in From .. S'Last loop
            exit when Is_Del (J, ";");
            if Word (J) = "with" then
               return True;
            end if;
         end loop;
         return False;
      end With_Before_End;

      K     : Positive := 1;
      Depth : Natural := 0;
      --  Inside parentheses nothing opens a construct: a declare
      --  expression "(declare ... begin ...)" has no "end".
   begin
      while K <= S'Last loop
         declare
            W        : constant String := Word (K);
            Stop     : Natural;
            Contract : Boolean;
         begin
            if Is_Del (K, "(") then
               Depth := Depth + 1;
            elsif Is_Del (K, ")") then
               Depth := (if Depth > 0 then Depth - 1 else 0);
            elsif Depth > 0 then
               null;
            elsif W in "procedure" | "function" | "entry"
              --  Not a generic formal subprogram nor an access type.
              and then Word (K - 1) not in "with" | "access"
              and then not (Word (K - 1) = "protected"
                            and then Word (K - 2) = "access")
            then
               Scan (K + 1, Stop, Contract);
               if Stop /= 0 and then Word (Stop) = "is" then
                  if Word (Stop + 1) in "new" | "separate" | "abstract"
                                        | "null"
                    or else Is_Del (Stop + 1, "<>")
                  then
                     K := Stop;
                  elsif W = "function" and then Is_Del (Stop + 1, "(") then
                     declare
                        E : constant Natural := Closing (Stop + 1);
                     begin
                        Result.Append
                          (Subprogram'
                             (Name       => To_Unbounded_String (Txt (K + 1)),
                              Line       => S (K).Line,
                              First      => S (K).First,
                              Last       => (if E /= 0 then S (E).Last
                                             else Source'Last),
                              Expression => True,
                              Contract   => Contract,
                              Parent     => Enclosing));
                        K := (if E /= 0 then E else S'Last);
                     end;
                  else
                     Result.Append
                       (Subprogram'
                          (Name       => To_Unbounded_String (Txt (K + 1)),
                           Line       => S (K).Line,
                           First      => S (K).First,
                           Last       => Source'Last,
                           Expression => False,
                           Contract   => Contract,
                           Parent     => Enclosing));
                     Stack.Append
                       (Frame'(Name      => To_Unbounded_String
                                 (Name_At (K + 1)),
                               Sub       => Result.Last_Index,
                               Has_Begin => True,
                               Begun     => False));
                     K := Stop;
                  end if;
               elsif Stop /= 0 then
                  K := Stop;
               end if;

            elsif W = "package"
              or else (W in "task" | "protected" and then Word (K - 1) /= "access")
            then
               declare
                  Is_Body : constant Boolean := Word (K + 1) = "body";
                  Name_K  : constant Positive :=
                    K + (if Is_Body or else Word (K + 1) = "type" then 2 else 1);
               begin
                  Scan (Name_K, Stop, Contract);
                  if Stop /= 0 and then Word (Stop) = "is"
                    and then Word (Stop + 1) /= "separate"
                    and then (Word (Stop + 1) /= "new"
                              or else (W /= "package"
                                       and then With_Before_End (Stop + 1)))
                  then
                     Stack.Append
                       (Frame'(Name      => To_Unbounded_String
                                 (Name_At (Name_K)),
                               Sub       => 0,
                               Has_Begin => Is_Body and then W /= "protected",
                               Begun     => False));
                  end if;
                  if Stop /= 0 then
                     K := Stop;
                  end if;
               end;

            elsif W = "declare" then
               Stack.Append
                 (Frame'(Name      => To_Unbounded_String (Label (K)),
                         Sub       => 0,
                         Has_Begin => True,
                         Begun     => False));

            elsif W = "begin" then
               if not Stack.Is_Empty and then Stack.Last_Element.Has_Begin
                 and then not Stack.Last_Element.Begun
               then
                  Stack (Stack.Last_Index).Begun := True;
               else
                  Stack.Append
                    (Frame'(Name      => To_Unbounded_String (Label (K)),
                            Sub       => 0,
                            Has_Begin => True,
                            Begun     => True));
               end if;

            elsif W = "accept" then
               Scan (K + 1, Stop, Contract);
               if Stop /= 0 and then Word (Stop) = "do" then
                  Stack.Append
                    (Frame'(Name      => To_Unbounded_String (Name_At (K + 1)),
                            Sub       => 0,
                            Has_Begin => False,
                            Begun     => False));
               end if;
               if Stop /= 0 then
                  K := Stop;
               end if;

            elsif W = "end" then
               if Word (K + 1) in "if" | "loop" | "case" | "record" | "select"
                                 | "return"
               then
                  K := K + 1;
               else
                  declare
                     Name  : constant String := Name_At (K + 1);
                     Semi  : Positive := K;
                     Found : Natural := 0;
                  begin
                     while Semi < S'Last and then not Is_Del (Semi, ";") loop
                        Semi := Semi + 1;
                     end loop;
                     --  "end Name;" closes the construct of that name and
                     --  whatever was left open inside it.
                     if Name /= "" then
                        for F in reverse Stack.First_Index .. Stack.Last_Index
                        loop
                           if To_String (Stack (F).Name) = Name then
                              Found := F;
                              exit;
                           end if;
                        end loop;
                     end if;
                     if Found = 0 then
                        Found := Stack.Last_Index;
                     end if;
                     while not Stack.Is_Empty
                       and then Stack.Last_Index >= Found
                     loop
                        if Stack.Last_Element.Sub /= 0 then
                           Result (Stack.Last_Element.Sub).Last :=
                             S (Semi).Last;
                        end if;
                        Stack.Delete_Last;
                     end loop;
                     K := Semi;
                  end;
               end if;
            end if;
         end;
         K := K + 1;
      end loop;
      return Result;
   end Find;

   function Visible_Names (Spec : String) return Name_Counts.Map is
      S      : constant Token_Array := Significant (Spec);
      Result : Name_Counts.Map;

      function Txt (K : Positive) return String is
        (Spec (S (K).First .. S (K).Last));

      function Word (K : Integer) return String is
        (if K in S'Range and then S (K).Kind = Reserved_Word
         then Lower (Txt (K)) else "");

      function Is_Del (K : Integer; D : String) return Boolean is
        (K in S'Range and then S (K).Kind = Delimiter and then Txt (K) = D);
      Unit : Boolean := False;
      --  The unit has started: a "private" before it is "private with"
      --  or that of a private child unit.
   begin
      for K in S'Range loop
         --  The private part starts at a "private" that is not the end of
         --  "is private;" or "with private;".
         exit when Unit and then Word (K) = "private"
           and then not Is_Del (K + 1, ";")
           and then (Is_Del (K - 1, ";") or else Word (K - 1) = "is");
         Unit := Unit
           or else Word (K) in "package" | "generic" | "procedure" | "function";
         if Word (K) in "procedure" | "function"
           and then Word (K - 1) not in "with" | "access"
           and then not (Word (K - 1) = "protected"
                         and then Word (K - 2) = "access")
           and then K + 1 in S'Range
         then
            declare
               Name : constant String := Lower (Txt (K + 1));
            begin
               if Result.Contains (Name) then
                  Result.Replace (Name, Result (Name) + 1);
               else
                  Result.Insert (Name, 1);
               end if;
            end;
         end if;
      end loop;
      return Result;
   end Visible_Names;

   function Place_Of
     (Subs    : Subprogram_Vectors.Vector;
      Offset  : Positive;
      Visible : Name_Counts.Map) return Place
   is
      Inner  : Natural := 0;
      Result : Place;

      function Visible_Body (I : Positive) return Boolean is
         --  The spec declares the subprogram of the body Subs (I): its
         --  name, and no more bodies of that name in the unit than the
         --  visible part declares (an overload that only the body has
         --  is not told apart by name).
         Name  : constant String := Lower (To_String (Subs (I).Name));
         Count : Natural := 0;
      begin
         if Subs (I).Parent /= 0 or else not Visible.Contains (Name) then
            return False;
         end if;
         for J of Subs loop
            if J.Parent = 0 and then Lower (To_String (J.Name)) = Name then
               Count := Count + 1;
            end if;
         end loop;
         return Count <= Visible (Name);
      end Visible_Body;
   begin
      for I in Subs.First_Index .. Subs.Last_Index loop
         if Subs (I).First <= Offset and then Offset <= Subs (I).Last
           and then (Inner = 0 or else Subs (I).First >= Subs (Inner).First)
         then
            Inner := I;
         end if;
      end loop;
      if Inner = 0 then
         return Result;
      end if;
      Result.Name := Subs (Inner).Name;
      declare
         I : Natural := Inner;
      begin
         while I /= 0 loop
            if not Subs (I).Expression
              and then (Subs (I).Contract or else Visible_Body (I))
            then
               Result.Limit := Subs (I).Line;
               exit;
            end if;
            --  A subprogram declared in another one is only called from
            --  there.
            I := Subs (I).Parent;
         end loop;
      end;
      return Result;
   end Place_Of;

end AdaMutant.Subprograms;
