with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with AdaMutant.Files; use AdaMutant.Files;
with AdaMutant.Processes;

package body AdaMutant.Changes is

   use Change_Maps;

   procedure Add (Map : in out Change_Maps.Map; Path : String; R : Line_Range)
   is
      C : constant Cursor := Map.Find (Path);
   begin
      if Has_Element (C) then
         Map.Reference (C).Append (R);
      else
         Map.Insert (Path, Range_Vectors.To_Vector (R, 1));
      end if;
   end Add;

   --  Calls Process for every line of Text without its line terminator.
   procedure For_Each_Line
     (Text : String; Process : not null access procedure (Line : String))
   is
      First : Positive := Text'First;
   begin
      for K in Text'Range loop
         if Text (K) = ASCII.LF or else K = Text'Last then
            declare
               Last : Natural := (if Text (K) = ASCII.LF then K - 1 else K);
            begin
               if Last >= First and then Text (Last) = ASCII.CR then
                  Last := Last - 1;
               end if;
               Process (Text (First .. Last));
            end;
            First := K + 1;
         end if;
      end loop;
   end For_Each_Line;

   function Starts_With (S, Prefix : String) return Boolean is
     (S'Length >= Prefix'Length
      and then S (S'First .. S'First + Prefix'Length - 1) = Prefix);

   function Parse_Diff (Diff : String) return Change_Maps.Map is
      Result   : Change_Maps.Map;
      Current  : Unbounded_String;
      In_File  : Boolean := False;
      Old_Left : Natural := 0;
      New_Left : Natural := 0;

      --  "N" or "N,C" in Line (First .. Last): the start and line count.
      procedure Side (Line : String; Start, Count : out Natural) is
         Comma : constant Natural := Ada.Strings.Fixed.Index (Line, ",");
      begin
         if Comma = 0 then
            Start := Natural'Value (Line);
            Count := 1;
         else
            Start := Natural'Value (Line (Line'First .. Comma - 1));
            Count := Natural'Value (Line (Comma + 1 .. Line'Last));
         end if;
      end Side;

      --  "@@ -a[,b] +c[,d] @@ ...".
      procedure Hunk (Line : String) is
         Minus : constant Natural := Line'First + 3;
         Plus  : constant Natural :=
           Ada.Strings.Fixed.Index (Line, " +", Minus);
         Space : constant Natural :=
           (if Plus = 0 then 0 else Ada.Strings.Fixed.Index (Line, " ", Plus + 2));
         Old_Start, Start, Count : Natural;
      begin
         if Line'Length < 4 or else Line (Minus) /= '-' or else Space = 0 then
            raise Change_Error with "unexpected diff line: " & Line;
         end if;
         Side (Line (Minus + 1 .. Plus - 1), Old_Start, Old_Left);
         Side (Line (Plus + 2 .. Space - 1), Start, Count);
         New_Left := Count;
         if Count > 0 and then In_File then
            Add (Result, To_String (Current), (Start, Start + Count - 1));
         end if;
      exception
         when Constraint_Error =>
            raise Change_Error with "unexpected diff line: " & Line;
      end Hunk;

      procedure Line (L : String) is
      begin
         if Old_Left + New_Left > 0 and then L'Length > 0
           and then L (L'First) in '-' | '+' | ' '
         then
            if L (L'First) in '-' | ' ' and then Old_Left > 0 then
               Old_Left := Old_Left - 1;
            end if;
            if L (L'First) in '+' | ' ' and then New_Left > 0 then
               New_Left := New_Left - 1;
            end if;
         elsif Starts_With (L, "@@ ") then
            Hunk (L);
         elsif Starts_With (L, "+++ ") then
            declare
               Path : constant String := L (L'First + 4 .. L'Last);
            begin
               In_File := Path /= "/dev/null";
               if Path'Length >= 2 and then Path (Path'First) = '"'
                 and then Path (Path'Last) = '"'
               then
                  Current := To_Unbounded_String
                    (Path (Path'First + 1 .. Path'Last - 1));
               else
                  Current := To_Unbounded_String (Path);
               end if;
            end;
         elsif Starts_With (L, "diff ") then
            In_File := False;
         end if;
      end Line;
   begin
      For_Each_Line (Diff, Line'Access);
      return Result;
   end Parse_Diff;

   function Touches
     (Changes : Change_Maps.Map; Path : String; First, Last : Positive)
      return Boolean
   is
      C : constant Cursor := Changes.Find (Path);
   begin
      if Has_Element (C) then
         for R of Changes.Constant_Reference (C) loop
            if R.First <= Last and then First <= R.Last then
               return True;
            end if;
         end loop;
      end if;
      return False;
   end Touches;

   function Changed_Since (Root, Ref : String) return Change_Maps.Map is
      Work : constant String := Join (Root, ".adamutant");
      Log  : constant String := Join (Work, "since.log");

      function Git (Arguments : String) return String is
         R : AdaMutant.Processes.Run_Result;
      begin
         R := AdaMutant.Processes.Run
           ("git -c core.quotePath=false " & Arguments, Root, Log, 0, 0.0);
         if R.Exit_Code /= 0 then
            raise Change_Error with
              "git " & Arguments & " failed (exit status" & R.Exit_Code'Image
              & "): " & Tail (Log, 5);
         end if;
         return Read (Log);
      exception
         when AdaMutant.Processes.Spawn_Error =>
            raise Change_Error with "cannot run git " & Arguments;
      end Git;

      Base   : Natural := 0;
      Result : Change_Maps.Map;

      procedure Untracked (Path : String) is
      begin
         if Path /= "" then
            Add (Result, Path, (1, Positive'Last));
         end if;
      end Untracked;
   begin
      if Ref = "" or else Ref (Ref'First) = '-' then
         raise Change_Error with "invalid revision '" & Ref & "'";
      end if;
      for C of Ref loop
         if C not in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9'
                   | '.' | '_' | '-' | '/' | '~' | '@' | '{' | '}'
         then
            raise Change_Error with "invalid revision '" & Ref & "'";
         end if;
      end loop;
      Ada.Directories.Create_Path (Work);

      declare
         Out_Text : constant String := Git ("merge-base " & Ref & " HEAD");
      begin
         Base := Out_Text'First;
         while Base <= Out_Text'Last
           and then Out_Text (Base) in '0' .. '9' | 'a' .. 'f'
         loop
            Base := Base + 1;
         end loop;
         if Base - Out_Text'First < 40 then
            raise Change_Error with
              "git merge-base " & Ref & " HEAD printed no commit: " & Out_Text;
         end if;
         Result := Parse_Diff
           (Git ("diff -U0 --no-color --no-ext-diff --no-renames --no-prefix"
                 & " --relative " & Out_Text (Out_Text'First .. Base - 1)
                 & " --"));
      end;
      For_Each_Line (Git ("ls-files --others --exclude-standard"),
                     Untracked'Access);
      return Result;
   end Changed_Since;

end AdaMutant.Changes;
