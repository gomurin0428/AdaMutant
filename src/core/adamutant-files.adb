with Ada.Containers.Generic_Array_Sort;
with Ada.Directories; use Ada.Directories;
with Ada.Streams.Stream_IO;
with GNAT.OS_Lib;

package body AdaMutant.Files is

   package SIO renames Ada.Streams.Stream_IO;

   function Read (Path : String) return String is
      F : SIO.File_Type;
   begin
      SIO.Open (F, SIO.In_File, Path);
      declare
         Len : constant Natural := Natural (SIO.Size (F));
         S   : String (1 .. Len);
      begin
         String'Read (SIO.Stream (F), S);
         SIO.Close (F);
         return S;
      end;
   exception
      when SIO.Name_Error | SIO.Use_Error | SIO.End_Error =>
         raise File_Error with "cannot read " & Path;
   end Read;

   procedure Write (Path : String; Content : String) is
      F : SIO.File_Type;
   begin
      SIO.Create (F, SIO.Out_File, Path);
      String'Write (SIO.Stream (F), Content);
      SIO.Close (F);
   exception
      when SIO.Name_Error | SIO.Use_Error =>
         raise File_Error with "cannot write " & Path;
   end Write;

   procedure Write_Changed (Path : String; Content : String) is
      use GNAT.OS_Lib;
      Before : constant OS_Time := File_Time_Stamp (Path);
      After  : OS_Time;

   begin
      Write (Path, Content);
      After := File_Time_Stamp (Path);
      if Before /= Invalid_Time and then After <= Before then
         Set_File_Last_Modify_Time_Stamp (Path, To_Ada (To_C (Before) + 1));
         After := File_Time_Stamp (Path);
         if After <= Before then
            raise File_Error with "cannot update the time stamp of " & Path;
         end if;
      end if;
   end Write_Changed;

   function Glob_Match (Pattern, Path : String) return Boolean is
      function M (P : Positive; S : Positive) return Boolean is
      begin
         if P > Pattern'Last then
            return S > Path'Last;
         end if;
         if Pattern (P) = '*' then
            if P < Pattern'Last and then Pattern (P + 1) = '*' then
               declare
                  Next : Positive := P + 2;
               begin
                  --  "**/" also matches zero directories.
                  if Next <= Pattern'Last and then Pattern (Next) = '/' then
                     if M (Next + 1, S) then
                        return True;
                     end if;
                  elsif Next > Pattern'Last then
                     return True;
                  end if;
                  Next := P + 2;
                  for K in S .. Path'Last + 1 loop
                     if M (Next, K) then
                        return True;
                     end if;
                  end loop;
                  return False;
               end;
            end if;
            for K in S .. Path'Last + 1 loop
               if M (P + 1, K) then
                  return True;
               end if;
               exit when K <= Path'Last and then Path (K) = '/';
            end loop;
            return False;
         elsif S > Path'Last then
            return False;
         elsif Pattern (P) = '?' then
            return Path (S) /= '/' and then M (P + 1, S + 1);
         else
            return Pattern (P) = Path (S) and then M (P + 1, S + 1);
         end if;
      end M;
   begin
      return M (Pattern'First, Path'First);
   end Glob_Match;

   function Join (Dir, Relative : String) return String is
     (if Dir = "" then Relative
      elsif Dir (Dir'Last) = '/' or else Dir (Dir'Last) = '\' then
        Dir & Relative
      else Dir & "/" & Relative);

   function Skipped
     (Rel : String; Skip_Dirs : String_Vectors.Vector) return Boolean is
   begin
      for P of Skip_Dirs loop
         if Glob_Match (P, Rel) then
            return True;
         end if;
      end loop;
      return False;
   end Skipped;

   procedure Walk
     (Root, Rel : String;
      Skip_Dirs : String_Vectors.Vector;
      Result    : in out String_Vectors.Vector)
   is
      Dir    : constant String := (if Rel = "" then Root else Join (Root, Rel));
      Search : Search_Type;
      E      : Directory_Entry_Type;
      Names  : String_Vectors.Vector;
      Kinds  : String_Vectors.Vector;
   begin
      Start_Search (Search, Dir, "",
                    [Directory | Ordinary_File => True, others => False]);
      while More_Entries (Search) loop
         Get_Next_Entry (Search, E);
         declare
            N : constant String := Simple_Name (E);
         begin
            if N /= "." and then N /= ".." then
               Names.Append (N);
               Kinds.Append (if Kind (E) = Directory then "d" else "f");
            end if;
         end;
      end loop;
      End_Search (Search);

      declare
         type Index_Array is array (Positive range <>) of Positive;
         Order : Index_Array (1 .. Natural (Names.Length));
         function Less (A, B : Positive) return Boolean is
           (Names (A) < Names (B));
         procedure Sort is new Ada.Containers.Generic_Array_Sort
           (Positive, Positive, Index_Array, Less);
      begin
         for K in Order'Range loop
            Order (K) := K;
         end loop;
         Sort (Order);
         for K of Order loop
            declare
               Sub : constant String :=
                 (if Rel = "" then Names (K) else Rel & "/" & Names (K));
            begin
               if Kinds (K) = "d" then
                  if not Skipped (Sub, Skip_Dirs) then
                     Walk (Root, Sub, Skip_Dirs, Result);
                  end if;
               else
                  Result.Append (Sub);
               end if;
            end;
         end loop;
      end;
   end Walk;

   function Find_Files
     (Root : String; Skip_Dirs : String_Vectors.Vector)
      return String_Vectors.Vector
   is
      Result : String_Vectors.Vector;
   begin
      Walk (Root, "", Skip_Dirs, Result);
      return Result;
   exception
      when Ada.Directories.Name_Error | Ada.Directories.Use_Error =>
         raise File_Error with "cannot list " & Root;
   end Find_Files;

   procedure Copy_Tree
     (From, To : String; Skip_Dirs : String_Vectors.Vector) is
   begin
      Create_Path (To);
      for Rel of Find_Files (From, Skip_Dirs) loop
         declare
            Target : constant String := Join (To, Rel);
         begin
            Create_Path (Containing_Directory (Target));
            Copy_File (Join (From, Rel), Target,
                       "mode=overwrite,preserve=all_attributes");
         end;
      end loop;
   exception
      when Ada.Directories.Name_Error | Ada.Directories.Use_Error =>
         raise File_Error with "cannot copy " & From & " to " & To;
   end Copy_Tree;

   procedure Delete_Tree (Path : String) is
   begin
      if Exists (Path) then
         Ada.Directories.Delete_Tree (Path);
      end if;
   exception
      when Ada.Directories.Name_Error | Ada.Directories.Use_Error =>
         raise File_Error with "cannot delete " & Path;
   end Delete_Tree;

   function Tail (Path : String; Max_Lines : Positive) return String is
      S     : constant String := Read (Path);
      Lines : Natural := 0;
      Last  : Natural := S'Last;
   begin
      while Last >= S'First and then S (Last) in ASCII.LF | ASCII.CR loop
         Last := Last - 1;
      end loop;
      for K in reverse S'First .. Last loop
         if S (K) = ASCII.LF then
            Lines := Lines + 1;
            if Lines = Max_Lines then
               return S (K + 1 .. Last);
            end if;
         end if;
      end loop;
      return S (S'First .. Last);
   exception
      when File_Error =>
         return "";
   end Tail;

end AdaMutant.Files;
