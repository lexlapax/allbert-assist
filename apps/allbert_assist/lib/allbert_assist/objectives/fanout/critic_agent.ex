defmodule AllbertAssist.Objectives.Fanout.CriticAgent do
  @moduledoc """
  Ephemeral private Jido lifecycle for one policy-owned critic group.

  `ReviewRound` hosts each instance in its own owner-linked Task. The Agent owns
  no durable state or authority and is discarded after one `assess` command.
  """

  @dialyzer {:nowarn_function, __agent_metadata__: 0}
  @dialyzer {:nowarn_function, actions: 0}
  @dialyzer {:nowarn_function, signal_routes: 0}
  @dialyzer {:nowarn_function, validate: 2}

  use Jido.Agent,
    name: "allbert_fanout_private_critic",
    description: "Assess one closed policy rule group without revising candidate text.",
    signal_routes: [
      {"allbert.objectives.fanout.critic.assess",
       AllbertAssist.Objectives.Fanout.CriticAgent.Commands.Assess}
    ]

  alias AllbertAssist.Objectives.Fanout.CriticAgent.Commands.Assess
  alias AllbertAssist.Objectives.Fanout.ReviewProtocol

  @doc false
  @spec assess(ReviewProtocol.t(), String.t(), map(), map(), module()) ::
          {:ok, map()} | {:error, atom()}
  def assess(%ReviewProtocol{} = protocol, group_id, source_bindings, context, implementation)
      when is_binary(group_id) and is_map(source_bindings) and is_map(context) and
             is_atom(implementation) do
    with {:ok, request} <- ReviewProtocol.critic_request(protocol, group_id, source_bindings) do
      agent =
        new(
          id: "fanout-critic-#{group_id}-#{System.unique_integer([:positive, :monotonic])}",
          state: %{
            status: :ready,
            assessment: nil,
            reviewer_config_sha256: nil,
            error: nil
          }
        )

      payload = %{
        protocol: protocol,
        group_id: group_id,
        source_bindings: source_bindings,
        request: request,
        critic_context: context,
        implementation: implementation
      }

      {agent, _directives} =
        cmd(agent, {Assess, payload},
          timeout: 0,
          max_retries: 0,
          __jido_instance__: AllbertAssist.Jido
        )

      case agent.state do
        %{
          status: :assessed,
          assessment: assessment,
          reviewer_config_sha256: reviewer_config_sha256
        }
        when is_map(assessment) and is_binary(reviewer_config_sha256) ->
          {:ok,
           %{
             assessment: assessment,
             reviewer_config_sha256: reviewer_config_sha256
           }}

        %{status: :failed, error: reason} when is_atom(reason) ->
          {:error, reason}

        _invalid ->
          {:error, :invalid_critic_result}
      end
    end
  end

  def assess(_protocol, _group_id, _source_bindings, _context, _implementation),
    do: {:error, :invalid_critic_input}
end
