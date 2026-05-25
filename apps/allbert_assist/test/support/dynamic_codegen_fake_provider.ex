defmodule AllbertAssist.TestSupport.DynamicCodegenFakeProvider do
  @moduledoc false

  alias AllbertAssist.DynamicPlugins.Codegen.CapabilityGap

  @behaviour AllbertAssist.DynamicPlugins.Codegen.LLM

  @impl true
  def generate_action(%CapabilityGap{} = gap, _profile, _budget, _context) do
    {:ok,
     %{
       "action_name" => "dynamic_#{gap.slug}",
       "description" => "Fake-provider read-only summary action.",
       "source" => action_source(),
       "test_source" => test_source(),
       "notes" => ["fake_provider", "source_bearing"],
       "usage" => %{total_tokens: 123}
     }}
  end

  defp action_source do
    """
    defmodule {{MODULE}} do
      use AllbertAssist.Action,
        permission: :read_only,
        exposure: :internal,
        execution_mode: :read_only,
        skill_backed?: false,
        confirmation: :not_required,
        name: "{{ACTION_NAME}}",
        description: "Summarize a name, score, and tags.",
        category: "dynamic_plugins",
        tags: ["dynamic", "generated"],
        schema: [
          name: [type: :string, required: false],
          score: [type: :integer, required: false],
          tags: [type: {:list, :string}, required: false]
        ],
        output_schema: [
          message: [type: :string, required: true],
          status: [type: :atom, required: true],
          actions: [type: {:list, :map}, required: true]
        ]

      @impl true
      def run(params, _context) do
        name = String.trim(Map.get(params, :name, "item"))
        tags = Map.get(params, :tags, [])
        normalized_tags = Enum.map(tags, fn tag -> String.upcase(to_string(tag)) end)
        adjusted_score = Map.get(params, :score, 0) + Enum.count(normalized_tags)

        tier =
          if adjusted_score >= 10 do
            "high"
          else
            "normal"
          end

        message = "\#{name}: \#{tier} score=\#{adjusted_score} tags=\#{Enum.join(normalized_tags, ", ")}"
        {:ok, %{message: message, status: :completed, actions: []}}
      end
    end
    """
  end

  defp test_source do
    """
    defmodule {{TEST_MODULE}} do
      use ExUnit.Case, async: true

      test "generated read-only action summarizes params" do
        assert {:ok, %{status: :completed, message: message, actions: []}} =
                 {{MODULE}}.run(%{name: " Ada ", score: 8, tags: ["math", "code"]}, %{})

        assert message == "Ada: high score=10 tags=MATH, CODE"
      end
    end
    """
  end
end
