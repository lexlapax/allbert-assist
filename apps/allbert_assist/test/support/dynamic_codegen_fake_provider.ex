defmodule AllbertAssist.TestSupport.DynamicCodegenFakeProvider do
  @moduledoc false

  @behaviour AllbertAssist.DynamicPlugins.Codegen.LLM

  @impl true
  def generate_role(:planner, %{"gap" => %{"id" => gap_id}}, _profile, _budget, _context) do
    {:ok,
     %{
       "target_shape" => "action",
       "permission_ceiling" => "read_only",
       "summary" => "Plan fake-provider read-only summary action.",
       "acceptance_criteria" => ["formats a completed response", "stays read-only"],
       "constraints" => ["no protected runtime calls", "no confirmation"],
       "test_strategy" => "Call run/2 directly with name, score, and tags.",
       "notes" => ["fake_provider", gap_id],
       "usage_units" => 10,
       "prompt_hash" => "sha256:fake-planner"
     }}
  end

  def generate_role(:author, %{"gap" => %{"slug" => slug}}, _profile, _budget, _context) do
    {:ok,
     %{
       "action_name" => "dynamic_#{slug}",
       "description" => "Fake-provider read-only summary action.",
       "source" => action_source(),
       "notes" => ["fake_provider", "source_bearing"],
       "usage_units" => 50,
       "prompt_hash" => "sha256:fake-author"
     }}
  end

  def generate_role(:trial_author, _input, _profile, _budget, _context) do
    {:ok,
     %{
       "test_source" => test_source(),
       "focused_test_paths" => ["source/test/action_test.exs"],
       "notes" => ["fake_provider", "focused_test"],
       "usage_units" => 30,
       "prompt_hash" => "sha256:fake-trial-author"
     }}
  end

  def generate_role(
        :critic,
        %{"evidence" => %{"status" => "passed"}},
        _profile,
        _budget,
        _context
      ) do
    {:ok,
     %{
       "verdict" => "accepted",
       "findings" => [],
       "repair_instructions" => "",
       "notes" => ["fake_provider", "critic_accept"],
       "usage_units" => 20,
       "prompt_hash" => "sha256:fake-critic"
     }}
  end

  def generate_role(:critic, _input, _profile, _budget, _context) do
    {:ok,
     %{
       "verdict" => "repair_requested",
       "findings" => ["deterministic evidence did not pass"],
       "repair_instructions" => "Return placeholder-bearing source and tests.",
       "notes" => ["fake_provider", "critic_repair"],
       "usage_units" => 20,
       "prompt_hash" => "sha256:fake-critic-repair"
     }}
  end

  def generate_role(
        :repair,
        %{"critic" => %{"verdict" => "accepted"}},
        _profile,
        _budget,
        _context
      ) do
    {:ok,
     %{
       "status" => "not_needed",
       "action_name" => "",
       "description" => "",
       "source" => "",
       "test_source" => "",
       "notes" => ["fake_provider", "repair_not_needed"],
       "usage_units" => 13,
       "prompt_hash" => "sha256:fake-repair-not-needed"
     }}
  end

  def generate_role(:repair, _input, _profile, _budget, _context) do
    {:ok,
     %{
       "status" => "repaired",
       "action_name" => "",
       "description" => "Fake-provider repaired read-only summary action.",
       "source" => action_source(),
       "test_source" => test_source(),
       "notes" => ["fake_provider", "repair"],
       "usage_units" => 13,
       "prompt_hash" => "sha256:fake-repair"
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
