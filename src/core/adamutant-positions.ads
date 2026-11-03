--  Line and column positions of byte offsets in UTF-8 source text.
package AdaMutant.Positions is

   type Position is record
      Line   : Positive := 1;
      Column : Positive := 1;
   end record;
   --  Column counts characters (UTF-8 code points), starting at 1.

   function Of_Offset (Source : String; Offset : Positive) return Position;
   --  Position of Source (Offset); Offset may be Source'Last + 1 to denote
   --  the end of the text.

end AdaMutant.Positions;
