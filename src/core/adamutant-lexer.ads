with Ada.Containers.Vectors;

--  Lexical analysis of Ada 2022 source text (Ada RM 2.2 .. 2.8).
--  Tokens refer to byte ranges of the analysed source, so mutations can be
--  applied without re-printing the program.
package AdaMutant.Lexer is

   type Token_Kind is
     (Identifier,
      Reserved_Word,
      Numeric_Literal,
      Character_Literal,
      String_Literal,
      Delimiter,
      Comment);

   type Token is record
      Kind  : Token_Kind := Delimiter;
      First : Positive := 1;
      Last  : Natural := 0;
      Line  : Positive := 1;
   end record;

   package Token_Vectors is new Ada.Containers.Vectors (Positive, Token);

   Lexical_Error : exception;

   function Tokenize (Source : String) return Token_Vectors.Vector;
   --  Raises Lexical_Error with "line N: ..." when Source is not lexically
   --  valid Ada (for example gnatprep input).

   function Lower (S : String) return String;

   function Is_Reserved (Lower_Word : String) return Boolean;

   function Image (Source : String; T : Token) return String is
     (Source (T.First .. T.Last));

end AdaMutant.Lexer;
