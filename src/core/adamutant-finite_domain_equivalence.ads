with AdaMutant.Mutators;

package AdaMutant.Finite_Domain_Equivalence is

   --  Prove equivalence only after both versions pass eligibility checks and
   --  every Boolean input combination evaluates normally with equal results.
   --  Mutations outside the return expression and unsupported or unresolved
   --  syntax are rejected. Combinations is zero unless the complete domain
   --  was evaluated successfully.
   function Proves_Equivalent
     (Source        : String;
      File_Name     : String;
      Mutation      : AdaMutant.Mutators.Mutation;
      Project_Files : AdaMutant.Mutators.Name_Sets.Set;
      Combinations  : out Natural) return Boolean;

end AdaMutant.Finite_Domain_Equivalence;
