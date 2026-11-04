with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Containers.Vectors;

--  Lines changed relative to a git revision, for "--since".
package AdaMutant.Changes is

   type Line_Range is record
      First, Last : Positive;
   end record;

   package Range_Vectors is new Ada.Containers.Vectors (Positive, Line_Range);

   package Change_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (String, Range_Vectors.Vector, "<", Range_Vectors."=");
   --  Relative path ('/' separators) to its changed lines.

   Change_Error : exception;

   function Parse_Diff (Diff : String) return Change_Maps.Map;
   --  The added and modified lines of the new side of a unified diff made
   --  with --no-prefix (as "git diff -U0 --no-prefix" writes it).  Deleted
   --  files and pure deletions add nothing.

   function Touches
     (Changes : Change_Maps.Map; Path : String; First, Last : Positive)
      return Boolean;
   --  Whether a changed line of Path lies in First .. Last.

   function Changed_Since (Root, Ref : String) return Change_Maps.Map;
   --  Lines of the files under Root that differ between the merge base of
   --  Ref and HEAD and the working tree, with untracked (not ignored) files
   --  changed as a whole.  Runs git in Root; raises Change_Error when git
   --  fails or Ref is not a valid revision name.

end AdaMutant.Changes;
