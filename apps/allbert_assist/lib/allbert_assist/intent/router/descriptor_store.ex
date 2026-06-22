defmodule AllbertAssist.Intent.Router.DescriptorStore do
  @moduledoc """
  v0.54 M9.3c (ADR 0062) — data-only YAML store for lifecycle-managed intent
  descriptors under `<ALLBERT_HOME>/intents/`:

    * `generated/`      — accepted machine-generated descriptors (loaded)
    * `learned/review/` — learned/generated proposals, inert until promoted
    * `overrides/`      — operator-curated descriptors (highest precedence, loaded)
    * `audit/`          — append-only change log

  Each descriptor is a YAML map at `<tier>/<app_id>/<action_name>.yaml`.
  Descriptor files are operator-editable data; they are never evaluated as code.
  """
  alias AllbertAssist.Intent.Descriptor
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings.YamlCodec

  @tiers ~w(generated review learned_review overrides audit)a
  @loaded_tiers ~w(generated overrides)a
  @safe_component ~r/^[a-z][a-z0-9_]*$/

  @type tier :: :generated | :review | :learned_review | :overrides | :audit
  @type loaded_tier :: :generated | :overrides

  @spec root() :: String.t()
  def root, do: Path.join(Paths.home(), "intents")

  @spec dir(tier()) :: String.t()
  def dir(tier) when tier in [:review, :learned_review],
    do: Path.join([root(), "learned", "review"])

  def dir(tier) when tier in @tiers, do: Path.join(root(), to_string(tier))

  @doc "Canonical YAML path for one descriptor in a tier."
  @spec path(tier(), atom() | String.t(), atom() | String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def path(tier, app_id, action_name) when tier in @tiers do
    with {:ok, app_id} <- safe_component(app_id, :app_id),
         {:ok, action_name} <- safe_component(action_name, :action_name) do
      {:ok, Path.join([dir(tier), app_id, "#{action_name}.yaml"])}
    end
  end

  @doc "Normalized descriptors persisted in a loaded tier (`:generated` or `:overrides`)."
  @spec load(loaded_tier()) :: [Descriptor.t()]
  def load(tier) when tier in @loaded_tiers do
    tier
    |> read_attrs()
    |> Descriptor.normalize_many(source: :"#{tier}")
    |> Map.fetch!(:descriptors)
  end

  @doc "Raw descriptor attrs maps in a tier (unnormalized; for listing/review)."
  @spec read_attrs(tier()) :: [map()]
  def read_attrs(tier) when tier in @tiers do
    tier
    |> dir()
    |> yaml_files()
    |> Enum.flat_map(&read_yaml_attrs/1)
  end

  @doc "Write a descriptor attrs map into a tier; returns the file path."
  @spec put(tier(), map()) :: {:ok, String.t()} | {:error, term()}
  def put(tier, %{} = attrs) when tier in @tiers do
    with {:ok, app_id} <- fetch(attrs, :app_id),
         {:ok, action} <- fetch(attrs, :action_name),
         {:ok, file} <- path(tier, app_id, action),
         :ok <- safe_destination?(file),
         :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- write_yaml_atomic(file, attrs) do
      {:ok, file}
    end
  end

  @doc "Move a descriptor from one tier to another (e.g. promote review -> generated)."
  @spec promote(tier(), tier(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def promote(from, to, app_id, action) when from in @tiers and to in @tiers do
    with {:ok, src} <- path(from, app_id, action),
         :ok <- safe_existing_file?(src),
         {:ok, attrs} <- YamlCodec.read_file(src),
         {:ok, dest} <- put(to, attrs),
         :ok <- File.rm(src) do
      {:ok, dest}
    else
      {:error, {:settings_parse_failed, _reason} = parse_error} -> {:error, parse_error}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Delete a descriptor attrs map from a tier; missing files are a no-op."
  @spec delete(tier(), String.t() | atom(), String.t() | atom()) ::
          {:ok, String.t()} | {:error, term()}
  def delete(tier, app_id, action) when tier in @tiers do
    with {:ok, file} <- path(tier, app_id, action),
         :ok <- safe_delete_target?(file) do
      case File.rm(file) do
        :ok -> {:ok, file}
        {:error, :enoent} -> {:ok, file}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp yaml_files(path) do
    case File.ls(path) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.flat_map(fn entry -> yaml_files_entry(Path.join(path, entry)) end)

      {:error, _reason} ->
        []
    end
  end

  defp yaml_files_entry(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        if yaml_file?(path) and under_root?(path), do: [path], else: []

      {:ok, %File.Stat{type: :directory}} ->
        if under_root?(path), do: yaml_files(path), else: []

      _other ->
        []
    end
  end

  defp read_yaml_attrs(path) do
    with :ok <- safe_existing_file?(path),
         {:ok, %{} = attrs} <- YamlCodec.read_file(path) do
      [attrs]
    else
      _error -> []
    end
  end

  defp write_yaml_atomic(file, attrs) do
    yaml =
      attrs
      |> prepare_attrs()
      |> YamlCodec.encode!()

    tmp = "#{file}.tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.write(tmp, yaml),
         :ok <- File.rename(tmp, file) do
      :ok
    else
      {:error, reason} = error ->
        _ = File.rm(tmp)
        {:error, reason || error}
    end
  end

  defp prepare_attrs(attrs) do
    attrs
    |> stringify_data()
    |> Map.put_new("schema_version", 1)
  end

  defp stringify_data(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {to_key(key), stringify_data(value)} end)
    |> Map.new()
  end

  defp stringify_data(values) when is_list(values), do: Enum.map(values, &stringify_data/1)
  defp stringify_data(value) when is_boolean(value), do: value
  defp stringify_data(nil), do: nil
  defp stringify_data(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_data(value), do: value

  defp to_key(key) when is_atom(key), do: Atom.to_string(key)
  defp to_key(key), do: to_string(key)

  defp safe_existing_file?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        if yaml_file?(path) and under_root?(path), do: :ok, else: {:error, :unsafe_path}

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :unsafe_path}

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :unsafe_path}
    end
  end

  defp safe_destination?(path) do
    cond do
      not yaml_file?(path) or not under_root?(path) ->
        {:error, :unsafe_path}

      File.exists?(path) ->
        safe_existing_file?(path)

      true ->
        :ok
    end
  end

  defp safe_delete_target?(path) do
    cond do
      not yaml_file?(path) or not under_root?(path) ->
        {:error, :unsafe_path}

      File.exists?(path) ->
        safe_existing_file?(path)

      true ->
        :ok
    end
  end

  defp under_root?(path) do
    root = Path.expand(root())
    expanded = Path.expand(path)
    expanded == root or String.starts_with?(expanded, root <> "/")
  end

  defp yaml_file?(path), do: Path.extname(path) in [".yaml", ".yml"]

  defp safe_component(value, field_name) when is_atom(value),
    do: value |> Atom.to_string() |> safe_component(field_name)

  defp safe_component(value, field_name) when is_binary(value) do
    value =
      value
      |> String.trim()
      |> String.downcase()

    if Regex.match?(@safe_component, value) do
      {:ok, value}
    else
      {:error, {:invalid_component, field_name, value}}
    end
  end

  defp safe_component(value, field_name), do: {:error, {:invalid_component, field_name, value}}

  defp fetch(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, to_string(key)) do
      nil -> {:error, {:missing, key}}
      value -> {:ok, value}
    end
  end
end
