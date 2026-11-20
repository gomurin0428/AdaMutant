with Ada.Characters.Handling; use Ada.Characters.Handling;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Strings.Fixed;
with Ada.Strings.UTF_Encoding.Wide_Wide_Strings;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with GNATCOLL.JSON;
with GNATCOLL.GMP.Integers;
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
     (Procedure_Name, Package_Name, Result_Type, Type_Package, Call : String)
      return String
   is
   begin
      return "with Ada.Text_IO;" & LF
        & "with " & Package_Name & ";" & LF
        & (if Type_Package'Length = 0
             or else To_Lower (Type_Package) = To_Lower (Package_Name)
           then ""
           else "with " & Type_Package & ";" & LF)
        & "procedure " & Procedure_Name & " is" & LF
        & "begin" & LF
        & "   Ada.Text_IO.Put_Line (" & Result_Type & "'Image (" & Call & "));"
        & LF
        & "end " & Procedure_Name & ";" & LF;
   end Probe_Source;

   function Small_Integer (Index : Positive) return String is
   begin
      case Index is
         when 1 => return "0";
         when 2 => return "1";
         when 3 => return "-1";
         when 4 => return "2";
         when 5 => return "-2";
         when 6 => return "3";
         when 7 => return "-3";
         when others => return "";
      end case;
   end Small_Integer;

   function Search_Id_Text (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   function Search_Probe_Source
     (Procedure_Name, Package_Name, Function_Name, Result_Type : String;
      Formal_Types, Type_Packages, Type_Constraints,
        Formal_Type_Ranges : String_Vectors.Vector)
      return String
   is
      Result : Unbounded_String;
      Withs  : String_Vectors.Vector;

      procedure Add_With (Name : String) is
      begin
         if Name'Length > 0
           and then (for all Existing of Withs =>
                       To_Lower (Existing) /= To_Lower (Name))
         then
            Withs.Append (Name);
         end if;
      end Add_With;

   begin
      Add_With (Package_Name);
      for Name of Type_Packages loop
         Add_With (Name);
      end loop;
      Append (Result, "with Ada.Assertions;" & LF
              & "with Ada.Command_Line;" & LF
              & "with Ada.Text_IO;" & LF);
      for Name of Withs loop
         Append (Result, "with " & Name & ";" & LF);
      end loop;
      Append (Result, "procedure " & Procedure_Name & " is" & LF);
      for I in 1 .. Natural (Formal_Types.Length) loop
         declare
            Suffix : constant String := Search_Id_Text (I);
            Formal_Type : constant String := Formal_Types (I);
            Constraint  : constant String := Type_Constraints (I);
            Range_Constraint : constant String := Formal_Type_Ranges (I);
         begin
            Append (Result, "   subtype Search_Argument_" & Suffix & " is "
                    & Formal_Type
                    & (if Constraint'Length = 0 then ""
                       else " " & Constraint) & ";" & LF
                    & "   use type Search_Argument_" & Suffix & ";" & LF
                    & "   subtype Search_Declared_Bounds_" & Suffix & " is "
                    & "Search_Argument_" & Suffix & "'Base "
                    & Range_Constraint & ";" & LF
                    & "   subtype Search_Bounds_" & Suffix & " is "
                    & "Search_Declared_Bounds_" & Suffix
                    & (if Constraint'Length = 0 then ""
                       else " " & Constraint) & ";" & LF
                    & "   type Search_Values_" & Suffix
                    & " is array (Positive range 1 .. 11) of Search_Argument_"
                    & Suffix & ";" & LF
                    & "   procedure List_" & Suffix & " is" & LF
                    & "      Values : Search_Values_" & Suffix & ";" & LF
                    & "      Count : Natural := 0;" & LF
                    & "      procedure Add (Value : Search_Argument_" & Suffix
                    & ") is" & LF
                    & "      begin" & LF
                    & "         for K in 1 .. Count loop" & LF
                    & "            if Values (K) = Value then" & LF
                    & "               return;" & LF
                    & "            end if;" & LF
                    & "         end loop;" & LF
                    & "         Count := Count + 1;" & LF
                    & "         Values (Count) := Value;" & LF
                    & "      end Add;" & LF
                    & "      procedure Add_Text (Value : String) is" & LF
                    & "      begin" & LF
                    & "         Add (Search_Argument_" & Suffix
                    & "'Value (Value));" & LF
                    & "      exception" & LF
                    & "         when Constraint_Error | Ada.Assertions.Assertion_Error => null;"
                    & LF
                    & "      end Add_Text;" & LF
                    & "      procedure Add_First is" & LF
                    & "      begin" & LF
                    & "         Add (Search_Bounds_" & Suffix & "'First);" & LF
                    & "      exception" & LF
                    & "         when Constraint_Error | Ada.Assertions.Assertion_Error => null;"
                    & LF
                    & "      end Add_First;" & LF
                    & "      procedure Add_Last is" & LF
                    & "      begin" & LF
                    & "         Add (Search_Bounds_" & Suffix & "'Last);" & LF
                    & "      exception" & LF
                    & "         when Constraint_Error | Ada.Assertions.Assertion_Error => null;"
                    & LF
                    & "      end Add_Last;" & LF
                    & "      procedure Add_Succ_First is" & LF
                    & "      begin" & LF
                    & "         if Search_Bounds_" & Suffix & "'First < Search_Bounds_"
                    & Suffix & "'Last then" & LF
                    & "            Add (Search_Bounds_" & Suffix
                    & "'Succ (Search_Bounds_" & Suffix & "'First));" & LF
                    & "         end if;" & LF
                    & "      exception" & LF
                    & "         when Constraint_Error | Ada.Assertions.Assertion_Error => null;"
                    & LF
                    & "      end Add_Succ_First;" & LF
                    & "      procedure Add_Pred_Last is" & LF
                    & "      begin" & LF
                    & "         if Search_Bounds_" & Suffix & "'First < Search_Bounds_"
                    & Suffix & "'Last then" & LF
                    & "            Add (Search_Bounds_" & Suffix
                    & "'Pred (Search_Bounds_" & Suffix & "'Last));" & LF
                    & "         end if;" & LF
                    & "      exception" & LF
                    & "         when Constraint_Error | Ada.Assertions.Assertion_Error => null;"
                    & LF
                    & "      end Add_Pred_Last;" & LF
                    & "   begin" & LF);
            for Value_Index in 1 .. 7 loop
               declare
                  Value : constant String := Small_Integer (Value_Index);
               begin
                  Append (Result, "      Add_Text (""" & Value & """);" & LF);
               end;
            end loop;
            Append (Result, "      Add_First;" & LF
                    & "      Add_Last;" & LF
                    & "      Add_Succ_First;" & LF
                    & "      Add_Pred_Last;" & LF
                    & "      for K in 1 .. Count loop" & LF
                    & "         Ada.Text_IO.Put_Line" & LF
                    & "           (""ADAMUTANT_SEARCH_VALUE:""" & LF
                    & "            & Search_Argument_" & Suffix
                    & "'Image (Values (K)));" & LF
                    & "      end loop;" & LF
                    & "   end List_" & Suffix & ";" & LF);
         end;
      end loop;
      Append (Result, "begin" & LF
              & "   if Ada.Command_Line.Argument_Count = 2" & LF
              & "     and then Ada.Command_Line.Argument (1) = ""--values""" & LF
              & "   then" & LF
              & "      case Positive'Value (Ada.Command_Line.Argument (2)) is" & LF);
      for I in 1 .. Natural (Formal_Types.Length) loop
         Append (Result, "         when " & Search_Id_Text (I) & " => List_"
                 & Search_Id_Text (I) & ";" & LF);
      end loop;
      Append (Result, "         when others =>" & LF
              & "            Ada.Command_Line.Set_Exit_Status" & LF
              & "              (Ada.Command_Line.Failure);" & LF
              & "      end case;" & LF
              & "      return;" & LF
              & "   end if;" & LF
              & "   if Ada.Command_Line.Argument_Count /= "
              & Search_Id_Text (Natural (Formal_Types.Length)) & " then" & LF
              & "      Ada.Command_Line.Set_Exit_Status" & LF
              & "        (Ada.Command_Line.Failure);" & LF
              & "      return;" & LF
              & "   end if;" & LF
              & "   Ada.Text_IO.Put_Line" & LF
              & "     (""ADAMUTANT_SEARCH_RESULT:"" & " & Result_Type
              & "'Image (" & Package_Name & "." & Function_Name & " (" & LF);
      for I in 1 .. Natural (Formal_Types.Length) loop
         Append (Result, "        Search_Argument_" & Search_Id_Text (I)
                 & "'Value (Ada.Command_Line.Argument (" & Search_Id_Text (I) & "))"
                 & (if I = Natural (Formal_Types.Length) then ")));" & LF
                    else "," & LF));
      end loop;
      Append (Result, "end " & Procedure_Name & ";" & LF);
      return To_String (Result);
   end Search_Probe_Source;

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
      if Type_Expr.Is_Null
        or else Type_Expr.Kind not in LC.Ada_Subtype_Indication
                                      | LC.Ada_Constrained_Subtype_Indication
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
      Type_Name, Type_Package : out Unbounded_String;
      Range_Constraint : out Unbounded_String;
      Need_Range : Boolean := False) return Boolean
   is
      Name : LAL.Name;
      Decl : LAL.Basic_Decl;
      Type_Decl : LAL.Base_Type_Decl;
      Current : LAL.Ada_Node;
      Package_Path : Unbounded_String;
      Simple_Name : Unbounded_String;
      Bounds : LAL.Discrete_Range;
      Low, High : LAL.Expr;
   begin
      Type_Name := Null_Unbounded_String;
      Type_Package := Null_Unbounded_String;
      Range_Constraint := Null_Unbounded_String;
      if Type_Expr.Is_Null
        or else Type_Expr.Kind not in LC.Ada_Subtype_Indication
                                      | LC.Ada_Constrained_Subtype_Indication
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
      if Need_Range then
         Bounds := Type_Decl.P_Discrete_Range;
         Low := LAL.Low_Bound (Bounds).As_Expr;
         High := LAL.High_Bound (Bounds).As_Expr;
         if Low.Is_Null or else High.Is_Null
           or else not Low.P_Is_Static_Expr
           or else not High.P_Is_Static_Expr
         then
            return False;
         end if;
         Range_Constraint := To_Unbounded_String
           ("range "
            & Trimmed (GNATCOLL.GMP.Integers.Image (Low.P_Eval_As_Int))
            & " .. "
            & Trimmed (GNATCOLL.GMP.Integers.Image (High.P_Eval_As_Int)));
      end if;
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
      Formal_Type_Names   : String_Vectors.Vector;
      Formal_Type_Packages : String_Vectors.Vector;
      Formal_Type_Constraints : String_Vectors.Vector;
      Formal_Type_Ranges : String_Vectors.Vector;
      Actuals             : String_Vectors.Vector;
   end record;

   function Identify
     (Root, File_Path : String;
      Skip_Dirs : String_Vectors.Vector;
      M : Mutant;
      Info : out Function_Info;
      Reason : out Unbounded_String;
      Require_Bindings : Boolean := True) return Boolean
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
      Result_Type_Range : Unbounded_String;
      Body_Formals : String_Vectors.Vector;
      Formal_Index : Natural := 0;
      Visible_Count : Natural := 0;
      All_Count : Natural := 0;
      Found_Visible : LAL.Ada_Node := LAL.No_Ada_Node;

      function In_Candidate_Package_Scope
        (N : LAL.Ada_Node'Class) return Boolean
      is
         Current : LAL.Ada_Node := N.Parent;
      begin
         while not Current.Is_Null loop
            if Current.Kind = LC.Ada_Package_Decl then
               return LAL."=" (Current, Package_Decl.As_Ada_Node);
            elsif Current.Kind in LC.Ada_Subp_Body | LC.Ada_Expr_Function
              | LC.Ada_Generic_Subp_Internal | LC.Ada_Package_Body
            then
               return False;
            end if;
            Current := Current.Parent;
         end loop;
         return False;
      end In_Candidate_Package_Scope;

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
         if In_Candidate_Package_Scope (N)
           and then To_Lower (Subprogram_Name (N)) = To_Lower (To_String (Function_Name))
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
         if In_Candidate_Package_Scope (N)
           and then To_Lower (Subprogram_Name (N)) = To_Lower (To_String (Function_Name))
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

      Subp_Spec := Found_Visible.As_Classic_Subp_Decl.F_Subp_Spec;
      if not Integer_Type_Info
         (Found_Visible.As_Classic_Subp_Decl.F_Subp_Spec.F_Subp_Returns,
         Info.Result_Type_Name, Info.Result_Type_Package,
         Result_Type_Range)
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
      if Require_Bindings then
         declare
            Body_Spec : constant LAL.Subp_Spec :=
              Candidate_Node.As_Base_Subp_Body.F_Subp_Spec;
         begin
            if Body_Spec.Is_Null or else Body_Spec.F_Subp_Params.Is_Null then
               Reason := To_Unbounded_String
                 ("the function body has no matching formal parameters");
               return False;
            end if;
            declare
               Body_Params : constant LAL.Param_Spec_List :=
                 Body_Spec.F_Subp_Params.F_Params;
            begin
               for K in 1 .. LAL.Children_Count (Body_Params) loop
                  declare
                     Ids : constant LAL.Defining_Name_List :=
                       LAL.Child (Body_Params, K).As_Param_Spec.F_Ids;
                  begin
                     for J in 1 .. LAL.Children_Count (Ids) loop
                        Body_Formals.Append
                          (Text_Of
                             (LAL.Child (Ids, J).As_Defining_Name.F_Name));
                     end loop;
                  end;
               end loop;
            end;
         end;
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
               Type_Name : Unbounded_String;
               Type_Package : Unbounded_String;
               Type_Constraint : Unbounded_String;
               Type_Range : Unbounded_String;
            begin
               if not Mode.Is_Null
                 and then Mode.Kind not in LC.Ada_Mode_Default | LC.Ada_Mode_In
               then
                  Reason := To_Unbounded_String
                    ("only in-mode integer parameters are supported");
                  return False;
               end if;
               if not Is_Integer_Type (Type_Expr)
                 or else not Integer_Type_Info
                   (Type_Expr, Type_Name, Type_Package, Type_Range,
                    Need_Range => not Require_Bindings)
               then
                  Reason := To_Unbounded_String
                    ("a formal parameter is not a supported integer scalar type");
                  return False;
               end if;
               if Type_Expr.Kind in LC.Ada_Subtype_Indication
                                      | LC.Ada_Constrained_Subtype_Indication
                 and then not Type_Expr.As_Subtype_Indication.F_Constraint.Is_Null
               then
                  Type_Constraint := To_Unbounded_String
                    (Text_Of
                       (Type_Expr.As_Subtype_Indication.F_Constraint));
               end if;
               declare
                  Ids : constant LAL.Defining_Name_List := Param.F_Ids;
               begin
                  for J in 1 .. LAL.Children_Count (Ids) loop
                     Formal_Index := Formal_Index + 1;
                     if Require_Bindings then
                        if Formal_Index > Natural (Body_Formals.Length) then
                           Reason := To_Unbounded_String
                             ("the public declaration and function body have different formal parameters");
                           return False;
                        end if;
                        Info.Formals.Append (Body_Formals (Formal_Index));
                     else
                        Info.Formals.Append
                          (Text_Of
                             (LAL.Child (Ids, J).As_Defining_Name.F_Name));
                     end if;
                     Info.Formal_Type_Names.Append (To_String (Type_Name));
                     Info.Formal_Type_Packages.Append
                       (To_String (Type_Package));
                     Info.Formal_Type_Constraints.Append
                       (To_String (Type_Constraint));
                     Info.Formal_Type_Ranges.Append
                       (To_String (Type_Range));
                  end loop;
               end;
            end;
         end loop;
      end;
      if Require_Bindings
        and then Formal_Index /= Natural (Body_Formals.Length)
      then
         Reason := To_Unbounded_String
           ("the public declaration and function body have different formal parameters");
         return False;
      end if;
      Info.Package_Name := Package_Name;
      Info.Function_Name := Function_Name;
      if Require_Bindings
        and then not Parse_Bindings
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

   function Search_Build_Command (Project_File : String) return String is
     ("gprbuild -p -f -q -P " & Shell_Quote (Native_Path (Project_File))
      & " -cargs:Ada -gnata -gnato");

   procedure Search
     (Root, File_Path, Source, Search_Project : String;
      Skip_Dirs : String_Vectors.Vector;
      Build_Timeout, Run_Timeout, Budget : Duration;
      M : in out Mutant;
      Memory_Limit_Mb : Natural := 0)
   is
      use type Ada.Real_Time.Time;

      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Deadline : constant Ada.Real_Time.Time :=
        Started + Ada.Real_Time.To_Time_Span (Duration'Max (0.0, Budget));
      Work : Unbounded_String;
      Original_Dir : Unbounded_String;
      Mutant_Dir : Unbounded_String;
      Project_Path : Unbounded_String;
      Project_Name : Unbounded_String;
      Probe_Name : Unbounded_String;
      Probe_Source : Unbounded_String;
      Original_Project : Unbounded_String;
      Mutant_Project : Unbounded_String;
      Original_Executable : Unbounded_String;
      Mutant_Executable : Unbounded_String;
      Type_Packages : String_Vectors.Vector;
      Skip : String_Vectors.Vector := Skip_Dirs;
      Info : Function_Info;
      Reason : Unbounded_String;
      Expired : Boolean := False;
      Original_Successes : Natural := 0;
      Mutant_Successes : Natural := 0;
      Same_Outputs : Natural := 0;
      Mutant_Failures : Natural := 0;
      Max_Combinations : constant Natural := 256;
      Id : constant String := Id_Text (M.Id);

      function Remaining return Duration is
        (Duration'Max
           (0.0,
            Ada.Real_Time.To_Duration (Deadline - Ada.Real_Time.Clock)));

      function Search_Trim (Text : String) return String is
         First : Natural := Text'First;
         Last  : Natural := Text'Last;
      begin
         while First <= Last and then Is_Space (Text (First)) loop
            First := First + 1;
         end loop;
         while Last >= First and then Is_Space (Text (Last)) loop
            Last := Last - 1;
         end loop;
         return (if First > Last then "" else Text (First .. Last));
      end Search_Trim;

      function Is_Static_Range (Constraint : String) return Boolean is
         Text : constant String := Search_Trim (Constraint);
         Lower : constant String := To_Lower (Text);
         Bounds : Unbounded_String;
         Separator : Natural;
      begin
         if Text = "" then
            return True;
         elsif Lower'Length < 5 or else Lower (Lower'First .. Lower'First + 4)
           /= "range"
         then
            return False;
         end if;
         Bounds := To_Unbounded_String
           (Search_Trim (Text (Text'First + 5 .. Text'Last)));
         Separator := Ada.Strings.Fixed.Index (To_String (Bounds), "..");
         if Separator = 0 then
            return False;
         end if;
         declare
            Range_Text : constant String := To_String (Bounds);
            Left : constant String := Search_Trim
              (Range_Text (Range_Text'First .. Separator - 1));
            Right : constant String := Search_Trim
              (Range_Text (Separator + 2 .. Range_Text'Last));
         begin
            return Is_Integer_Literal (Left) and then Is_Integer_Literal (Right);
         end;
      end Is_Static_Range;

      function Bounded_Timeout (Configured : Duration) return Duration is
         Left : constant Duration := Remaining;
      begin
         if Configured <= 0.0 then
            return Left;
         end if;
         return Duration'Min (Left, Configured);
      end Bounded_Timeout;

      function Run_Child
        (Command, Directory, Log : String; Configured : Duration)
         return AdaMutant.Processes.Run_Result
      is
         Timeout : constant Duration := Bounded_Timeout (Configured);
      begin
         if Timeout < 0.001 then
            return (Exit_Code => -1, Timed_Out => True, Elapsed => 0.0);
         end if;
         return AdaMutant.Processes.Run
           (Command => Command,
            Directory => Directory,
            Log_File => Log,
            Mutant_Id => 0,
            Timeout => Timeout,
            Memory_Limit_Mb => Memory_Limit_Mb,
            Mutant_File => File_Path,
            Mutant_Line => M.Start_Pos.Line);
      exception
         when AdaMutant.Processes.Spawn_Error =>
            return (Exit_Code => -1, Timed_Out => False, Elapsed => 0.0);
      end Run_Child;

      function Marked_Result (Path : String) return String is
         Text : constant String := AdaMutant.Files.Read (Path);
         Marker : constant String := "ADAMUTANT_SEARCH_RESULT:";
         First : Natural := Text'First;
         Count : Natural := 0;
         Value : Unbounded_String;
      begin
         while First <= Text'Last loop
            declare
               Last : Natural := First;
               Line : Unbounded_String;
            begin
               while Last <= Text'Last and then Text (Last) /= ASCII.LF loop
                  Last := Last + 1;
               end loop;
               Line := To_Unbounded_String
                 (Search_Trim
                    (if Last = First then ""
                     else Text (First .. Last - 1)));
               declare
                  Line_Text_Value : constant String := To_String (Line);
               begin
                  if Line_Text_Value'Length >= Marker'Length
                    and then Line_Text_Value
                      (1 .. Marker'Length) = Marker
                  then
                     declare
                        Found : constant String := Search_Trim
                          (if Line_Text_Value'Length = Marker'Length then ""
                           else Line_Text_Value
                             (Marker'Length + 1 .. Line_Text_Value'Last));
                     begin
                        if Count > 0 or else not Is_Integer_Literal (Found) then
                           return "";
                        end if;
                        Count := Count + 1;
                        Value := To_Unbounded_String (Found);
                     end;
                  end if;
               end;
               First := Last + 1;
            end;
         end loop;
         return (if Count = 1 then To_String (Value) else "");
      exception
         when others =>
            return "";
      end Marked_Result;

      procedure Read_Candidate_Values
        (Path : String; Values : out String_Vectors.Vector;
         Valid : out Boolean)
      is
         Text : constant String := AdaMutant.Files.Read (Path);
         Marker : constant String := "ADAMUTANT_SEARCH_VALUE:";
         First : Natural := Text'First;
      begin
         Values := String_Vectors.Empty_Vector;
         Valid := True;
         while First <= Text'Last loop
            declare
               Last : Natural := First;
               Line : Unbounded_String;
            begin
               while Last <= Text'Last and then Text (Last) /= ASCII.LF loop
                  Last := Last + 1;
               end loop;
               Line := To_Unbounded_String
                 (Search_Trim
                    (if Last = First then ""
                     else Text (First .. Last - 1)));
               declare
                  Line_Text_Value : constant String := To_String (Line);
               begin
                  if Line_Text_Value'Length >= Marker'Length
                    and then Line_Text_Value
                      (1 .. Marker'Length) = Marker
                  then
                     declare
                        Value : constant String := Search_Trim
                          (if Line_Text_Value'Length = Marker'Length then ""
                           else Line_Text_Value
                             (Marker'Length + 1 .. Line_Text_Value'Last));
                     begin
                        if not Is_Integer_Literal (Value) then
                           Valid := False;
                           return;
                        end if;
                        if not (for some Existing of Values => Existing = Value) then
                           Values.Append (Value);
                        end if;
                     end;
                  end if;
               end;
               First := Last + 1;
            end;
         end loop;
         Valid := not Values.Is_Empty;
      exception
         when others =>
            Values := String_Vectors.Empty_Vector;
            Valid := False;
      end Read_Candidate_Values;

      procedure Inconclusive (Text : String) is
      begin
         M.Input_Search.Status := Search_Inconclusive;
         M.Input_Search.Reason := To_Unbounded_String (Text);
      end Inconclusive;

      procedure Clean_Work is
      begin
         if Length (Work) > 0 then
            AdaMutant.Files.Delete_Tree (To_String (Work));
         end if;
      exception
         when others =>
            null;
      end Clean_Work;

   begin
      M.Input_Search := (others => <>);
      if M.Status /= Survived then
         return;
      elsif Budget <= 0.0 then
         return;
      elsif Search_Project = "" then
         Inconclusive ("search_project is not configured");
         return;
      elsif Is_Absolute (Search_Project) then
         Inconclusive ("search_project must be relative to the project root");
         return;
      end if;

      Project_Path := To_Unbounded_String
        (AdaMutant.Files.Join (Root, Search_Project));
      if not Ada.Directories.Exists (To_String (Project_Path))
        or else not Is_Within (Root, To_String (Project_Path))
      then
         Inconclusive ("the configured search_project does not exist inside the project root");
         return;
      end if;
      Project_Path := To_Unbounded_String
        (Ada.Directories.Full_Name (To_String (Project_Path)));
      Project_Name := To_Unbounded_String
        (GPR_Project_Name (AdaMutant.Files.Read (To_String (Project_Path))));
      if Length (Project_Name) = 0 then
         Inconclusive ("the configured search_project has no simple project declaration");
         return;
      end if;
      Skip.Append (".adamutant");
      Skip.Append ("**/.adamutant");
      Skip.Append (".git");
      Skip.Append ("**/.git");
      Skip.Append ("obj");
      Skip.Append ("bin");
      Skip.Append ("**/obj");
      Skip.Append ("**/bin");
      Skip.Append ("gnatprove");
      Skip.Append ("**/gnatprove");
      if not Identify (Root, File_Path, Skip, M, Info, Reason,
                       Require_Bindings => False)
      then
         Inconclusive (To_String (Reason));
         return;
      end if;
      if Info.Formals.Is_Empty then
         Inconclusive ("functions without integer inputs are unsupported");
         return;
      elsif Natural (Info.Formals.Length) > 16 then
         Inconclusive ("functions with more than 16 integer inputs are unsupported");
         return;
      end if;
      for Constraint of Info.Formal_Type_Constraints loop
         if not Is_Static_Range (Constraint) then
            Inconclusive ("a formal parameter has an unsupported non-static range constraint");
            return;
         end if;
      end loop;
      for Formal_Range of Info.Formal_Type_Ranges loop
         if Formal_Range = "" then
            Inconclusive
              ("a formal parameter has an unsupported non-static declared range");
            return;
         end if;
      end loop;
      if Remaining < 0.001 then
         Expired := True;
         Inconclusive ("the search budget expired during function identification");
         return;
      end if;

      Work := To_Unbounded_String
        (AdaMutant.Files.Join
           (Root, ".adamutant/input-search/mutant-" & Id));
      Original_Dir := To_Unbounded_String
        (AdaMutant.Files.Join (To_String (Work), "original"));
      Mutant_Dir := To_Unbounded_String
        (AdaMutant.Files.Join (To_String (Work), "mutant"));
      Clean_Work;
      Ada.Directories.Create_Path (To_String (Work));
      if Remaining < 0.001 then
         Expired := True;
         Inconclusive ("the search budget expired before copying the project");
         Clean_Work;
         return;
      end if;
      AdaMutant.Files.Copy_Tree (Root, To_String (Original_Dir), Skip);
      if Remaining < 0.001 then
         Expired := True;
         Inconclusive ("the search budget expired while copying the project");
         Clean_Work;
         return;
      end if;
      AdaMutant.Files.Copy_Tree (Root, To_String (Mutant_Dir), Skip);
      AdaMutant.Files.Write
        (AdaMutant.Files.Join (To_String (Mutant_Dir), File_Path),
         AdaMutant.Mutators.Apply (Source, M.Mutation));

      for Package_Name of Info.Formal_Type_Packages loop
         Type_Packages.Append (Package_Name);
      end loop;
      Type_Packages.Append (To_String (Info.Result_Type_Package));
      Probe_Name := To_Unbounded_String ("adamutant_search_probe_" & Id);
      Probe_Source := To_Unbounded_String
        (Search_Probe_Source
           (To_String (Probe_Name),
            To_String (Info.Package_Name),
            To_String (Info.Function_Name),
            To_String (Info.Result_Type_Name),
            Info.Formal_Type_Names,
            Type_Packages,
            Info.Formal_Type_Constraints,
            Info.Formal_Type_Ranges));
      if Remaining < 0.001 then
         Expired := True;
         Inconclusive ("the search budget expired while creating probe sources");
         Clean_Work;
         return;
      end if;
      Ada.Directories.Create_Path
        (AdaMutant.Files.Join (To_String (Original_Dir), "search-source"));
      AdaMutant.Files.Write
        (AdaMutant.Files.Join
           (To_String (Original_Dir),
            "search-source/" & To_String (Probe_Name) & ".adb"),
         To_String (Probe_Source));
      if Remaining < 0.001 then
         Expired := True;
         Inconclusive ("the search budget expired while creating probe sources");
         Clean_Work;
         return;
      end if;
      Ada.Directories.Create_Path
        (AdaMutant.Files.Join (To_String (Mutant_Dir), "search-source"));
      AdaMutant.Files.Write
        (AdaMutant.Files.Join
           (To_String (Mutant_Dir),
            "search-source/" & To_String (Probe_Name) & ".adb"),
         To_String (Probe_Source));

      Original_Project := To_Unbounded_String
        (AdaMutant.Files.Join
           (".", "adamutant_search_original_" & Id & ".gpr"));
      Mutant_Project := To_Unbounded_String
        (AdaMutant.Files.Join
           (".", "adamutant_search_mutant_" & Id & ".gpr"));
      AdaMutant.Files.Write
        (AdaMutant.Files.Join
           (To_String (Original_Dir), To_String (Original_Project)),
         GPR_Source
           ("AdaMutant_Search_Original_" & Id,
            Search_Project,
            To_String (Project_Name),
            "search-source",
            To_String (Probe_Name) & ".adb",
            "obj/search-original-" & Id,
            "bin/search-original-" & Id));
      if Remaining < 0.001 then
         Expired := True;
         Inconclusive ("the search budget expired while creating probe projects");
         Clean_Work;
         return;
      end if;
      AdaMutant.Files.Write
        (AdaMutant.Files.Join
           (To_String (Mutant_Dir), To_String (Mutant_Project)),
         GPR_Source
           ("AdaMutant_Search_Mutant_" & Id,
            Search_Project,
            To_String (Project_Name),
            "search-source",
            To_String (Probe_Name) & ".adb",
            "obj/search-mutant-" & Id,
            "bin/search-mutant-" & Id));
      Original_Executable := To_Unbounded_String
        (Executable (To_String (Probe_Name), "bin/search-original-" & Id));
      Mutant_Executable := To_Unbounded_String
        (Executable (To_String (Probe_Name), "bin/search-mutant-" & Id));
      if Remaining < 0.001 then
         Expired := True;
         Inconclusive ("the search budget expired before compiling the input probes");
         Clean_Work;
         return;
      end if;
      declare
         Built : constant AdaMutant.Processes.Run_Result := Run_Child
           (Search_Build_Command (To_String (Original_Project)),
            To_String (Original_Dir),
            AdaMutant.Files.Join (To_String (Original_Dir), "search-build.log"),
            Build_Timeout);
      begin
         if Built.Timed_Out or else Built.Exit_Code /= 0 then
            Inconclusive
              ("the original input probe did not build"
               & (if Built.Timed_Out then " before its time limit"
                  else " (exit status" & Built.Exit_Code'Image & ")"));
            Expired := Remaining < 0.001;
            Clean_Work;
            return;
         end if;
      end;
      if Remaining < 0.001 then
         Expired := True;
         Inconclusive ("the search budget expired before compiling the mutant probe");
         Clean_Work;
         return;
      end if;
      declare
         Built : constant AdaMutant.Processes.Run_Result := Run_Child
           (Search_Build_Command (To_String (Mutant_Project)),
            To_String (Mutant_Dir),
            AdaMutant.Files.Join (To_String (Mutant_Dir), "search-build.log"),
            Build_Timeout);
      begin
         if Built.Timed_Out or else Built.Exit_Code /= 0 then
            Inconclusive
              ("the mutant input probe did not build"
               & (if Built.Timed_Out then " before its time limit"
                  else " (exit status" & Built.Exit_Code'Image & ")"));
            Expired := Remaining < 0.001;
            Clean_Work;
            return;
         end if;
      end;
      if Remaining < 0.001 then
         Expired := True;
         Inconclusive ("the search budget expired before enumerating input values");
         Clean_Work;
         return;
      end if;

      declare
         Formal_Count : constant Positive := Positive (Info.Formals.Length);
         type Pool_Array is array (Positive range <>) of String_Vectors.Vector;
         type Index_Array is array (Positive range <>) of Natural;
         Pools : Pool_Array (1 .. Formal_Count);
         Indices : Index_Array (1 .. Formal_Count) := [others => 1];
         Attempts : Natural := 0;
         Found : Boolean := False;

         procedure Try_Combination is
            Arguments : Unbounded_String;
            Input : Unbounded_String;
            Original_Result : Unbounded_String;
            Mutant_Result : Unbounded_String;
            Original_Run : AdaMutant.Processes.Run_Result;
            Mutant_Run : AdaMutant.Processes.Run_Result;
            Original_Log : constant String :=
              AdaMutant.Files.Join (To_String (Original_Dir), "search-run.log");
            Mutant_Log : constant String :=
              AdaMutant.Files.Join (To_String (Mutant_Dir), "search-run.log");
         begin
            if Attempts >= Max_Combinations then
               return;
            elsif Remaining < 0.001 then
               Expired := True;
               return;
            end if;
            Attempts := Attempts + 1;
            M.Input_Search.Attempts := Attempts;
            for I in 1 .. Formal_Count loop
               declare
                  Value : constant String := Pools (I) (Positive (Indices (I)));
               begin
                  if I > 1 then
                     Append (Arguments, " ");
                     Append (Input, ", ");
                  end if;
                  Append (Arguments, Shell_Quote (Value));
                  Append (Input, Value);
               end;
            end loop;
            Original_Run := Run_Child
              (To_String (Original_Executable) & " " & To_String (Arguments),
               To_String (Original_Dir), Original_Log, Run_Timeout);
            if Original_Run.Timed_Out then
               Expired := Remaining < 0.001;
               return;
            elsif Original_Run.Exit_Code /= 0 then
               return;
            end if;
            declare
               Observed : constant String := Marked_Result (Original_Log);
            begin
               if Observed = "" then
                  return;
               end if;
               Original_Successes := Original_Successes + 1;
               Original_Result := To_Unbounded_String (Observed);
            end;
            if Remaining < 0.001 then
               Expired := True;
               return;
            end if;
            Mutant_Run := Run_Child
              (To_String (Mutant_Executable) & " " & To_String (Arguments),
               To_String (Mutant_Dir), Mutant_Log, Run_Timeout);
            if Mutant_Run.Timed_Out then
               Mutant_Failures := Mutant_Failures + 1;
               Expired := Remaining < 0.001;
               return;
            elsif Mutant_Run.Exit_Code /= 0 then
               Mutant_Failures := Mutant_Failures + 1;
               return;
            end if;
            declare
               Observed : constant String := Marked_Result (Mutant_Log);
            begin
               if Observed = "" then
                  Mutant_Failures := Mutant_Failures + 1;
                  return;
               end if;
               Mutant_Successes := Mutant_Successes + 1;
               Mutant_Result := To_Unbounded_String (Observed);
            end;
            if To_String (Original_Result) /= To_String (Mutant_Result) then
               M.Input_Search.Status := Search_Found;
               M.Input_Search.Input := To_Unbounded_String
                 (To_String (Info.Package_Name) & "."
                  & To_String (Info.Function_Name) & " ("
                  & To_String (Input) & ")");
               M.Input_Search.Original_Output := Original_Result;
               M.Input_Search.Mutant_Output := Mutant_Result;
               M.Input_Search.Reason := To_Unbounded_String
                 ("the original and mutant returned different integer values");
               Found := True;
            else
               Same_Outputs := Same_Outputs + 1;
            end if;
         end Try_Combination;

         function Next_Combination return Boolean is
         begin
            for I in reverse 1 .. Formal_Count loop
               if Indices (I) < Natural (Pools (I).Length) then
                  Indices (I) := Indices (I) + 1;
                  for J in I + 1 .. Formal_Count loop
                     Indices (J) := 1;
                  end loop;
                  return True;
               end if;
            end loop;
            return False;
         end Next_Combination;

         function Changed_Arguments return Natural is
            Count : Natural := 0;
         begin
            for Index of Indices loop
               if Index > 1 then
                  Count := Count + 1;
               end if;
            end loop;
            return Count;
         end Changed_Arguments;
      begin
         for I in 1 .. Formal_Count loop
            if Remaining < 0.001 then
               Expired := True;
               exit;
            end if;
            declare
               Values_Log : constant String := AdaMutant.Files.Join
                 (To_String (Original_Dir), "search-values.log");
               Listed : constant AdaMutant.Processes.Run_Result := Run_Child
                 (To_String (Original_Executable) & " --values " & Id_Text (I),
                  To_String (Original_Dir), Values_Log, Run_Timeout);
               Valid : Boolean;
            begin
               if Listed.Timed_Out or else Listed.Exit_Code /= 0 then
                  Expired := Remaining < 0.001;
                  Inconclusive
                    (if Expired then "the search budget expired while generating candidate values"
                     else "the original input probe could not generate candidate values");
                  exit;
               end if;
               Read_Candidate_Values (Values_Log, Pools (I), Valid);
               if not Valid then
                  Inconclusive ("the input probe produced no valid integer candidates");
                  exit;
               end if;
            end;
         end loop;
         if not Expired and then M.Input_Search.Status /= Search_Inconclusive then
            Try_Combination;
            for I in 1 .. Formal_Count loop
               exit when Found or else Expired or else Attempts >= Max_Combinations;
               for J in 2 .. Natural (Pools (I).Length) loop
                  exit when Found or else Expired or else Attempts >= Max_Combinations;
                  Indices := [others => 1];
                  Indices (I) := J;
                  Try_Combination;
               end loop;
            end loop;
            Indices := [others => 1];
            while not Found and then not Expired and then Attempts < Max_Combinations
              and then Next_Combination
            loop
               if Changed_Arguments > 1 then
                  Try_Combination;
               end if;
            end loop;
         end if;
         if not Found and then M.Input_Search.Status /= Search_Inconclusive then
            if Expired or else Remaining < 0.001 then
               Inconclusive
                 ("search budget exhausted after" & Attempts'Image
                  & " candidate combinations");
            elsif Attempts >= Max_Combinations then
               Inconclusive
                 ("no distinguishing input found within 256 candidate combinations");
            elsif Original_Successes = 0 then
               Inconclusive
                 ("no candidate input completed successfully on the original program");
            elsif Mutant_Successes = 0 then
               Inconclusive
                 ("no candidate input produced successful outputs from both programs");
            elsif Mutant_Failures > 0 then
               Inconclusive
                 ("no distinguishing input found; some mutant executions did not complete successfully");
            else
               Inconclusive
                 ("no distinguishing input found among" & Attempts'Image
                  & " bounded candidate combinations");
            end if;
         end if;
      end;
      Clean_Work;
   exception
      when E : others =>
         Clean_Work;
         Inconclusive
           ("input search could not complete: "
            & Ada.Exceptions.Exception_Message (E));
   end Search;

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
      Skip.Append (".adamutant/suggestion-work");
      Skip.Append ("**/.adamutant/suggestion-work");
      Skip.Append ("obj");
      Skip.Append ("bin");
      Skip.Append ("**/obj");
      Skip.Append ("**/bin");
      Skip.Append ("gnatprove");
      Skip.Append ("**/gnatprove");
      if not Identify (Root, File_Path, Skip, M, Info, Reason) then
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
                       To_String (Info.Result_Type_Name),
                       To_String (Info.Result_Type_Package), To_String (Call)));
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
