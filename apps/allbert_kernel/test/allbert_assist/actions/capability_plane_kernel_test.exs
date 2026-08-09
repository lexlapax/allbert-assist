defmodule AllbertAssist.Actions.CapabilityPlaneKernelTest do
  # Runs in the kernel application alone: no database, no Allbert Home, no
  # registry fixtures, no composition. That is the point — after M8 the
  # Capability Plane is kernel code, and this proves it behaves correctly
  # against its own contracts rather than against the pack. The residual
  # integration suites still cover the wired-up product; these rows cover what
  # the kernel guarantees on its own.
  #
  # The lane is global_process_serial, not pure_async: these rows read two
  # globally named GenServers, `Pack.Registry` and `Pack.Readiness`. The reads
  # are safe, but claiming pure_async would overstate the isolation, and the
  # lane checker classifies it correctly.
  use ExUnit.Case, async: false

  @moduletag :global_process_serial

  alias AllbertAssist.Actions.ParamContract
  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.RegistryContext
  alias AllbertAssist.Runtime.Response

  defmodule StrictAction do
    @moduledoc false
    use AllbertAssist.Action,
      registry_order: 900_001,
      permission: :read_only,
      exposure: :internal,
      execution_mode: :read_only,
      skill_backed?: false,
      confirmation: :not_required,
      name: "kernel_strict_action",
      description: "Kernel-owned param contract fixture.",
      category: "test",
      schema: [text: [type: :string, required: true], count: [type: :integer, default: 1]]

    @impl true
    def run(params, _context), do: {:ok, params}
  end

  describe "the action registry with no finalized catalog" do
    # The kernel ships no action list of its own — ADR 0098 deleted it — so
    # without a finalized Pack snapshot the catalog is empty. Every lookup must
    # refuse rather than improvise.

    test "resolution refuses every shape of unknown action" do
      for action <- ["kernel_strict_action", :kernel_strict_action, StrictAction, "", 42] do
        assert {:error, {:unknown_action, ^action}} = Registry.resolve(action)
      end
    end

    test "capability lookup refuses instead of synthesising metadata" do
      assert {:error, {:unknown_action, _}} = Registry.capability("kernel_strict_action")
      assert {:error, {:unknown_action, _}} = Registry.capability(StrictAction)
    end

    test "an unregistered module is never reported as registered" do
      refute Registry.registered_module?(StrictAction)
      refute Registry.resumable?(StrictAction)
    end

    test "the empty catalog is empty rather than partially populated" do
      assert Registry.modules() == []
      assert Registry.names() == []
      assert Registry.agent_modules() == []
      assert Registry.capabilities() == []
      assert Registry.duplicate_names() == []
    end
  end

  describe "the runner's fail-closed boundary" do
    # Readiness never opens in a kernel-only VM, so every row here exercises the
    # refusal path. That is the security-relevant direction: the kernel must
    # decline to run work it cannot prove admissible.

    test "an unready product refuses a known-shaped call" do
      assert {:ok, response} = Runner.run("kernel_strict_action", %{"text" => "hi"}, %{})
      assert response.status == :unavailable
      assert response.error == :product_not_ready
    end

    test "an unready product refuses before deciding the action is unknown" do
      # The readiness gate runs first, so an unknown action and a known one are
      # refused identically. Resolution never happens, which is what keeps an
      # unadmitted call from reaching the registry at all.
      assert {:ok, unknown} = Runner.run("no_such_action_at_all", %{}, %{})
      assert unknown.error == :product_not_ready
    end

    test "non-map params are refused without reaching an action body" do
      assert {:ok, response} = Runner.run("kernel_strict_action", :not_a_map, %{})
      assert response.status == :unavailable
      assert response.error == :product_not_ready
    end

    test "a caller-supplied activation carrier cannot buy admission" do
      # The carrier is the internal boot-time token. Accepting it at a public
      # boundary would let a caller claim readiness it was never granted.
      assert {:ok, response} =
               Runner.run("kernel_strict_action", %{}, %{allbert_pack_activation: :forged})

      assert response.error == :product_not_ready
    end
  end

  describe "the param contract" do
    # ParamContract is pure: it needs no registry, no readiness, and no
    # database, so the kernel can prove it outright.

    test "string keys normalise to schema atoms and defaults are applied" do
      assert {:ok, params} =
               ParamContract.normalize_and_validate(StrictAction, %{"text" => "hello"})

      assert params == %{text: "hello", count: 1}
    end

    test "an unknown string key is rejected without creating an atom" do
      unknown = "kernel_unknown_param_#{System.unique_integer([:positive])}"

      assert {:error, {:unknown_params, "kernel_strict_action", [^unknown]}} =
               ParamContract.normalize_and_validate(StrictAction, %{
                 "text" => "hello",
                 unknown => "x"
               })

      # The rejection must not be the thing that creates the atom it rejects.
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    end

    test "a missing required key is rejected rather than defaulted" do
      assert {:error, reason} = ParamContract.normalize_and_validate(StrictAction, %{})
      refute match?({:unknown_params, _, _}, reason)
    end
  end

  describe "the registry context" do
    test "carries only its declared keys and defaults the rest to empty" do
      opts = [app: [server: :a], plugin: [server: :b], pack: [server: :c], other: :dropped]

      assert RegistryContext.app_opts(opts) == [server: :a]
      assert RegistryContext.plugin_opts(opts) == [server: :b]
      assert RegistryContext.pack_opts(opts) == [server: :c]

      assert RegistryContext.take(opts) == [app: [server: :a], plugin: [server: :b], pack: [server: :c]]

      assert RegistryContext.app_opts([]) == []
      assert RegistryContext.plugin_opts([]) == []
      assert RegistryContext.pack_opts([]) == []
    end
  end

  describe "the canonical response" do
    test "builders cover the status vocabulary without any bound provider" do
      assert Response.completed("done").status == :completed
      assert Response.denied("no").status == :denied
      assert Response.unavailable("offline", :capability_disabled).status == :unavailable
      assert Response.unavailable("offline", :capability_disabled).error == :capability_disabled
    end

    test "a response carrying no decision renders absent rather than guessing" do
      response = Response.normalize(%{"message" => "Ready.", "status" => "completed"})

      assert response.decision == nil
      assert response.resource_access == []
      assert response.approval_handoff == nil
    end
  end
end
