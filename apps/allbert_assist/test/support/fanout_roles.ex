defmodule AllbertAssist.TestSupport.FanoutRoles do
  @moduledoc """
  v1.3 M9.b.12.d — makes the fan-out roles admissible inside a test.

  `Runtime.fanout_role_readiness_step/3` refuses fan-out admission when the
  `fanout_manager` and `fanout_synthesis` roles resolve to no callable model.
  That gate landed in M9.b, after most fan-out tests were written, so any test
  that submits real user input and expects a decomposition needs the roles
  pointed at a resolvable profile and readiness stubbed — otherwise the input
  falls through to a single direct answer and the test silently stops asserting
  what its name says it asserts.

  This is admission infrastructure only. It does not relax any assertion: it
  puts the fan-out into the state the test already believed it was in.
  """

  import ExUnit.Assertions

  alias AllbertAssist.Settings
  alias AllbertAssist.Test.ModelReadinessFake
  alias AllbertAssist.TestSupport.ReadyEffectContext

  @roles ~w[direct_answer fanout_manager fanout_synthesis]

  @doc """
  Stubs model readiness and points every fan-out role at a local profile.

  Registers an `on_exit` callback restoring the previous readiness module, so
  callers only need to invoke this from inside a test or setup block.
  """
  def configure! do
    original_readiness = Application.get_env(:allbert_assist, :runtime_model_readiness)

    Application.put_env(:allbert_assist, :runtime_model_readiness, ModelReadinessFake)

    ExUnit.Callbacks.on_exit(fn ->
      if original_readiness,
        do: Application.put_env(:allbert_assist, :runtime_model_readiness, original_readiness),
        else: Application.delete_env(:allbert_assist, :runtime_model_readiness)
    end)

    assert {:ok, _} =
             Settings.put(
               "providers.openai.enabled",
               false,
               ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, _} =
             Settings.put(
               "intent.direct_answer_model_enabled",
               true,
               ReadyEffectContext.attach(%{audit?: false})
             )

    Enum.each(@roles, fn role ->
      assert {:ok, _} =
               Settings.put(
                 "model_preferences.tasks.#{role}",
                 ["direct_answer_local"],
                 ReadyEffectContext.attach(%{audit?: false})
               )
    end)

    :ok
  end
end
