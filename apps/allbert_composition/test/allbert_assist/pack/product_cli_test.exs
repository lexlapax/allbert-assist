defmodule AllbertAssist.Pack.ProductCLITest do
  use ExUnit.Case, async: false

  @moduletag :global_process_serial

  alias AllbertAssist.Pack.ProductCLI

  defmodule CLI do
    def entry_plan(argv) do
      send(test_pid(), {:entry_plan, argv})

      case argv do
        ["licenses" | _] -> %{disposition: :license_view}
        ["--help"] -> %{disposition: :runtime_free}
        _ -> %{disposition: :runtime_required}
      end
    end

    def run_local(plan, opts) do
      send(test_pid(), {:run_local, plan, opts})
      {:stdout, "local", 0}
    end

    def classify_attach(result) do
      send(test_pid(), {:classify_attach, result})

      case result do
        :attached -> {:attached, "daemon", 0}
        :rejected -> {:error, "Allbert product is not ready; retry the command."}
        :transport_failed -> :fallback
      end
    end

    defp test_pid, do: Process.get(:product_cli_test_pid)
  end

  defmodule Attach do
    def run(argv) do
      send(Process.get(:product_cli_test_pid), {:attach, argv})
      Process.get(:product_cli_attach_result)
    end
  end

  defmodule Bootstrap do
    def ensure_ready([]) do
      send(Process.get(:product_cli_test_pid), :bootstrap)
      Process.get(:product_cli_bootstrap_result)
    end
  end

  setup do
    Process.put(:product_cli_test_pid, self())

    on_exit(fn ->
      Process.delete(:product_cli_test_pid)
      Process.delete(:product_cli_attach_result)
      Process.delete(:product_cli_bootstrap_result)
    end)

    :ok
  end

  test "licenses skips Req, Attach, and composition bootstrap" do
    assert {:stdout, "local", 0} =
             ProductCLI.run_entry_for_test(["licenses"],
               cli: CLI,
               attach: Attach,
               bootstrap: Bootstrap,
               req_starter: fn :req -> flunk("licenses must not start Req") end
             )

    assert_receive {:entry_plan, ["licenses"]}
    assert_receive {:run_local, %{disposition: :license_view}, []}
    refute_received {:attach, _}
    refute_received :bootstrap
  end

  test "runtime-free plans start Req but never attach or bootstrap" do
    assert {:stdout, "local", 0} =
             ProductCLI.run_entry_for_test(["--help"],
               cli: CLI,
               attach: Attach,
               bootstrap: Bootstrap,
               req_starter: fn :req ->
                 send(self(), :req_started)
                 {:ok, [:req]}
               end
             )

    assert_receive {:entry_plan, ["--help"]}
    assert_receive :req_started
    assert_receive {:run_local, %{disposition: :runtime_free}, []}
    refute_received {:attach, _}
    refute_received :bootstrap
  end

  test "a daemon reply is final and cannot start embedded composition" do
    Process.put(:product_cli_attach_result, :attached)

    assert {:stdout, "daemon", 0} =
             ProductCLI.run_entry_for_test(["ask", "hello"],
               cli: CLI,
               attach: Attach,
               bootstrap: Bootstrap,
               req_starter: fn :req -> {:ok, [:req]} end
             )

    assert_receive {:entry_plan, ["ask", "hello"]}
    assert_receive {:attach, ["ask", "hello"]}
    assert_receive {:classify_attach, :attached}
    refute_received :bootstrap
    refute_received {:run_local, _, _}
  end

  test "only a proven pre-dispatch transport failure may use the embedded bootstrap" do
    epoch = %{barrier_pid: self(), snapshot_digest: String.duplicate("a", 64)}
    Process.put(:product_cli_attach_result, :transport_failed)
    Process.put(:product_cli_bootstrap_result, {:ok, epoch})

    assert {:stdout, "local", 0} =
             ProductCLI.run_entry_for_test(["ask", "hello"],
               cli: CLI,
               attach: Attach,
               bootstrap: Bootstrap,
               req_starter: fn :req -> {:ok, [:req]} end
             )

    assert_receive {:classify_attach, :transport_failed}
    assert_receive :bootstrap
    assert_receive {:run_local, %{disposition: :runtime_required}, allbert_pack_epoch: ^epoch}
  end

  test "a product-not-ready daemon rejection is final stderr exit 3, not fallback" do
    Process.put(:product_cli_attach_result, :rejected)

    assert {:stderr, "Allbert product is not ready; retry the command.", 3} =
             ProductCLI.run_entry_for_test(["ask", "hello"],
               cli: CLI,
               attach: Attach,
               bootstrap: Bootstrap,
               req_starter: fn :req -> {:ok, [:req]} end
             )

    assert_receive {:classify_attach, :rejected}
    refute_received :bootstrap
    refute_received {:run_local, _, _}
  end
end
