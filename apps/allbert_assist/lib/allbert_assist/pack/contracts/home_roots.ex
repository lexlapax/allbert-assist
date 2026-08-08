defmodule AllbertAssist.Pack.Contracts.HomeRoots do
  @moduledoc """
  Residual provider for the kernel `HomeRoots` contract.

  The residual owns all five subsystem roots today, so it answers for all five.
  Each is read live from application environment on every call, exactly as
  `AllbertAssist.Paths` read it before relocation — the suite writes these keys
  after boot, and a cached answer would ignore those writes.

  When a subsystem extracts into its own pack, its row leaves this module and
  arrives through that pack's `home_roots/0` descriptor contribution instead.
  """

  @behaviour AllbertAssist.Kernel.Contract.HomeRoots

  @app :allbert_assist

  @owners %{
    settings: AllbertAssist.Settings,
    memory: AllbertAssist.Memory,
    artifacts: AllbertAssist.Artifacts,
    confirmations: AllbertAssist.Confirmations,
    execution_audit: AllbertAssist.Execution.Audit
  }

  @impl true
  def override(root_id) do
    case Map.fetch(@owners, root_id) do
      {:ok, owner} -> configured_root(owner)
      :error -> nil
    end
  end

  defp configured_root(owner) do
    @app
    |> Application.get_env(owner, [])
    |> Keyword.get(:root)
    |> expand_if_present()
  end

  defp expand_if_present(path) when is_binary(path), do: Path.expand(path)
  defp expand_if_present(_path), do: nil
end
