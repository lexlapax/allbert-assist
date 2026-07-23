defmodule AllbertAssist.Coding.CommandGrants do
  @moduledoc """
  Remembered command grants for v0.57 local-coding bash prompts.

  Grants are stored in `resource_grants.remembered` so they share the existing
  Settings-backed lifecycle. The stored record carries only hashes and bounded
  command metadata; matching uses repo fingerprint, permission, cwd, and the
  canonical command form.
  """

  alias AllbertAssist.Coding.Config
  alias AllbertAssist.Maps
  alias AllbertAssist.Resources.Grants
  alias AllbertAssist.Resources.ResourceURI

  @permission :coding_shell_execute
  @grant_kind "coding_command"

  @type command_params :: map()
  @type grant_ref :: %{
          required(:resource_uri) => String.t(),
          required(:scope_value) => String.t(),
          required(:repo_fingerprint) => String.t(),
          required(:cwd) => String.t(),
          required(:cwd_sha256) => String.t(),
          required(:command_sha256) => String.t(),
          required(:command_mode) => String.t(),
          required(:command_metadata) => map(),
          required(:permission) => String.t()
        }

  @doc "Remember an exact bash command grant for the current repo/cwd."
  @spec remember(command_params(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def remember(command_params, opts \\ %{}) do
    opts = attrs_map(opts)

    with {:ok, ref} <- canonical_ref(command_params, opts),
         :ok <- ensure_capacity(ref, opts),
         record <- record(ref, opts) do
      Grants.remember_record(record, settings_context(opts))
    end
  end

  @doc "Find an applicable exact bash command grant."
  @spec find_applicable(command_params(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def find_applicable(command_params, opts \\ %{}) do
    opts = attrs_map(opts)

    with {:ok, ref} <- canonical_ref(command_params, opts),
         {:ok, grant} <- find_applicable_ref(ref, opts) do
      {:ok, grant}
    end
  end

  @doc "Find an applicable exact bash command grant from a hash-only grant reference."
  @spec find_applicable_ref(map(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def find_applicable_ref(ref, opts \\ %{}) do
    opts = attrs_map(opts)
    ref = normalize_grant_ref(ref)

    with :ok <- validate_grant_ref(ref),
         {:ok, grants} <- Grants.list() do
      grants
      |> Enum.find(&matches?(stringify_record(&1), ref, opts))
      |> case do
        nil -> {:error, :no_matching_command_grant}
        grant -> {:ok, grant}
      end
    end
  end

  @doc "Return true when the current context has an applicable command grant."
  @spec applicable?(atom(), map()) :: boolean()
  def applicable?(@permission, context) when is_map(context) do
    opts = [context: context, permission: @permission, now: field(context, :now)]

    case command_grant_ref_from_context(context) do
      {:ok, ref} ->
        match?({:ok, _grant}, find_applicable_ref(ref, opts))

      {:error, _reason} ->
        with {:ok, command_params} <- command_params_from_context(context),
             {:ok, _grant} <- find_applicable(command_params, opts) do
          true
        else
          _other -> false
        end
    end
  end

  def applicable?(_permission, _context), do: false

  @doc "Build the canonical grant reference used for matching and tests."
  @spec canonical_ref(command_params(), map() | keyword()) ::
          {:ok, grant_ref()} | {:error, term()}
  def canonical_ref(command_params, opts \\ %{})

  def canonical_ref(command_params, opts) when is_map(command_params) do
    opts = attrs_map(opts)

    with {:ok, cwd} <- canonical_cwd(command_params),
         {:ok, repo_root} <- repo_root(cwd),
         {:ok, command_mode, canonical_command, metadata} <- canonical_command(command_params),
         permission <- normalize_permission(field(opts, :permission) || @permission) do
      repo_fingerprint = sha256(repo_root)
      cwd_sha256 = sha256(cwd)
      command_sha256 = sha256(canonical_command)

      scope_value =
        sha256(Enum.join([repo_fingerprint, permission, cwd, canonical_command], "\0"))

      {:ok,
       %{
         resource_uri: ResourceURI.file!(repo_root),
         scope_value: scope_value,
         repo_fingerprint: repo_fingerprint,
         cwd: cwd,
         cwd_sha256: cwd_sha256,
         command_sha256: command_sha256,
         command_mode: command_mode,
         command_metadata: metadata,
         permission: permission
       }}
    end
  end

  def canonical_ref(_command_params, _opts), do: {:error, :invalid_command_params}

  @doc "Return a hash-only representation safe for Security Central context."
  @spec redacted_ref(grant_ref()) :: map()
  def redacted_ref(ref) when is_map(ref) do
    %{
      resource_uri: ref.resource_uri,
      scope_value: ref.scope_value,
      repo_fingerprint: ref.repo_fingerprint,
      cwd_sha256: ref.cwd_sha256,
      command_sha256: ref.command_sha256,
      command_mode: ref.command_mode,
      permission: ref.permission
    }
  end

  defp record(ref, opts) do
    now = field(opts, :created_at) || DateTime.utc_now()

    %{
      "id" => to_string(field(opts, :id) || grant_id()),
      "resource_uri" => ref.resource_uri,
      "origin_kind" => "local_path",
      "scope" => %{"kind" => "canonical_command", "value" => ref.scope_value},
      "operation_class" => "run_shell_command",
      "access_mode" => "execute",
      "created_at" => datetime_text(now),
      "action_permission" => ref.permission,
      "metadata" =>
        Map.merge(ref.command_metadata, %{
          "grant_kind" => @grant_kind,
          "repo_fingerprint" => ref.repo_fingerprint,
          "cwd_sha256" => ref.cwd_sha256,
          "command_sha256" => ref.command_sha256,
          "command_mode" => ref.command_mode
        })
    }
    |> maybe_put_string("origin_channel", channel_name(field(opts, :context, %{})))
    |> maybe_put_string("reason", field(opts, :reason))
    |> maybe_put_datetime("expires_at", expires_at(now, opts))
  end

  defp matches?(grant, ref, opts) do
    command_boundary_matches?(grant, ref) and command_scope_matches?(grant, ref) and
      command_metadata_matches?(grant, ref) and active_grant?(grant, opts)
  end

  defp command_boundary_matches?(grant, ref) do
    grant["operation_class"] == "run_shell_command" and grant["access_mode"] == "execute" and
      grant["action_permission"] == ref.permission and grant["resource_uri"] == ref.resource_uri
  end

  defp command_scope_matches?(grant, ref) do
    get_in(grant, ["scope", "kind"]) == "canonical_command" and
      get_in(grant, ["scope", "value"]) == ref.scope_value
  end

  defp command_metadata_matches?(grant, ref) do
    metadata = Map.get(grant, "metadata", %{})

    metadata["grant_kind"] == @grant_kind and
      metadata["repo_fingerprint"] == ref.repo_fingerprint
  end

  defp active_grant?(grant, opts) do
    not revoked?(grant) and not expired?(grant, opts)
  end

  defp ensure_capacity(ref, opts) do
    max_entries = Config.command_grants_max_entries_per_repo()

    with {:ok, grants} <- Grants.list() do
      active_count =
        Enum.count(grants, fn grant ->
          grant = stringify_record(grant)
          metadata = Map.get(grant, "metadata", %{})

          metadata["grant_kind"] == @grant_kind and
            metadata["repo_fingerprint"] == ref.repo_fingerprint and not revoked?(grant) and
            not expired?(grant, opts)
        end)

      if active_count < max_entries do
        :ok
      else
        {:error, {:max_command_grants_per_repo, ref.repo_fingerprint, max_entries}}
      end
    end
  end

  defp command_params_from_context(context) do
    case coding_context_value(context, :command_params) do
      params when is_map(params) -> {:ok, params}
      _other -> {:error, :missing_command_params}
    end
  end

  defp command_grant_ref_from_context(context) do
    case coding_context_value(context, :command_grant_ref) do
      ref when is_map(ref) -> {:ok, ref}
      _other -> {:error, :missing_command_grant_ref}
    end
  end

  defp normalize_grant_ref(ref) when is_map(ref) do
    %{
      resource_uri: field(ref, :resource_uri),
      scope_value: field(ref, :scope_value),
      repo_fingerprint: field(ref, :repo_fingerprint),
      permission: normalize_permission(field(ref, :permission) || @permission)
    }
  end

  defp normalize_grant_ref(ref), do: ref

  defp validate_grant_ref(ref) when is_map(ref) do
    if Enum.all?([:resource_uri, :scope_value, :repo_fingerprint, :permission], fn key ->
         field(ref, key) not in [nil, ""]
       end) do
      :ok
    else
      {:error, :invalid_command_grant_ref}
    end
  end

  defp validate_grant_ref(_ref), do: {:error, :invalid_command_grant_ref}

  defp canonical_command(params) do
    if raw_shell_params?(params) do
      raw_shell_command(params)
    else
      argv_command(params)
    end
  end

  defp raw_shell_command(params) do
    command = params |> field(:command) |> to_string() |> String.trim()

    if command == "" do
      {:error, :missing_command}
    else
      {:ok, "raw_shell", "raw_shell\0#{command}", %{"executable" => "/bin/sh", "arg_count" => 1}}
    end
  end

  defp argv_command(params) do
    executable = params |> field(:executable) |> to_string() |> String.trim()
    args = params |> field(:args) |> list_param()

    if executable == "" do
      {:error, :missing_executable}
    else
      canonical = Enum.join(["argv", executable | args], "\0")
      {:ok, "argv", canonical, %{"executable" => executable, "arg_count" => length(args)}}
    end
  end

  defp raw_shell_params?(params) do
    field(params, :mode) in [:raw_shell, "raw_shell"] or
      (is_binary(field(params, :command)) and field(params, :executable) in [nil, ""])
  end

  defp canonical_cwd(params) do
    cwd = field(params, :cwd) || "."

    cwd
    |> to_string()
    |> Path.expand()
    |> real_path()
    |> then(&{:ok, &1})
  end

  defp repo_root(cwd) do
    cwd
    |> Path.expand()
    |> real_path()
    |> find_repo_root()
    |> then(&{:ok, &1})
  end

  defp real_path(path), do: resolve_symlink_path(path, 0)

  defp resolve_symlink_path(path, depth) when depth > 40, do: Path.expand(path)

  defp resolve_symlink_path(path, depth) do
    case Path.split(path) do
      ["/" | parts] -> resolve_symlink_parts(parts, "/", depth)
      parts -> resolve_symlink_parts(parts, Path.expand("."), depth)
    end
  end

  defp resolve_symlink_parts([], path, _depth), do: path

  defp resolve_symlink_parts([part | rest], base, depth) do
    candidate = Path.join(base, part)

    case File.read_link(candidate) do
      {:ok, target} ->
        target
        |> expand_symlink_target(base)
        |> append_path_parts(rest)
        |> resolve_symlink_path(depth + 1)

      {:error, _reason} ->
        resolve_symlink_parts(rest, candidate, depth)
    end
  end

  defp expand_symlink_target(target, base) do
    if Path.type(target) == :absolute, do: target, else: Path.expand(target, base)
  end

  defp append_path_parts(path, []), do: path
  defp append_path_parts(path, rest), do: Path.join([path | rest])

  defp find_repo_root(path) do
    cond do
      File.exists?(Path.join(path, ".git")) ->
        path

      Path.dirname(path) == path ->
        path

      true ->
        path |> Path.dirname() |> find_repo_root()
    end
  end

  defp expires_at(now, opts) do
    case field(opts, :expires_at) do
      nil ->
        DateTime.add(now, Config.command_grants_default_ttl_ms() * 1_000, :microsecond)

      expires_at ->
        expires_at
    end
  end

  defp revoked?(grant), do: present?(grant["revoked_at"])

  defp expired?(grant, opts) do
    case grant["expires_at"] do
      nil ->
        false

      "" ->
        false

      expires_at ->
        {:ok, expires_at, _offset} = DateTime.from_iso8601(expires_at)
        DateTime.compare(expires_at, now(opts)) != :gt
    end
  end

  defp now(opts), do: field(opts, :now) || DateTime.utc_now()

  defp settings_context(opts) do
    opts
    |> field(:context, %{})
    |> Map.take([:actor, :channel, :surface, :audit?])
    |> Map.put_new(:actor, "local")
    |> Map.put_new(:channel, :coding_command_grants)
  end

  defp coding_context_value(context, key) do
    field(context, key) || get_in(context, [:coding, key]) ||
      get_in(context, ["coding", Atom.to_string(key)])
  end

  defp channel_name(%{channel: %{name: name}}), do: to_string(name)
  defp channel_name(%{"channel" => %{"name" => name}}), do: to_string(name)
  defp channel_name(%{channel: channel}) when is_atom(channel), do: Atom.to_string(channel)
  defp channel_name(%{"channel" => channel}) when is_atom(channel), do: Atom.to_string(channel)
  defp channel_name(%{channel: channel}) when is_binary(channel), do: channel
  defp channel_name(%{"channel" => channel}) when is_binary(channel), do: channel
  defp channel_name(_context), do: nil

  defp normalize_permission(permission) when is_atom(permission), do: Atom.to_string(permission)
  defp normalize_permission(permission), do: to_string(permission)

  defp list_param(value) when is_list(value), do: Enum.map(value, &to_string/1)
  defp list_param(nil), do: []
  defp list_param(value), do: [to_string(value)]

  defp sha256(value), do: :crypto.hash(:sha256, to_string(value)) |> Base.encode16(case: :lower)

  defp grant_id do
    "grant_#{System.system_time(:microsecond)}_#{System.unique_integer([:positive])}"
  end

  defp datetime_text(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp datetime_text(value) when is_binary(value), do: value

  defp maybe_put_string(map, _key, nil), do: map
  defp maybe_put_string(map, _key, ""), do: map
  defp maybe_put_string(map, key, value), do: Map.put(map, key, to_string(value))

  defp maybe_put_datetime(map, key, value), do: Map.put(map, key, datetime_text(value))

  defp stringify_record(record) when is_map(record) do
    record
    |> Enum.map(fn {key, value} -> {to_string(key), stringify_value(value)} end)
    |> Map.new()
  end

  defp stringify_value(value) when is_map(value), do: stringify_record(value)
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value), do: value

  defp attrs_map(attrs) when is_map(attrs), do: attrs
  defp attrs_map(attrs) when is_list(attrs), do: Map.new(attrs)

  defp field(map, key, default \\ nil) when is_map(map),
    do: Maps.field_truthy(map, key) || default

  defp present?(value), do: value not in [nil, ""]
end
