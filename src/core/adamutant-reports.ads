with AdaMutant.Positions;
with AdaMutant.Results;

--  Report writers.
package AdaMutant.Reports is

   function Json (R : AdaMutant.Results.Report) return String;
   --  mutation-testing-report-schema version 2 (as used by Stryker), so the
   --  report can also be read by the Stryker dashboard and elements.

   function Html (R : AdaMutant.Results.Report) return String;
   --  A self-contained page (no network access needed).

   procedure Print_Console (R : AdaMutant.Results.Report);
   --  Survived mutants and a per-file score table on standard output.

   function Has_Steps_Limit (Command : String) return Boolean;
   --  Whether Command gives GNATprove a steps limit: its last --steps
   --  with a value other than 0, which means no limit.  A limit in the
   --  project file or in a script that the command runs is not seen.

   function Json_String (S : String) return String;
   --  S as a quoted JSON string; bytes that are not valid UTF-8 are read
   --  as Latin-1.

   function One_Line (S : String) return String;

   function Never_Reached
     (Warning     : String;
      Source      : String;
      Name        : String;
      First, Last : AdaMutant.Positions.Position) return Boolean;
   --  Warning, a proof warning of GNATprove ("f.adb:13:10: warning:
   --  unreachable code"), says that the text from First to Last of Source
   --  is never reached: Name (the base name of the file of Source) is the
   --  file of the warning, and the text lies in the statement that starts
   --  at its line and column (up to its first semicolon outside
   --  parentheses).  Other warnings never say so.
   --  S with each line break and the blanks around it replaced by one
   --  space, for showing a mutation spanning several lines on one line.

end AdaMutant.Reports;
