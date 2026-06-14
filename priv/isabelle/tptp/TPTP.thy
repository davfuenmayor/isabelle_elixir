theory TPTP
  imports Main
begin

(*Removes colliding notation (Warning: only valid for Isabelle2025 onwards)*)
no_notation (ASCII)
  Not  (\<open>(\<open>open_block notation=\<open>prefix ~\<close>\<close>~ _)\<close> [40] 40) and
  conj  (infixr \<open>&\<close> 35) and
  disj  (infixr \<open>|\<close> 30) and
  Set.member  (\<open>(\<open>notation=\<open>infix :\<close>\<close>_/ : _)\<close> [51, 51] 50)
no_notation List.append (infixr \<open>@\<close> 65)

(*Introduces explicit application connective (useful later for generating THF)*)
definition thf_app :: "('a \<Rightarrow> 'b) \<Rightarrow> 'a \<Rightarrow> 'b"  (infixl "@" 70)
  where "f @ x \<equiv> f x"
declare thf_app_def[simp] (*add as simplification rule (in case we forget to manually unfold it before proving)*)

syntax
  "_thf_arrow" :: "type \<Rightarrow> type \<Rightarrow> type"  (infixr ">" 0)
  "_thf_bool"  :: "type"  ("$o")
  "_thf_true"  :: "logic"  ("$true")
  "_thf_false"  :: "logic"  ("$false")
  "_thf_not"  :: "logic \<Rightarrow> logic"  ("~")
  "_thf_impl"  :: "logic \<Rightarrow> logic \<Rightarrow> logic"  (infixr "=>" 25)
  "_thf_dimpl"  :: "logic \<Rightarrow> logic \<Rightarrow> logic"  (infixr "<=>" 25)
  "_thf_xor"  :: "logic \<Rightarrow> logic \<Rightarrow> logic"  (infixr "<~>" 25)
  "_thf_diseq"  :: "logic \<Rightarrow> logic \<Rightarrow> logic"  (infix "!=" 50)
  "_thf_and"  :: "logic \<Rightarrow> logic \<Rightarrow> logic"  (infixl "&" 35)
  "_thf_or"  :: "logic \<Rightarrow> logic \<Rightarrow> logic"  (infixl "|" 30)
  "_thf_lam" :: "args \<Rightarrow> logic \<Rightarrow> logic" ("(3^ [(_)] :/ _)" [0, 10] 10)
  "_thf_all" :: "args \<Rightarrow> logic \<Rightarrow> logic" ("(3! [(_)] :/ _)" [0, 10] 10)
  "_thf_ex" :: "args \<Rightarrow> logic \<Rightarrow> logic"  ("(3? [(_)] :/ _)" [0, 10] 10)
  "_thf_idtyp" :: "id \<Rightarrow> type \<Rightarrow> idt" ("(1_ :/ _)" [4, 0] 0)
  "_thf_constrain" :: "logic \<Rightarrow> type \<Rightarrow> logic" ("_ :/ _" [4, 0] 3)
  "_thf_All" :: "logic \<Rightarrow> logic" ("!!")
  "_thf_Ex" :: "logic \<Rightarrow> logic" ("??")

(*Other TPTP interpreted symbol types*)
typedecl i
(*... add others on-demand*)

bundle from_TPTP begin
  translations
  "~a" \<rightharpoonup> "\<not>a"
  "a & b" \<rightharpoonup> "a \<and> b"
  "a | b" \<rightharpoonup> "a \<or> b"
  "a => b" \<rightharpoonup> "a \<longrightarrow> b"
  "a <=> b" \<rightharpoonup> "a \<longleftrightarrow> b"
  "a <~> b" \<rightharpoonup> "\<not>(a \<longleftrightarrow> b)"
  "a != b" \<rightharpoonup> "a \<noteq> b"
  "$true" \<rightharpoonup> "CONST True"
  "$false" \<rightharpoonup> "CONST False"
  (type) "$o" \<rightharpoonup> (type) "bool"
  (type) "'a > 'b" \<rightharpoonup> (type) "'a \<Rightarrow> 'b"
  "_thf_idtyp x T" \<rightharpoonup> "_idtyp x T"
  "_thf_constrain t T" \<rightharpoonup> "_constrain t T"
  "^ [x, xs] : t" \<rightharpoonup> "\<lambda>x. (_thf_lam xs t)"
  "! [x, xs] : t" \<rightharpoonup> "\<forall>x. (_thf_all xs t)"
  "? [x, xs] : t" \<rightharpoonup> "\<exists>x. (_thf_ex xs t)"
  "^ [x] : t" \<rightharpoonup> "(\<lambda>x. t)"
  "! [x] : t" \<rightharpoonup> "(\<forall>x. t)"
  "? [x] : t" \<rightharpoonup> "(\<exists>x. t)"
  "f @ x" \<rightharpoonup> "f x"
  "!! t" \<rightharpoonup> "CONST All t"
  "?? t" \<rightharpoonup> "CONST Ex t"

  type_notation(input) i ("$i")
  (*... add others*)
