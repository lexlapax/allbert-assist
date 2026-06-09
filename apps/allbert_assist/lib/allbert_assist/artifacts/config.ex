defmodule AllbertAssist.Artifacts.Config do
  @moduledoc """
  Settings-backed artifact policy helpers.

  The store remains a plain file-backed CAS. This module is the small adapter
  that lets action-facing code honor Settings Central without making the storage
  primitives responsible for permissions or runtime policy.
  """

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  @default_settings %{
    "artifacts" => %{
      "enabled" => false,
      "retention_enabled" => false,
      "max_bytes" => 20_971_520,
      "allowed_mime" => ["*/*"],
      "allowed_types" => ["*"],
      "gc" => %{
        "enabled" => false,
        "delete_orphans" => true
      }
    }
  }

  @type bounds_settings :: %{
          required(String.t()) => %{
            required(String.t()) => term()
          }
        }

  @type gc_policy :: %{
          required(:enabled?) => boolean(),
          required(:delete_orphans?) => boolean()
        }

  @type doctor :: %{
          required(:enabled?) => boolean(),
          required(:retention_enabled?) => boolean(),
          required(:root) => String.t(),
          required(:root_exists?) => boolean(),
          required(:objects_root_exists?) => boolean(),
          required(:index_root_exists?) => boolean(),
          required(:max_bytes) => term(),
          required(:allowed_mime) => term(),
          required(:allowed_types) => term(),
          required(:gc) => gc_policy()
        }

  @doc "Return true when artifact writes are enabled in Settings Central."
  @spec enabled?() :: boolean()
  def enabled?, do: setting("artifacts.enabled", false) == true

  @doc "Return true when durable artifact retention is enabled."
  @spec retention_enabled?() :: boolean()
  def retention_enabled?, do: setting("artifacts.retention_enabled", false) == true

  @doc "Return the artifact root, honoring operator-set `artifacts.root` only."
  @spec root() :: String.t()
  def root do
    case Settings.resolve("artifacts.root") do
      {:ok, %{source: :operator, value: value}} when is_binary(value) and value != "" ->
        expand_home(value)

      _other ->
        Paths.artifacts_root()
    end
  end

  @doc "Return a nested settings map consumable by artifact bounds validation."
  @spec bounds_settings() :: bounds_settings()
  def bounds_settings do
    %{
      "artifacts" => %{
        "max_bytes" => setting("artifacts.max_bytes", 20_971_520),
        "allowed_mime" => setting("artifacts.allowed_mime", ["*/*"]),
        "allowed_types" => setting("artifacts.allowed_types", ["*"])
      }
    }
  end

  @doc "Merge Settings Central bounds into operation options without overriding explicit opts."
  @spec with_bounds(keyword()) :: keyword()
  def with_bounds(opts) when is_list(opts) do
    cond do
      Keyword.has_key?(opts, :settings) ->
        opts

      Keyword.has_key?(opts, :root) and not Keyword.get(opts, :use_settings?, false) ->
        opts

      true ->
        Keyword.put_new(opts, :settings, bounds_settings())
    end
  end

  @doc "Return the GC policy snapshot."
  @spec gc_policy() :: gc_policy()
  def gc_policy do
    %{
      enabled?: setting("artifacts.gc.enabled", false) == true,
      delete_orphans?: setting("artifacts.gc.delete_orphans", true) == true
    }
  end

  @doc "Return a redacted doctor snapshot for operator-facing artifact status."
  @spec doctor() :: doctor()
  def doctor do
    root = root()
    policy = gc_policy()

    %{
      enabled?: enabled?(),
      retention_enabled?: retention_enabled?(),
      root: root,
      root_exists?: File.dir?(root),
      objects_root_exists?: File.dir?(Path.join(root, "objects")),
      index_root_exists?: File.dir?(Path.join(root, "index")),
      max_bytes: get_in(bounds_settings(), ["artifacts", "max_bytes"]),
      allowed_mime: get_in(bounds_settings(), ["artifacts", "allowed_mime"]),
      allowed_types: get_in(bounds_settings(), ["artifacts", "allowed_types"]),
      gc: policy
    }
  end

  defp setting(key, default) do
    case Settings.get(key) do
      {:ok, value} -> value
      {:error, _reason} -> get_in(@default_settings, String.split(key, ".")) || default
    end
  end

  defp expand_home(path) when is_binary(path) do
    path
    |> String.replace("<ALLBERT_HOME>", Paths.home())
    |> Path.expand()
  end
end
