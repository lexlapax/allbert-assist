defmodule AllbertAssist.Settings.VersionContract do
  @moduledoc """
  First-class settings-fragment version inventory and fail-closed compatibility checks.
  """

  alias AllbertAssist.Settings.Fragment
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Schema
  alias AllbertAssist.Settings.Store

  @type fragment_status :: :current | :pending | :forward | :invalid
  @type counts :: %{
          required(:current) => non_neg_integer(),
          required(:pending) => non_neg_integer(),
          required(:forward) => non_neg_integer(),
          required(:invalid) => non_neg_integer()
        }
  @type status_report :: %{
          required(:status) => :blocked | :ok | :pending,
          required(:total_fragments) => non_neg_integer(),
          required(:counts) => counts(),
          required(:diagnostics) => [term()],
          required(:inventory) => [map()]
        }

  @doc "Return the generated settings-fragment version inventory."
  @spec inventory(keyword()) :: [map()]
  def inventory(opts \\ []) do
    fragments = Keyword.get_lazy(opts, :fragments, &Fragments.registered_fragments/0)
    user_settings = Keyword.get(opts, :user_settings, %{})
    stored_versions = normalize_stored_versions(Keyword.get(opts, :stored_versions, %{}))

    fragments
    |> Enum.map(&inventory_entry(&1, user_settings, stored_versions))
    |> Enum.sort_by(& &1.fragment_id)
  end

  @doc "Return an operator-facing summary of the settings version contract."
  @spec status(keyword()) :: status_report()
  def status(opts \\ []) do
    entries = inventory(opts)
    counts = counts(entries)
    diagnostics = diagnostics(entries)

    %{
      status: overall_status(counts),
      total_fragments: length(entries),
      counts: counts,
      diagnostics: diagnostics,
      inventory: entries
    }
  end

  @doc "Read current user settings without opening the merged Settings Store, then check versions."
  @spec status_from_store(keyword()) :: status_report()
  def status_from_store(opts \\ []) do
    user_settings =
      case Store.read_user_settings() do
        {:ok, settings} -> settings
        {:error, reason} -> %{"__read_error__" => inspect(reason)}
      end

    opts
    |> Keyword.put_new(:user_settings, user_settings)
    |> status()
  end

  @doc "Return :ok unless the supplied user settings contain unsupported forward versions."
  @spec reject_forward_versions(map(), keyword()) ::
          :ok | {:error, {:settings_version_contract_blocked, [map()]}}
  def reject_forward_versions(user_settings, opts \\ []) when is_map(user_settings) do
    report =
      opts
      |> Keyword.put_new(:user_settings, user_settings)
      |> status()

    blocking =
      Enum.filter(report.diagnostics, fn diagnostic ->
        diagnostic.status in [:forward, :invalid]
      end)

    case blocking do
      [] -> :ok
      diagnostics -> {:error, {:settings_version_contract_blocked, diagnostics}}
    end
  end

  @doc "Render a compact operator report."
  @spec render(map()) :: String.t()
  def render(report) when is_map(report) do
    counts = report.counts

    header =
      "settings version contract status=#{report.status} total=#{report.total_fragments} " <>
        "current=#{counts.current} pending=#{counts.pending} forward=#{counts.forward} " <>
        "invalid=#{counts.invalid}"

    rows =
      report.inventory
      |> Enum.map(fn entry ->
        "- #{entry.fragment_id} source=#{entry.source} known=#{entry.known_schema_version} " <>
          "stored=#{inspect(entry.stored_schema_version)} status=#{entry.status}"
      end)

    diagnostics =
      case report.diagnostics do
        [] ->
          ["diagnostics=none"]

        diagnostics ->
          ["diagnostics:"] ++
            Enum.map(diagnostics, fn diagnostic ->
              "- #{diagnostic.fragment_id} #{diagnostic.status}: #{diagnostic.message}"
            end)
      end

    Enum.join([header | rows ++ diagnostics], "\n")
  end

  defp inventory_entry(%Fragment{} = fragment, user_settings, stored_versions) do
    known_version = fragment.schema_version
    version_keys = version_keys(fragment)
    stored_version = stored_version(fragment, user_settings, stored_versions, version_keys)
    status = fragment_status(stored_version, known_version)

    %{
      fragment_id: to_string(fragment.id),
      owner: fragment.owner,
      source: fragment.source,
      group: fragment.group,
      known_schema_version: known_version,
      stored_schema_version: stored_version,
      status: status,
      version_keys: version_keys
    }
  end

  defp version_keys(%Fragment{schema: schema}) do
    schema
    |> Map.keys()
    |> Enum.filter(&String.ends_with?(&1, ".schema_version"))
    |> Enum.sort()
  end

  defp stored_version(fragment, user_settings, stored_versions, version_keys) do
    Map.get_lazy(stored_versions, to_string(fragment.id), fn ->
      version_keys
      |> Enum.map(&Schema.get_dotted(user_settings, &1))
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> 1
        versions -> max_version(versions)
      end
    end)
  end

  defp max_version(versions) do
    if Enum.all?(versions, &positive_integer?/1) do
      Enum.max(versions)
    else
      {:invalid, versions}
    end
  end

  defp fragment_status(version, _known) when is_tuple(version), do: :invalid
  defp fragment_status(version, known) when version > known, do: :forward
  defp fragment_status(version, known) when version < known, do: :pending
  defp fragment_status(_version, _known), do: :current

  defp counts(entries) do
    frequencies = Enum.frequencies_by(entries, & &1.status)

    %{
      current: Map.get(frequencies, :current, 0),
      pending: Map.get(frequencies, :pending, 0),
      forward: Map.get(frequencies, :forward, 0),
      invalid: Map.get(frequencies, :invalid, 0)
    }
  end

  defp overall_status(%{forward: forward, invalid: invalid}) when forward + invalid > 0,
    do: :blocked

  defp overall_status(%{pending: pending}) when pending > 0, do: :pending
  defp overall_status(_counts), do: :ok

  defp diagnostics(entries) do
    entries
    |> Enum.reject(&(&1.status == :current))
    |> Enum.map(fn entry ->
      %{
        code: diagnostic_code(entry.status),
        status: entry.status,
        severity: diagnostic_severity(entry.status),
        fragment_id: entry.fragment_id,
        known_schema_version: entry.known_schema_version,
        stored_schema_version: entry.stored_schema_version,
        message: diagnostic_message(entry)
      }
    end)
  end

  defp diagnostic_code(:pending), do: :settings_schema_version_pending
  defp diagnostic_code(:forward), do: :settings_schema_version_forward
  defp diagnostic_code(:invalid), do: :settings_schema_version_invalid

  defp diagnostic_severity(:pending), do: :warning
  defp diagnostic_severity(:forward), do: :error
  defp diagnostic_severity(:invalid), do: :error

  defp diagnostic_message(%{status: :pending} = entry) do
    "Stored settings fragment version #{entry.stored_schema_version} is older than runtime version #{entry.known_schema_version}; migration runner is deferred, so this is recorded as pending."
  end

  defp diagnostic_message(%{status: :forward} = entry) do
    "Stored settings fragment version #{entry.stored_schema_version} is newer than runtime known max #{entry.known_schema_version}; refusing to silently load."
  end

  defp diagnostic_message(%{status: :invalid} = entry) do
    "Stored settings fragment version #{inspect(entry.stored_schema_version)} is invalid; refusing to silently load."
  end

  defp normalize_stored_versions(versions) when is_map(versions) do
    Map.new(versions, fn {fragment_id, version} -> {to_string(fragment_id), version} end)
  end

  defp normalize_stored_versions(_versions), do: %{}

  defp positive_integer?(value), do: is_integer(value) and value > 0
end
