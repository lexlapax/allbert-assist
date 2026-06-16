defmodule AllbertAssist.Intent.Router.DescriptorStore do
  @moduledoc """
  v0.54 M9.3c (ADR 0062) — md/yaml-free disk store for lifecycle-managed intent
  descriptors under `<ALLBERT_HOME>/intents/`:

    * `generated/`  — accepted machine-generated descriptors (loaded by the resolver)
    * `review/`     — generated descriptors for dynamic/write-code actions, **inert**
                      until operator promotion (not loaded)
    * `overrides/`  — operator-curated descriptors (highest precedence, loaded)
    * `audit/`      — append-only change log

  Each descriptor is a `.exs` file named `<app_id>__<action_name>.exs` returning a
  descriptor attrs map. Trusted-local (same trust class as memory/settings md).
  """
  alias AllbertAssist.Intent.Descriptor
  alias AllbertAssist.Paths

  @tiers ~w(generated review overrides audit)a

  @spec root() :: String.t()
  def root, do: Path.join(Paths.home(), "intents")

  @spec dir(atom()) :: String.t()
  def dir(tier) when tier in @tiers, do: Path.join(root(), to_string(tier))

  @doc "Normalized descriptors persisted in a loaded tier (`:generated` or `:overrides`)."
  @spec load(atom()) :: [Descriptor.t()]
  def load(tier) when tier in [:generated, :overrides] do
    tier
    |> read_attrs()
    |> Descriptor.normalize_many(source: :"#{tier}")
    |> Map.fetch!(:descriptors)
  end

  @doc "Raw descriptor attrs maps in a tier (unnormalized; for listing/review)."
  @spec read_attrs(atom()) :: [map()]
  def read_attrs(tier) when tier in @tiers do
    path = dir(tier)

    case File.ls(path) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".exs"))
        |> Enum.flat_map(fn file -> eval_attrs(Path.join(path, file)) end)

      _other ->
        []
    end
  end

  @doc "Write a descriptor attrs map into a tier; returns the file path."
  @spec put(atom(), map()) :: {:ok, String.t()} | {:error, term()}
  def put(tier, %{} = attrs) when tier in @tiers do
    with {:ok, app_id} <- fetch(attrs, :app_id),
         {:ok, action} <- fetch(attrs, :action_name) do
      File.mkdir_p!(dir(tier))
      file = Path.join(dir(tier), "#{app_id}__#{action}.exs")
      File.write!(file, inspect(attrs, pretty: true, limit: :infinity) <> "\n")
      {:ok, file}
    end
  end

  @doc "Move a descriptor from one tier to another (e.g. promote review -> generated)."
  @spec promote(atom(), atom(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def promote(from, to, app_id, action) when from in @tiers and to in @tiers do
    src = Path.join(dir(from), "#{app_id}__#{action}.exs")

    case eval_attrs(src) do
      [attrs | _] ->
        {:ok, dest} = put(to, attrs)
        File.rm(src)
        {:ok, dest}

      [] ->
        {:error, :not_found}
    end
  end

  defp eval_attrs(file) do
    {term, _binding} = Code.eval_file(file)
    if is_map(term), do: [term], else: []
  rescue
    _exception -> []
  end

  defp fetch(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, to_string(key)) do
      nil -> {:error, {:missing, key}}
      value -> {:ok, value}
    end
  end
end
