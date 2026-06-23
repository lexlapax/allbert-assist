defmodule AllbertAssist.Security.V054IntentRouterEvalTest do
  @moduledoc """
  v0.54 router, descriptor lifecycle foundation, outbound compose, and security
  eval (ADR 0060/0061/0062/0063). Consolidates the behavior- and authority-
  relevant invariants as deterministic assertions (local fakes; no live model).
  The full functional coverage lives in the focused test files; this set is the
  release gate's named eval rows.
  """
  use ExUnit.Case, async: false
  @moduletag :security_eval_serial
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Calendar.CreateCalendarEvent
  alias AllbertAssist.Actions.Channels.SendChannelMessage
  alias AllbertAssist.Actions.Email.SendEmail
  alias AllbertAssist.Intent.Router
  alias AllbertAssist.Intent.Router.ClarifyResolver
  alias AllbertAssist.Intent.Router.DescriptorResolver
  alias AllbertAssist.Intent.Router.DescriptorStore
  alias AllbertAssist.Intent.Router.Disambiguator
  alias AllbertAssist.Intent.Router.Disambiguator.FakeDisambiguator
  alias AllbertAssist.Intent.Router.Embedder.FakeEmbedder
  alias AllbertAssist.Intent.Router.Index
  alias AllbertAssist.Intent.Router.Optimizer
  alias AllbertAssist.Intent.Router.Outcome
  alias AllbertAssist.Intent.Router.Prefilter
  alias AllbertAssist.Paths
  alias AllbertAssist.Security.Policy
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Schema
  alias AllbertAssist.TestSupport.ProviderPreconditions

  @shortlist [
    %{action_name: "create_note", app_id: :notes_files, label: "Create or write a local note"},
    %{action_name: "search_notes", app_id: :notes_files, label: "Search local notes"}
  ]
  @opts [min_confidence: 0.6, disambiguation_margin: 0.12]

  setup do
    original = %{
      home: System.get_env("ALLBERT_HOME"),
      paths: Application.get_env(:allbert_assist, Paths),
      settings: Application.get_env(:allbert_assist, Settings),
      embedder: Application.get_env(:allbert_assist, :intent_router_embedder),
      disambiguator: Application.get_env(:allbert_assist, :intent_router_disambiguator),
      selection: Application.get_env(:allbert_assist, :intent_router_fake_selection),
      override: Application.get_env(:allbert_assist, :intent_router_strategy_override)
    }

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-v054-eval-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(home)
    System.put_env("ALLBERT_HOME", home)

    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)
    Application.put_env(:allbert_assist, :intent_router_embedder, FakeEmbedder)
    Application.put_env(:allbert_assist, :intent_router_disambiguator, FakeDisambiguator)
    Application.delete_env(:allbert_assist, :intent_router_embedder_error)
    ProviderPreconditions.ensure_notes_files_descriptors!()

    on_exit(fn ->
      if original.home,
        do: System.put_env("ALLBERT_HOME", original.home),
        else: System.delete_env("ALLBERT_HOME")

      restore(Paths, original.paths)
      restore(Settings, original.settings)
      restore(:intent_router_embedder, original.embedder)
      restore(:intent_router_disambiguator, original.disambiguator)
      restore(:intent_router_fake_selection, original.selection)
      restore(:intent_router_strategy_override, original.override)
      File.rm_rf!(home)
    end)

    :ok
  end

  # intent-router-shortlist-constrained-001 / authority-unchanged-001
  test "a selection outside the shortlist never executes (no hallucinated action)" do
    assert %Outcome{kind: :clarify} =
             Disambiguator.decide(
               %{selected: "delete_all_files", confidence: 0.99},
               @shortlist,
               0.5,
               @opts
             )
  end

  # intent-router-low-confidence-clarifies-001
  test "low confidence clarifies rather than guessing" do
    assert %Outcome{kind: :clarify} =
             Disambiguator.decide(
               %{selected: "create_note", confidence: 0.3},
               @shortlist,
               0.5,
               @opts
             )
  end

  # intent-router-escalation-local-by-default-001
  test "escalation default is a LOCAL profile (no remote egress); disabling falls to clarify" do
    # The shipped escalation target is local-only, so default escalation never egresses.
    {:ok, profile_name} = Settings.get("intent.router_escalation_profile")
    assert profile_name == "router_escalation_local"
    {:ok, profile} = Settings.resolve_model_profile(profile_name)
    assert profile.provider_endpoint_kind == "local_endpoint"

    # With escalation explicitly disabled, a low-confidence selection clarifies (no escalation call).
    Application.put_env(
      :allbert_assist,
      :intent_router_fake_selection,
      {:ok, %{selected: "create_note", confidence: 0.3}}
    )

    assert {:ok, %Outcome{kind: :clarify}} =
             Disambiguator.disambiguate(
               "note",
               @shortlist,
               0.5,
               %{},
               @opts ++ [escalation_profile: ""]
             )
  end

  # intent-router-create-vs-search-001 (the original mis-route regression)
  test "create-a-note shortlists write_note at or above search_notes" do
    Index.rebuild()

    assert {:ok, %{shortlist: shortlist}} =
             Prefilter.shortlist("create a note titled groceries with milk")

    scores = Map.new(shortlist, fn s -> {s.action_name, s.score} end)
    assert Map.has_key?(scores, "write_note")

    if Map.has_key?(scores, "search_notes"),
      do: assert(scores["write_note"] >= scores["search_notes"])
  end

  # intent-router-no-app-handoff-deadend-channel-001
  test "a clarify outcome is channel-answerable (carries a question + shortlist), not a dead-end" do
    outcome =
      Disambiguator.decide(%{selected: "__clarify__", confidence: 0.9}, @shortlist, 0.5, @opts)

    assert %Outcome{kind: :clarify, shortlist: @shortlist} = outcome
    assert is_binary(outcome.question) and outcome.question != ""
  end

  # intent-clarify-reply-revalidated-001 / pending-clarification re-classify-fresh
  test "an unrelated clarification reply does not bind (re-classified fresh)" do
    assert :no_match = ClarifyResolver.resolve("what's the weather", clarify_options())

    assert {:ok, %{id: "search_notes"}} =
             ClarifyResolver.resolve("the second one", clarify_options())
  end

  # intent-router-default-two-stage-local
  test "the shipped default routing strategy is the local two-stage router" do
    assert Schema.get_dotted(Schema.defaults(), "intent.router_strategy") == "two_stage_local"
    # the test env override keeps the suite deterministic
    assert Router.strategy() == :deterministic
  end

  # ── M9 descriptor-lifecycle eval rows (ADR 0062) ─────────────────────────────

  # intent-descriptor-new-action-routable-after-reindex-001
  test "a generated descriptor from the generated tier is resolved" do
    assert %{source: source} = descriptor_for("show_app")
    refute source == :generated

    {:ok, path} =
      DescriptorStore.put(:generated, %{
        app_id: :allbert,
        action_name: "show_app",
        label: "Generated show app",
        examples: ["generated show app"],
        synonyms: ["generated app"],
        vocabulary: %{phrases: ["generated show app"], allow_single_token_match: false},
        required_slots: []
      })

    assert String.ends_with?(path, "/intents/generated/allbert/show_app.yaml")
    assert %{source: :generated, label: "Generated show app"} = descriptor_for("show_app")
  end

  # intent-descriptor-yaml-store-data-only-001 /
  # intent-descriptor-invalid-yaml-fails-closed-001
  test "descriptor store is data-only YAML and invalid files fail closed" do
    generated = DescriptorStore.dir(:generated)
    File.mkdir_p!(Path.join(generated, "allbert"))

    File.write!(
      Path.join([generated, "allbert", "unsafe.exs"]),
      "%{action_name: \"unsafe_code_action\"}"
    )

    File.write!(Path.join([generated, "allbert", "broken.yaml"]), "not: [valid\n")

    refute DescriptorStore.read_attrs(:generated)
           |> Enum.any?(
             &((Map.get(&1, "action_name") || Map.get(&1, :action_name)) ==
                 "unsafe_code_action")
           )
  end

  # intent-descriptor-override-precedence-001 (disable removes a descriptor)
  test "an operator disable override removes an action from the resolved set" do
    assert DescriptorResolver.resolve() |> Enum.any?(&(&1.action_name == "send_email"))

    {:ok, _path} =
      DescriptorStore.put(:overrides, %{
        app_id: :allbert,
        action_name: "send_email",
        disabled: true
      })

    refute DescriptorResolver.resolve() |> Enum.any?(&(&1.action_name == "send_email"))
  end

  # intent-descriptor-grants-no-authority-001 (routable != executable)
  test "a descriptor does not change the action's confirmation gate" do
    descriptor = DescriptorResolver.resolve() |> Enum.find(&(&1.action_name == "send_email"))
    assert descriptor.source == :action
    assert descriptor.required_slots == [:to, :body]
    assert descriptor.capability.confirmation == :required
  end

  # intent-descriptor-dynamic-inert-until-promoted-001 /
  # intent-descriptor-review-tier-inert-001
  test "a review-tier descriptor is inert until promoted" do
    attrs = %{
      app_id: :allbert,
      action_name: "show_app",
      label: "Review show app",
      examples: ["review show app"],
      synonyms: ["review app"],
      required_slots: []
    }

    {:ok, _} = DescriptorStore.put(:review, attrs)

    refute DescriptorResolver.resolve()
           |> Enum.any?(&(&1.action_name == "show_app" and &1.source == :review))

    {:ok, _} = DescriptorStore.promote(:review, :generated, :allbert, "show_app")
    assert %{source: :generated, label: "Review show app"} = descriptor_for("show_app")
  end

  # intent-descriptor-heuristic-generation-local-only-001
  test "heuristic descriptor generation is deterministic and offline" do
    module =
      AllbertAssist.Actions.Registry.modules()
      |> Enum.find(&(&1.name() == "show_app"))

    attrs = Optimizer.generate(module, :heuristic)
    assert attrs.action_name == "show_app"
    assert is_binary(attrs.label) and attrs.label != ""
    assert is_list(attrs.examples) and attrs.examples != []
  end

  # ── M10 outbound-compose eval rows (ADR 0063) ────────────────────────────────

  # m10-permission-floors-001
  test "outbound permissions default to a needs_confirmation floor" do
    for permission <- [:email_send, :channel_message_send, :calendar_write] do
      assert Policy.resolve(permission, %{}).effective == :needs_confirmation
    end
  end

  # m10-send-email-reaches-confirmation-001 (+ outbound-grants-no-authority)
  test "send_email reaches the confirmation gate and never auto-sends" do
    assert {:ok, response} = SendEmail.run(%{to: "a@example.com", body: "hello"}, %{})
    assert response.status == :needs_confirmation
    assert is_binary(response.confirmation_id)
  end

  # m10-channel-send-target-gated-001
  test "send_channel_message rejects an un-allowlisted target before dispatch" do
    assert {:ok, response} =
             SendChannelMessage.run(%{channel: "slack", target: "#random", body: "hi"}, %{})

    assert response.status == :stopped
    assert match?({:target_rejected, _}, response.error)
  end

  # m10-calendar-mcp-backed-001 (graceful when no calendar MCP server)
  test "create_calendar_event degrades gracefully without a calendar MCP server" do
    assert {:ok, response} = CreateCalendarEvent.run(%{title: "sync", start: "tomorrow 3pm"}, %{})
    assert response.status in [:answer, :failed]
  end

  # m10-outbound-resumable-001 (confirmation-gated + opt-in resumable; routable != executable)
  test "outbound actions are confirmation-required and resumable" do
    for module <- [SendEmail, SendChannelMessage, CreateCalendarEvent] do
      capability = module.capability()
      assert capability.confirmation == :required
      assert capability.resumable? == true
    end
  end

  defp clarify_options do
    Enum.map(@shortlist, fn s -> %{kind: :action, id: s.action_name, label: s.label} end)
  end

  defp descriptor_for(action_name) do
    DescriptorResolver.resolve()
    |> Enum.find(&(&1.action_name == action_name))
  end

  defp restore(key, nil) when is_atom(key), do: Application.delete_env(:allbert_assist, key)
  defp restore(key, value), do: Application.put_env(:allbert_assist, key, value)
end
