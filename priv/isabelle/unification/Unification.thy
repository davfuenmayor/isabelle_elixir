theory Unification
  imports Main
  keywords "unification" :: diag
begin

ML \<open>
structure Unification =
struct
  fun err kind n got =
    error (kind ^ " expects " ^ string_of_int n ^ " arguments, got " ^ string_of_int got);

  fun schematic_typ ctxt =
    Syntax.read_typ ctxt #>
    Term.map_atyps (fn TFree (a, S) => TVar ((a, 0), S) | T => T);

  fun show title xs =
    writeln (title ^ "\n" ^ cat_lines (map (prefix "  ") xs));

  fun commas_or_none [] = "no assignments"
    | commas_or_none xs = commas xs;

  fun tyenv ctxt =
    Vartab.dest #> map (fn (xi, (_, T)) =>
      Term.string_of_vname xi ^ " := " ^ Syntax.string_of_typ ctxt T);

  fun tenv ctxt =
    Vartab.dest #> map (fn (xi, (T, t)) =>
      Term.string_of_vname xi ^ " :: " ^ Syntax.string_of_typ ctxt T ^
        " := " ^ Syntax.string_of_term ctxt t);

  fun assignments ctxt (Envir.Envir {tenv = tenv', tyenv = tyenv', ...}) =
    map (prefix "type ") (tyenv ctxt tyenv') @
    map (prefix "term ") (tenv ctxt tenv');

  fun unifier_lines ctxt xs =
    maps (fn (i, (e, ff)) =>
      ("result " ^ string_of_int (i + 1) ^
        ": flex-flex pairs = " ^ string_of_int (length ff) ^
        ", " ^ commas_or_none (assignments ctxt e)) ::
      map (fn (l, r) =>
        "  flex-flex " ^ Syntax.string_of_term ctxt l ^ " =? " ^
          Syntax.string_of_term ctxt r) ff) (map_index I xs);

  fun command kind args st =
    let
      val ctxt = Toplevel.context_of st;
      val thy = Proof_Context.theory_of ctxt;
      val context = Context.Proof ctxt;
      val read = Proof_Context.read_term_schematic ctxt;
      val readT = schematic_typ ctxt;
    in
      (case (kind, args) of
        ("type_match", [a, b]) =>
          show "Sign.typ_match" (tyenv ctxt (Sign.typ_match thy (readT a, readT b) Vartab.empty))
      | ("type_match", xs) => err kind 2 (length xs)
      | ("type_unify", [a, b]) =>
          show "Sign.typ_unify"
            (tyenv ctxt (#1 (Sign.typ_unify thy (readT a, readT b) (Vartab.empty, 0))))
      | ("type_unify", xs) => err kind 2 (length xs)
      | ("pattern_unify", [a, b]) =>
          show "Pattern.unify"
            (assignments ctxt (Pattern.unify context (apply2 read (a, b)) (Envir.empty 0)))
      | ("pattern_unify", xs) => err kind 2 (length xs)
      | ("pattern_match", [a, b]) =>
          let val (tys, ts) = Pattern.match thy (apply2 read (a, b)) (Vartab.empty, Vartab.empty)
          in
            show "Pattern.match type assignments" (tyenv ctxt tys);
            show "Pattern.match term assignments" (tenv ctxt ts)
          end
      | ("pattern_match", xs) => err kind 2 (length xs)
      | ("pattern_matches", [a, b]) =>
          writeln ("Pattern.matches: " ^ Bool.toString (Pattern.matches thy (apply2 read (a, b))))
      | ("pattern_matches", xs) => err kind 2 (length xs)
      | ("pattern_rewrite", [target, lhs, rhs]) =>
          (case Pattern.match_rew thy (read target) (read lhs, read rhs) of
            NONE => writeln "Pattern.match_rew:\n  no match"
          | SOME (inst, raw) =>
              writeln ("Pattern.match_rew:\n  instantiated rhs = " ^
                Syntax.string_of_term ctxt inst ^ "\nraw renamed rhs = " ^
                Syntax.string_of_term ctxt raw))
      | ("pattern_rewrite", xs) => err kind 3 (length xs)
      | ("unifiers", [a, b]) =>
          show "Unify.unifiers"
            (unifier_lines ctxt
              (Unify.unifiers (context, Envir.empty 0, [apply2 read (a, b)]) |> Seq.list_of))
      | ("unifiers", xs) => err kind 2 (length xs)
      | ("smash_unifiers", [a, b]) =>
          show "Unify.smash_unifiers"
            (map (commas_or_none o assignments ctxt)
              (Unify.smash_unifiers context [apply2 read (a, b)] (Envir.empty 0) |> Seq.list_of))
      | ("smash_unifiers", xs) => err kind 2 (length xs)
      | ("matchers", [a, b]) =>
          show "Unify.matchers"
            (map (commas_or_none o assignments ctxt)
              (Unify.matchers context [apply2 read (a, b)] |> Seq.list_of))
      | ("matchers", xs) => err kind 2 (length xs)
      | ("matcher", [a, b]) =>
          (case Unify.matcher context [read a] [read b] of
            NONE => writeln "Unify.matcher: no matcher"
          | SOME e => show "Unify.matcher" (assignments ctxt e))
      | ("matcher", xs) => err kind 2 (length xs)
      | _ =>
          error ("Unknown unification kind " ^ quote kind ^ ". Available kinds: " ^
            commas_quote ["type_unify", "type_match", "pattern_unify", "pattern_match",
              "pattern_matches", "pattern_rewrite", "unifiers", "smash_unifiers",
              "matchers", "matcher"]))
    end
    handle
        Type.TUNIFY => writeln "Type.TUNIFY: types are not unifiable"
      | Type.TYPE_MATCH => writeln "Type.TYPE_MATCH: type does not match"
      | Pattern.Unif => writeln "Pattern.Unif: terms/types are not unifiable"
      | Pattern.Pattern => writeln "Pattern.Pattern: outside the higher-order pattern fragment"
      | Pattern.MATCH => writeln "Pattern.MATCH: term does not match";
end;

val _ =
  Outer_Syntax.command \<^command_keyword>\<open>unification\<close>
    "run Isabelle unification or matching on supplied types/terms"
    (Parse.name -- Scan.repeat1 Parse.embedded >>
      (fn (kind, args) => Toplevel.keep (Unification.command kind args)));
\<close>

end
