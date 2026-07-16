defmodule AllbertAssist.Workflows.SchemaTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Workflows.Schema

  test "assembles a strict Draft 2020-12 schema from action modules" do
    schema = Schema.json_schema([DirectAnswer])

    assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    assert schema["additionalProperties"] == false
    assert schema["required"] == ["id", "version", "steps"]

    action_branch =
      schema
      |> get_in(["properties", "steps", "items", "oneOf"])
      |> Enum.find(&(get_in(&1, ["oneOf"]) != nil))
      |> get_in(["oneOf"])
      |> List.first()

    assert get_in(action_branch, ["properties", "kind", "const"]) == "action"
    assert get_in(action_branch, ["properties", "action", "const"]) == "direct_answer"
    assert get_in(action_branch, ["properties", "params", "additionalProperties"]) == false
  end

  test "validates a representative action workflow through the compiled root" do
    workflow = %{
      "id" => "schema_check",
      "version" => 1,
      "steps" => [
        %{
          "id" => "answer",
          "kind" => "action",
          "action" => "direct_answer",
          "params" => %{"text" => "Say hello."}
        }
      ]
    }

    assert {:ok, _data} = JSV.validate(workflow, Schema.root([DirectAnswer]))
  end
end
