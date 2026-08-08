defmodule AllbertAssist.DevGates.GateTargetResolver do
  @moduledoc """
  Resolves historical gate targets against a composed gate-owner record.

  The resolver is deliberately data-driven and contains no application or Pack
  roster. Exact paths resolve first. When a test has moved between owner roots,
  its path below `test/` is treated as the stable logical identity and must
  resolve to exactly one current owner. Missing and ambiguous targets fail
  closed.
  """

  @spec resolve(map(), String.t(), String.t(), String.t()) ::
          {:ok, %{owner_id: atom(), path: String.t()}} | {:error, term()}
  def resolve(owner, target, from_cwd, repository_root)
      when is_map(owner) and is_binary(target) and is_binary(from_cwd) and
             is_binary(repository_root) do
    with {:ok, repository_path} <- repository_path(target, from_cwd, repository_root) do
      roots = roots_for(repository_path, owner)

      cond do
        under_any_root?(repository_path, roots) and exists?(repository_root, repository_path) ->
          {:ok, %{owner_id: owner.owner_id, path: repository_path}}

        true ->
          resolve_logical(owner, repository_path, repository_root)
      end
    end
  end

  defp repository_path(target, from_cwd, repository_root) do
    expanded = Path.expand(target, from_cwd)
    relative = Path.relative_to(expanded, repository_root)

    if relative == ".." or String.starts_with?(relative, "../") do
      {:error, {:target_outside_repository, target}}
    else
      {:ok, relative}
    end
  end

  defp resolve_logical(owner, repository_path, repository_root) do
    case logical_suffix(repository_path) do
      nil ->
        {:error, {:unresolved_target, repository_path}}

      {kind, suffix} ->
        roots_for(kind, owner)
        |> Enum.map(&Path.join(&1, suffix))
        |> Enum.filter(&exists?(repository_root, &1))
        |> Enum.uniq()
        |> case do
          [path] -> {:ok, %{owner_id: owner.owner_id, path: path}}
          [] -> {:error, {:unresolved_target, repository_path}}
          paths -> {:error, {:ambiguous_target, repository_path, paths}}
        end
    end
  end

  defp logical_suffix(path) do
    cond do
      String.contains?(path, "/test/") ->
        [_prefix, suffix] = String.split(path, "/test/", parts: 2)
        {:test, suffix}

      String.starts_with?(path, "test/") ->
        {:test, String.replace_prefix(path, "test/", "")}

      String.contains?(path, "/lib/") ->
        [_prefix, suffix] = String.split(path, "/lib/", parts: 2)
        {:production, suffix}

      String.starts_with?(path, "lib/") ->
        {:production, String.replace_prefix(path, "lib/", "")}

      true ->
        nil
    end
  end

  defp roots_for(path, owner) when is_binary(path) do
    case logical_suffix(path) do
      {:production, _suffix} -> owner.production_source_roots
      _other -> owner.test_roots
    end
  end

  defp roots_for(:production, owner), do: owner.production_source_roots
  defp roots_for(:test, owner), do: owner.test_roots

  defp under_any_root?(path, roots), do: Enum.any?(roots, &within?(path, &1))

  defp within?(path, root), do: path == root or String.starts_with?(path, root <> "/")
  defp exists?(repository_root, path), do: File.exists?(Path.join(repository_root, path))
end
