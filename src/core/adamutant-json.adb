with Ada.Unchecked_Deallocation;

package body AdaMutant.Json is

   procedure Free (V : in out Value) is
      procedure Release is new Ada.Unchecked_Deallocation (Node, Value);
   begin
      if V /= null then
         for Item of V.Items loop
            declare
               Inner : Value := Item;
            begin
               Free (Inner);
            end;
         end loop;
         Release (V);
      end if;
   end Free;

   function Parse (Source : String) return Value is
      P : Positive := Source'First;

      procedure Fail (Reason : String) with No_Return is
      begin
         raise Syntax_Error with
           "offset" & Integer'Image (P - Source'First) & ": " & Reason;
      end Fail;

      function At_End return Boolean is (P > Source'Last);

      function Cur return Character is
        (if At_End then ASCII.NUL else Source (P));

      procedure Skip_Blanks is
      begin
         while not At_End
           and then Cur in ' ' | ASCII.HT | ASCII.LF | ASCII.CR
         loop
            P := P + 1;
         end loop;
      end Skip_Blanks;

      procedure Expect (Word : String) is
      begin
         if P + Word'Length - 1 > Source'Last
           or else Source (P .. P + Word'Length - 1) /= Word
         then
            Fail ("'" & Word & "' is expected");
         end if;
         P := P + Word'Length;
      end Expect;

      function Hex4 return Natural is
         N : Natural := 0;
      begin
         if P + 3 > Source'Last then
            Fail ("four hexadecimal digits are expected");
         end if;
         for K in P .. P + 3 loop
            N := N * 16
              + (case Source (K) is
                    when '0' .. '9' =>
                      Character'Pos (Source (K)) - Character'Pos ('0'),
                    when 'a' .. 'f' =>
                      Character'Pos (Source (K)) - Character'Pos ('a') + 10,
                    when 'A' .. 'F' =>
                      Character'Pos (Source (K)) - Character'Pos ('A') + 10,
                    when others => 16#1_0000#);
         end loop;
         if N > 16#FFFF# then
            Fail ("four hexadecimal digits are expected");
         end if;
         P := P + 4;
         return N;
      end Hex4;

      procedure Append_Utf8 (To : in out Unbounded_String; Code : Natural) is
      begin
         if Code < 16#80# then
            Append (To, Character'Val (Code));
         elsif Code < 16#800# then
            Append (To, Character'Val (16#C0# + Code / 64));
            Append (To, Character'Val (16#80# + Code mod 64));
         elsif Code < 16#1_0000# then
            Append (To, Character'Val (16#E0# + Code / 4096));
            Append (To, Character'Val (16#80# + Code / 64 mod 64));
            Append (To, Character'Val (16#80# + Code mod 64));
         else
            Append (To, Character'Val (16#F0# + Code / 262_144));
            Append (To, Character'Val (16#80# + Code / 4096 mod 64));
            Append (To, Character'Val (16#80# + Code / 64 mod 64));
            Append (To, Character'Val (16#80# + Code mod 64));
         end if;
      end Append_Utf8;

      function String_Text return Unbounded_String is
         R : Unbounded_String;
      begin
         Expect ("""");
         loop
            if At_End then
               Fail ("unterminated string");
            end if;
            exit when Cur = '"';
            if Cur = '\' then
               P := P + 1;
               case Cur is
                  when '"' | '\' | '/' =>
                     Append (R, Cur);
                     P := P + 1;
                  when 'b' =>
                     Append (R, ASCII.BS);
                     P := P + 1;
                  when 'f' =>
                     Append (R, ASCII.FF);
                     P := P + 1;
                  when 'n' =>
                     Append (R, ASCII.LF);
                     P := P + 1;
                  when 'r' =>
                     Append (R, ASCII.CR);
                     P := P + 1;
                  when 't' =>
                     Append (R, ASCII.HT);
                     P := P + 1;
                  when 'u' =>
                     P := P + 1;
                     declare
                        Code : Natural := Hex4;
                     begin
                        --  A pair of surrogates is one character.
                        if Code in 16#D800# .. 16#DBFF#
                          and then P + 1 <= Source'Last
                          and then Source (P .. P + 1) = "\u"
                        then
                           declare
                              Back : constant Positive := P;
                              Low  : Natural;
                           begin
                              P := P + 2;
                              Low := Hex4;
                              if Low in 16#DC00# .. 16#DFFF# then
                                 Code := 16#1_0000#
                                   + (Code - 16#D800#) * 1024
                                   + (Low - 16#DC00#);
                              else
                                 P := Back;
                              end if;
                           end;
                        end if;
                        Append_Utf8 (R, Code);
                     end;
                  when others =>
                     Fail ("unknown escape sequence");
               end case;
            elsif Character'Pos (Cur) < 16#20# then
               Fail ("control character in a string");
            else
               Append (R, Cur);
               P := P + 1;
            end if;
         end loop;
         P := P + 1;
         return R;
      end String_Text;

      function Any (Depth : Natural) return Value is
         Result : constant Value := new Node;
      begin
         if Depth > 200 then
            Fail ("nested too deeply");
         end if;
         Skip_Blanks;
         case Cur is
            when '{' =>
               Result.What := Object;
               P := P + 1;
               Skip_Blanks;
               if Cur = '}' then
                  P := P + 1;
                  return Result;
               end if;
               loop
                  Skip_Blanks;
                  Result.Names.Append (String_Text);
                  Skip_Blanks;
                  Expect (":");
                  Result.Items.Append (Any (Depth + 1));
                  Skip_Blanks;
                  exit when Cur = '}';
                  Expect (",");
               end loop;
               P := P + 1;
            when '[' =>
               Result.What := List;
               P := P + 1;
               Skip_Blanks;
               if Cur = ']' then
                  P := P + 1;
                  return Result;
               end if;
               loop
                  Result.Items.Append (Any (Depth + 1));
                  Skip_Blanks;
                  exit when Cur = ']';
                  Expect (",");
               end loop;
               P := P + 1;
            when '"' =>
               Result.What := Text;
               Result.Image := String_Text;
            when 't' =>
               Expect ("true");
               Result.What := Boolean_Value;
               Result.Flag := True;
            when 'f' =>
               Expect ("false");
               Result.What := Boolean_Value;
            when 'n' =>
               Expect ("null");
            when '-' | '0' .. '9' =>
               declare
                  Start : constant Positive := P;
               begin
                  while not At_End
                    and then Cur in '-' | '+' | '.' | 'e' | 'E' | '0' .. '9'
                  loop
                     P := P + 1;
                  end loop;
                  Result.What := Number;
                  Result.Image :=
                    To_Unbounded_String (Source (Start .. P - 1));
               end;
            when others =>
               Fail ("a value is expected");
         end case;
         return Result;
      end Any;

      Result : Value;
   begin
      Result := Any (0);
      Skip_Blanks;
      if not At_End then
         Fail ("text after the value");
      end if;
      return Result;
   end Parse;

   function Kind_Of (V : Value) return Kind is (V.What);

   function Is_Text (V : Value) return Boolean is
     (V /= null and then V.What = Text);

   function Is_List (V : Value) return Boolean is
     (V /= null and then V.What = List);

   function Is_Object (V : Value) return Boolean is
     (V /= null and then V.What = Object);

   function Text_Of (V : Value) return String is (To_String (V.Image));

   function Integer_Of (V : Value; Default : Integer) return Integer is
   begin
      if V = null or else V.What /= Number then
         return Default;
      end if;
      declare
         S : constant String := To_String (V.Image);
      begin
         if S'Length > 9
           or else (for some C of S => C not in '0' .. '9' | '-')
         then
            return Default;
         end if;
         return Integer'Value (S);
      end;
   exception
      when Constraint_Error =>
         return Default;
   end Integer_Of;

   function Length (V : Value) return Natural is
     (Natural (V.Items.Length));

   function Element (V : Value; Index : Positive) return Value is
     (V.Items (Index));

   function Name (V : Value; Index : Positive) return String is
     (To_String (V.Names (Index)));

   function Field (V : Value; Name : String) return Value is
   begin
      if Is_Object (V) then
         for K in V.Names.First_Index .. V.Names.Last_Index loop
            if V.Names (K) = Name then
               return V.Items (K);
            end if;
         end loop;
      end if;
      return null;
   end Field;

end AdaMutant.Json;
