with Interfaces.C; use Interfaces.C;
with Interfaces.C.Strings; use Interfaces.C.Strings;

package body AdaMutant.Processes is

   Spawn_Failed : constant := -1000;

   function C_Run
     (Command, Directory, Log_Path, Extra_Env : chars_ptr;
      Timeout_Ms : int;
      Timed_Out  : access int;
      Elapsed_Ms : access int) return int
     with Import, Convention => C, External_Name => "adamutant_run";

   function Run
     (Command   : String;
      Directory : String;
      Log_File  : String;
      Mutant_Id : Natural;
      Timeout   : Duration) return Run_Result
   is
      Id_Image : constant String := Mutant_Id'Image;
      C_Cmd    : chars_ptr := New_String (Command);
      C_Dir    : chars_ptr := New_String (Directory);
      C_Log    : chars_ptr := New_String (Log_File);
      C_Env    : chars_ptr := New_String
        ("ADAMUTANT_MUTANT_ID=" & Id_Image (Id_Image'First + 1 .. Id_Image'Last));
      T_Out    : aliased int := 0;
      Elapsed  : aliased int := 0;
      Ms       : constant int :=
        (if Timeout <= 0.0 then 0
         elsif Timeout >= 2_000_000.0 then int'Last
         else int (Timeout * 1000.0));
      Code     : int;
   begin
      Code := C_Run (C_Cmd, C_Dir, C_Log, C_Env, Ms,
                     T_Out'Access, Elapsed'Access);
      Free (C_Cmd);
      Free (C_Dir);
      Free (C_Log);
      Free (C_Env);
      if Code = Spawn_Failed then
         raise Spawn_Error with
           "cannot run '" & Command & "' in " & Directory
           & " (log file " & Log_File & ")";
      end if;
      return (Exit_Code => Integer (Code),
              Timed_Out => T_Out /= 0,
              Elapsed   => Duration (Elapsed) / 1000.0);
   end Run;

end AdaMutant.Processes;
