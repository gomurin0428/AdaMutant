with AdaMutant.Files;
with AdaMutant.Results;

--  Reuse of the results of an earlier run ("--baseline").
package AdaMutant.Baselines is

   Baseline_Error : exception;

   procedure Apply
     (R      : in out AdaMutant.Results.Report;
      Text   : String;
      Reused : out Natural);
   --  Text is the JSON report of an earlier run of AdaMutant on the same
   --  project.  A mutant of R takes its result from the report when
   --
   --  * the report has the same mutation at the same place: the file has
   --    the same path, the lines of the mutant are lines that the file of
   --    the report also has, unchanged and in the same order (see
   --    Line_Map), and the columns, the mutator and the replacement are
   --    the same; and
   --
   --  * the mutant is Pending and the report says Killed, Timeout or
   --    CompileError: a detected mutant stays detected as long as no test
   --    is taken away, while a mutant that was not detected may be
   --    detected by now, so it runs again; or
   --
   --  * the mutant is left out as Unchanged ("--since") and the report
   --    has a result for it: any status but Pending, and but Ignored
   --    unless as an equivalent mutant.
   --
   --  Reused is the number of such mutants; they get the Reused flag.
   --  Raises Baseline_Error when Text is not such a report.

   package Line_Vectors renames AdaMutant.Files.String_Vectors;

   type Line_Numbers is array (Positive range <>) of Natural;

   function Line_Map
     (Old_Lines, New_Lines : Line_Vectors.Vector) return Line_Numbers;
   --  For each line of New_Lines the number of the line of Old_Lines that
   --  it is, or 0 for a line that is new or changed.  The lines that are
   --  mapped are a longest common subsequence of the two texts once their
   --  common beginning and end are set aside; when what remains is too
   --  long to compare (more than four million pairs of lines), all of it
   --  counts as changed.

   function Lines (Text : String) return Line_Vectors.Vector;
   --  The lines of Text without their line feeds.

end AdaMutant.Baselines;
