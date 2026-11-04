with Ada.Characters.Handling; use Ada.Characters.Handling;
with Ada.Directories;
with Ada.Exceptions;
with System.Multiprocessors;

package body AdaMutant.Config is

   use AdaMutant.Files.String_Vectors;
   use AdaMutant.Mutators;

   LF : constant Character := ASCII.LF;

   function Parse (Text : String; Root : String) return Configuration is
      C     : Configuration;
      P     : Positive := Text'First;
      Table : Unbounded_String;
      Seen  : String_Vector;
      Have_Mutate, Have_Sandbox_Exclude : Boolean := False;
      Have_Mutators : Boolean := False;
      Mutators_List, Excluded_List, Reporters : String_Vector;

      function Line return String is
         N : Natural := 1;
      begin
         for K in Text'First .. Natural'Min (P, Text'Last + 1) - 1 loop
            if Text (K) = LF then
               N := N + 1;
            end if;
         end loop;
         return "line" & N'Image;
      end Line;

      procedure Fail (Reason : String) with No_Return is
      begin
         raise Config_Error with Line & ": " & Reason;
      end Fail;

      function At_End return Boolean is (P > Text'Last);
      function Cur return Character is (if At_End then ASCII.NUL else Text (P));

      procedure Skip_Blanks is
      begin
         while not At_End and then Cur in ' ' | ASCII.HT loop
            P := P + 1;
         end loop;
      end Skip_Blanks;

      procedure Skip_Comment is
      begin
         if Cur = '#' then
            while not At_End and then Cur /= LF loop
               P := P + 1;
            end loop;
         end if;
      end Skip_Comment;

      procedure Skip_All is
      begin
         loop
            Skip_Blanks;
            Skip_Comment;
            exit when At_End or else Cur not in LF | ASCII.CR;
            P := P + 1;
         end loop;
      end Skip_All;

      procedure End_Of_Line is
      begin
         Skip_Blanks;
         Skip_Comment;
         if Cur = ASCII.CR then
            P := P + 1;
         end if;
         if not At_End then
            if Cur /= LF then
               Fail ("unexpected text after the value");
            end if;
            P := P + 1;
         end if;
      end End_Of_Line;

      function Bare_Word return String is
         Start : constant Positive := P;
      begin
         while not At_End
           and then (Is_Alphanumeric (Cur) or else Cur in '_' | '-' | '.')
         loop
            P := P + 1;
         end loop;
         return Text (Start .. P - 1);
      end Bare_Word;

      function String_Value return String is
         R     : Unbounded_String;
         Quote : constant Character := Cur;
      begin
         if Quote not in '"' | ''' then
            Fail ("a string in quotes is expected");
         end if;
         P := P + 1;
         loop
            if At_End or else Cur = LF then
               Fail ("unterminated string");
            end if;
            exit when Cur = Quote;
            if Quote = '"' and then Cur = '\' then
               P := P + 1;
               case Cur is
                  when '"' => Append (R, '"');
                  when '\' => Append (R, '\');
                  when 'n' => Append (R, LF);
                  when 't' => Append (R, ASCII.HT);
                  when others => Fail ("unsupported escape sequence");
               end case;
            else
               Append (R, Cur);
            end if;
            P := P + 1;
         end loop;
         P := P + 1;
         return To_String (R);
      end String_Value;

      function Array_Value return String_Vector is
         R : String_Vector;
      begin
         if Cur /= '[' then
            Fail ("an array of strings is expected");
         end if;
         P := P + 1;
         loop
            Skip_All;
            exit when Cur = ']';
            R.Append (String_Value);
            Skip_All;
            if Cur = ',' then
               P := P + 1;
            elsif Cur /= ']' then
               Fail ("',' or ']' is expected in the array");
            end if;
         end loop;
         P := P + 1;
         return R;
      end Array_Value;

      function Number_Text return String is
         Start : constant Positive := P;
      begin
         while not At_End and then Cur in '0' .. '9' | '.' | '_' | '-' | '+'
           | 'e' | 'E'
         loop
            P := P + 1;
         end loop;
         if Start = P then
            Fail ("a number is expected");
         end if;
         return Text (Start .. P - 1);
      end Number_Text;

      function Integer_Value (Max : Natural := Natural'Last) return Natural is
         S : constant String := Number_Text;
         V : Long_Long_Integer;
      begin
         if (for some Ch of S => Ch not in '0' .. '9' | '_') then
            Fail ("a non-negative integer is expected");
         end if;
         V := Long_Long_Integer'Value (S);
         if V > Long_Long_Integer (Max) then
            Fail ("the value must not exceed" & Max'Image);
         end if;
         return Natural (V);
      exception
         when Constraint_Error =>
            Fail ("invalid integer '" & S & "'");
      end Integer_Value;

      function Float_Value return Float is
         S : constant String := Number_Text;
      begin
         return Float'Value (S);
      exception
         when Constraint_Error =>
            Fail ("invalid number '" & S & "'");
      end Float_Value;

      function Boolean_Value return Boolean is
         W : constant String := Bare_Word;
      begin
         if W = "true" then
            return True;
         elsif W = "false" then
            return False;
         end if;
         Fail ("true or false is expected");
      end Boolean_Value;

      procedure Key_Value is
         Key  : constant String := Bare_Word;
         Full : constant String :=
           (if Length (Table) = 0 then Key else To_String (Table) & "." & Key);
      begin
         if Key = "" then
            Fail ("a key is expected");
         end if;
         if Seen.Contains (Full) then
            Fail ("duplicate key '" & Full & "'");
         end if;
         Seen.Append (Full);
         Skip_Blanks;
         if Cur /= '=' then
            Fail ("'=' is expected after '" & Key & "'");
         end if;
         P := P + 1;
         Skip_Blanks;

         if Full = "mutate" then
            C.Mutate := Array_Value;
            Have_Mutate := True;
         elsif Full = "exclude" then
            C.Exclude := Array_Value;
         elsif Full = "build" then
            C.Build := To_Unbounded_String (String_Value);
         elsif Full = "test" then
            C.Test := To_Unbounded_String (String_Value);
         elsif Full = "prove" then
            C.Prove := To_Unbounded_String (String_Value);
         elsif Full = "concurrency" then
            declare
               N : constant Natural := Integer_Value (1024);
            begin
               if N = 0 then
                  Fail ("concurrency must be at least 1");
               end if;
               C.Concurrency := N;
            end;
         elsif Full = "timeout_factor" then
            C.Timeout_Factor := Float_Value;
            if C.Timeout_Factor < 1.0 then
               Fail ("timeout_factor must be at least 1.0");
            end if;
         elsif Full = "timeout_ms" then
            C.Timeout_Ms := Integer_Value;
         elsif Full = "build_timeout_ms" then
            C.Build_Timeout_Ms := Integer_Value;
         elsif Full = "test_memory_limit_mb" then
            C.Test_Memory_Limit_Mb :=
              Integer_Value
                (if Standard'Address_Size = 32 then 4095 else Natural'Last);
         elsif Full = "mutators" then
            Mutators_List := Array_Value;
            Have_Mutators := True;
         elsif Full = "exclude_mutators" then
            Excluded_List := Array_Value;
         elsif Full = "mutate_contracts" then
            C.Scan.Mutate_Contracts := Boolean_Value;
         elsif Full = "sandbox_exclude" then
            C.Sandbox_Exclude := Array_Value;
            Have_Sandbox_Exclude := True;
         elsif Full = "report_dir" then
            C.Report_Dir := To_Unbounded_String (String_Value);
         elsif Full = "reporters" then
            Reporters := Array_Value;
            C.Console_Report := False;
            C.Html_Report := False;
            C.Json_Report := False;
            for R of Reporters loop
               if R = "console" then
                  C.Console_Report := True;
               elsif R = "html" then
                  C.Html_Report := True;
               elsif R = "json" then
                  C.Json_Report := True;
               else
                  Fail ("unknown reporter '" & R
                        & "' (expected console, html or json)");
               end if;
            end loop;
         elsif Full = "thresholds.high" then
            C.High := Percentage (Integer_Value (100));
         elsif Full = "thresholds.low" then
            C.Low := Percentage (Integer_Value (100));
         elsif Full = "thresholds.break" then
            C.Break := Percentage (Integer_Value (100));
         else
            Fail ("unknown key '" & Full & "'");
         end if;
         End_Of_Line;
      end Key_Value;

      procedure Check_Mutators (List : String_Vector; Key : String) is
         K : Mutator_Kind;
      begin
         for Name of List loop
            if not AdaMutant.Mutators.Parse (Name, K) then
               raise Config_Error with
                 Key & ": unknown mutator '" & Name & "'";
            end if;
         end loop;
      end Check_Mutators;

   begin
      C.Root := To_Unbounded_String (Root);
      C.Report_Dir := To_Unbounded_String (".adamutant/reports");
      C.Concurrency := Positive'Max
        (1, Positive (System.Multiprocessors.Number_Of_CPUs) / 2);

      loop
         Skip_All;
         exit when At_End;
         if Cur = '[' then
            P := P + 1;
            Skip_Blanks;
            Table := To_Unbounded_String (Bare_Word);
            Skip_Blanks;
            if Cur /= ']' then
               Fail ("']' is expected");
            end if;
            P := P + 1;
            if To_String (Table) /= "thresholds" then
               Fail ("unknown table [" & To_String (Table) & "]");
            end if;
            End_Of_Line;
         else
            Key_Value;
         end if;
      end loop;

      if not Have_Mutate then
         C.Mutate.Append ("src/**/*.adb");
         C.Mutate.Append ("src/**/*.ads");
      end if;
      if not Have_Sandbox_Exclude then
         C.Sandbox_Exclude.Append (".git");
      end if;
      C.Sandbox_Exclude.Append (".adamutant");

      Check_Mutators (Mutators_List, "mutators");
      Check_Mutators (Excluded_List, "exclude_mutators");
      declare
         K : Mutator_Kind;
      begin
         if Have_Mutators then
            C.Scan.Enabled := [others => False];
            for Name of Mutators_List loop
               if AdaMutant.Mutators.Parse (Name, K) then
                  C.Scan.Enabled (K) := True;
               end if;
            end loop;
         end if;
         for Name of Excluded_List loop
            if AdaMutant.Mutators.Parse (Name, K) then
               C.Scan.Enabled (K) := False;
            end if;
         end loop;
      end;

      if Length (C.Build) = 0 then
         raise Config_Error with "the 'build' command is required";
      end if;
      if Length (C.Test) = 0 and then Length (C.Prove) = 0 then
         raise Config_Error with
           "at least one of the 'test' and 'prove' commands is required";
      end if;
      if C.Low > C.High then
         raise Config_Error with
           "thresholds: low must not be greater than high";
      end if;
      return C;
   end Parse;

   function Load (Path : String) return Configuration is
      Text : constant String := AdaMutant.Files.Read (Path);
      Full : constant String := Ada.Directories.Full_Name (Path);
   begin
      return Parse (Text, Ada.Directories.Containing_Directory (Full));
   exception
      when AdaMutant.Files.File_Error =>
         raise Config_Error with Path & ": cannot read the configuration";
      when E : Config_Error =>
         raise Config_Error with
           Path & ": " & Ada.Exceptions.Exception_Message (E);
   end Load;

   function Template return String is
     ("# AdaMutant configuration. Paths are relative to this file." & LF
      & "# Files to mutate (globs: ** any directories, * any name part)." & LF
      & "mutate = [""src/**/*.adb"", ""src/**/*.ads""]" & LF
      & "exclude = []" & LF
      & LF
      & "# Commands run by the shell in a copy of this directory." & LF
      & "# A non-zero exit status of 'test' or 'prove' kills the mutant." & LF
      & "build = ""gprbuild -p -q -P tests/tests.gpr""" & LF
      & "test = ""./tests/bin/test_main""" & LF
      & "# prove = ""gnatprove -P project.gpr --level=1 --checks-as-errors=on""" & LF
      & LF
      & "# concurrency = 4" & LF
      & "timeout_factor = 1.5" & LF
      & "timeout_ms = 5000" & LF
      & "# test_memory_limit_mb = 2048" & LF
      & "# mutators = [""ArithmeticOperator"", ""EqualityOperator""]" & LF
      & "# exclude_mutators = [""StringLiteral""]" & LF
      & "mutate_contracts = false" & LF
      & "sandbox_exclude = ["".git"", ""obj"", ""bin""]" & LF
      & "reporters = [""console"", ""html"", ""json""]" & LF
      & LF
      & "[thresholds]" & LF
      & "high = 80" & LF
      & "low = 60" & LF
      & "break = 0" & LF);

end AdaMutant.Config;
