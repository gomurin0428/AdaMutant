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

   --  The helpers below read the significant tokens S of Source.

   function Txt (Source : String; S : Token_Array; K : Positive) return String
   is (Source (S (K).First .. S (K).Last));

   function Word (Source : String; S : Token_Array; K : Integer) return String
   is (if K in S'Range and then S (K).Kind = Reserved_Word
       then Lower (Txt (Source, S, K)) else "");

   function Is_Del
     (Source : String; S : Token_Array; K : Integer; D : String)
      return Boolean
   is (K in S'Range and then S (K).Kind = Delimiter
       and then Txt (Source, S, K) = D);

   function Opens (Source : String; S : Token_Array; K : Integer)
     return Boolean
   is (Is_Del (Source, S, K, "(") or else Is_Del (Source, S, K, "["));

   function Closes (Source : String; S : Token_Array; K : Integer)
     return Boolean
   is (Is_Del (Source, S, K, ")") or else Is_Del (Source, S, K, "]"));

   function Name_At (Source : String; S : Token_Array; K : Integer)
     return String
   is
      --  A name (identifiers and dots) or an operator symbol, in lower
      --  case, or "".
      Last : Integer := K;
   begin
      if K not in S'Range then
         return "";
      elsif S (K).Kind = String_Literal then
         return Lower (Txt (Source, S, K));
      elsif S (K).Kind /= Identifier then
         return "";
      end if;
      while Is_Del (Source, S, Last + 1, ".") and then Last + 2 in S'Range
        and then S (Last + 2).Kind = Identifier
      loop
         Last := Last + 2;
      end loop;
      return Lower (Source (S (K).First .. S (Last).Last));
   end Name_At;

   function Starts_Subprogram (Source : String; S : Token_Array; K : Integer)
     return Boolean
   is
      --  "procedure", "function" or "entry" that starts a declaration or
      --  a body: not a generic formal subprogram, nor an access type.
      W : constant String := Word (Source, S, K);
   begin
      return W in "procedure" | "function" | "entry"
        and then Word (Source, S, K - 1) not in "with" | "access"
        and then not (Word (Source, S, K - 1) = "protected"
                      and then Word (Source, S, K - 2) = "access");
   end Starts_Subprogram;

   type Aspect_Info is record
      Own, Other, Globals : Boolean := False;
   end record;

   procedure Scan
     (Source : String; S : Token_Array; From : Positive;
      Stop : out Natural; Info : out Aspect_Info)
   is
      --  The first ";", "is", "renames" or "do" outside parentheses from
      --  From on, or 0, and the aspects before it.  An aspect is a name
      --  right after "with", or after a comma that follows "with" (not a
      --  parameter, a type or the subprogram called so).
      Depth   : Natural := 0;
      Aspects : Boolean := False;
   begin
      Stop := 0;
      Info := (others => False);
      for J in From .. S'Last loop
         if Opens (Source, S, J) then
            Depth := Depth + 1;
         elsif Closes (Source, S, J) then
            Depth := (if Depth > 0 then Depth - 1 else 0);
         elsif Depth = 0 then
            if Is_Del (Source, S, J, ";")
              or else Word (Source, S, J) in "is" | "renames" | "do"
            then
               Stop := J;
               return;
            elsif Word (Source, S, J) = "with" then
               Aspects := True;
            elsif Aspects and then S (J).Kind = Identifier
              and then (Word (Source, S, J - 1) = "with"
                        or else Is_Del (Source, S, J - 1, ","))
            then
               declare
                  A : constant String := Lower (Txt (Source, S, J));
               begin
                  if A in "global" | "depends" | "refined_global"
                        | "refined_depends"
                  then
                     Info.Globals := True;
                     Info.Own := True;
                  elsif A in "pre" | "post" | "contract_cases"
                           | "subprogram_variant" | "always_terminates"
                           | "exceptional_cases" | "refined_post"
                  then
                     Info.Own := True;
                  else
                     Info.Other := True;
                  end if;
               end;
            end if;
         end if;
      end loop;
   end Scan;

   function Closing (Source : String; S : Token_Array; Open : Positive)
     return Natural
   is
      --  The parenthesis or bracket that closes the one at Open, or 0.
      Depth : Natural := 0;
   begin
      for J in Open .. S'Last loop
         if Opens (Source, S, J) then
            Depth := Depth + 1;
         elsif Closes (Source, S, J) then
            Depth := Depth - 1;
            if Depth = 0 then
               return J;
            end if;
         end if;
      end loop;
      return 0;
   end Closing;

   function Generic_Names (Source : String) return Name_Counts.Map is
      S      : constant Token_Array := Significant (Source);
      Result : Name_Counts.Map;
   begin
      for J in S'Range loop
         if Word (Source, S, J) = "generic" then
            --  The unit that follows the formal part.
            for K in J + 1 .. S'Last loop
               if Starts_Subprogram (Source, S, K)
                 or else (Word (Source, S, K) = "package"
                          and then Word (Source, S, K - 1) /= "with")
               then
                  Result.Include (Name_At (Source, S, K + 1), 1);
                  exit;
               end if;
            end loop;
         end if;
      end loop;
      return Result;
   end Generic_Names;

   function Find
     (Source   : String;
      Generics : Name_Counts.Map := Name_Counts.Empty_Map)
      return Subprogram_Vectors.Vector
   is
      S      : constant Token_Array := Significant (Source);
      Result : Subprogram_Vectors.Vector;
      Gen    : Name_Counts.Map := Generic_Names (Source);

      function Txt (K : Positive) return String is (Txt (Source, S, K));
      function Word (K : Integer) return String is (Word (Source, S, K));
      function Is_Del (K : Integer; D : String) return Boolean is
        (Is_Del (Source, S, K, D));
      function Name_At (K : Integer) return String is
        (Name_At (Source, S, K));

      --  The constructs that a plain "end" closes: bodies, package and
      --  task specifications, blocks and accept statements.
      type Frame is record
         Name       : Unbounded_String;
         --  Lower case; "" for a block without a label.
         Sub        : Natural := 0;
         --  The index in Result of a subprogram body.
         Has_Begin  : Boolean := False;
         Begun      : Boolean := False;
         Is_Generic : Boolean := False;
         --  A generic unit, or in one.
         Body_From  : Positive := 1;
         --  The first token after "is" of a subprogram body.
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

      function In_Generic (Name : String) return Boolean is
        ((Name /= "" and then Gen.Contains (Name))
         or else (not Stack.Is_Empty and then Stack.Last_Element.Is_Generic));

      function Label (K : Positive) return String is
        (if Is_Del (K - 1, ":") and then K - 2 in S'Range
           and then S (K - 2).Kind = Identifier
         then Lower (Txt (K - 2)) else "");

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

      function Calls_Itself (Name : String; From, To : Natural) return Boolean
      is
         --  The tokens From .. To name Name, other than in "end Name" or
         --  as a component of another name.
      begin
         for J in From .. To loop
            if J in S'Range and then S (J).Kind = Identifier
              and then Lower (Txt (J)) = Name
              and then Word (J - 1) /= "end" and then not Is_Del (J - 1, ".")
            then
               return True;
            end if;
         end loop;
         return False;
      end Calls_Itself;

      procedure Add (K, Stop, Last : Positive; Expression : Boolean;
                     Info : Aspect_Info) is
         --  The subprogram whose "procedure" or "function" is at K.
      begin
         Result.Append
           (Subprogram'
              (Name         => To_Unbounded_String (Txt (K + 1)),
               Line         => S (K + 1).Line,
               First        => S (K).First,
               Last         => Last,
               Expression   => Expression,
               Own          => Info.Own,
               Other        => Info.Other,
               Globals      => Info.Globals,
               Recursive    => False,
               Generic_Unit => In_Generic (Name_At (K + 1)),
               Parent       => Enclosing));
         if not Expression then
            Stack.Append
              (Frame'(Name       => To_Unbounded_String (Name_At (K + 1)),
                      Sub        => Result.Last_Index,
                      Has_Begin  => True,
                      Begun      => False,
                      Is_Generic => Result.Last_Element.Generic_Unit,
                      Body_From  => Stop + 1));
         end if;
      end Add;

      procedure Push (Name : String; K : Positive;
                      Has_Begin, Begun : Boolean) is
      begin
         Stack.Append
           (Frame'(Name       => To_Unbounded_String (Name),
                   Sub        => 0,
                   Has_Begin  => Has_Begin,
                   Begun      => Begun,
                   Is_Generic => In_Generic (Name),
                   Body_From  => K));
      end Push;

      K     : Positive := 1;
      Depth : Natural := 0;
      --  Inside parentheses and brackets nothing opens a construct: a
      --  declare expression "(declare ... begin ...)" has no "end".
   begin
      for C in Generics.Iterate loop
         Gen.Include (Name_Counts.Key (C), 1);
      end loop;
      while K <= S'Last loop
         declare
            W    : constant String := Word (K);
            Stop : Natural;
            Info : Aspect_Info;
         begin
            if Opens (Source, S, K) then
               Depth := Depth + 1;
            elsif Closes (Source, S, K) then
               Depth := (if Depth > 0 then Depth - 1 else 0);
            elsif Depth > 0 then
               null;
            elsif Starts_Subprogram (Source, S, K) then
               Scan (Source, S, K + 1, Stop, Info);
               if Stop /= 0 and then Word (Stop) = "is" then
                  if Word (Stop + 1) in "new" | "separate" | "abstract"
                                        | "null"
                    or else Is_Del (Stop + 1, "<>")
                  then
                     K := Stop;
                  elsif W = "function" and then Opens (Source, S, Stop + 1)
                  then
                     --  An expression function, "is (...)" or "is [...]".
                     declare
                        E : constant Natural := Closing (Source, S, Stop + 1);
                     begin
                        Add (K, Stop,
                             (if E /= 0 then S (E).Last else Source'Last),
                             Expression => True, Info => Info);
                        K := (if E /= 0 then E else S'Last);
                     end;
                  else
                     Add (K, Stop, Source'Last, Expression => False,
                          Info => Info);
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
                  Scan (Source, S, Name_K, Stop, Info);
                  if Stop /= 0 and then Word (Stop) = "is"
                    and then Word (Stop + 1) /= "separate"
                    and then (Word (Stop + 1) /= "new"
                              or else (W /= "package"
                                       and then With_Before_End (Stop + 1)))
                  then
                     Push (Name_At (Name_K), Stop,
                           Has_Begin => Is_Body and then W /= "protected",
                           Begun     => False);
                  end if;
                  if Stop /= 0 then
                     K := Stop;
                  end if;
               end;

            elsif W = "declare" then
               Push (Label (K), K, Has_Begin => True, Begun => False);

            elsif W = "begin" then
               if not Stack.Is_Empty and then Stack.Last_Element.Has_Begin
                 and then not Stack.Last_Element.Begun
               then
                  Stack (Stack.Last_Index).Begun := True;
               else
                  Push (Label (K), K, Has_Begin => True, Begun => True);
               end if;

            elsif W = "accept" then
               Scan (Source, S, K + 1, Stop, Info);
               if Stop /= 0 and then Word (Stop) = "do" then
                  Push (Name_At (K + 1), Stop, Has_Begin => False,
                        Begun => False);
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
                        declare
                           F : constant Frame := Stack.Last_Element;
                        begin
                           if F.Sub /= 0 then
                              Result (F.Sub).Last := S (Semi).Last;
                              Result (F.Sub).Recursive := Calls_Itself
                                (To_String (F.Name), F.Body_From, K - 1);
                           end if;
                        end;
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

   function Declared_Names (Spec : String) return Name_Counts.Map is
      S      : constant Token_Array := Significant (Spec);
      Result : Name_Counts.Map;
      Stop   : Natural;
      Info   : Aspect_Info;
   begin
      for K in S'Range loop
         if Starts_Subprogram (Spec, S, K)
           and then Word (Spec, S, K) /= "entry" and then K + 1 in S'Range
         then
            Scan (Spec, S, K + 1, Stop, Info);
            --  Only a declaration that a body completes.
            if Stop /= 0 and then Is_Del (Spec, S, Stop, ";") then
               declare
                  Name : constant String := Lower (Txt (Spec, S, K + 1));
               begin
                  if Result.Contains (Name) then
                     Result.Replace (Name, Result (Name) + 1);
                  else
                     Result.Insert (Name, 1);
                  end if;
               end;
            end if;
         end if;
      end loop;
      return Result;
   end Declared_Names;

   function Place_Of
     (Subs     : Subprogram_Vectors.Vector;
      Offset   : Positive;
      Declared : Name_Counts.Map) return Place
   is
      Inner  : Natural := 0;
      Result : Place;

      function Declared_Body (I : Positive) return Boolean is
         --  The spec declares the subprogram of the body Subs (I): its
         --  name, and no more bodies of that name in the unit than the
         --  spec declares (an overload that only the body has is not told
         --  apart by name).
         Name  : constant String := Lower (To_String (Subs (I).Name));
         Count : Natural := 0;
      begin
         if Subs (I).Parent /= 0 or else not Declared.Contains (Name) then
            return False;
         end if;
         for J of Subs loop
            if J.Parent = 0 and then not J.Expression
              and then Lower (To_String (J.Name)) = Name
            then
               Count := Count + 1;
            end if;
         end loop;
         return Count <= Declared (Name);
      end Declared_Body;
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
            declare
               Sub : constant Subprogram := Subs (I);
            begin
               --  GNATprove analyses the instances, not the generic.
               exit when Sub.Generic_Unit;
               if Sub.Expression then
                  --  Its callers see its body: those around it, if any.
                  I := Sub.Parent;
               elsif Sub.Own or else Sub.Recursive
                 or else (Sub.Parent = 0 and then Declared_Body (I))
               then
                  Result.Limit := Sub.Line;
                  Result.Globals := Sub.Globals;
                  exit;
               elsif Sub.Parent /= 0 and then not Sub.Other then
                  --  Inlined in the subprogram around it.
                  I := Sub.Parent;
               else
                  exit;
               end if;
            end;
         end loop;
      end;
      return Result;
   end Place_Of;

end AdaMutant.Subprograms;
