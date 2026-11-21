with Ada.Characters.Handling;
with Ada.Strings.Unbounded;
with Ada.Strings.UTF_Encoding.Wide_Wide_Strings;
with GNATCOLL.VFS;
with Langkit_Support.Slocs;
with Libadalang.Analysis;
with Libadalang.Auto_Provider;
with Libadalang.Common;

package body AdaMutant.Finite_Domain_Equivalence is

   package LAL renames Libadalang.Analysis;
   package LC renames Libadalang.Common;
   use type LC.Ada_Node_Kind_Type;
   use type LAL.Analysis_Unit;
   use type Langkit_Support.Slocs.Line_Number;
   use type Langkit_Support.Slocs.Column_Number;

   Max_Parameters : constant Positive := 8;

   Provider_Files : AdaMutant.Mutators.Name_Sets.Set;
   Providers      : array (Boolean) of LAL.Unit_Provider_Reference;
   Provided       : array (Boolean) of Boolean := [others => False];

   function Same (Left, Right : LAL.Ada_Node'Class) return Boolean
     renames LAL."=";

   function Text_Of (Node : LAL.Ada_Node'Class) return String is
     (Ada.Strings.UTF_Encoding.Wide_Wide_Strings.Encode (LAL.Text (Node)));

   function Lower (Text : String) return String is
     (Ada.Characters.Handling.To_Lower (Text));

   type Parsed_Source is record
      Context : LAL.Analysis_Context;
      Unit    : LAL.Analysis_Unit;
   end record;

   function Project_Provider
     (Project_Files : AdaMutant.Mutators.Name_Sets.Set;
      Charset       : String) return LAL.Unit_Provider_Reference
   is
      UTF_8 : constant Boolean := Charset = "utf-8";
   begin
      if not AdaMutant.Mutators.Name_Sets."="
        (Project_Files, Provider_Files)
      then
         Provider_Files := Project_Files;
         Provided := [others => False];
      end if;
      if not Provided (UTF_8) then
         declare
            Paths : GNATCOLL.VFS.File_Array
              (1 .. Natural (Project_Files.Length));
            Last : Natural := 0;
         begin
            for Path of Project_Files loop
               Last := Last + 1;
               Paths (Last) := GNATCOLL.VFS.Create
                 (GNATCOLL.VFS."+" (Path));
            end loop;
            Providers (UTF_8) :=
              Libadalang.Auto_Provider.Create_Auto_Provider_Reference
                (Paths, Charset);
            Provided (UTF_8) := True;
         end;
      end if;
      return Providers (UTF_8);
   end Project_Provider;

   function Parse
     (Source, File_Name, Charset : String;
      Project_Files : AdaMutant.Mutators.Name_Sets.Set)
      return Parsed_Source
   is
      Provider : LAL.Unit_Provider_Reference;
      Context  : LAL.Analysis_Context;
      Unit     : LAL.Analysis_Unit;
   begin
      Provider := Project_Provider (Project_Files, Charset);
      Context := LAL.Create_Context
        (Charset => Charset, Unit_Provider => Provider, Tab_Stop => 1);
      Unit := Context.Get_From_Buffer
        (Filename => File_Name,
         Charset  => Charset,
         Buffer   => Source,
         Rule     => LC.Compilation_Rule);
      return (Context => Context, Unit => Unit);
   end Parse;

   function Boolean_Type
     (Type_Expr : LAL.Type_Expr;
      Decl      : out LAL.Base_Type_Decl) return Boolean
   is
      Name : LAL.Name;
      Ref  : LAL.Basic_Decl;
   begin
      Decl := LAL.No_Base_Type_Decl;
      if Type_Expr.Is_Null
        or else Type_Expr.Kind /= LC.Ada_Subtype_Indication
      then
         return False;
      end if;

      declare
         Indication : constant LAL.Subtype_Indication :=
           Type_Expr.As_Subtype_Indication;
      begin
         if not Indication.F_Constraint.Is_Null then
            return False;
         end if;
         Name := Indication.F_Name;
      end;
      if Name.Is_Null then
         return False;
      end if;
      Ref := Name.P_Referenced_Decl;
      if Ref.Is_Null or else Ref.Unit /= Name.P_Standard_Unit then
         return False;
      end if;
      Decl := Ref.As_Base_Type_Decl;
      return Lower (Text_Of (Decl.F_Name.F_Name)) = "boolean";
   end Boolean_Type;

   type Parameter_Decls is array (Positive range 1 .. Max_Parameters)
     of LAL.Param_Spec;
   type Parameter_Names is array (Positive range 1 .. Max_Parameters)
     of Ada.Strings.Unbounded.Unbounded_String;
   type Boolean_Array is array (Positive range <>) of Boolean;

   type Function_Info is record
      Context      : LAL.Analysis_Context;
      Unit         : LAL.Analysis_Unit;
      Node         : LAL.Ada_Node := LAL.No_Ada_Node;
      Spec         : LAL.Subp_Spec := LAL.No_Subp_Spec;
      Expression   : LAL.Expr := LAL.No_Expr;
      Boolean_Decl : LAL.Base_Type_Decl := LAL.No_Base_Type_Decl;
      Count        : Natural := 0;
      Decls        : Parameter_Decls := [others => LAL.No_Param_Spec];
      Names        : Parameter_Names := [others => <>];
   end record;

   function Position
     (Source, Charset : String; Offset : Positive)
      return Langkit_Support.Slocs.Source_Location
   is
      Result : Langkit_Support.Slocs.Source_Location :=
        (Line => 1, Column => 1);
   begin
      for Index in Source'First .. Natural'Min (Offset - 1, Source'Last) loop
         if Source (Index) = ASCII.LF then
            Result.Line := Result.Line + 1;
            Result.Column := 1;
         elsif Charset = "utf-8"
           and then Character'Pos (Source (Index)) in 16#80# .. 16#BF#
         then
            null;
         else
            Result.Column := Result.Column + 1;
         end if;
      end loop;
      return Result;
   end Position;

   function Before_Or_Equal
     (Left, Right : Langkit_Support.Slocs.Source_Location) return Boolean is
     (Left.Line < Right.Line
      or else (Left.Line = Right.Line and then Left.Column <= Right.Column));

   function Mutation_Fits
     (Source, Charset : String;
      Mutation : AdaMutant.Mutators.Mutation;
      Expression : LAL.Expr;
      Is_Original : Boolean) return Boolean
   is
      Expression_Range : constant Langkit_Support.Slocs.Source_Location_Range :=
        Expression.Sloc_Range;
      Start_Offset : constant Positive := Mutation.First;
      End_Offset : Natural;
   begin
      if Source'Length = 0
        or else Start_Offset not in Source'Range
        or else Mutation.Last < Mutation.First
      then
         return False;
      end if;
      if Is_Original then
         if Mutation.Last not in Source'Range then
            return False;
         end if;
         End_Offset := Mutation.Last + 1;
      else
         End_Offset := Mutation.First
           + Ada.Strings.Unbounded.Length (Mutation.Replacement);
         if End_Offset > Source'Last + 1 then
            return False;
         end if;
      end if;
      return Before_Or_Equal
        (Langkit_Support.Slocs.Start_Sloc (Expression_Range),
         Position (Source, Charset, Start_Offset))
        and then Before_Or_Equal
          (Position (Source, Charset, End_Offset),
           Langkit_Support.Slocs.End_Sloc (Expression_Range));
   end Mutation_Fits;

   function Is_Function_Node (Node : LAL.Ada_Node) return Boolean is
     (not Node.Is_Null
      and then Node.Kind in LC.Ada_Subp_Body | LC.Ada_Expr_Function);

   function Same_Name_Count
     (Node : LAL.Ada_Node; Name : String) return Natural
   is
      Result : Natural := 0;
   begin
      if Node.Is_Null then
         return 0;
      end if;
      if Node.Kind in LC.Ada_Subp_Decl | LC.Ada_Abstract_Subp_Decl then
         declare
            Spec : constant LAL.Subp_Spec :=
              (if Node.Kind = LC.Ada_Subp_Decl
               then Node.As_Subp_Decl.F_Subp_Spec
               else Node.As_Abstract_Subp_Decl.F_Subp_Spec);
         begin
            if not Spec.Is_Null and then not Spec.F_Subp_Name.Is_Null
              and then Lower (Text_Of (Spec.F_Subp_Name)) = Lower (Name)
            then
               Result := 1;
            end if;
         end;
      end if;
      for Index in 1 .. LAL.Children_Count (Node) loop
         Result := Result + Same_Name_Count (LAL.Child (Node, Index), Name);
      end loop;
      return Result;
   end Same_Name_Count;

   function Has_Pragma (Node : LAL.Ada_Node) return Boolean is
   begin
      if Node.Is_Null then
         return False;
      elsif Node.Kind = LC.Ada_Pragma_Node then
         return True;
      end if;
      for Index in 1 .. LAL.Children_Count (Node) loop
         if Has_Pragma (LAL.Child (Node, Index)) then
            return True;
         end if;
      end loop;
      return False;
   end Has_Pragma;

   function Package_Ancestor (Node : LAL.Ada_Node) return LAL.Ada_Node is
      Current : LAL.Ada_Node := Node.Parent;
   begin
      while not Current.Is_Null loop
         if Current.Kind in LC.Ada_Package_Decl | LC.Ada_Package_Body then
            return Current;
         elsif Current.Kind in LC.Ada_Subp_Body | LC.Ada_Expr_Function
           | LC.Ada_Block_Stmt
         then
            return LAL.No_Ada_Node;
         end if;
         Current := Current.Parent;
      end loop;
      return LAL.No_Ada_Node;
   end Package_Ancestor;

   function Prepare
     (Source, File_Name, Charset : String;
      Mutation : AdaMutant.Mutators.Mutation;
      Is_Original : Boolean;
      Project_Files : AdaMutant.Mutators.Name_Sets.Set;
      Info : out Function_Info) return Boolean
   is
      Parsed : constant Parsed_Source := Parse
        (Source, File_Name, Charset, Project_Files);
      Node : LAL.Ada_Node;
      Previous : LAL.Basic_Decl;
      Previous_Spec : LAL.Subp_Spec;
      Params : LAL.Param_Spec_List;
      Package_Node : LAL.Ada_Node;
      Previous_Package : LAL.Ada_Node;
      Function_Name : Ada.Strings.Unbounded.Unbounded_String;
   begin
      Info := (Context => Parsed.Context, Unit => Parsed.Unit, others => <>);
      if Parsed.Unit.Has_Diagnostics then
         return False;
      end if;
      Node := Parsed.Unit.Root.Lookup
        (Position (Source, Charset, Mutation.First));
      while not Node.Is_Null and then not Is_Function_Node (Node) loop
         Node := Node.Parent;
      end loop;
      if Node.Is_Null or else not Node.As_Base_Subp_Body.F_Aspects.Is_Null then
         return False;
      end if;

      Package_Node := Package_Ancestor (Node);
      if Package_Node.Is_Null then
         return False;
      end if;
      Info.Spec := Node.As_Base_Subp_Body.F_Subp_Spec;
      if Info.Spec.Is_Null or else Info.Spec.F_Subp_Name.Is_Null
        or else Info.Spec.F_Subp_Returns.Is_Null
        or else not Boolean_Type (Info.Spec.F_Subp_Returns, Info.Boolean_Decl)
      then
         return False;
      end if;
      Function_Name := Ada.Strings.Unbounded.To_Unbounded_String
        (Text_Of (Info.Spec.F_Subp_Name));

      Previous := Node.As_Base_Subp_Body.P_Previous_Part;
      if Previous.Is_Null or else Previous.Kind /= LC.Ada_Subp_Decl then
         return False;
      end if;
      Previous_Spec := Previous.As_Subp_Decl.F_Subp_Spec;
      Previous_Package := Package_Ancestor (Previous.As_Ada_Node);
      if Previous_Spec.Is_Null or else not Previous.F_Aspects.Is_Null
        or else Previous_Package.Is_Null
        or else Previous_Package.Kind /= LC.Ada_Package_Decl
        or else Has_Pragma (Package_Node)
        or else Has_Pragma (Previous_Package)
        or else Same_Name_Count
          (Previous_Package, Ada.Strings.Unbounded.To_String (Function_Name)) /= 1
      then
         return False;
      end if;

      declare
         Previous_Type : LAL.Base_Type_Decl;
      begin
         if Previous_Spec.F_Subp_Returns.Is_Null
           or else not Boolean_Type (Previous_Spec.F_Subp_Returns, Previous_Type)
           or else not Same (Previous_Type, Info.Boolean_Decl)
         then
            return False;
         end if;
      end;

      Params := Info.Spec.F_Subp_Params.F_Params;
      if Params.Is_Null or else LAL.Children_Count (Params) = 0 then
         return False;
      end if;
      for Index in 1 .. LAL.Children_Count (Params) loop
         declare
            Param : constant LAL.Param_Spec :=
              LAL.Child (Params, Index).As_Param_Spec;
            Mode : constant LAL.Mode := Param.F_Mode;
            Param_Type : LAL.Base_Type_Decl;
            Ids : constant LAL.Defining_Name_List := Param.F_Ids;
            Has_Boolean_Type : constant Boolean :=
              Boolean_Type (Param.F_Type_Expr, Param_Type);
            Mode_Is_Only : constant Boolean :=
              Mode.Is_Null
              or else Mode.Kind in LC.Ada_Mode_In | LC.Ada_Mode_Default;
            No_Default : constant Boolean := Param.F_Default_Expr.Is_Null;
            No_Aspects : constant Boolean := Param.F_Aspects.Is_Null;
            Not_Aliased : constant Boolean :=
              Param.F_Has_Aliased.Kind /= LC.Ada_Aliased_Present;
         begin
            if not Mode_Is_Only or else not No_Default or else not No_Aspects
              or else not Not_Aliased or else not Has_Boolean_Type
              or else not Same (Param_Type, Info.Boolean_Decl)
            then
               return False;
            end if;
            for Id_Index in 1 .. LAL.Children_Count (Ids) loop
               if Info.Count = Max_Parameters then
                  return False;
               end if;
               Info.Count := Info.Count + 1;
               Info.Decls (Info.Count) := Param;
               Info.Names (Info.Count) := Ada.Strings.Unbounded.To_Unbounded_String
                 (Text_Of
                    (LAL.Child (Ids, Id_Index).As_Defining_Name.F_Name));
            end loop;
         end;
      end loop;
      if Info.Count = 0 then
         return False;
      end if;

      declare
         Previous_Params : constant LAL.Param_Spec_List :=
           Previous_Spec.F_Subp_Params.F_Params;
      begin
         if Previous_Params.Is_Null
           or else LAL.Children_Count (Previous_Params) /= LAL.Children_Count (Params)
         then
            return False;
         end if;
         for Index in 1 .. LAL.Children_Count (Previous_Params) loop
            declare
               Param : constant LAL.Param_Spec :=
                 LAL.Child (Previous_Params, Index).As_Param_Spec;
               Mode : constant LAL.Mode := Param.F_Mode;
               Param_Type : LAL.Base_Type_Decl;
               Ids : constant LAL.Defining_Name_List := Param.F_Ids;
               Body_Ids : constant LAL.Defining_Name_List :=
                 LAL.Child (Params, Index).As_Param_Spec.F_Ids;
               Not_Aliased : constant Boolean :=
                 Param.F_Has_Aliased.Kind /= LC.Ada_Aliased_Present;
            begin
               if (not Mode.Is_Null
                   and then Mode.Kind not in
                     LC.Ada_Mode_In | LC.Ada_Mode_Default)
                 or else not Param.F_Default_Expr.Is_Null
                 or else not Param.F_Aspects.Is_Null
                 or else not Not_Aliased
                 or else not Boolean_Type (Param.F_Type_Expr, Param_Type)
                 or else not Same (Param_Type, Info.Boolean_Decl)
                 or else LAL.Children_Count (Ids) /= LAL.Children_Count (Body_Ids)
               then
                  return False;
               end if;
            end;
         end loop;
      end;

      case Node.Kind is
         when LC.Ada_Expr_Function =>
            Info.Expression := Node.As_Expr_Function.F_Expr;
         when LC.Ada_Subp_Body =>
            declare
               Body_Node : constant LAL.Subp_Body := Node.As_Subp_Body;
               Decls : constant LAL.Ada_Node_List :=
                 Body_Node.F_Decls.F_Decls;
               Handled : constant LAL.Handled_Stmts := Body_Node.F_Stmts;
               Stmts : constant LAL.Stmt_List := Handled.F_Stmts;
            begin
               if LAL.Children_Count (Decls) /= 0
                 or else LAL.Children_Count (Handled.F_Exceptions) /= 0
                 or else LAL.Children_Count (Stmts) /= 1
                 or else LAL.Child (Stmts, 1).Kind /= LC.Ada_Return_Stmt
               then
                  return False;
               end if;
               Info.Expression :=
                 LAL.Child (Stmts, 1).As_Return_Stmt.F_Return_Expr;
            end;
         when others =>
            return False;
      end case;
      if Info.Expression.Is_Null then
         return False;
      end if;
      if not Mutation_Fits
        (Source, Charset, Mutation, Info.Expression, Is_Original)
      then
         return False;
      end if;
      Info.Node := Node;
      return True;
   exception
      when others =>
         return False;
   end Prepare;

   function Is_Standard_Literal
     (Name : LAL.Name; Value : out Boolean) return Boolean
   is
      Ref : constant LAL.Basic_Decl := Name.P_Referenced_Decl;
      Text : constant String := Lower (Text_Of (Name));
   begin
      if Ref.Is_Null or else Ref.Kind /= LC.Ada_Enum_Literal_Decl
        or else Ref.Unit /= Name.P_Standard_Unit
      then
         return False;
      end if;
      if Text = "true" then
         Value := True;
         return True;
      elsif Text = "false" then
         Value := False;
         return True;
      else
         return False;
      end if;
   end Is_Standard_Literal;

   function Is_Formal
     (Name : LAL.Name; Info : Function_Info; Index : out Natural)
      return Boolean
   is
      Ref : constant LAL.Basic_Decl := Name.P_Referenced_Decl;
      Text : constant String := Lower (Text_Of (Name));
   begin
      Index := 0;
      if Ref.Is_Null then
         return False;
      end if;
      for I in 1 .. Info.Count loop
         if Same (Ref, Info.Decls (I))
           and then Text = Lower (Ada.Strings.Unbounded.To_String (Info.Names (I)))
         then
            Index := I;
            return True;
         end if;
      end loop;
      return False;
   end Is_Formal;

   function Is_Built_In_Operator (Operator : LAL.Op) return Boolean is
      Ref : constant LAL.Basic_Decl := Operator.P_Referenced_Decl;
   begin
      return Ref.Is_Null or else Ref.Unit = Operator.P_Standard_Unit;
   end Is_Built_In_Operator;

   function Validate
     (Expression : LAL.Expr; Info : Function_Info) return Boolean
   is
      function Is_Boolean_Expression (Node : LAL.Expr) return Boolean is
         Type_Decl : constant LAL.Base_Type_Decl := Node.P_Expression_Type;
      begin
         return not Type_Decl.Is_Null
           and then Same (Type_Decl, Info.Boolean_Decl);
      end Is_Boolean_Expression;

      function Visit (Node : LAL.Expr) return Boolean is
      begin
         if Node.Is_Null or else not Is_Boolean_Expression (Node) then
            return False;
         end if;
         case Node.Kind is
            when LC.Ada_Paren_Expr =>
               return Visit (Node.As_Paren_Expr.F_Expr);
            when LC.Ada_Identifier =>
               declare
                  Name : constant LAL.Name := Node.As_Name;
                  Index : Natural;
                  Value : Boolean;
               begin
                  return Is_Formal (Name, Info, Index)
                    or else Is_Standard_Literal (Name, Value);
               end;
            when LC.Ada_Un_Op =>
               declare
                  Op : constant LAL.Op := Node.As_Un_Op.F_Op;
               begin
                  return Op.Kind = LC.Ada_Op_Not
                    and then Is_Built_In_Operator (Op)
                    and then Visit (Node.As_Un_Op.F_Expr);
               end;
            when LC.Ada_Bin_Op | LC.Ada_Relation_Op =>
               declare
                  Binary : constant LAL.Bin_Op := Node.As_Bin_Op;
                  Op : constant LAL.Op := Binary.F_Op;
               begin
                  return Op.Kind in LC.Ada_Op_And | LC.Ada_Op_And_Then
                    | LC.Ada_Op_Or | LC.Ada_Op_Or_Else | LC.Ada_Op_Xor
                    | LC.Ada_Op_Eq | LC.Ada_Op_Neq
                    and then Is_Built_In_Operator (Op)
                    and then Visit (Binary.F_Left)
                    and then Visit (Binary.F_Right);
               end;
            when others =>
               return False;
         end case;
      end Visit;
   begin
      return Visit (Expression);
   exception
      when others =>
         return False;
   end Validate;

   function Evaluate
     (Expression : LAL.Expr; Info : Function_Info;
      Values : Boolean_Array) return Boolean
   is
      function Value_Of (Node : LAL.Expr) return Boolean is
      begin
         case Node.Kind is
            when LC.Ada_Paren_Expr =>
               return Value_Of (Node.As_Paren_Expr.F_Expr);
            when LC.Ada_Identifier =>
               declare
                  Name : constant LAL.Name := Node.As_Name;
                  Index : Natural;
                  Value : Boolean;
               begin
                  if Is_Formal (Name, Info, Index) then
                     return Values (Index);
                  elsif Is_Standard_Literal (Name, Value) then
                     return Value;
                  else
                     raise Program_Error;
                  end if;
               end;
            when LC.Ada_Un_Op =>
               return not Value_Of (Node.As_Un_Op.F_Expr);
            when LC.Ada_Bin_Op | LC.Ada_Relation_Op =>
               declare
                  Binary : constant LAL.Bin_Op := Node.As_Bin_Op;
                  Left : constant Boolean := Value_Of (Binary.F_Left);
               begin
                  case Binary.F_Op.Kind is
                     when LC.Ada_Op_And =>
                        return Left and Value_Of (Binary.F_Right);
                     when LC.Ada_Op_And_Then =>
                        return Left and then Value_Of (Binary.F_Right);
                     when LC.Ada_Op_Or =>
                        return Left or Value_Of (Binary.F_Right);
                     when LC.Ada_Op_Or_Else =>
                        return Left or else Value_Of (Binary.F_Right);
                     when LC.Ada_Op_Xor =>
                        return Left xor Value_Of (Binary.F_Right);
                     when LC.Ada_Op_Eq =>
                        return Left = Value_Of (Binary.F_Right);
                     when LC.Ada_Op_Neq =>
                        return Left /= Value_Of (Binary.F_Right);
                     when others =>
                        raise Program_Error;
                  end case;
               end;
            when others =>
               raise Program_Error;
         end case;
      end Value_Of;
   begin
      return Value_Of (Expression);
   end Evaluate;

   function Proves_Equivalent
     (Source        : String;
      File_Name     : String;
      Mutation      : AdaMutant.Mutators.Mutation;
      Project_Files : AdaMutant.Mutators.Name_Sets.Set;
      Combinations  : out Natural) return Boolean
   is
      Mutant_Source : constant String := AdaMutant.Mutators.Apply
        (Source, Mutation);
   begin
      Combinations := 0;
      if Mutation.Contract or else Project_Files.Is_Empty
        or else not Project_Files.Contains (File_Name)
      then
         return False;
      end if;

      for Attempt in 1 .. 2 loop
         declare
            Charset : constant String :=
              (if Attempt = 1 then "utf-8" else "iso-8859-1");
            Original : Function_Info;
            Mutant   : Function_Info;
            Count    : Natural := 0;
            Valid    : Boolean := True;
         begin
            if not Prepare
              (Source, File_Name, Charset, Mutation, True, Project_Files, Original)
              or else not Prepare
                (Mutant_Source, File_Name, Charset, Mutation, False,
                 Project_Files, Mutant)
              or else Original.Count /= Mutant.Count
            then
               null;
            else
               for Index in 1 .. Original.Count loop
                  if Lower (Ada.Strings.Unbounded.To_String
                    (Original.Names (Index))) /=
                    Lower (Ada.Strings.Unbounded.To_String
                      (Mutant.Names (Index)))
                  then
                     Valid := False;
                  end if;
               end loop;
               if Valid
                 and then Validate (Original.Expression, Original)
                 and then Validate (Mutant.Expression, Mutant)
               then
                  Count := 2 ** Original.Count;
                  for Combination in 0 .. Count - 1 loop
                     declare
                        Values : Boolean_Array (1 .. Original.Count);
                     begin
                        for Index in 1 .. Original.Count loop
                           Values (Index) :=
                             (Combination / (2 ** (Index - 1))) mod 2 = 1;
                        end loop;
                        if Evaluate (Original.Expression, Original, Values) /=
                          Evaluate (Mutant.Expression, Mutant, Values)
                        then
                           return False;
                        end if;
                     end;
                  end loop;
                  Combinations := Count;
                  return True;
               end if;
            end if;
         exception
            when others =>
               null;
         end;
      end loop;
      Combinations := 0;
      return False;
   exception
      when others =>
         Combinations := 0;
         return False;
   end Proves_Equivalent;

end AdaMutant.Finite_Domain_Equivalence;
