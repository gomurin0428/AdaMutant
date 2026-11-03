package body AdaMutant.Positions is

   function Of_Offset (Source : String; Offset : Positive) return Position is
      P : Position;
   begin
      for K in Source'First .. Natural'Min (Offset - 1, Source'Last) loop
         if Source (K) = ASCII.LF then
            P.Line := P.Line + 1;
            P.Column := 1;
         elsif Character'Pos (Source (K)) / 64 /= 2 then
            --  Not a UTF-8 continuation byte.
            P.Column := P.Column + 1;
         end if;
      end loop;
      return P;
   end Of_Offset;

end AdaMutant.Positions;