end

bundle to_TPTP begin
declare [[eta_contract = false]] (*important, otherwise quantifiers like "\<forall>x y. f x y" break*)
no_notation (output) All (binder "\<forall>" 10)
no_notation (output) Ex  (binder \<open>\<exists>\<close> 10)
  translations
  "~a" \<leftharpoondown> "\<not>a"
  "a & b" \<leftharpoondown> "a \<and> b"
  "a | b" \<leftharpoondown> "a \<or> b"
  "a => b" \<leftharpoondown> "a \<longrightarrow> b"
  "a <=> b" \<leftharpoondown> "a \<longleftrightarrow> b"
  "a <~> b" \<leftharpoondown> "\<not>(a \<longleftrightarrow> b)"
  "a != b" \<leftharpoondown> "a \<noteq> b"
  "$true" \<leftharpoondown> "CONST True"
  "$false" \<leftharpoondown> "CONST False"
  (type) "$o" \<leftharpoondown> (type) "bool"
  (type) "'a > 'b" \<leftharpoondown> (type) "'a \<Rightarrow> 'b"
  "_thf_idtyp x T" \<leftharpoondown> "_idtyp x T"
  "_thf_constrain t T" \<leftharpoondown> "_constrain t T"
  "! [x] : t" \<leftharpoondown> "CONST All (\<lambda>x. t)"
  "? [x] : t" \<leftharpoondown> "CONST Ex (\<lambda>x. t)" 
  "^ [x] : t" \<leftharpoondown> "(\<lambda>x. t)"
  "!! t" \<leftharpoondown> "CONST All t"
  "?? t" \<leftharpoondown> "CONST Ex t"

  type_notation(output) i ("$i")
  (*... add others*)
end

(* Reifying @s in THF *)
ML \<open>
  (* A list of "protected" constants that we don't want to convert:*)
  val protected = Symtab.make_set
      [@{const_name HOL.conj},    (* otherwise "a \<and> b" becomes "(\<and>) @ a @ b" and so on ...*)
       @{const_name HOL.Not},  
       @{const_name HOL.disj},
       @{const_name HOL.implies},
       @{const_name HOL.eq},
       @{const_name HOL.All},
       @{const_name HOL.Ex},
       @{const_name HOL.Trueprop}
            (*...*)
      ]
  (* Detects heads that should keep their normal notation*)
  fun protected_head (Const (d, _)) =
      d = @{const_name thf_app} orelse Symtab.defined protected d
    | protected_head _ = false

  (* Builds a well-typed explicit application node ("thf_app f x")*) 
  fun app Ts f x =
    let
      val A = Term.fastype_of1 (Ts, x)
      val B = Term.fastype_of1 (Ts, f $ x)
    in
      Const (@{const_name thf_app}, (A --> B) --> A --> B) $ f $ x
    end

  (* Converts ordinary application chains into @-chains*)
  fun reify Ts (Abs (x, T, t)) =
        Abs (x, T, reify (T :: Ts) t)
    | reify Ts t =
        let val (h, xs) = Term.strip_comb t in
          if null xs orelse protected_head h
          then Term.list_comb (h, map (reify Ts) xs)
          else fold (fn x => fn f => app Ts f x) (map (reify Ts) xs) (reify Ts h)
        end

  (*Introduces a new configuration flag "show_thf_app" to enable/disable @-reification*)
  val show = Attrib.setup_config_bool @{binding show_thf_app} (K true)
  (* Runs @-reification before pretty-printing (only if the flag is set)*)
  fun uncheck ctxt = if Config.get ctxt show then map (reify []) else I
\<close>
(* Register "uncheck" as term-uncheck phase*)
setup \<open>Context.theory_map (Syntax_Phases.term_uncheck 100 "thf_app" uncheck)\<close>

end
