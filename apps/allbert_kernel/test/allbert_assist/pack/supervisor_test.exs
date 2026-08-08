defmodule AllbertAssist.Pack.SupervisorTest do
  use ExUnit.Case, async: false

  @moduletag :global_process_serial

  alias AllbertAssist.Pack.{Registry, Supervisor}

  test "M1.b production supervision starts an authoritative registry explicitly" do
    registry = :m1b_supervised_authoritative_registry

    start_supervised!(
      {Supervisor,
       name: :m1b_authoritative_pack_supervisor,
       registry: registry,
       readiness: :m1b_authoritative_pack_readiness,
       coordinator: self()}
    )

    assert {:ok, %{phase: :collecting, publication: :authoritative}} =
             Registry.status(server: registry)
  end
end
