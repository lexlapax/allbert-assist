defmodule AllbertAssist.Security.IdentityContextEvalTest do
  use AllbertAssist.SecurityEvalCase, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Conversations
  alias AllbertAssist.Jobs
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.Session
  alias AllbertAssist.Settings
  alias AllbertAssist.StockSageRegistryCase

  setup do
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-v028-identity-context-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    :ok = StockSageRegistryCase.setup()

    on_exit(fn ->
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "cross-user-thread-001: injected user_id cannot read another user's thread" do
    fixture = EvalInventory.row!("cross-user-thread-001")
    private_marker = "alice-private-thread-marker"
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Private review")
    assert {:ok, _message} = Conversations.append_user_message(thread, private_marker)

    eval =
      run_eval(
        Map.merge(fixture, %{
          run: fn fixture ->
            case Conversations.show_thread("bob", thread.id) do
              {:error, {:thread_not_found, attempted_thread_id}} ->
                %{
                  decision: :denied,
                  result: %{error: :thread_not_found, attempted_thread_id: attempted_thread_id},
                  trace: %{
                    fixture_id: fixture.id,
                    boundary: :conversations,
                    scope_key: :user_id,
                    requester_user_id: "bob",
                    thread_lookup: :not_found
                  }
                }

              {:ok, result} ->
                %{decision: :allowed, result: result, trace: %{fixture_id: fixture.id}}
            end
          end
        })
      )

    assert_denied(eval)
    assert_trace_records(eval, [:boundary, :scope_key, :thread_lookup])
    assert_no_cross_user_leak(eval, "alice")
    assert_no_cross_user_leak(eval, private_marker)
    assert {:ok, owned} = Conversations.show_thread("alice", thread.id)
    assert Enum.any?(owned.messages, &(&1.content == private_marker))
  end

  test "scratchpad-bleed-001: session lookup is scoped by user and session id" do
    fixture = EvalInventory.row!("scratchpad-bleed-001")
    session_id = "shared-looking-session"
    ensure_stocksage_registered!()

    assert {:ok, _entry} = Session.set_active_app("alice", session_id, :stocksage)
    assert {:ok, _entry} = Session.merge_working_memory("alice", session_id, %{pane: "alpha"})

    eval =
      run_eval(
        Map.merge(fixture, %{
          run: fn fixture ->
            {:ok, response} =
              Runner.run(
                "show_session_scratchpad",
                %{user_id: "bob", session_id: session_id},
                context("bob")
              )

            %{
              decision: if(response.status == :not_found, do: :denied, else: response.status),
              result: response,
              trace: %{
                fixture_id: fixture.id,
                boundary: :session_scratchpad,
                lookup_status: response.status,
                scope_key: {:user_id, :session_id}
              }
            }
          end
        })
      )

    assert_denied(eval)
    assert_trace_records(eval, [:boundary, :lookup_status, :scope_key])
    assert_no_cross_user_leak(eval, "alice")
    assert_no_cross_user_leak(eval, "stocksage")
    refute inspect(eval.result) =~ "active_app=stocksage"
    assert {:ok, owned} = Session.get("alice", session_id)
    assert owned.active_app == :stocksage
  end

  test "channel-spoof-001: forged nested request channel cannot override resolver channel" do
    fixture = EvalInventory.row!("channel-spoof-001")

    assert {:ok, _setting} =
             Settings.put("permissions.external_network", "allowed", %{audit?: false})

    context = %{
      actor: "remote-operator",
      channel: :email,
      surface: "email",
      request: %{
        operator_id: "local",
        channel: :cli,
        input_signal_id: "sig-forged-local-channel"
      }
    }

    eval =
      run_eval(
        Map.merge(fixture, %{
          run: fn fixture ->
            decision = PermissionGate.authorize(:external_network, context)

            %{
              decision: decision.decision,
              result: %{permission_decision: decision},
              trace: %{
                fixture_id: fixture.id,
                actor_id: decision.context.actor.id,
                channel_name: decision.context.channel.name,
                channel_trust: decision.context.channel.trust,
                forged_channel: :cli,
                boundary_truth: :outer_runtime_context
              }
            }
          end
        })
      )

    assert_needs_confirmation(eval)
    assert_trace_records(eval, [:channel_name, :channel_trust, :boundary_truth])
    assert eval.trace.actor_id == "remote-operator"
    assert eval.trace.channel_name == :email
    assert eval.trace.channel_trust == :future_remote
  end

  test "job-context-001: scheduled jobs cannot borrow another user's origin thread" do
    fixture = EvalInventory.row!("job-context-001")
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Scheduled private topic")

    eval =
      run_eval(
        Map.merge(fixture, %{
          run: fn fixture ->
            case Jobs.create_job(%{
                   name: "wrong-user-origin-thread",
                   target_type: "runtime_prompt",
                   target: %{text: "Follow up on Alice's thread."},
                   schedule: %{kind: "manual"},
                   user_id: "bob",
                   thread_id: thread.id
                 }) do
              {:error, {:thread_not_found, attempted_thread_id}} ->
                %{
                  decision: :denied,
                  result: %{error: :thread_not_found, attempted_thread_id: attempted_thread_id},
                  trace: %{
                    fixture_id: fixture.id,
                    boundary: :jobs,
                    target_type: "runtime_prompt",
                    thread_mode: "origin_thread",
                    job_user_id: "bob",
                    thread_scope: :user_owned
                  }
                }

              {:ok, job} ->
                %{decision: :allowed, result: job, trace: %{fixture_id: fixture.id}}
            end
          end
        })
      )

    assert_denied(eval)
    assert_trace_records(eval, [:boundary, :thread_scope, :target_type])
    assert_no_cross_user_leak(eval, "alice")
  end

  defp context(user_id) do
    %{
      actor: user_id,
      channel: :test,
      surface: "security_eval",
      request: %{operator_id: user_id, channel: :test, input_signal_id: "sig-identity-eval"}
    }
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)

  defp ensure_stocksage_registered! do
    :ok = StockSageRegistryCase.setup()
  end
end
