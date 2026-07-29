defmodule AllbertAssist.Settings.KeyCustody do
  @moduledoc """
  Decrypt-once custody process for Settings Central secrets.

  This is a plain GenServer because it owns one local cache and exposes no
  Allbert capability action. Secret values are held behind zero-arity closures;
  local VM callers can fetch values through this module, while process state and
  status rendering avoid containing directly inspectable secret material.
  """

  use GenServer

  alias AllbertAssist.Settings.Audit
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Settings.Store

  defmodule State do
    @moduledoc false

    defstruct root: nil,
              secrets_path: nil,
              secrets: %{},
              system_secrets: %{},
              system_load_error: nil,
              loaded?: false,
              load_error: nil
  end

  defimpl Inspect, for: State do
    import Inspect.Algebra

    alias AllbertAssist.Settings.KeyCustody

    def inspect(state, opts) do
      state
      |> KeyCustody.redacted_state()
      |> to_doc(opts)
      |> concat_prefix()
    end

    defp concat_prefix(doc) do
      concat(["#AllbertAssist.Settings.KeyCustody.State<", doc, ">"])
    end
  end

  @type secret_ref :: String.t()
  @type fetch_context :: map()

  @system_integrity_ref "secret://system/integrity_v1"
  @system_integrity_key_version 1
  @system_integrity_key_bytes 32
  @system_integrity_domains MapSet.new([
                              "allbert.tui.receipt-payload.v1",
                              "allbert.memory.claim-transition.v1",
                              "allbert.memory.manual-confirmation.v1",
                              "allbert.memory.destination-chain-confirmation.v1",
                              "allbert.memory.forget-suppression.v1",
                              "allbert.search.cursor.v1",
                              "allbert.search.query-scope.v1",
                              "allbert.search.purge-preview.v1",
                              "allbert.conversations.delete-preview.v1"
                            ])

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec fetch(secret_ref(), fetch_context()) :: {:ok, String.t()} | {:error, term()}
  def fetch(secret_ref, context \\ %{}) do
    with :ok <- Secrets.validate_secret_ref(secret_ref),
         {:ok, value} <- call_custody({:fetch, secret_ref, context}) do
      {:ok, value}
    end
  end

  @spec status(secret_ref()) :: :configured | :missing | :decrypt_failed | :invalid_ref
  def status(secret_ref) do
    with :ok <- Secrets.validate_secret_ref(secret_ref) do
      case call_custody({:status, secret_ref}) do
        {:ok, status} -> status
        {:error, {:secret_decrypt_failed, _reason}} -> :decrypt_failed
        {:error, _reason} -> :missing
      end
    else
      {:error, _reason} -> :invalid_ref
    end
  end

  @spec list_secret_status(String.t() | nil) :: {:ok, [map()]} | {:decrypt_failed, term()}
  def list_secret_status(namespace \\ nil) do
    case call_custody({:list_status, namespace}) do
      {:ok, statuses} -> {:ok, statuses}
      {:error, {:secret_decrypt_failed, reason}} -> {:decrypt_failed, reason}
      {:error, reason} -> {:decrypt_failed, reason}
    end
  end

  @spec secure_compare(secret_ref(), binary(), fetch_context()) ::
          {:ok, boolean()} | {:error, term()}
  def secure_compare(secret_ref, candidate, context \\ %{})

  def secure_compare(secret_ref, candidate, context) when is_binary(candidate) do
    with {:ok, expected} <- fetch(secret_ref, context) do
      {:ok,
       byte_size(candidate) == byte_size(expected) and
         Plug.Crypto.secure_compare(candidate, expected)}
    end
  end

  def secure_compare(_secret_ref, _candidate, _context),
    do: {:error, {:invalid_secret_value, :not_a_binary}}

  @doc """
  Creates a domain-separated HMAC without releasing the per-Home key.

  `fields` is an ordered list of binaries. Each field is encoded as an unsigned
  64-bit big-endian byte length followed by its bytes, so field boundaries and
  order are unambiguous. Only the frozen v1.3 integrity domains and key version
  `1` are accepted. The returned map contains the raw 32-byte tag and the
  non-secret reference/version consumers must persist beside it.
  """
  @spec system_hmac(String.t(), [binary()], pos_integer()) ::
          {:ok,
           %{
             tag: binary(),
             key_ref: String.t(),
             key_version: pos_integer()
           }}
          | {:error, term()}
  def system_hmac(domain, fields, key_version) do
    with :ok <- validate_system_domain(domain),
         :ok <- validate_system_fields(fields),
         :ok <- validate_system_key_version(key_version) do
      call_custody({:system_hmac, domain, fields, key_version})
    end
  end

  @doc """
  Verifies a raw 32-byte system HMAC against an exact stored key reference.

  Verification is fetch-only: missing or malformed referenced material fails
  closed and never provisions a replacement key.
  """
  @spec verify_system_hmac(String.t(), [binary()], binary(), String.t(), pos_integer()) ::
          {:ok, boolean()} | {:error, term()}
  def verify_system_hmac(domain, fields, tag, key_ref, key_version) do
    with :ok <- validate_system_domain(domain),
         :ok <- validate_system_fields(fields),
         :ok <- validate_system_tag(tag),
         :ok <- validate_system_key_ref(key_ref),
         :ok <- validate_system_key_version(key_version) do
      call_custody({:verify_system_hmac, domain, fields, tag, key_ref, key_version})
    end
  end

  @spec invalidate(secret_ref() | :all) :: :ok
  def invalidate(secret_ref_or_all \\ :all) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.cast(__MODULE__, {:invalidate, secret_ref_or_all})
    end
  end

  @doc false
  def redacted_state(%State{} = state) do
    %{
      root: state.root,
      secrets_path: state.secrets_path,
      secret_count: map_size(state.secrets),
      loaded?: state.loaded?,
      load_error: redacted_error(state.load_error)
    }
  end

  @impl true
  def init(_opts) do
    :erlang.process_flag(:sensitive, true)
    {:ok, %State{}}
  end

  @impl true
  def handle_call({:fetch, secret_ref, context}, _from, state) do
    with {:ok, state} <- ensure_loaded(state),
         {:ok, secret_fun} <- fetch_secret_fun(state, secret_ref),
         {:ok, value} <- reveal_secret(secret_fun) do
      audit_fetch(secret_ref, context)
      {:reply, {:ok, value}, state}
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:status, secret_ref}, _from, state) do
    with {:ok, state} <- ensure_loaded(state) do
      status = if Map.has_key?(state.secrets, secret_ref), do: :configured, else: :missing
      {:reply, {:ok, status}, state}
    else
      {:error, {:secret_decrypt_failed, reason}, state} ->
        {:reply, {:error, {:secret_decrypt_failed, reason}}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:list_status, namespace}, _from, state) do
    with {:ok, state} <- ensure_loaded(state) do
      statuses =
        state.secrets
        |> Map.keys()
        |> Enum.filter(fn ref -> is_nil(namespace) or String.starts_with?(ref, namespace) end)
        |> Enum.sort()
        |> Enum.map(&%{secret_ref: &1, status: :configured})

      {:reply, {:ok, statuses}, state}
    else
      {:error, {:secret_decrypt_failed, reason}, state} ->
        {:reply, {:error, {:secret_decrypt_failed, reason}}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:system_hmac, domain, fields, @system_integrity_key_version},
        _from,
        state
      ) do
    with {:ok, key, state} <-
           fetch_or_create_system(
             @system_integrity_ref,
             @system_integrity_key_bytes,
             state
           ) do
      tag = system_tag(key, domain, fields)

      {:reply,
       {:ok,
        %{
          tag: tag,
          key_ref: @system_integrity_ref,
          key_version: @system_integrity_key_version
        }}, state}
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:verify_system_hmac, domain, fields, tag, @system_integrity_ref,
         @system_integrity_key_version},
        _from,
        state
      ) do
    with {:ok, state} <- ensure_loaded(state),
         {:ok, key} <-
           fetch_system(state, @system_integrity_ref, @system_integrity_key_version) do
      expected = system_tag(key, domain, fields)
      {:reply, {:ok, Plug.Crypto.secure_compare(tag, expected)}, state}
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:invalidate, :all}, state), do: {:noreply, unloaded_state(state)}

  def handle_cast({:invalidate, secret_ref}, state) when is_binary(secret_ref) do
    {:noreply, %{unloaded_state(state) | secrets: Map.delete(state.secrets, secret_ref)}}
  end

  @impl true
  def format_status(status) do
    Map.update(status, :state, :redacted, fn
      %State{} = state -> redacted_state(state)
      _other -> :redacted
    end)
  end

  defp call_custody(message) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :key_custody_unavailable}
      _pid -> GenServer.call(__MODULE__, message)
    end
  end

  defp ensure_loaded(%State{} = state) do
    {root, path} = location()

    if state.loaded? and state.root == root and state.secrets_path == path do
      {:ok, state}
    else
      load_state(%{state | root: root, secrets_path: path})
    end
  end

  defp load_state(%State{} = state) do
    case Secrets.load_plaintext_for_custody() do
      {:ok, plaintext} ->
        secrets =
          plaintext
          |> Secrets.plaintext_entries_for_custody()
          |> Map.new(fn {secret_ref, value} -> {secret_ref, secret_closure(value)} end)

        {system_secrets, system_load_error} = system_secrets_from_plaintext(plaintext)

        {:ok,
         %{
           state
           | secrets: secrets,
             system_secrets: system_secrets,
             system_load_error: system_load_error,
             loaded?: true,
             load_error: nil
         }}

      {:error, {:secret_decrypt_failed, reason}} ->
        state = %{
          state
          | secrets: %{},
            system_secrets: %{},
            system_load_error: nil,
            loaded?: false,
            load_error: {:secret_decrypt_failed, reason}
        }

        {:error, {:secret_decrypt_failed, reason}, state}

      {:error, reason} ->
        state = %{
          state
          | secrets: %{},
            system_secrets: %{},
            system_load_error: nil,
            loaded?: false,
            load_error: reason
        }

        {:error, reason, state}
    end
  end

  defp fetch_secret_fun(%State{} = state, secret_ref) do
    case Map.fetch(state.secrets, secret_ref) do
      {:ok, secret_fun} -> {:ok, secret_fun}
      :error -> {:error, {:secret_not_found, secret_ref}}
    end
  end

  defp reveal_secret(secret_fun) when is_function(secret_fun, 0) do
    try do
      {:ok, secret_fun.()}
    rescue
      exception ->
        stacktrace = Plug.Crypto.prune_args_from_stacktrace(__STACKTRACE__)
        reraise exception, stacktrace
    end
  end

  defp secret_closure(value) when is_binary(value), do: fn -> value end

  defp system_secrets_from_plaintext(plaintext) do
    case Secrets.system_plaintext_entries_for_custody(plaintext) do
      {:ok, entries} ->
        secrets =
          Map.new(entries, fn {identity, value} -> {identity, secret_closure(value)} end)

        {secrets, nil}

      {:error, reason} ->
        {%{}, reason}
    end
  end

  defp fetch_or_create_system(secret_ref, byte_count, state) do
    case ensure_loaded(state) do
      {:ok, state} -> fetch_or_create_loaded_system(secret_ref, byte_count, state)
      {:error, reason, state} -> {:error, reason, state}
    end
  end

  defp fetch_or_create_loaded_system(secret_ref, byte_count, state) do
    case fetch_system(state, secret_ref, @system_integrity_key_version) do
      {:ok, value} ->
        {:ok, value, state}

      {:error, {:system_integrity_key_unavailable, @system_integrity_key_version}}
      when is_nil(state.system_load_error) ->
        persist_system_secret(secret_ref, byte_count, state)

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp persist_system_secret(secret_ref, byte_count, state) do
    case Secrets.fetch_or_create_system_for_custody(secret_ref, byte_count) do
      {:ok, value} ->
        identity = {secret_ref, @system_integrity_key_version}
        system_secrets = Map.put(state.system_secrets, identity, secret_closure(value))
        {:ok, value, %{state | system_secrets: system_secrets}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp fetch_system(%State{} = state, secret_ref, key_version) do
    case Map.fetch(state.system_secrets, {secret_ref, key_version}) do
      {:ok, secret_fun} -> reveal_secret(secret_fun)
      :error when not is_nil(state.system_load_error) -> {:error, state.system_load_error}
      :error -> {:error, {:system_integrity_key_unavailable, key_version}}
    end
  end

  defp audit_fetch(secret_ref, context) do
    case Audit.append_secret_fetch(secret_ref, context) do
      {:ok, _path} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp unloaded_state(%State{} = state) do
    %{
      state
      | secrets: %{},
        system_secrets: %{},
        system_load_error: nil,
        loaded?: false,
        load_error: nil
    }
  end

  defp location do
    {Store.root(), Secrets.secrets_path()}
  end

  defp redacted_error(nil), do: nil
  defp redacted_error({kind, _reason}) when kind in [:secret_decrypt_failed], do: kind
  defp redacted_error(reason), do: reason

  defp validate_system_domain(domain) when is_binary(domain) do
    if MapSet.member?(@system_integrity_domains, domain) do
      :ok
    else
      {:error, {:unsupported_system_integrity_domain, domain}}
    end
  end

  defp validate_system_domain(domain),
    do: {:error, {:unsupported_system_integrity_domain, domain}}

  defp validate_system_fields(fields) when is_list(fields) do
    if Enum.all?(fields, &is_binary/1) do
      :ok
    else
      {:error, {:invalid_system_integrity_fields, :non_binary_field}}
    end
  end

  defp validate_system_fields(_fields),
    do: {:error, {:invalid_system_integrity_fields, :not_a_list}}

  defp validate_system_key_version(@system_integrity_key_version), do: :ok

  defp validate_system_key_version(key_version),
    do: {:error, {:unsupported_system_integrity_key_version, key_version}}

  defp validate_system_key_ref(@system_integrity_ref), do: :ok

  defp validate_system_key_ref(key_ref),
    do: {:error, {:unsupported_system_integrity_key_ref, key_ref}}

  defp validate_system_tag(tag) when is_binary(tag) and byte_size(tag) == 32, do: :ok

  defp validate_system_tag(_tag),
    do: {:error, {:invalid_system_integrity_tag, :expected_32_bytes}}

  defp system_tag(key, domain, fields) do
    domain_key = :crypto.mac(:hmac, :sha256, key, domain)
    :crypto.mac(:hmac, :sha256, domain_key, encode_system_fields(fields))
  end

  defp encode_system_fields(fields) do
    fields
    |> Enum.map(fn field -> <<byte_size(field)::unsigned-big-64, field::binary>> end)
    |> IO.iodata_to_binary()
  end
end
