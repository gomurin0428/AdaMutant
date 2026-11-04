--  Running shell commands with a timeout.
package AdaMutant.Processes is

   type Run_Result is record
      Exit_Code : Integer := 0;
      Timed_Out : Boolean := False;
      Elapsed   : Duration := 0.0;
   end record;

   Spawn_Error : exception;

   function Run
     (Command   : String;
      Directory : String;
      Log_File  : String;
      Mutant_Id : Natural;
      Timeout   : Duration;
      Memory_Limit_Mb : Natural := 0;
      Mutant_File : String := "") return Run_Result;
   --  Runs Command with the platform shell (/bin/sh -c, or cmd.exe /c on
   --  Windows) in Directory, with stdout and stderr written to Log_File,
   --  ADAMUTANT_MUTANT_ID set to Mutant_Id and ADAMUTANT_MUTANT_FILE set to
   --  Mutant_File (empty, which cmd.exe treats as unset, by default).  A Timeout of 0.0 means none.
   --  A Memory_Limit_Mb other than 0 caps the memory of each process; an
   --  allocation beyond it fails (Storage_Error in Ada programs).
   --  The whole process tree is killed when the command ends or times out.

end AdaMutant.Processes;
