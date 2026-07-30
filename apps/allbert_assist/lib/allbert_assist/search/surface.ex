defmodule AllbertAssist.Search.Surface do
  @moduledoc """
  Shared explicit Search command boundary for Web, TUI, CLI, and mapped DMs.

  It parses one closed surface grammar and dispatches only registered actions.
  Surface adapters provide verified identity and origin context; they never
  access Search storage or Corpus persistence directly.
  """

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Intent.ApprovalHandoff
  alias AllbertAssist.Runtime.Response
  alias AllbertAssist.Search.Presentation
  alias AllbertAssist.Settings

  @local_surfaces ~w[cli live_view web tui]
  @switches [
    all_history: :boolean,
    order: :string,
    limit: :integer,
    cursor: :string,
    chain: :string,
    author: :keep,
    surface: :keep,
    thread: :keep,
    after: :string,
    before: :string,
    e2ee: :boolean
  ]

  @usage "Usage: /search [options --] QUERY"

  @doc "True only for the explicit Search command."
  @spec command?(term()) :: boolean()
  def command?(text) when is_binary(text),
    do: Regex.match?(~r/^\s*\/search(?:\s|$)/u, text)

  def command?(_text), do: false

  @doc "Dispatch a slash-form Search command through the registered action spine."
  @spec dispatch_text(String.t(), map()) :: {:ok, map()}
  def dispatch_text(text, context) when is_binary(text) and is_map(context) do
    text
    |> String.replace(~r/^\s*\/search\b/u, "", global: false)
    |> parse_text()
    |> dispatch_parsed(context)
  end

  @doc "Dispatch CLI argv following `allbert search`."
  @spec dispatch_argv([String.t()], map()) :: {:ok, map()}
  def dispatch_argv(argv, context) when is_list(argv) and is_map(context) do
    argv
    |> parse_argv()
    |> dispatch_parsed(context)
  end

  @doc "Render a Search action response with the common result presentation."
  @spec present(map()) :: map()
  def present(response) when is_map(response) do
    response = Response.normalize(response)

    text =
      case Map.get(response, :search_page) do
        page when is_map(page) -> Presentation.render(page)
        _other -> response.message
      end

    text = append_disclosure(text, Map.get(response, :search_disclosure))

    response
    |> Map.put(:message, text)
    |> Map.put(:model_payload, text)
    |> Map.put(:surface_payload, text)
  end

  defp parse_text(text) do
    text = String.trim(text)

    cond do
      text == "" -> {:error, :missing_query}
      String.starts_with?(text, "--") -> parse_option_text(text)
      true -> {:ok, %{query: text}, %{all_history?: false}}
    end
  end

  defp parse_option_text(text) do
    case Regex.run(~r/\A(.*?)\s+--\s+(.+)\z/us, text, capture: :all_but_first) do
      [option_text, query] -> parse_options(OptionParser.split(option_text), String.trim(query))
      _other -> {:error, :query_separator_required}
    end
  end

  defp parse_argv(argv) do
    case Enum.split_while(argv, &(&1 != "--")) do
      {[], ["--" | query]} ->
        query_only(query)

      {options, ["--" | query]} ->
        parse_options(options, Enum.join(query, " "))

      {[first | _rest], []} when is_binary(first) and binary_part(first, 0, 2) == "--" ->
        {:error, :query_separator_required}

      {query, []} ->
        query_only(query)
    end
  end

  defp query_only(query) do
    query = query |> Enum.join(" ") |> String.trim()

    if query == "",
      do: {:error, :missing_query},
      else: {:ok, %{query: query}, %{all_history?: false}}
  end

  defp parse_options(options, query) do
    {parsed, rest, invalid} = OptionParser.parse(options, strict: @switches)

    with :ok <- valid_option_parse(rest, invalid),
         :ok <- present_query(query),
         {:ok, order} <- order(parsed[:order]),
         {:ok, filters} <- filters(parsed) do
      request =
        %{query: query, filters: filters}
        |> put_present(:order, order)
        |> put_present(:limit, parsed[:limit])
        |> put_present(:cursor, parsed[:cursor])
        |> put_present(:query_chain_id, parsed[:chain])

      {:ok, request, %{all_history?: parsed[:all_history] == true}}
    end
  end

  defp dispatch_parsed({:error, reason}, _context),
    do: {:ok, Response.error(command_error(reason), reason)}

  defp dispatch_parsed({:ok, request, opts}, context) do
    context = scope_context(context, opts)

    with {:ok, disclosure} <- grant_disclosure(context),
         {:ok, response} <- run(request, context, opts) do
      {:ok,
       response
       |> maybe_put(:search_disclosure, disclosure)
       |> maybe_attach_handoff(context)
       |> present()}
    else
      {:error, {:grant_required, disclosure}} ->
        {:ok, Response.advisory(disclosure, error: :search_origin_grant_required)}

      {:error, {:scope_excluded, disclosure}} ->
        {:ok, Response.denied(disclosure, error: :search_scope_excluded)}

      {:error, reason} ->
        {:ok, Response.error("Search command failed.", reason)}
    end
  end

  defp run(request, context, %{all_history?: true}) do
    case Map.get(request, :query_chain_id) do
      nil ->
        params =
          request
          |> Map.take([:query, :order, :limit, :filters])
          |> Map.merge(Map.take(context, [:source_message_id, :operator_id, :thread_id, :origin]))

        Runner.run("authorize_search_query_scope", params, context)

      _query_chain_id ->
        Runner.run("search_conversations", request, context)
    end
  end

  defp run(request, context, _opts), do: Runner.run("search_conversations", request, context)

  defp scope_context(context, opts) do
    surface = Map.get(context, :channel) || Map.get(context, :surface)

    if to_string(surface) in @local_surfaces do
      Map.put(context, :origin_scope, :local_operator)
    else
      context
      |> Map.put(:origin_scope, :mapped_operator_dm)
      |> maybe_put(:search_scope, if(opts.all_history?, do: :cross_surface))
    end
  end

  defp grant_disclosure(%{origin_scope: :local_operator}), do: {:ok, nil}

  defp grant_disclosure(context) do
    grants = setting("search.origin_grants", ["local_operator"])

    cond do
      Map.get(context, :conversation_scope) not in [:direct, "direct"] ->
        {:error,
         {:scope_excluded,
          "Search is available in verified mapped one-to-one operator DMs only; shared or unverified channel conversations are excluded."}}

      "mapped_operator_dm" not in grants ->
        {:error,
         {:grant_required,
          "Search is not enabled for mapped operator DMs. Opt in once in Settings Central by adding mapped_operator_dm to search.origin_grants. E2EE-origin text remains excluded unless e2ee_operator is also added."}}

      e2ee_origin?(context) and "e2ee_operator" not in grants ->
        {:ok,
         "E2EE-origin text is excluded from Search. To include it, opt in once in Settings Central by adding e2ee_operator to search.origin_grants; Search projections are local plaintext derivatives."}

      true ->
        {:ok, nil}
    end
  end

  defp maybe_attach_handoff(%{status: :needs_confirmation} = response, context) do
    decision = Map.get(response, :permission_decision, %{})

    handoff =
      decision
      |> ApprovalHandoff.pending(response, context)
      |> ApprovalHandoff.to_map()

    Map.put(response, :approval_handoff, handoff)
  end

  defp maybe_attach_handoff(response, _context), do: response

  defp filters(opts) do
    authors = Keyword.get_values(opts, :author)
    surfaces = Keyword.get_values(opts, :surface)
    threads = Keyword.get_values(opts, :thread)

    {:ok,
     %{}
     |> put_list(:authors, authors)
     |> put_list(:surfaces, surfaces)
     |> put_list(:thread_ids, threads)
     |> put_present(:after, opts[:after])
     |> put_present(:before, opts[:before])
     |> put_present(:e2ee, Keyword.get(opts, :e2ee))}
  end

  defp order(nil), do: {:ok, nil}
  defp order(value) when value in ~w[relevance newest oldest], do: {:ok, value}
  defp order(_value), do: {:error, :invalid_order}

  defp valid_option_parse([], []), do: :ok
  defp valid_option_parse(_rest, _invalid), do: {:error, :invalid_options}

  defp present_query(value) when is_binary(value) and value != "", do: :ok
  defp present_query(_value), do: {:error, :missing_query}

  defp e2ee_origin?(context) do
    trust = Map.get(context, :trust_class) || get_in(context, [:channel_thread_ref, :trust_class])
    trust in [:e2ee_origin, "e2ee_origin"]
  end

  defp setting(key, default) do
    case Settings.get(key) do
      {:ok, value} -> value
      _other -> default
    end
  end

  defp command_error(:missing_query), do: @usage

  defp command_error(:query_separator_required),
    do: "Search options require `--` before QUERY. #{@usage}"

  defp command_error(:invalid_order), do: "Search order must be relevance, newest, or oldest."
  defp command_error(:invalid_options), do: "Invalid Search options. #{@usage}"
  defp command_error(_reason), do: "Invalid Search command. #{@usage}"

  defp append_disclosure(text, nil), do: text
  defp append_disclosure(text, disclosure), do: text <> "\n\nPrivacy: " <> disclosure

  defp put_list(map, _key, []), do: map
  defp put_list(map, key, values), do: Map.put(map, key, values)

  defp put_present(map, _key, value) when value in [nil, "", []], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
