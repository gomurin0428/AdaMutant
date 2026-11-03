with Ada.Containers.Indefinite_Vectors;

--  File system helpers.  Relative paths always use '/' separators.
package AdaMutant.Files is

   package String_Vectors is new Ada.Containers.Indefinite_Vectors
     (Positive, String);

   File_Error : exception;

   function Read (Path : String) return String;

   procedure Write (Path : String; Content : String);

   procedure Write_Changed (Path : String; Content : String);
   --  Writes Content and makes sure the modification time differs from the
   --  previous one, so time-stamp based builders (gprbuild) notice the
   --  change even when several writes happen within one second.

   function Glob_Match (Pattern, Path : String) return Boolean;
   --  "**" matches any sequence including '/', "*" any sequence without
   --  '/', "?" one character other than '/'.  "dir/**" matches everything
   --  under dir.

   function Find_Files
     (Root : String; Skip_Dirs : String_Vectors.Vector)
      return String_Vectors.Vector;
   --  All regular files under Root as sorted relative paths.  Directories
   --  whose relative path matches an entry of Skip_Dirs are not visited.

   procedure Copy_Tree
     (From, To : String; Skip_Dirs : String_Vectors.Vector);
   --  Copies the files under From to To, preserving time stamps.

   procedure Delete_Tree (Path : String);
   --  Does nothing when Path does not exist.

   function Join (Dir, Relative : String) return String;

   function Tail (Path : String; Max_Lines : Positive) return String;
   --  Last lines of a text file, or "" when it cannot be read.

end AdaMutant.Files;
