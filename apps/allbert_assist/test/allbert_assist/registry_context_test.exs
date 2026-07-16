defmodule AllbertAssist.RegistryContextTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  # v1.0.2 M2 (ADR 0082) proof suite for the registry injection seam:
  #
  #   1. Default-path identity — empty opts read exactly what the no-argument
  #      functions read (values and order included).
  #   2. Two concurrent private contexts never cross-contaminate registrations,
  #      capabilities, descriptors, diagnostics, provenance, or skills, and
  #      neither leaks into the global default read.
  #   3. `side_effects: false` registration emits no global registration signal
  #      and does not clear the shared Settings-schema cache.

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Extensions.Registry, as: ExtensionsRegistry
  alias AllbertAssist.Intent.Engine
  alias AllbertAssist.Intent.EvalFixtures
  alias AllbertAssist.Plugin.Entry, as: PluginEntry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Settings.Fragments, as: SettingsFragments
  alias AllbertAssist.Skills
  alias AllbertAssist.TestSupport.RegistryIsolationFixtures, as: Fixtures
  alias Jido.Signal.Bus

  defmodule ContextProbeA do
    use Jido.Action,
      name: "registry_context_probe_a",
      description: "Context A probe action for registry isolation tests.",
      schema: []

    def capability do
      %{
        permission: :read_only,
        exposure: :agent,
        execution_mode: :read_only,
        skill_backed?: false,
        confirmation: :not_required
      }
    end

    @impl true
    def run(_params, _context), do: {:ok, %{status: :completed}}
  end

  defmodule ContextProbeB do
    use Jido.Action,
      name: "registry_context_probe_b",
      description: "Context B probe action for registry isolation tests.",
      schema: []

    def capability do
      %{
        permission: :read_only,
        exposure: :agent,
        execution_mode: :read_only,
        skill_backed?: false,
        confirmation: :not_required
      }
    end

    @impl true
    def run(_params, _context), do: {:ok, %{status: :completed}}
  end

  defmodule ContextAppA do
    use AllbertAssist.App

    @impl true
    def app_id, do: :registry_context_app_a

    @impl true
    def display_name, do: "Registry Context App A"

    @impl true
    def version, do: "1.0.2"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def actions, do: [DirectAnswer]

    @impl true
    def skill_paths, do: [AllbertAssist.RegistryContextTest.skill_root(:a)]

    # Inert descriptor (registered?: false), like the research descriptors:
    # Descriptor.normalize verifies registered capabilities against the GLOBAL
    # Actions.Registry, which a private-context action cannot satisfy.
    def intent_descriptors do
      [
        %{
          app_id: :registry_context_app_a,
          action_name: "registry_context_probe_a",
          label: "Registry context probe A",
          examples: ["probe registry context a"],
          synonyms: ["registry context a probe"],
          required_slots: [],
          handoff_required?: true,
          capability: %{registered?: false}
        }
      ]
    end
  end

  defmodule ContextAppB do
    use AllbertAssist.App

    @impl true
    def app_id, do: :registry_context_app_b

    @impl true
    def display_name, do: "Registry Context App B"

    @impl true
    def version, do: "1.0.2"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def actions, do: [DirectAnswer]

    @impl true
    def skill_paths, do: [AllbertAssist.RegistryContextTest.skill_root(:b)]

    def intent_descriptors do
      [
        %{
          app_id: :registry_context_app_b,
          action_name: "registry_context_probe_b",
          label: "Registry context probe B",
          examples: ["probe registry context b"],
          synonyms: ["registry context b probe"],
          required_slots: [],
          handoff_required?: true,
          capability: %{registered?: false}
        }
      ]
    end
  end

  defmodule ContextAppC do
    use AllbertAssist.App

    @impl true
    def app_id, do: :registry_context_app_c

    @impl true
    def display_name, do: "Registry Context App C"

    @impl true
    def version, do: "1.0.2"

    @impl true
    def validate(_opts), do: :ok
  end

  # Skill roots live under the per-run test home (unique per `mix test`
  # invocation), keyed by MIX_TEST_PARTITION so partitioned runs cannot collide.
  def skill_root(tag) do
    partition = System.get_env("MIX_TEST_PARTITION") || "0"

    Path.join(
      AllbertAssist.Paths.home(),
      "registry-context-fixtures/skills-#{tag}-p#{partition}"
    )
  end

  describe "default-path identity" do
    test "Actions.Registry reads with empty opts equal the no-argument reads" do
      assert ActionsRegistry.modules([]) == ActionsRegistry.modules()
      assert ActionsRegistry.agent_modules([]) == ActionsRegistry.agent_modules()
      assert ActionsRegistry.names([]) == ActionsRegistry.names()
      assert ActionsRegistry.capabilities([]) == ActionsRegistry.capabilities()
      assert ActionsRegistry.agent_capabilities([]) == ActionsRegistry.agent_capabilities()
      assert ActionsRegistry.internal_capabilities([]) == ActionsRegistry.internal_capabilities()
      assert ActionsRegistry.diagnostics([]) == ActionsRegistry.diagnostics()
      assert ActionsRegistry.duplicate_names([]) == ActionsRegistry.duplicate_names()

      assert ActionsRegistry.resolve("direct_answer", []) ==
               ActionsRegistry.resolve("direct_answer")

      assert ActionsRegistry.capability("direct_answer", []) ==
               ActionsRegistry.capability("direct_answer")
    end

    test "Skills.Registry reads with an empty registry context equal the default reads" do
      assert Skills.Registry.load(%{registry: []}) == Skills.Registry.load(%{})
      assert Skills.Registry.list(%{registry: []}) == Skills.Registry.list(%{})
    end

    test "Engine.decide/2 with empty opts equals decide/1 for a fixed request" do
      request = EvalFixtures.request(text: "hello there")

      assert Engine.decide(request, []) == Engine.decide(request)
      assert Engine.collect_candidates(request, []) == Engine.collect_candidates(request)
    end
  end

  describe "two isolated contexts" do
    test "registrations, capabilities, descriptors, diagnostics, provenance, and skills never cross-contaminate or leak globally" do
      context_a = Fixtures.start_isolated_registries(:registry_context_a)
      context_b = Fixtures.start_isolated_registries(:registry_context_b)

      write_probe_skill!(:a)
      write_probe_skill!(:b)

      # Register a distinct fake app + plugin into each context CONCURRENTLY;
      # the registrations are side-effect isolated and must not interfere.
      task_a =
        Task.async(fn ->
          Fixtures.register_plugin!(
            context_a,
            plugin_entry("registry_context.plugin_a", [ContextProbeA])
          )

          Fixtures.register_app!(context_a, ContextAppA)
        end)

      task_b =
        Task.async(fn ->
          Fixtures.register_plugin!(
            context_b,
            plugin_entry("registry_context.plugin_b", [ContextProbeB])
          )

          Fixtures.register_app!(context_b, ContextAppB)
        end)

      assert Task.await(task_a) == :registry_context_app_a
      assert Task.await(task_b) == :registry_context_app_b

      # Registrations are visible only inside their own context.
      assert AppRegistry.known_app_id?(:registry_context_app_a, context_a[:app])
      refute AppRegistry.known_app_id?(:registry_context_app_a, context_b[:app])
      refute AppRegistry.known_app_id?(:registry_context_app_a)
      assert AppRegistry.known_app_id?(:registry_context_app_b, context_b[:app])
      refute AppRegistry.known_app_id?(:registry_context_app_b, context_a[:app])
      refute AppRegistry.known_app_id?(:registry_context_app_b)

      # Plugin-contributed action modules and names stay context-local.
      assert "registry_context_probe_a" in ActionsRegistry.names(context_a)
      refute "registry_context_probe_b" in ActionsRegistry.names(context_a)
      assert "registry_context_probe_b" in ActionsRegistry.names(context_b)
      refute "registry_context_probe_a" in ActionsRegistry.names(context_b)
      refute "registry_context_probe_a" in ActionsRegistry.names()
      refute "registry_context_probe_b" in ActionsRegistry.names()

      # Capability resolution and plugin provenance stay context-local.
      assert {:ok, capability_a} =
               ActionsRegistry.capability("registry_context_probe_a", context_a)

      assert capability_a.plugin_id == "registry_context.plugin_a"

      assert {:error, {:unknown_action, _}} =
               ActionsRegistry.capability("registry_context_probe_a", context_b)

      assert {:error, {:unknown_action, _}} =
               ActionsRegistry.capability("registry_context_probe_a")

      # App provenance: the same static action resolves to each context's app.
      assert {:ok, direct_answer_a} = ActionsRegistry.capability(DirectAnswer, context_a)
      assert direct_answer_a.app_id == :registry_context_app_a
      assert {:ok, direct_answer_b} = ActionsRegistry.capability(DirectAnswer, context_b)
      assert direct_answer_b.app_id == :registry_context_app_b
      assert {:ok, direct_answer_global} = ActionsRegistry.capability(DirectAnswer)
      refute direct_answer_global.app_id in [:registry_context_app_a, :registry_context_app_b]

      # Descriptors from the app modules stay context-local.
      descriptors_a = ExtensionsRegistry.registered_intent_descriptors(context_a)
      assert Enum.any?(descriptors_a, &(&1.action_name == "registry_context_probe_a"))
      refute Enum.any?(descriptors_a, &(&1.action_name == "registry_context_probe_b"))
      descriptors_b = ExtensionsRegistry.registered_intent_descriptors(context_b)
      assert Enum.any?(descriptors_b, &(&1.action_name == "registry_context_probe_b"))
      refute Enum.any?(descriptors_b, &(&1.action_name == "registry_context_probe_a"))
      descriptors_global = ExtensionsRegistry.registered_intent_descriptors()
      refute Enum.any?(descriptors_global, &(&1.action_name =~ "registry_context_probe"))

      # Engine candidate collection follows the context end-to-end.
      request = EvalFixtures.request(text: "probe registry context a")
      candidates_a = Engine.collect_candidates(request, context_a)

      assert Enum.any?(
               candidates_a,
               &match?(%{kind: :app_intent, action_name: "registry_context_probe_a"}, &1)
             )

      refute Enum.any?(candidates_a, &match?(%{action_name: "registry_context_probe_b"}, &1))
      candidates_b = Engine.collect_candidates(request, context_b)
      refute Enum.any?(candidates_b, &match?(%{action_name: "registry_context_probe_a"}, &1))
      candidates_global = Engine.collect_candidates(request)
      refute Enum.any?(candidates_global, &match?(%{action_name: "registry_context_probe_a"}, &1))
      refute Enum.any?(candidates_global, &match?(%{action_name: "registry_context_probe_b"}, &1))

      # Diagnostics stay context-local: a plugin action colliding with a static
      # action name is diagnosed only inside the context that registered it.
      Fixtures.register_plugin!(
        context_a,
        plugin_entry("registry_context.collision_a", [ContextProbeA])
      )

      diagnostics_a = ActionsRegistry.diagnostics(context_a)
      assert Enum.any?(diagnostics_a, &(&1[:plugin_id] == "registry_context.collision_a"))

      refute Enum.any?(
               ActionsRegistry.diagnostics(context_b),
               &(&1[:plugin_id] == "registry_context.collision_a")
             )

      refute Enum.any?(
               ActionsRegistry.diagnostics(),
               &(&1[:plugin_id] == "registry_context.collision_a")
             )

      # App-declared skill roots stay context-local.
      assert {:ok, skills_a} = Skills.Registry.list(%{registry: context_a})
      assert Enum.any?(skills_a, &(&1.name == "registry-context-probe-skill-a"))
      refute Enum.any?(skills_a, &(&1.name == "registry-context-probe-skill-b"))
      assert {:ok, skills_b} = Skills.Registry.list(%{registry: context_b})
      assert Enum.any?(skills_b, &(&1.name == "registry-context-probe-skill-b"))
      refute Enum.any?(skills_b, &(&1.name == "registry-context-probe-skill-a"))
      assert {:ok, skills_global} = Skills.Registry.list(%{})
      refute Enum.any?(skills_global, &(&1.name =~ "registry-context-probe-skill"))
    end
  end

  describe "side_effects: false" do
    test "private registration emits no global registration signal and keeps the Settings-schema cache" do
      context = Fixtures.start_isolated_registries(:registry_context_side_effects)

      assert {:ok, _app_subscription} = Bus.subscribe(AllbertAssist.SignalBus, "allbert.app.**")

      assert {:ok, _plugin_subscription} =
               Bus.subscribe(AllbertAssist.SignalBus, "allbert.plugin.**")

      assert {:ok, _action_subscription} =
               Bus.subscribe(AllbertAssist.SignalBus, "allbert.action.**")

      # Warm the shared Settings-schema cache with the real global composition
      # so invalidation is observable. Nothing in the pure_async lane mutates
      # the global registries, so the cached term stays stable for this test.
      _ = SettingsFragments.schema()
      cache_key = {SettingsFragments, :default_composition}
      cached = :persistent_term.get(cache_key, nil)
      refute is_nil(cached)

      assert Fixtures.register_app!(context, ContextAppC) == :registry_context_app_c

      assert Fixtures.register_plugin!(
               context,
               plugin_entry("registry_context.plugin_c", [ContextProbeA])
             ) == "registry_context.plugin_c"

      # Registry-local state is intact while the global default sees nothing.
      assert AppRegistry.known_app_id?(:registry_context_app_c, context[:app])
      refute AppRegistry.known_app_id?(:registry_context_app_c)
      assert {:ok, _entry} = PluginRegistry.lookup("registry_context.plugin_c", context[:plugin])
      assert PluginRegistry.lookup("registry_context.plugin_c") == {:error, :not_found}

      # No global registration signal was emitted for the fixture set...
      refute_receive {:signal,
                      %{type: "allbert.app.registered", data: %{app_id: :registry_context_app_c}}},
                     200

      refute_receive {:signal,
                      %{
                        type: "allbert.plugin.registered",
                        data: %{plugin_id: "registry_context.plugin_c"}
                      }},
                     100

      refute_receive {:signal,
                      %{
                        type: "allbert.action.registry_changed",
                        data: %{app_id: :registry_context_app_c}
                      }},
                     100

      # ...and the shared Settings-schema cache was not invalidated.
      assert :persistent_term.get(cache_key, nil) == cached
    end
  end

  defp plugin_entry(plugin_id, actions) do
    %PluginEntry{
      plugin_id: plugin_id,
      display_name: "Registry Context Fixture #{plugin_id}",
      version: "1.0.2",
      kind: "actions",
      source: :project,
      status: :enabled,
      trust_status: :trusted,
      actions: actions
    }
  end

  defp write_probe_skill!(tag) do
    skill_dir = Path.join(skill_root(tag), "registry-context-probe-skill-#{tag}")
    File.mkdir_p!(skill_dir)

    File.write!(Path.join(skill_dir, "SKILL.md"), """
    ---
    name: registry-context-probe-skill-#{tag}
    description: Registry context probe skill #{tag} for isolation tests.
    ---

    Probe skill body for registry context #{tag}.
    """)

    on_exit(fn -> File.rm_rf!(skill_root(tag)) end)
  end
end
