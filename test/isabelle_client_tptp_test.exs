defmodule IsabelleClientTPTPTest do
  use ExUnit.Case, async: false

  alias IsabelleClient.Task

  test "isabellizes annotated THF formulae" do
    tptp = """
    % Basic declarations.
    thf(type_entity,type,(entity: $tType)).
    thf(type_pred,type,(human: entity > $o)).
    thf(type_alias,type,(predicate: entity > $o = entity > $o)).

    thf(ax_human,axiom,
      (! [X: entity] : (human @ X) => (human @ X)),
      [simp]).

    thf(conj_human,conjecture,
      (? [X: entity] : (human @ X))).
    """

    assert IsabelleClient.TPTP.isabellize_theory(tptp) == """
           (* Basic declarations. *)

           typedecl entity

           consts human :: "entity > $o"

           type_synonym predicate = "entity > $o"

           axiomatization where ax_human[simp]: "(! [X: entity] : (human @ X) => (human @ X))"

           lemma conj_human: "(? [X: entity] : (human @ X))"
           """
  end

  test "isabellizes varied metadata lists without requiring a special shape" do
    tptp = """
    thf(type_i,type,(i: $tType), file('example.p', type_i), [description('type')]).
    thf(type_p,type,(p: i > $o), introduced(local)).
    thf(ax_intro,axiom,(p @ a), file('example.p', ax_intro), [intro, relevance(0.8)]).
    thf(ax_iff,axiom,((p @ a) <=> (p @ a)), [named('anything'), iff]).
    thf(thm_elim,theorem,(p @ a), [source(foo,bar), elim, unknown(metadata, with, commas)]).
    """

    assert IsabelleClient.TPTP.isabellize_theory(tptp) == """
           typedecl i

           consts p :: "i > $o"

           axiomatization where ax_intro[intro, relevance(0.8)]: "(p @ a)"

           axiomatization where ax_iff[named('anything'), iff]: "((p @ a) <=> (p @ a))"

           lemma thm_elim[source(foo,bar), elim, unknown(metadata, with, commas)]: "(p @ a)"
           """
  end

  test "isabellizes TPTP line and block comments" do
    tptp = """
    % A leading line comment.
    thf(type_i,type,(i: $tType)).
    /* A block comment
       spanning two lines. */
    thf(type_a,type,(a: i)).
    thf(ax,axiom,(a = a)). % trailing comment
    """

    assert IsabelleClient.TPTP.isabellize_theory(tptp) == """
           (* A leading line comment. *)

           typedecl i

           (* A block comment
              spanning two lines. *)

           consts a :: "i"

           axiomatization where ax: "(a = a)"

           (* trailing comment *)
           """
  end

  test "isabellizes simple include directives" do
    tptp = """
    include('Axioms/SET001.ax').
    include('Problems/PUZ001+0.p', [agatha, butler]).
    thf(type_i,type,(i: $tType)).
    """

    assert IsabelleClient.TPTP.isabellize_theory(tptp) == """
           imports "Axioms/SET001"

           imports "Problems/PUZ001+0"

           typedecl i
           """
  end

  @tag timeout: 180_000
  test "loads bundled TPTP support into an existing HOL session" do
    IsabelleTestSupport.with_server("tptp", fn server ->
      assert {:ok, client} =
               IsabelleClient.connect(server["password"],
                 host: server["host"],
                 port: server["port"]
               )

      assert {:error, :no_session} = IsabelleClient.TPTP.load(client)

      assert {:ok, client, %Task{status: :finished}} =
               IsabelleClient.start_session(client, [session: "HOL"], 120_000)

      assert {:ok, %Task{status: :finished, result: %{"ok" => true}} = load_task} =
               IsabelleClient.TPTP.load(client, 120_000)

      assert IsabelleClient.errors(load_task) == []

      assert IsabelleClient.TPTP.check(
               client,
               "TPTP",
               "TPTPLoadedExample",
               """
               typedecl entity
               consts human :: "entity > $o"
               consts socrates :: entity

               lemma "(human @ socrates) => (human @ socrates)"
                 unfolding thf_app_def
                 by blast
               """,
               from: true,
               timeout: 120_000
             ) =~ "theorem human @ socrates"

      assert "" =
               IsabelleClient.TPTP.check(
                 client,
                 "TPTP",
                 "TPTPQuietExample",
                 "typedecl quiet",
                 timeout: 120_000
               )

      annotated =
        """
        thf(type_living,type,(living: $tType)).
        thf(type_lives,type,(lives: living > $o)).
        thf(ax_lives,axiom,(! [X: living] : (lives @ X) => (lives @ X)),[simp]).
        thf(conj_lives,conjecture,(? [X: living] : (lives @ X))).
        """

      assert "" =
               IsabelleClient.TPTP.check(
                 client,
                 "TPTP",
                 "TPTPAnnotatedFormulae",
                 IsabelleClient.TPTP.isabellize_theory(annotated) <> "\noops",
                 from: true,
                 timeout: 120_000
               )

      rich_metadata =
        """
        thf(type_person,type,(person: $tType), file('rich.p', type_person)).
        thf(type_good,type,(good: person > $o), introduced(local)).
        thf(type_alice,type,(alice: person), [description('constant')]).
        thf(ax_good,axiom,((good @ alice) => (good @ alice)),
          file('rich.p', ax_good),
          [simp]).
        thf(thm_good,theorem,((good @ alice) => (good @ alice)),
          inference(copy, [], [ax_good]),
          [intro]).
        """

      assert IsabelleClient.TPTP.check(
               client,
               "TPTP",
               "TPTPRichMetadata",
               IsabelleClient.TPTP.isabellize_theory(rich_metadata) <> "\nby simp",
               from: true,
               timeout: 120_000
             ) =~ "theorem thm_good"

      assert "" =
               IsabelleClient.TPTP.check(
                 client,
                 "TPTP",
                 "TPTPQuietAfterRichMetadata",
                 "typedecl quiet_after_rich_metadata",
                 timeout: 120_000
               )

      assert {:ok, client, %Task{status: :finished}} =
               IsabelleClient.stop_session(client, 120_000)

      assert client.sessions == []
      assert {:ok, nil} = IsabelleClient.shutdown_server(client)
      assert :ok = IsabelleClient.close(client)
    end)
  end
end
