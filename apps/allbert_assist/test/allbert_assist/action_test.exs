defmodule AllbertAssist.ActionTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Action

  defmodule DemoAction do
    use AllbertAssist.Action,
      permission: :read_only,
      exposure: :agent,
      execution_mode: :read_only,
      skill_backed?: false,
      confirmation: :not_required,
      name: "demo_allbert_action",
      description: "Demo Allbert action wrapper.",
      category: "test",
      schema: [text: [type: :string, required: true]]

    @impl true
    def run(%{text: text}, _context), do: {:ok, %{message: text, status: :completed}}
  end

  defmodule OverrideAction do
    use AllbertAssist.Action,
      permission: :read_only,
      exposure: :agent,
      execution_mode: :read_only,
      skill_backed?: false,
      confirmation: :not_required,
      name: "override_allbert_action",
      description: "Demo override action wrapper.",
      category: "test",
      schema: []

    def capability do
      %{
        permission: :memory_write,
        exposure: :internal,
        execution_mode: :memory_write,
        skill_backed?: false,
        confirmation: :required,
        resumable?: true
      }
    end

    @impl true
    def run(_params, _context), do: {:ok, %{message: "override", status: :completed}}
  end

  test "wraps Jido.Action and pins Allbert capability metadata" do
    assert DemoAction.name() == "demo_allbert_action"
    assert Action.allbert_action?(DemoAction)

    assert DemoAction.capability() == %{
             permission: :read_only,
             exposure: :agent,
             execution_mode: :read_only,
             skill_backed?: false,
             confirmation: :not_required,
             resumable?: false
           }
  end

  test "lets plugin-style modules override capability metadata explicitly" do
    assert Action.allbert_action?(OverrideAction)
    assert OverrideAction.capability().permission == :memory_write
    assert OverrideAction.capability().confirmation == :required
    assert OverrideAction.capability().resumable?
  end

  test "validates required capability metadata" do
    assert {:error, {:missing_capability_keys, [:confirmation]}} =
             Action.validate_capability(
               permission: :read_only,
               exposure: :agent,
               execution_mode: :read_only,
               skill_backed?: false
             )
  end

  test "accepts MCP server connect capability metadata" do
    assert {:ok, capability} =
             Action.validate_capability(
               permission: :mcp_server_connect,
               exposure: :internal,
               execution_mode: :mcp_server_connect,
               skill_backed?: false,
               confirmation: :required
             )

    assert capability.permission == :mcp_server_connect
    assert capability.execution_mode == :mcp_server_connect
  end
end
