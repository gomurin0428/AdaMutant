with Ada.Characters.Handling;

package body AdaMutant.Lexer is

   function Lower (S : String) return String is
     (Ada.Characters.Handling.To_Lower (S));

   type Word is access constant String;

   type Word_List is array (Positive range <>) of Word;

   function "+" (S : String) return Word is (new String'(S));

   Reserved : constant Word_List :=
     [+"abort", +"abs", +"abstract", +"accept", +"access", +"aliased",
      +"all", +"and", +"array", +"at", +"begin", +"body", +"case",
      +"constant", +"declare", +"delay", +"delta", +"digits", +"do",
      +"else", +"elsif", +"end", +"entry", +"exception", +"exit", +"for",
      +"function", +"generic", +"goto", +"if", +"in", +"interface", +"is",
      +"limited", +"loop", +"mod", +"new", +"not", +"null", +"of", +"or",
      +"others", +"out", +"overriding", +"package", +"parallel", +"pragma",
      +"private", +"procedure", +"protected", +"raise", +"range",
      +"record", +"rem", +"renames", +"requeue", +"return", +"reverse",
      +"select", +"separate", +"some", +"subtype", +"synchronized",
      +"tagged", +"task", +"terminate", +"then", +"type", +"until", +"use",
      +"when", +"while", +"with", +"xor"];

   function Is_Reserved (Lower_Word : String) return Boolean is
   begin
      for W of Reserved loop
         if W.all = Lower_Word then
            return True;
         end if;
      end loop;
      return False;
   end Is_Reserved;

   function Is_Letter (C : Character) return Boolean is
     (C in 'A' .. 'Z' | 'a' .. 'z' or else Character'Pos (C) >= 128);

   function Is_Digit (C : Character) return Boolean is (C in '0' .. '9');

   function Is_Extended_Digit (C : Character) return Boolean is
     (C in '0' .. '9' | 'A' .. 'F' | 'a' .. 'f');

   function UTF8_Length (C : Character) return Positive is
     (case Character'Pos (C) is
         when 16#C0# .. 16#DF# => 2,
         when 16#E0# .. 16#EF# => 3,
         when 16#F0# .. 16#F7# => 4,
         when others           => 1);

   function Tokenize (Source : String) return Token_Vectors.Vector is
      Result     : Token_Vectors.Vector;
      I          : Natural := Source'First;
      Line       : Positive := 1;
      Have_Prev  : Boolean := False;
      Prev       : Token;
      After_Tick : Boolean := False;

      procedure Fail (Message : String) with No_Return is
      begin
         raise Lexical_Error with "line" & Line'Image & ": " & Message;
      end Fail;

      procedure Add (Kind : Token_Kind; First, Last : Natural) is
         T : constant Token :=
           (Kind => Kind, First => First, Last => Last, Line => Line);
      begin
         Result.Append (T);
         if Kind /= Comment then
            After_Tick :=
              Kind = Delimiter and then Source (First .. Last) = "'";
            Have_Prev := True;
            Prev := T;
         end if;
      end Add;

      function Prev_Is (Text : String) return Boolean is
        (Have_Prev
         and then Prev.Kind in Delimiter | Reserved_Word
         and then Lower (Source (Prev.First .. Prev.Last)) = Text);

      function Tick_Is_Attribute return Boolean is
        (Have_Prev
         and then (Prev.Kind = Identifier
                   or else Prev_Is (")")
                   or else Prev_Is ("]")
                   or else Prev_Is ("all")));

      function At_Char (J : Natural) return Character is
        (if J <= Source'Last then Source (J) else ASCII.NUL);

      procedure Scan_Exponent is
      begin
         if At_Char (I) in 'E' | 'e'
           and then (Is_Digit (At_Char (I + 1))
                     or else (At_Char (I + 1) in '+' | '-'
                              and then Is_Digit (At_Char (I + 2))))
         then
            I := I + 2;
            while Is_Digit (At_Char (I)) or else At_Char (I) = '_' loop
               I := I + 1;
            end loop;
         end if;
      end Scan_Exponent;

      Two_Char : constant array (1 .. 10) of String (1 .. 2) :=
        ["=>", "..", "**", ":=", "/=", ">=", "<=", "<<", ">>", "<>"];
   begin
      if Source'Length >= 3
        and then Source (Source'First .. Source'First + 2) =
          Character'Val (16#EF#) & Character'Val (16#BB#)
          & Character'Val (16#BF#)
      then
         I := Source'First + 3;
      end if;

      while I <= Source'Last loop
         declare
            C     : constant Character := Source (I);
            Start : constant Positive := I;
         begin
            case C is
               when ASCII.LF =>
                  Line := Line + 1;
                  I := I + 1;

               when ' ' | ASCII.HT | ASCII.CR | ASCII.VT | ASCII.FF =>
                  I := I + 1;

               when '-' =>
                  if At_Char (I + 1) = '-' then
                     while I <= Source'Last
                       and then Source (I) not in ASCII.LF | ASCII.CR
                     loop
                        I := I + 1;
                     end loop;
                     Add (Comment, Start, I - 1);
                  else
                     I := I + 1;
                     Add (Delimiter, Start, Start);
                  end if;

               when '"' =>
                  I := I + 1;
                  loop
                     if I > Source'Last
                       or else Source (I) in ASCII.LF | ASCII.CR
                     then
                        Fail ("unterminated string literal");
                     elsif Source (I) = '"' then
                        if At_Char (I + 1) = '"' then
                           I := I + 2;
                        else
                           I := I + 1;
                           exit;
                        end if;
                     else
                        I := I + 1;
                     end if;
                  end loop;
                  Add (String_Literal, Start, I - 1);

               when ''' =>
                  if Tick_Is_Attribute then
                     I := I + 1;
                     Add (Delimiter, Start, Start);
                  else
                     declare
                        Len : constant Positive :=
                          UTF8_Length (At_Char (I + 1));
                     begin
                        if I + Len + 1 <= Source'Last
                          and then Source (I + Len + 1) = '''
                        then
                           I := I + Len + 2;
                           Add (Character_Literal, Start, I - 1);
                        else
                           I := I + 1;
                           Add (Delimiter, Start, Start);
                        end if;
                     end;
                  end if;

               when '0' .. '9' =>
                  while Is_Digit (At_Char (I)) or else At_Char (I) = '_' loop
                     I := I + 1;
                  end loop;
                  if At_Char (I) = '#' then
                     I := I + 1;
                     while Is_Extended_Digit (At_Char (I))
                       or else At_Char (I) in '_' | '.'
                     loop
                        I := I + 1;
                     end loop;
                     if At_Char (I) /= '#' then
                        Fail ("malformed based literal");
                     end if;
                     I := I + 1;
                  elsif At_Char (I) = '.' and then Is_Digit (At_Char (I + 1))
                  then
                     I := I + 1;
                     while Is_Digit (At_Char (I)) or else At_Char (I) = '_'
                     loop
                        I := I + 1;
                     end loop;
                  end if;
                  Scan_Exponent;
                  if Is_Letter (At_Char (I)) then
                     Fail ("malformed numeric literal");
                  end if;
                  Add (Numeric_Literal, Start, I - 1);

               when others =>
                  if Is_Letter (C) then
                     while Is_Letter (At_Char (I))
                       or else Is_Digit (At_Char (I))
                       or else At_Char (I) = '_'
                     loop
                        I := I + 1;
                     end loop;
                     if not After_Tick
                       and then Is_Reserved (Lower (Source (Start .. I - 1)))
                     then
                        Add (Reserved_Word, Start, I - 1);
                     else
                        Add (Identifier, Start, I - 1);
                     end if;
                  else
                     declare
                        Found : Boolean := False;
                     begin
                        if I < Source'Last then
                           for D of Two_Char loop
                              if Source (I .. I + 1) = D then
                                 Found := True;
                                 exit;
                              end if;
                           end loop;
                        end if;
                        if Found then
                           I := I + 2;
                           Add (Delimiter, Start, Start + 1);
                        elsif C in '&' | '(' | ')' | '*' | '+' | ',' | '.'
                          | '/' | ':' | ';' | '<' | '=' | '>' | '|' | '['
                          | ']' | '@'
                        then
                           I := I + 1;
                           Add (Delimiter, Start, Start);
                        else
                           Fail ("unexpected character '" & C & "'");
                        end if;
                     end;
                  end if;
            end case;
         end;
      end loop;
      return Result;
   end Tokenize;

end AdaMutant.Lexer;
