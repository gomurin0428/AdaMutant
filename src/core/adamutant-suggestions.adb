with Ada.Characters.Handling; use Ada.Characters.Handling;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.UTF_Encoding.Wide_Wide_Strings;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with GNATCOLL.JSON;
with GNATCOLL.VFS;
with Langkit_Support.Slocs;
with Libadalang.Analysis;
with Libadalang.Auto_Provider;
with Libadalang.Common;
with GNAT.OS_Lib;
with AdaMutant.Mutators;
with AdaMutant.Processes;

package body AdaMutant.Suggestions is

   package LAL renames Libadalang.Analysis;
   package LC renames Libadalang.Common;
   package String_Vectors renames AdaMutant.Files.String_Vectors;

   use AdaMutant.Results;
   use type LC.Ada_Node_Kind_Type;

   LF : constant Character := ASCII.LF;

   function Trimmed (S : String) return String is
     (Ada.Strings.Fixed.Trim (S, Ada.Strings.Both));

   function Is_Space (C : Character) return Boolean is
     (C in ' ' | ASCII.HT | ASCII.CR | ASCII.LF);

   function Is_Identifier (S : String) return Boolean is
   begin
      if S'Length = 0 or else S (S'First) not in 'A' .. 'Z' | 'a' .. 'z' then
         return False;
      end if;
      for C of S (S'First + 1 .. S'Last) loop
         if C not in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' then
            return False;
         end if;
      end loop;
      return True;
   end Is_Identifier;

   function Digit_Value (C : Character) return Natural is
     (case C is
         when '0' .. '9' => Character'Pos (C) - Character'Pos ('0'),
         when 'a' .. 'f' => Character'Pos (C) - Character'Pos ('a') + 10,
         when 'A' .. 'F' => Character'Pos (C) - Character'Pos ('A') + 10,
         when others    => 100);

   function Digit_Sequence (S : String; Base : Natural) return Boolean is
      Previous_Digit : Boolean := False;
      Seen_Digit     : Boolean := False;
   begin
      if S'Length = 0 then
         return False;
      end if;
      for C of S loop
         if C = '_' then
            if not Previous_Digit then
               return False;
            end if;
            Previous_Digit := False;
         else
            if Digit_Value (C) >= Base then
               return False;
            end if;
            Previous_Digit := True;
            Seen_Digit := True;
         end if;
      end loop;
      return Seen_Digit and then Previous_Digit;
   end Digit_Sequence;

   function Is_Integer_Literal (Value : String) return Boolean is
      S     : constant String := Trimmed (Value);
      First : Positive;
      Hash  : Natural := 0;
      Base  : Natural := 0;
   begin
      if S'Length = 0 then
         return False;
      end if;
      First := S'First;
      if S (First) in '+' | '-' then
         First := First + 1;
         if First > S'Last then
            return False;
         end if;
      end if;

      for I in First .. S'Last loop
         if S (I) = '#' then
            Hash := I;
            exit;
         end if;
      end loop;
      if Hash = 0 then
         return Digit_Sequence (S (First .. S'Last), 10);
      end if;
      if Hash = First or else Hash = S'Last
        or else S (S'Last) /= '#'
        or else not Digit_Sequence (S (First .. Hash - 1), 10)
      then
         return False;
      end if;
      for C of S (First .. Hash - 1) loop
         if C /= '_' then
            Base := Base * 10 + Digit_Value (C);
            if Base > 16 then
               return False;
            end if;
         end if;
      end loop;
      return Base in 2 .. 16
        and then Digit_Sequence (S (Hash + 1 .. S'Last - 1), Base);
   end Is_Integer_Literal;

   function Normalize_Spaces (S : String) return String is
      Result : Unbounded_String;
      Space  : Boolean := False;
   begin
      for C of S loop
         if Is_Space (C) then
            Space := Length (Result) > 0;
         else
            if Space then
               Append (Result, ' ');
               Space := False;
            end if;
            Append (Result, C);
         end if;
      end loop;
      return To_String (Result);
   end Normalize_Spaces;

   function Parse_Bindings
     (Example : String;
      Formals : String_Vectors.Vector;
      Actuals : out String_Vectors.Vector;
      Reason  : out Unbounded_String) return Boolean
   is
      Text : constant String := Normalize_Spaces (Example);
      Prefix : constant String := "e.g. when ";
      type Bound_Array is array (Positive range <>) of Boolean;
      Bound : Bound_Array (1 .. Natural (Formals.Length)) := (others => False);
      Start : Positive;
      Last  : Natural;
   begin
      Actuals.Clear;
      Reason := Null_Unbounded_String;
      if Formals.Is_Empty then
         Reason := To_Unbounded_String ("the function has no formal parameters");
         return False;
      end if;
      if Text'Length <= Prefix'Length
        or else To_Lower (Text (Text'First .. Text'First + Prefix'Length - 1))
          /= Prefix
      then
         Reason := To_Unbounded_String
           ("the GNATprove counterexample is not a simple 'e.g. when' binding list");
         return False;
      end if;
      for I in 1 .. Natural (Formals.Length) loop
         Actuals.Append ("");
         if not Is_Identifier (Formals (I)) then
            Reason := To_Unbounded_String ("a formal parameter name is unsupported");
            return False;
         end if;
      end loop;

      Start := Text'First + Prefix'Length;
      Last := Text'Last;
      while Start <= Last loop
         declare
            Sep : Natural := 0;
            Equals : Natural := 0;
         begin
            if Last - Start + 1 >= 5 then
               for I in Start .. Last - 4 loop
                  if Text (I .. I + 4) = " and " then
                     Sep := I;
                     exit;
                  end if;
               end loop;
            end if;
            declare
               Finish : constant Natural := (if Sep = 0 then Last else Sep - 1);
               Binding : constant String := Trimmed (Text (Start .. Finish));
               Value_Start : Natural := 0;
            begin
               if Binding'Length = 0 then
                  Reason := To_Unbounded_String ("the counterexample contains an empty binding");
                  return False;
               end if;
               for I in Binding'Range loop
                  if Binding (I) = '=' then
                     if Equals /= 0 then
                        Reason := To_Unbounded_String ("a binding contains more than one '='");
                        return False;
                     end if;
                     Equals := I;
                  end if;
               end loop;
               if Equals = 0 then
                  Reason := To_Unbounded_String ("a counterexample binding has no '='");
                  return False;
               end if;
               declare
                  Name : constant String := Trimmed
                    (Binding (Binding'First .. Equals - 1));
                  Value : constant String := Trimmed
                    (Binding (Equals + 1 .. Binding'Last));
                  Index : Natural := 0;
               begin
                  if not Is_Identifier (Name) then
                     Reason := To_Unbounded_String ("a binding name is not an identifier");
                     return False;
                  end if;
                  if not Is_Integer_Literal (Value) then
                     Reason := To_Unbounded_String
                       ("a binding value is not an integer literal");
                     return False;
                  end if;
                  for I in 1 .. Natural (Formals.Length) loop
                     if To_Lower (Formals (I)) = To_Lower (Name) then
                        Index := I;
                        exit;
                     end if;
                  end loop;
                  if Index = 0 then
                     Reason := To_Unbounded_String
                       ("the counterexample contains an extra binding for '" & Name & "'");
                     return False;
                  elsif Bound (Index) then
                     Reason := To_Unbounded_String
                       ("the counterexample contains a duplicate binding for '" & Name & "'");
                     return False;
                  end if;
                  Bound (Index) := True;
                  Actuals.Replace_Element (Index, Value);
               end;
               if Sep = 0 then
                  exit;
               end if;
               Value_Start := Sep + 5;
               if Value_Start > Last then
                  Reason := To_Unbounded_String ("the counterexample ends with an empty binding");
                  return False;
               end if;
               Start := Value_Start;
            end;
         end;
      end loop;
      for I in Bound'Range loop
         if not Bound (I) then
            Reason := To_Unbounded_String
              ("the counterexample is missing a binding for '" & Formals (I) & "'");
            return False;
         end if;
      end loop;
      return True;
   end Parse_Bindings;

   function Candidate_Source
     (Procedure_Name, Package_Name, Function_Name, Arguments,
      Expected_Value, Failure_Marker, Result_Type, Type_Package : String)
      return String
   is
      Call : constant String := Package_Name & "." & Function_Name
        & " (" & Arguments & ")";
   begin
      return "with Ada.Command_Line;" & LF
        & "with Ada.Text_IO;" & LF
        & "with " & Package_Name & ";" & LF
        & (if Type_Package'Length = 0
             or else To_Lower (Type_Package) = To_Lower (Package_Name)
           then ""
           else "with " & Type_Package & ";" & LF)
        & "procedure " & Procedure_Name & " is" & LF
        & "   use type " & Result_Type & ";" & LF
        & "   procedure Report_Failure is" & LF
        & "   begin" & LF
        & "      Ada.Text_IO.Put_Line (""" & Failure_Marker & """);" & LF
        & "      Ada.Command_Line.Set_Exit_Status (1);" & LF
        & "   end Report_Failure;" & LF
        & "begin" & LF
        & "   begin" & LF
        & "      if " & Call & " /= " & Expected_Value & " then" & LF
        & "         Report_Failure;" & LF
        & "      end if;" & LF
        & "   exception" & LF
        & "      when others =>" & LF
        & "         Report_Failure;" & LF
        & "   end;" & LF
        & "end " & Procedure_Name & ";" & LF;
   end Candidate_Source;

   function Is_Explicit_Mutant_Failure
     (Exit_Code : Integer; Timed_Out : Boolean; Output, Failure_Marker : String)
      return Boolean
   is
   begin
      return not Timed_Out
        and then Exit_Code = 1
        and then Failure_Marker'Length > 0
        and then Ada.Strings.Fixed.Index (Output, Failure_Marker) > 0;
   end Is_Explicit_Mutant_Failure;

   function Probe_Source
     (Procedure_Name, Package_Name, Call : String) return String
   is
   begin
      return "with Ada.Text_IO;" & LF
        & "with " & Package_Name & ";" & LF
        & "procedure " & Procedure_Name & " is" & LF
        & "begin" & LF
        & "   Ada.Text_IO.Put_Line (" & Call & "'Image);" & LF
        & "end " & Procedure_Name & ";" & LF;
   end Probe_Source;

   function Text_Of (Node : LAL.Ada_Node'Class) return String is
     (Ada.Strings.UTF_Encoding.Wide_Wide_Strings.Encode (LAL.Text (Node)));

   function Subprogram_Name (Node : LAL.Ada_Node'Class) return String is
      Spec : LAL.Subp_Spec;
   begin
      case Node.Kind is
         when LC.Ada_Abstract_Subp_Decl | LC.Ada_Subp_Decl =>
            Spec := Node.As_Classic_Subp_Decl.F_Subp_Spec;
         when LC.Ada_Expr_Function | LC.Ada_Null_Subp_Decl
            | LC.Ada_Subp_Body | LC.Ada_Subp_Renaming_Decl =>
            Spec := Node.As_Base_Subp_Body.F_Subp_Spec;
         when LC.Ada_Generic_Subp_Internal =>
            Spec := Node.As_Generic_Subp_Internal.F_Subp_Spec;
         when others =>
            return "";
      end case;
      if Spec.Is_Null or else Spec.F_Subp_Name.Is_Null then
         return "";
      end if;
      return Text_Of (Spec.F_Subp_Name.F_Name);
   end Subprogram_Name;

   function Is_Function (Node : LAL.Ada_Node'Class) return Boolean is
      Spec : LAL.Subp_Spec;
   begin
      case Node.Kind is
         when LC.Ada_Subp_Decl | LC.Ada_Abstract_Subp_Decl =>
            Spec := Node.As_Classic_Subp_Decl.F_Subp_Spec;
         when LC.Ada_Expr_Function | LC.Ada_Null_Subp_Decl
            | LC.Ada_Subp_Body | LC.Ada_Subp_Renaming_Decl =>
            Spec := Node.As_Base_Subp_Body.F_Subp_Spec;
         when LC.Ada_Generic_Subp_Internal =>
            Spec := Node.As_Generic_Subp_Internal.F_Subp_Spec;
         when others =>
            return False;
      end case;
      return not Spec.Is_Null and then not Spec.F_Subp_Returns.Is_Null;
   end Is_Function;

   function Is_Integer_Type (Type_Expr : LAL.Type_Expr) return Boolean is
      Name : LAL.Name;
      Decl : LAL.Basic_Decl;
   begin
      if Type_Expr.Is_Null or else Type_Expr.Kind /= LC.Ada_Subtype_Indication
      then
         return False;
      end if;
      declare
         Subtype_Node : constant LAL.Subtype_Indication :=
           Type_Expr.As_Subtype_Indication;
      begin
         Name := Subtype_Node.F_Name;
      end;
      if Name.Kind not in LC.Ada_Identifier | LC.Ada_Dotted_Name then
         return False;
      end if;
      Decl := Name.P_Referenced_Decl;
      return not Decl.Is_Null
        and then Decl.As_Base_Type_Decl.P_Is_Int_Type (Origin => Name);
   exception
      when others =>
         return False;
   end Is_Integer_Type;

   function Integer_Type_Info
     (Type_Expr : LAL.Type_Expr;
      Type_Name, Type_Package : out Unbounded_String) return Boolean
   is
      Name : LAL.Name;
      Decl : LAL.Basic_Decl;
      Type_Decl : LAL.Base_Type_Decl;
      Current : LAL.Ada_Node;
      Package_Path : Unbounded_String;
      Simple_Name : Unbounded_String;
   begin
      Type_Name := Null_Unbounded_String;
      Type_Package := Null_Unbounded_String;
      if Type_Expr.Is_Null or else Type_Expr.Kind /= LC.Ada_Subtype_Indication
      then
         return False;
      end if;
      Name := Type_Expr.As_Subtype_Indication.F_Name;
      if Name.Kind not in LC.Ada_Identifier | LC.Ada_Dotted_Name then
         return False;
      end if;
      Decl := Name.P_Referenced_Decl;
      if Decl.Is_Null
        or else not Decl.As_Base_Type_Decl.P_Is_Int_Type (Origin => Name)
      then
         return False;
      end if;
      Type_Decl := Decl.As_Base_Type_Decl;
      if Type_Decl.F_Name.Is_Null
        or else Type_Decl.F_Name.F_Name.Is_Null
      then
         return False;
      end if;
      Simple_Name := To_Unbounded_String (Text_Of (Type_Decl.F_Name.F_Name));
      Current := Type_Decl.Parent;
      while not Current.Is_Null loop
         if Current.Kind = LC.Ada_Package_Decl then
            declare
               Name_Text : constant String :=
                 Text_Of (Current.As_Package_Decl.F_Package_Name.F_Name);
            begin
               if Length (Package_Path) = 0 then
                  Package_Path := To_Unbounded_String (Name_Text);
               elsif Ada.Strings.Fixed.Index (Name_Text, ".") = 0 then
                  Package_Path := To_Unbounded_String
                    (Name_Text & "." & To_String (Package_Path));
               end if;
            end;
         end if;
         Current := Current.Parent;
      end loop;
      if Length (Package_Path) = 0 then
         return False;
      elsif To_Lower (To_String (Package_Path)) = "standard" then
         Type_Name := Simple_Name;
      else
         Type_Package := Package_Path;
         Type_Name := To_Unbounded_String
           (To_String (Package_Path) & "." & To_String (Simple_Name));
      end if;
      return True;
   exception
      when others =>
         return False;
   end Integer_Type_Info;

   type Function_Info is record
      Package_Name        : Unbounded_String;
      Function_Name       : Unbounded_String;
      Result_Type_Name    : Unbounded_String;
      Result_Type_Package : Unbounded_String;
      Formals             : String_Vectors.Vector;
      Actuals             : String_Vectors.Vector;
   end record;

   function Identify
     (Root, File_Path : String;
      Skip_Dirs : String_Vectors.Vector;
      M : Mutant;
      Info : out Function_Info;
      Reason : out Unbounded_String) return Boolean
   is
      Files : constant String_Vectors.Vector :=
        AdaMutant.Files.Find_Files (Root, Skip_Dirs);
      Paths : GNATCOLL.VFS.File_Array (1 .. Natural (Files.Length));
      Last  : Natural := 0;
      Provider : LAL.Unit_Provider_Reference;
      Context  : LAL.Analysis_Context;
      Unit     : LAL.Analysis_Unit;
      Node     : LAL.Ada_Node;
      Candidate_Node : LAL.Ada_Node := LAL.No_Ada_Node;
      Package_Body_Node : LAL.Package_Body;
      Package_Decl : LAL.Package_Decl;
      Package_Node : LAL.Ada_Node;
      Package_Name : Unbounded_String;
      Function_Name : Unbounded_String;
      Subp_Spec : LAL.Subp_Spec;
      Visible_Count : Natural := 0;
      All_Count : Natural := 0;
      Found_Visible : LAL.Ada_Node := LAL.No_Ada_Node;

      function Ada_Source (Path : String) return Boolean is
         Name : constant String := To_Lower (Ada.Directories.Simple_Name (Path));
      begin
         return Name'Length >= 4
           and then (Name (Name'Last - 3 .. Name'Last) = ".ads"
                     or else Name (Name'Last - 3 .. Name'Last) = ".adb");
      end Ada_Source;

      function Count_Declaration
        (N : LAL.Ada_Node'Class) return LC.Visit_Status
      is
      begin
         if To_Lower (Subprogram_Name (N)) = To_Lower (To_String (Function_Name))
           and then Subprogram_Name (N) /= ""
         then
            All_Count := All_Count + 1;
         end if;
         return LC.Into;
      end Count_Declaration;

      function Count_Public
        (N : LAL.Ada_Node'Class) return LC.Visit_Status
      is
      begin
         if To_Lower (Subprogram_Name (N)) = To_Lower (To_String (Function_Name))
           and then Subprogram_Name (N) /= ""
         then
            Visible_Count := Visible_Count + 1;
            Found_Visible := N.As_Ada_Node;
         end if;
         return LC.Into;
      end Count_Public;

      function On_Public_Part (N : LAL.Ada_Node'Class) return Boolean is
         Public : constant LAL.Public_Part := Package_Decl.F_Public_Part;
         Current : LAL.Ada_Node := N.Parent;
      begin
         while not Current.Is_Null loop
            if LAL."=" (Current, Public.As_Ada_Node) then
               return True;
            end if;
            if Current.Kind in LC.Ada_Package_Decl | LC.Ada_Package_Body
              and then not LAL."=" (Current, Package_Decl.As_Ada_Node)
            then
               return False;
            end if;
            Current := Current.Parent;
         end loop;
         return False;
      end On_Public_Part;

   begin
      Reason := Null_Unbounded_String;
      Info := (others => <>);
      for Path of Files loop
         if Ada_Source (Path) then
            Last := Last + 1;
            if Last > Paths'Last then
               Reason := To_Unbounded_String ("the project has too many Ada source files");
               return False;
            end if;
            Paths (Last) := GNATCOLL.VFS.Create
              (GNATCOLL.VFS."+" (AdaMutant.Files.Join (Root, Path)));
         end if;
      end loop;
      Provider := Libadalang.Auto_Provider.Create_Auto_Provider_Reference
        (Paths (1 .. Last), "utf-8");
      Context := LAL.Create_Context
        (Charset => "utf-8", Unit_Provider => Provider, Tab_Stop => 1);
      Unit := Context.Get_From_File (AdaMutant.Files.Join (Root, File_Path));
      if Unit.Has_Diagnostics then
         Reason := To_Unbounded_String ("Libadalang could not parse the mutated source file");
         return False;
      end if;
      Node := Unit.Root.Lookup
        (Langkit_Support.Slocs.Source_Location'
           (Line   => Langkit_Support.Slocs.Line_Number (M.Start_Pos.Line),
            Column => Langkit_Support.Slocs.Column_Number (M.Start_Pos.Column)));
      while not Node.Is_Null and then Node.Kind /= LC.Ada_Subp_Body loop
         Node := Node.Parent;
      end loop;
      if Node.Is_Null then
         Reason := To_Unbounded_String
           ("the mutation is not inside a supported function body");
         return False;
      end if;
      Candidate_Node := Node;
      Function_Name := To_Unbounded_String (Subprogram_Name (Candidate_Node));
      if Length (Function_Name) = 0 then
         Reason := To_Unbounded_String ("the function name could not be resolved");
         return False;
      end if;
      Node := Candidate_Node.Parent;
      while not Node.Is_Null and then Node.Kind /= LC.Ada_Package_Body loop
         if Node.Kind in LC.Ada_Subp_Body | LC.Ada_Expr_Function
           | LC.Ada_Block_Stmt | LC.Ada_Generic_Subp_Internal
           | LC.Ada_Generic_Package_Internal | LC.Ada_Task_Body
           | LC.Ada_Protected_Body | LC.Ada_Entry_Body
         then
            Reason := To_Unbounded_String
              ("nested, generic, task, or protected functions are unsupported");
            return False;
         end if;
         Node := Node.Parent;
      end loop;
      if Node.Is_Null then
         Reason := To_Unbounded_String
           ("the function is not a package-level subprogram");
         return False;
      end if;
      Package_Body_Node := Node.As_Package_Body;
      Node := Package_Body_Node.F_Package_Name.F_Name.As_Ada_Node;
      if Node.Kind not in LC.Ada_Identifier | LC.Ada_Dotted_Name then
         Reason := To_Unbounded_String ("the containing package name is unsupported");
         return False;
      end if;
      Package_Name := To_Unbounded_String (Text_Of (Node));
      Package_Node := LAL.No_Ada_Node;
      declare
         Spec_Name : constant LAL.Defining_Name :=
           Package_Body_Node.F_Package_Name.P_Previous_Part
             (Imprecise_Fallback => True);
      begin
         if not Spec_Name.Is_Null then
            Package_Node := Spec_Name.P_Basic_Decl.As_Ada_Node;
         end if;
      end;
      if Package_Node.Is_Null then
         declare
            Decl : constant LAL.Basic_Decl :=
              Node.As_Name.P_Referenced_Decl (Imprecise_Fallback => True);
         begin
            if not Decl.Is_Null then
               Package_Node := Decl.As_Ada_Node;
            end if;
         end;
      end if;
      if Package_Node.Is_Null or else Package_Node.Kind /= LC.Ada_Package_Decl then
         Reason := To_Unbounded_String
           ("the containing package specification could not be resolved");
         return False;
      end if;
      Package_Decl := Package_Node.As_Package_Decl;
      LAL.Traverse (Package_Decl, Count_Declaration'Access);
      LAL.Traverse (Package_Decl.F_Public_Part, Count_Public'Access);
      if Visible_Count = 0 then
         Reason := To_Unbounded_String
           ("the function is not declared in the package's public part");
         return False;
      elsif Visible_Count /= 1 or else All_Count /= 1 then
         Reason := To_Unbounded_String
           ("overloaded functions are unsupported");
         return False;
      elsif not On_Public_Part (Found_Visible)
        or else Found_Visible.Kind not in LC.Ada_Subp_Decl
                                           | LC.Ada_Abstract_Subp_Decl
        or else not Is_Function (Found_Visible)
      then
         Reason := To_Unbounded_String
           ("the public declaration is not a simple function");
         return False;
      end if;

      Subp_Spec := Candidate_Node.As_Subp_Body.F_Subp_Spec;
      if Subp_Spec.F_Subp_Returns.Is_Null
        or else not Integer_Type_Info
          (Subp_Spec.F_Subp_Returns,
           Info.Result_Type_Name, Info.Result_Type_Package)
      then
         Reason := To_Unbounded_String
           ("the function return type is not a supported integer scalar type");
         return False;
      end if;
      if Subp_Spec.F_Subp_Params.Is_Null then
         Reason := To_Unbounded_String
           ("functions without explicit integer parameters are unsupported");
         return False;
      end if;
      declare
         Params : constant LAL.Params := Subp_Spec.F_Subp_Params;
         Param_List : constant LAL.Param_Spec_List := Params.F_Params;
      begin
         for K in 1 .. LAL.Children_Count (Param_List) loop
            declare
               Param : constant LAL.Param_Spec :=
                 LAL.Child (Param_List, K).As_Param_Spec;
               Mode  : constant LAL.Mode := Param.F_Mode;
               Type_Expr : constant LAL.Type_Expr := Param.F_Type_Expr;
            begin
               if not Mode.Is_Null
                 and then Mode.Kind not in LC.Ada_Mode_Default | LC.Ada_Mode_In
               then
                  Reason := To_Unbounded_String
                    ("only in-mode integer parameters are supported");
                  return False;
               end if;
               if not Is_Integer_Type (Type_Expr) then
                  Reason := To_Unbounded_String
                    ("a formal parameter is not a supported integer scalar type");
                  return False;
               end if;
               declare
                  Ids : constant LAL.Defining_Name_List := Param.F_Ids;
               begin
                  for J in 1 .. LAL.Children_Count (Ids) loop
                     Info.Formals.Append
                       (Text_Of (LAL.Child (Ids, J).As_Defining_Name.F_Name));
                  end loop;
               end;
            end;
         end loop;
      end;
      Info.Package_Name := Package_Name;
      Info.Function_Name := Function_Name;
      if not Parse_Bindings
        (To_String (M.Example), Info.Formals, Info.Actuals, Reason)
      then
         return False;
      end if;
      return True;
   exception
      when E : others =>
         Reason := To_Unbounded_String
           ("Libadalang could not resolve the function signature: "
            & Ada.Exceptions.Exception_Message (E));
         return False;
   end Identify;

   function GPR_Project_Name (Text : String) return String is
      I : Natural := Text'First;

      procedure Skip_Blanks is
      begin
         while I <= Text'Last and then Is_Space (Text (I)) loop
            I := I + 1;
         end loop;
      end Skip_Blanks;
   begin
      while I <= Text'Last loop
         if Text (I) = '-' and then I < Text'Last and then Text (I + 1) = '-' then
            while I <= Text'Last and then Text (I) /= LF loop
               I := I + 1;
            end loop;
         elsif Text (I) = '"' then
            I := I + 1;
            while I <= Text'Last loop
               if Text (I) = '"' then
                  if I < Text'Last and then Text (I + 1) = '"' then
                     I := I + 2;
                  else
                     I := I + 1;
                     exit;
                  end if;
               else
                  I := I + 1;
               end if;
            end loop;
         elsif Text (I) in 'A' .. 'Z' | 'a' .. 'z' | '_' then
            declare
               First : constant Positive := I;
            begin
               while I <= Text'Last
                 and then Text (I) in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_'
               loop
                  I := I + 1;
               end loop;
               if To_Lower (Text (First .. I - 1)) = "project" then
                  Skip_Blanks;
                  declare
                     Name_First : constant Natural := I;
                  begin
                     while I <= Text'Last
                       and then Text (I) in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9'
                         | '_' | '.'
                     loop
                        I := I + 1;
                     end loop;
                     if I > Name_First then
                        return Text (Name_First .. I - 1);
                     end if;
                  end;
               end if;
            end;
         else
            I := I + 1;
         end if;
      end loop;
      return "";
   end GPR_Project_Name;

   function GPR_String (S : String) return String is
      Result : Unbounded_String;
   begin
      Append (Result, '"');
      for C of S loop
         Append (Result, C);
         if C = '"' then
            Append (Result, '"');
         end if;
      end loop;
      Append (Result, '"');
      return To_String (Result);
   end GPR_String;

   function GPR_Source
     (Project_Name, Parent_Project, Parent_Name, Source_Dir, Main,
      Object_Dir, Exec_Dir : String;
      Absolute_Source_Dirs : String := "") return String
   is
   begin
      return "project " & Project_Name & " extends "
        & GPR_String (Parent_Project) & " is" & LF
        & "   for Source_Dirs use "
        & (if Absolute_Source_Dirs = ""
           then "(" & GPR_String (Source_Dir) & ") & "
             & Parent_Name & "'Source_Dirs"
           else "(" & Absolute_Source_Dirs & ")") & ";" & LF
        & "   for Object_Dir use " & GPR_String (Object_Dir) & ";" & LF
        & "   for Exec_Dir use " & GPR_String (Exec_Dir) & ";" & LF
        & "   for Main use (" & GPR_String (Main) & ");" & LF
        & "   package Compiler is" & LF
        & "      for Default_Switches (""Ada"") use "
        & Parent_Name & ".Compiler'Default_Switches (""Ada"")"
        & " & (""-gnata"", ""-gnato"");" & LF
        & "   end Compiler;" & LF
        & "end " & Project_Name & ";" & LF;
   end GPR_Source;

   function Is_Absolute (Path : String) return Boolean is
     (Path'Length > 0
      and then (Path (Path'First) = '/' or else Path (Path'First) = '\'
                or else (Path'Length > 1 and then Path (Path'First + 1) = ':')));

   function Is_Within (Root, Path : String) return Boolean is
      Parent : constant String := Ada.Directories.Full_Name (Root);
      Child  : constant String := Ada.Directories.Full_Name (Path);
      Prefix : constant String :=
        (if Parent (Parent'Last) = GNAT.OS_Lib.Directory_Separator
         then Parent
         else Parent & GNAT.OS_Lib.Directory_Separator);
   begin
      return Child'Length > Prefix'Length
        and then To_Lower (Child (Child'First .. Child'First + Prefix'Length - 1))
          = To_Lower (Prefix);
   end Is_Within;

   function Shell_Quote (S : String) return String is
      Result : Unbounded_String;
   begin
      if GNAT.OS_Lib.Directory_Separator = '/' then
         Append (Result, Character'Val (39));
         for C of S loop
            if C = Character'Val (39) then
               Append (Result, "'\''");
            else
               Append (Result, C);
            end if;
         end loop;
         Append (Result, Character'Val (39));
      else
         Append (Result, '"');
         for C of S loop
            if C = '"' then
               Append (Result, '\');
            end if;
            Append (Result, C);
         end loop;
         Append (Result, '"');
      end if;
      return To_String (Result);
   end Shell_Quote;

   function Native_Path (Path : String) return String is
      Result : String := Path;
   begin
      if GNAT.OS_Lib.Directory_Separator /= '/' then
         for I in Result'Range loop
            if Result (I) = '/' then
               Result (I) := '\';
            end if;
         end loop;
      end if;
      return Result;
   end Native_Path;

   function Build_Outcome
     (Command, Directory, Log : String; Timeout : Duration;
      Memory_Limit_Mb : Natural;
      M : Mutant; File_Path : String) return Verification_Outcome
   is
      Done : AdaMutant.Processes.Run_Result;
   begin
      Done := AdaMutant.Processes.Run
        (Command   => Command,
         Directory => Directory,
         Log_File  => Log,
         Mutant_Id => M.Id,
         Timeout   => Timeout,
         Memory_Limit_Mb => Memory_Limit_Mb,
         Mutant_File => File_Path,
         Mutant_Line => M.Start_Pos.Line);
      if Done.Timed_Out then
         return Timed_Out;
      elsif Done.Exit_Code = 0 then
         return Passed;
      else
         return Build_Failed;
      end if;
   exception
      when AdaMutant.Processes.Spawn_Error =>
         return Spawn_Failed;
      when others =>
         return Spawn_Failed;
   end Build_Outcome;

   function Test_Outcome
     (Command, Directory, Log : String; Timeout : Duration;
      Memory_Limit_Mb : Natural; M : Mutant; File_Path : String;
      Expected_Failure : Boolean; Failure_Marker : String := "")
      return Verification_Outcome
   is
      Done : AdaMutant.Processes.Run_Result;
      Output : Unbounded_String;
   begin
      Done := AdaMutant.Processes.Run
        (Command   => Command,
         Directory => Directory,
         Log_File  => Log,
         Mutant_Id => M.Id,
         Timeout   => Timeout,
         Memory_Limit_Mb => Memory_Limit_Mb,
         Mutant_File => File_Path,
         Mutant_Line => M.Start_Pos.Line);
      if Done.Timed_Out then
         return Timed_Out;
      end if;
      Output := To_Unbounded_String (AdaMutant.Files.Read (Log));
      if Expected_Failure then
         if Is_Explicit_Mutant_Failure
           (Done.Exit_Code, Done.Timed_Out, To_String (Output), Failure_Marker)
         then
            return Passed;
         else
            return Failed;
         end if;
      elsif Done.Exit_Code = 0
        and then (Failure_Marker = ""
                  or else Ada.Strings.Fixed.Index
                    (To_String (Output), Failure_Marker) = 0)
      then
         return Passed;
      else
         return Failed;
      end if;
   exception
      when AdaMutant.Processes.Spawn_Error =>
         return Spawn_Failed;
      when others =>
         return Spawn_Failed;
   end Test_Outcome;

   function Observation (Path : String) return String is
      Text : constant String := AdaMutant.Files.Read (Path);
      First : Natural := Text'First;
      Last  : Natural := Text'Last;
   begin
      while First <= Last and then Is_Space (Text (First)) loop
         First := First + 1;
      end loop;
      while Last >= First and then Is_Space (Text (Last)) loop
         Last := Last - 1;
      end loop;
      if First > Last then
         return "";
      end if;
      for I in First .. Last loop
         if Is_Space (Text (I)) then
            return "";
         end if;
      end loop;
      declare
         Value : constant String := Text (First .. Last);
      begin
         return (if Is_Integer_Literal (Value) then Value else "");
      end;
   exception
      when others =>
         return "";
   end Observation;

   function Id_Text (Id : Positive) return String is
     (Trimmed (Id'Image));

   function Executable (Name, Directory : String) return String is
      Path : constant String := Directory & "/" & Name
        & (if GNAT.OS_Lib.Directory_Separator = '\' then ".exe" else "");
   begin
      return Shell_Quote
        (Native_Path
           ((if Is_Absolute (Path) then ""
             elsif GNAT.OS_Lib.Directory_Separator = '/' then "./" else ".\")
            & Path));
   end Executable;

   function Build_Command (Project_File : String) return String is
     ("gprbuild -p -f -q -P " & Shell_Quote (Native_Path (Project_File)));

   procedure Generate
     (Root, File_Path, Source, Suggestion_Project, Report_Dir : String;
      Skip_Dirs : String_Vectors.Vector;
      Build_Timeout, Run_Timeout : Duration;
      M : in out Mutant;
      Memory_Limit_Mb : Natural := 0)
   is
      Work : Unbounded_String;
      Work_Original : Unbounded_String;
      Work_Mutant : Unbounded_String;
      Artifact_Dir : Unbounded_String;
      Artifact_Source : Unbounded_String;
      Artifact_Project : Unbounded_String;
      Artifact_Project_Command_Path : Unbounded_String;
      Probe_Name : Unbounded_String;
      Test_Name : Unbounded_String;
      Call : Unbounded_String;
      Candidate : Unbounded_String;
      Expected : Unbounded_String;
      Artifact_Source_Directories : String_Vectors.Vector;
      Project_Path : Unbounded_String;
      Project_Name : Unbounded_String;
      Skip : String_Vectors.Vector := Skip_Dirs;
      Info : Function_Info;
      Reason : Unbounded_String;
      Work_Project : Unbounded_String;
      Failure_Marker : Unbounded_String;
      Probe_Source_Path : Unbounded_String;
      Test_Source_Path : Unbounded_String;
      Probe_GPR : Unbounded_String;
      Original_GPR : Unbounded_String;
      Mutant_GPR : Unbounded_String;
      Probe_Exe : Unbounded_String;
      Original_Exe : Unbounded_String;
      Mutant_Exe : Unbounded_String;
      Outcome : Verification_Outcome;
      Arg_List : Unbounded_String;
      Id : constant String := Id_Text (M.Id);

      function Bounded_Run_Timeout (Timeout : Duration) return Duration is
        (if Timeout <= 0.0 then 5.0
         elsif Timeout > 30.0 then 30.0
         else Timeout);

      function Relative_To_Root (Path : String) return String is
         Root_Full : constant String := Ada.Directories.Full_Name (Root);
         Path_Full : constant String := Ada.Directories.Full_Name (Path);
         Prefix : constant String :=
           (if Root_Full (Root_Full'Last) = GNAT.OS_Lib.Directory_Separator
            then Root_Full
            else Root_Full & GNAT.OS_Lib.Directory_Separator);
      begin
         if Path_Full'Length > Prefix'Length
           and then To_Lower
             (Path_Full (Path_Full'First .. Path_Full'First + Prefix'Length - 1))
             = To_Lower (Prefix)
         then
            return Path_Full (Path_Full'First + Prefix'Length .. Path_Full'Last);
         else
            return Path_Full;
         end if;
      end Relative_To_Root;

      function GPR_Source_Directories return String_Vectors.Vector is
         Log : constant String :=
           AdaMutant.Files.Join (To_String (Work_Original), "project-inspect.log");
         Done : AdaMutant.Processes.Run_Result;
         Document : GNATCOLL.JSON.JSON_Value;
         Projects : GNATCOLL.JSON.JSON_Array;
         Root_Id : Unbounded_String;
         Result : String_Vectors.Vector;
      begin
         Done := AdaMutant.Processes.Run
           (Command => "gprinspect -P "
            & Shell_Quote (Native_Path (To_String (Project_Path)))
            & " --display=json --all",
            Directory => Root,
            Log_File => Log,
            Mutant_Id => M.Id,
            Timeout => Bounded_Run_Timeout (Build_Timeout),
            Memory_Limit_Mb => Memory_Limit_Mb,
            Mutant_File => File_Path,
            Mutant_Line => M.Start_Pos.Line);
         if Done.Timed_Out or else Done.Exit_Code /= 0 then
            raise Program_Error with "gprinspect failed to read suggestion_project";
         end if;
         Document := GNATCOLL.JSON.Read (AdaMutant.Files.Read (Log));
         declare
            Root_Id_Text : constant String := GNATCOLL.JSON.Get
              (GNATCOLL.JSON.Get
                 (GNATCOLL.JSON.Get (Document, "tree"), "root-project"), "id");
         begin
            Root_Id := To_Unbounded_String (Root_Id_Text);
         end;
         Projects := GNATCOLL.JSON.Get (Document, "projects");
         for Index in 1 .. GNATCOLL.JSON.Length (Projects) loop
            declare
               Project : constant GNATCOLL.JSON.JSON_Value :=
                 GNATCOLL.JSON.Get (Projects, Index);
               Info : constant GNATCOLL.JSON.JSON_Value :=
                 GNATCOLL.JSON.Get (Project, "project");
               Project_Id : constant String := GNATCOLL.JSON.Get (Info, "id");
            begin
               if Project_Id = To_String (Root_Id) then
                  declare
                     Dirs : constant GNATCOLL.JSON.JSON_Array :=
                       GNATCOLL.JSON.Get (Info, "source-directories");
                  begin
                     for Dir in 1 .. GNATCOLL.JSON.Length (Dirs) loop
                        declare
                           Value : constant GNATCOLL.JSON.JSON_Value :=
                             GNATCOLL.JSON.Get (Dirs, Dir);
                           Directory : constant String :=
                             GNATCOLL.JSON.Get (Value);
                        begin
                           Result.Append (Directory);
                        end;
                     end loop;
                  end;
                  return Result;
               end if;
            end;
         end loop;
         raise Program_Error with "gprinspect did not return root project sources";
      end GPR_Source_Directories;

      function GPR_Source_Directories_Text
        (Directories : String_Vectors.Vector) return String
      is
         Result : Unbounded_String;
      begin
         for Directory of Directories loop
            if Length (Result) > 0 then
               Append (Result, ", ");
            end if;
            Append (Result, GPR_String (Directory));
         end loop;
         return To_String (Result);
      end GPR_Source_Directories_Text;

      procedure Retain_Log (Stage, Directory : String) is
      begin
         if Directory'Length = 0 then
            return;
         end if;
         declare
            Source_Path : constant String :=
              AdaMutant.Files.Join (Directory, Stage & ".log");
            Target_Path : constant String := AdaMutant.Files.Join
              (Root, ".adamutant/logs/mutant-" & Id & "-" & Stage & ".log");
            Max_Length : constant Positive := 32_768;
         begin
            if not Ada.Directories.Exists (Source_Path) then
               return;
            end if;
            Ada.Directories.Create_Path
              (AdaMutant.Files.Join (Root, ".adamutant/logs"));
            declare
               Content : constant String := AdaMutant.Files.Read (Source_Path);
            begin
               if Content'Length > Max_Length then
                  AdaMutant.Files.Write
                    (Target_Path,
                     Content (Content'Last - Max_Length + 1 .. Content'Last));
               else
                  AdaMutant.Files.Write (Target_Path, Content);
               end if;
            end;
         exception
            when others =>
               null;
         end;
      end Retain_Log;

      procedure Retain_Work_Logs is
      begin
         if Length (Work_Original) > 0 then
            Retain_Log ("probe-build", To_String (Work_Original));
            Retain_Log ("probe-run", To_String (Work_Original));
            Retain_Log ("original-build", To_String (Work_Original));
            Retain_Log ("original-run", To_String (Work_Original));
         end if;
         if Length (Work_Mutant) > 0 then
            Retain_Log ("mutant-build", To_String (Work_Mutant));
            Retain_Log ("mutant-run", To_String (Work_Mutant));
         end if;
         if Length (Work_Original) > 0 then
            Retain_Log ("project-inspect", To_String (Work_Original));
         end if;
      end Retain_Work_Logs;

      procedure Fail (Message : String) is
      begin
         M.Suggestion.Status := Failed;
         M.Suggestion.Reason := To_Unbounded_String (Message);
         Retain_Work_Logs;
      end Fail;

      procedure Clean_Work is
      begin
         if Length (Work) > 0 then
            AdaMutant.Files.Delete_Tree (To_String (Work));
         end if;
      exception
         when others =>
            null;
      end Clean_Work;

      function Complete (Outcome : Verification_Outcome) return Boolean is
        (Outcome = Passed);

      function Artifact_Command return String is
      begin
         return Build_Command (To_String (Artifact_Project_Command_Path))
           & " && " & Executable
             ("suggestion_mutant_" & Id,
              AdaMutant.Files.Join
                (Relative_To_Root (To_String (Artifact_Dir)),
                 "build/mutant-" & Id & "/bin"));
      end Artifact_Command;

   begin
      M.Has_Suggestion := True;
      M.Suggestion := (others => <>);
      if M.Evidence /= Confirmed or else M.Killed_By /= Proof then
         M.Suggestion.Status := Ineligible;
         M.Suggestion.Reason := To_Unbounded_String
           ("only confirmed proof-only mutants are eligible");
         return;
      end if;
      if Suggestion_Project = "" then
         M.Suggestion.Status := Ineligible;
         M.Suggestion.Reason := To_Unbounded_String
           ("suggestion_project is not configured");
         return;
      end if;
      if Is_Absolute (Suggestion_Project) then
         M.Suggestion.Status := Unsupported;
         M.Suggestion.Reason := To_Unbounded_String
           ("suggestion_project must be relative to the project root for isolated verification");
         return;
      end if;
      Project_Path := To_Unbounded_String
        (AdaMutant.Files.Join (Root, Suggestion_Project));
      if not Ada.Directories.Exists (To_String (Project_Path)) then
         M.Suggestion.Probe_Build := Build_Failed;
         Fail ("the configured suggestion_project does not exist");
         return;
      end if;
      if not Is_Within (Root, To_String (Project_Path)) then
         M.Suggestion.Status := Unsupported;
         M.Suggestion.Reason := To_Unbounded_String
           ("suggestion_project must stay inside the project root for isolated verification");
         return;
      end if;
      Project_Path := To_Unbounded_String
        (Ada.Directories.Full_Name (To_String (Project_Path)));
      Project_Name := To_Unbounded_String
        (GPR_Project_Name (AdaMutant.Files.Read (To_String (Project_Path))));
      if Length (Project_Name) = 0 then
         M.Suggestion.Status := Unsupported;
         M.Suggestion.Reason := To_Unbounded_String
           ("the configured suggestion_project has no simple project declaration");
         return;
      end if;
      if not Identify (Root, File_Path, Skip_Dirs, M, Info, Reason) then
         M.Suggestion.Status := Unsupported;
         M.Suggestion.Reason := Reason;
         return;
      end if;
      Arg_List := Null_Unbounded_String;
      for I in 1 .. Natural (Info.Actuals.Length) loop
         if I > 1 then
            Append (Arg_List, ", ");
         end if;
         Append (Arg_List, Info.Actuals (I));
      end loop;
      Call := To_Unbounded_String
        (To_String (Info.Package_Name) & "." & To_String (Info.Function_Name)
         & " (" & To_String (Arg_List) & ")");
      Failure_Marker := To_Unbounded_String
        ("ADAMUTANT_SUGGESTION_FAILURE_" & Id);
      M.Suggestion.Call := Call;

      Work := To_Unbounded_String
        (AdaMutant.Files.Join
           (Root, ".adamutant/suggestion-work/mutant-" & Id));
      Work_Original := To_Unbounded_String
        (AdaMutant.Files.Join (To_String (Work), "original"));
      Work_Mutant := To_Unbounded_String
        (AdaMutant.Files.Join (To_String (Work), "mutant"));
      Skip.Append ("obj");
      Skip.Append ("bin");
      Skip.Append ("**/obj");
      Skip.Append ("**/bin");
      Skip.Append ("gnatprove");
      Skip.Append ("**/gnatprove");
      Clean_Work;
      Ada.Directories.Create_Path (To_String (Work));
      AdaMutant.Files.Copy_Tree (Root, To_String (Work_Original), Skip);
      AdaMutant.Files.Copy_Tree (Root, To_String (Work_Mutant), Skip);

      Probe_Name := To_Unbounded_String ("suggestion_probe_" & Id);
      Test_Name := To_Unbounded_String ("suggestion_mutant_" & Id);
      Probe_Source_Path := To_Unbounded_String
        (AdaMutant.Files.Join (To_String (Work_Original),
                               "suggestion-source/" & To_String (Probe_Name) & ".adb"));
      Test_Source_Path := To_Unbounded_String
        (AdaMutant.Files.Join (To_String (Work_Original),
                               "suggestion-source/" & To_String (Test_Name) & ".adb"));
      Ada.Directories.Create_Path
        (AdaMutant.Files.Join (To_String (Work_Original), "suggestion-source"));
      Ada.Directories.Create_Path
        (AdaMutant.Files.Join (To_String (Work_Mutant), "suggestion-source"));
      AdaMutant.Files.Write
        (To_String (Probe_Source_Path),
         Probe_Source (To_String (Probe_Name), To_String (Info.Package_Name),
                       To_String (Call)));
      Probe_GPR := To_Unbounded_String
        (AdaMutant.Files.Join (To_String (Work_Original), "suggestion_probe_" & Id & ".gpr"));
      Work_Project := To_Unbounded_String (Suggestion_Project);
      AdaMutant.Files.Write
        (To_String (Probe_GPR),
         GPR_Source ("Suggestion_Probe_" & Id, To_String (Work_Project),
                     To_String (Project_Name), "suggestion-source",
                     To_String (Probe_Name) & ".adb",
                     "obj/suggestion-probe-" & Id,
                     "bin/suggestion-probe-" & Id));
      Probe_Exe := To_Unbounded_String
        (Executable (To_String (Probe_Name), "bin/suggestion-probe-" & Id));
      Outcome := Build_Outcome
        (Build_Command (AdaMutant.Files.Join
           (".", "suggestion_probe_" & Id & ".gpr")),
         To_String (Work_Original),
         AdaMutant.Files.Join (To_String (Work_Original), "probe-build.log"),
         Build_Timeout, Memory_Limit_Mb, M, File_Path);
      M.Suggestion.Probe_Build := Outcome;
      if not Complete (Outcome) then
         Fail ("the original-source probe did not build (" & Name (Outcome) & ")");
         Clean_Work;
         return;
      end if;
      Outcome := Test_Outcome
        (To_String (Probe_Exe), To_String (Work_Original),
         AdaMutant.Files.Join (To_String (Work_Original), "probe-run.log"),
         Bounded_Run_Timeout (Run_Timeout), Memory_Limit_Mb,
         M, File_Path, False);
      M.Suggestion.Probe_Run := Outcome;
      if not Complete (Outcome) then
         Fail ("the original-source probe did not run successfully (" & Name (Outcome) & ")");
         Clean_Work;
         return;
      end if;
      declare
         Value : constant String := Observation
           (AdaMutant.Files.Join (To_String (Work_Original), "probe-run.log"));
      begin
         if Value = "" then
            M.Suggestion.Probe_Run := Invalid_Output;
            Fail ("the original-source probe did not produce one integer observation");
            Clean_Work;
            return;
         end if;
         Expected := To_Unbounded_String (Value);
      end;
      M.Suggestion.Assertion := To_Unbounded_String
        (To_String (Call) & " = " & To_String (Expected));
      Candidate := To_Unbounded_String
        (Candidate_Source (To_String (Test_Name), To_String (Info.Package_Name),
                           To_String (Info.Function_Name), To_String (Arg_List),
                           To_String (Expected), To_String (Failure_Marker),
                           To_String (Info.Result_Type_Name),
                           To_String (Info.Result_Type_Package)));
      AdaMutant.Files.Write (To_String (Test_Source_Path), To_String (Candidate));
      Original_GPR := To_Unbounded_String
        (AdaMutant.Files.Join (To_String (Work_Original), "suggestion_original_" & Id & ".gpr"));
      AdaMutant.Files.Write
        (To_String (Original_GPR),
         GPR_Source ("Suggestion_Original_" & Id, To_String (Work_Project),
                     To_String (Project_Name), "suggestion-source",
                     To_String (Test_Name) & ".adb",
                     "obj/suggestion-original-" & Id,
                     "bin/suggestion-original-" & Id));
      Outcome := Build_Outcome
        (Build_Command ("suggestion_original_" & Id & ".gpr"),
         To_String (Work_Original),
         AdaMutant.Files.Join (To_String (Work_Original), "original-build.log"),
         Build_Timeout, Memory_Limit_Mb, M, File_Path);
      M.Suggestion.Assertion_Build := Outcome;
      if not Complete (Outcome) then
         Fail ("the candidate test did not build against the original (" & Name (Outcome) & ")");
         Clean_Work;
         return;
      end if;
      Original_Exe := To_Unbounded_String
        (Executable (To_String (Test_Name), "bin/suggestion-original-" & Id));
      Outcome := Test_Outcome
        (To_String (Original_Exe), To_String (Work_Original),
         AdaMutant.Files.Join (To_String (Work_Original), "original-run.log"),
         Bounded_Run_Timeout (Run_Timeout), Memory_Limit_Mb,
         M, File_Path, False, To_String (Failure_Marker));
      M.Suggestion.Original_Run := Outcome;
      if not Complete (Outcome) then
         Fail ("the candidate test did not pass against the original (" & Name (Outcome) & ")");
         Clean_Work;
         return;
      end if;

      AdaMutant.Files.Write_Changed
        (AdaMutant.Files.Join (To_String (Work_Mutant), File_Path),
         AdaMutant.Mutators.Apply (Source, M.Mutation));
      AdaMutant.Files.Write
        (AdaMutant.Files.Join
           (To_String (Work_Mutant), "suggestion-source/" & To_String (Test_Name) & ".adb"),
         To_String (Candidate));
      Mutant_GPR := To_Unbounded_String
        (AdaMutant.Files.Join (To_String (Work_Mutant), "suggestion_mutant_" & Id & ".gpr"));
      AdaMutant.Files.Write
        (To_String (Mutant_GPR),
         GPR_Source ("Suggestion_Mutant_" & Id, To_String (Work_Project),
                     To_String (Project_Name), "suggestion-source",
                     To_String (Test_Name) & ".adb",
                     "obj/suggestion-mutant-" & Id,
                     "bin/suggestion-mutant-" & Id));
      Outcome := Build_Outcome
        (Build_Command ("suggestion_mutant_" & Id & ".gpr"),
         To_String (Work_Mutant),
         AdaMutant.Files.Join (To_String (Work_Mutant), "mutant-build.log"),
         Build_Timeout, Memory_Limit_Mb, M, File_Path);
      M.Suggestion.Mutant_Build := Outcome;
      if not Complete (Outcome) then
         Fail ("the candidate test did not build against the exact mutant (" & Name (Outcome) & ")");
         Clean_Work;
         return;
      end if;
      Mutant_Exe := To_Unbounded_String
        (Executable (To_String (Test_Name), "bin/suggestion-mutant-" & Id));
      Outcome := Test_Outcome
        (To_String (Mutant_Exe), To_String (Work_Mutant),
         AdaMutant.Files.Join (To_String (Work_Mutant), "mutant-run.log"),
         Bounded_Run_Timeout (Run_Timeout), Memory_Limit_Mb,
         M, File_Path, True, To_String (Failure_Marker));
      M.Suggestion.Mutant_Run := Outcome;
      if not Complete (Outcome) then
         Fail ("the candidate test did not detect the exact mutant (" & Name (Outcome) & ")");
         Clean_Work;
         return;
      end if;

      if Is_Absolute (Report_Dir) then
         Artifact_Dir := To_Unbounded_String
           (AdaMutant.Files.Join (Report_Dir, "suggestions"));
      else
         Artifact_Dir := To_Unbounded_String
           (AdaMutant.Files.Join (Root, Report_Dir & "/suggestions"));
      end if;
      Ada.Directories.Create_Path (To_String (Artifact_Dir));
      Artifact_Dir := To_Unbounded_String
        (Ada.Directories.Full_Name (To_String (Artifact_Dir)));
      Artifact_Source_Directories.Append (To_String (Artifact_Dir));
      for Directory of GPR_Source_Directories loop
         Artifact_Source_Directories.Append (Directory);
      end loop;
      Artifact_Source := To_Unbounded_String
        (AdaMutant.Files.Join (To_String (Artifact_Dir), "suggestion_mutant_" & Id & ".adb"));
      Artifact_Project := To_Unbounded_String
        (AdaMutant.Files.Join (To_String (Artifact_Dir), "mutant-" & Id & ".gpr"));
      Artifact_Project_Command_Path := To_Unbounded_String
        ((if Is_Absolute (Report_Dir)
          then To_String (Artifact_Project)
          else Relative_To_Root (To_String (Artifact_Project))));
      AdaMutant.Files.Write (To_String (Artifact_Source), To_String (Candidate));
      AdaMutant.Files.Write
        (To_String (Artifact_Project),
         GPR_Source
           ("Suggestion_Mutant_" & Id,
            To_String (Project_Path),
            To_String (Project_Name), ".",
            To_String (Test_Name) & ".adb",
            "build/mutant-" & Id & "/obj",
            "build/mutant-" & Id & "/bin",
            GPR_Source_Directories_Text (Artifact_Source_Directories)));
      M.Suggestion.Status := Verified;
      M.Suggestion.Reason := To_Unbounded_String
        ("the candidate passed on the original and failed on the exact mutant");
      M.Suggestion.Artifact_Path := To_Unbounded_String
        (if Is_Absolute (Report_Dir)
         then To_String (Artifact_Source)
         else Relative_To_Root (To_String (Artifact_Source)));
      M.Suggestion.Project_Path := To_Unbounded_String
        (if Is_Absolute (Report_Dir)
         then To_String (Artifact_Project)
         else Relative_To_Root (To_String (Artifact_Project)));
      M.Suggestion.Command := To_Unbounded_String (Artifact_Command);
      Clean_Work;
   exception
      when E : others =>
         Fail (Ada.Exceptions.Exception_Name (E) & ": "
               & Ada.Exceptions.Exception_Message (E));
         Clean_Work;
   end Generate;

end AdaMutant.Suggestions;
