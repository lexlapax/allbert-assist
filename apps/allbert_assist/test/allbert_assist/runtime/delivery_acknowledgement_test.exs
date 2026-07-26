defmodule AllbertAssist.Runtime.DeliveryAcknowledgementTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Runtime.DeliveryAcknowledgement

  test "known raised returned and exited database failures retry until acknowledgement succeeds" do
    failures = [
      fn -> raise %DBConnection.ConnectionError{message: "connection closed"} end,
      fn -> {:error, %Exqlite.Error{message: "database is locked"}} end,
      fn -> exit({:shutdown, %DBConnection.OwnershipError{message: "owner exited"}}) end
    ]

    Enum.each(failures, fn failure ->
      key = {__MODULE__, make_ref()}
      Process.put(key, 0)

      acknowledge_fun = fn ->
        attempt = Process.get(key) + 1
        Process.put(key, attempt)
        if attempt == 1, do: failure.(), else: :ok
      end

      assert :ok =
               DeliveryAcknowledgement.run(acknowledge_fun,
                 delay_fun: fn _delay -> :ok end
               )

      assert Process.get(key) == 2
    end)
  end

  test "identity errors do not retry and unknown exceptions remain visible" do
    parent = self()

    assert {:error, :receipt_identity_mismatch} =
             DeliveryAcknowledgement.run(fn ->
               send(parent, :identity_attempt)
               {:error, :receipt_identity_mismatch}
             end)

    assert_receive :identity_attempt
    refute_receive :identity_attempt

    assert_raise ArgumentError, "programming failure", fn ->
      DeliveryAcknowledgement.run(fn -> raise ArgumentError, "programming failure" end)
    end
  end

  test "bounded exhaustion stays a typed transient error" do
    parent = self()

    assert {:error, {:transient_database, summary}} =
             DeliveryAcknowledgement.run(
               fn ->
                 send(parent, :transient_attempt)
                 {:error, %DBConnection.ConnectionError{message: "database unavailable"}}
               end,
               attempts: 3,
               delay_fun: fn delay -> send(parent, {:retry_delay, delay}) end
             )

    assert summary =~ "DBConnection.ConnectionError"
    assert_receive :transient_attempt
    assert_receive {:retry_delay, 25}
    assert_receive :transient_attempt
    assert_receive {:retry_delay, 50}
    assert_receive :transient_attempt
    refute_receive :transient_attempt
  end
end
