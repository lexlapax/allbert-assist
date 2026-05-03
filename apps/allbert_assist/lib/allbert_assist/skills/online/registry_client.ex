defmodule AllbertAssist.Skills.Online.RegistryClient do
  @moduledoc """
  Req-backed client for online skill source profiles.

  The client knows a small, testable JSON shape and a conservative skills.sh
  page fallback. It never shells out to `npx`, `git`, or package managers.
  """

  alias AllbertAssist.Skills.Online.Source

  def search(%Source{} = source, query) when is_binary(query) do
    with :ok <- Source.validate_enabled(source),
         {:ok, body} <-
           request(source, search_url(source),
             params: %{"q" => query, "limit" => source.max_listing_results}
           ) do
      results =
        body
        |> list_items()
        |> Enum.map(&candidate_from_item(&1, source))
        |> Enum.filter(&matches_query?(&1, query))
        |> Enum.take(source.max_listing_results)

      {:ok,
       %{
         source: Source.summary(source),
         query: query,
         results: results,
         diagnostics: diagnostics(results)
       }}
    end
  end

  def show(%Source{} = source, id) when is_binary(id) do
    with :ok <- Source.validate_enabled(source) do
      case request(source, detail_api_url(source, id)) do
        {:ok, body} -> {:ok, detail_from_body(body, source, id)}
        {:error, _reason} -> fetch_detail_page(source, id)
      end
    end
  end

  defp fetch_detail_page(source, id) do
    with {:ok, body} <- request(source, detail_page_url(source, id)) do
      {:ok, detail_from_body(body, source, id)}
    end
  end

  defp request(source, url, opts \\ []) do
    req_opts =
      [
        method: :get,
        url: url,
        retry: false,
        redirect: false,
        receive_timeout: 5000
      ]
      |> Keyword.merge(opts)
      |> Keyword.merge(source.req_options)

    case Req.request(req_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        if response_size(body) <= source.max_download_bytes do
          {:ok, body}
        else
          {:error, {:online_skill_response_too_large, response_size(body)}}
        end

      {:ok, %{status: status}} ->
        {:error, {:online_skill_source_http_error, status}}

      {:error, reason} ->
        {:error, {:online_skill_source_request_failed, reason}}
    end
  end

  defp search_url(source), do: source.api_url <> "/search"

  defp detail_api_url(source, id) do
    source.api_url <> "/skills/" <> URI.encode(id, &URI.char_unreserved?/1)
  end

  defp detail_page_url(source, id), do: source.base_url <> "/" <> id

  defp list_items(items) when is_list(items), do: items

  defp list_items(%{} = body) do
    Map.get(body, "skills") || Map.get(body, "results") || Map.get(body, "data") || []
  end

  defp list_items(_body), do: []

  defp candidate_from_item(item, source) when is_map(item) do
    owner = text_field(item, ["owner", "org", "namespace"])
    repository = text_field(item, ["repository", "repo", "package"])
    name = text_field(item, ["name", "skill", "slug"])
    id = text_field(item, ["id", "source_id"]) || Enum.join([owner, repository, name], "/")

    %{
      source: source.id,
      id: id,
      name: name || id,
      title: text_field(item, ["title"]) || name || id,
      description: text_field(item, ["description", "summary"]),
      owner: owner,
      repository: repository,
      source_url: text_field(item, ["source_url", "repo_url", "repository_url", "url"]),
      detail_url: text_field(item, ["detail_url"]) || detail_page_url(source, id),
      license: text_field(item, ["license"]),
      install_count: number_field(item, ["install_count", "installs", "weekly_installs"]),
      ranking: number_field(item, ["ranking", "rank"]),
      audit_badges: list_field(item, ["audit_badges", "badges", "audits"]),
      importable?: Map.get(item, "importable", true),
      warnings: list_field(item, ["warnings"]),
      raw: item
    }
  end

  defp candidate_from_item(item, source) do
    id = to_string(item)
    %{source: source.id, id: id, name: id, title: id, warnings: [], raw: item}
  end

  defp detail_from_body(%{} = body, source, id) do
    candidate =
      body
      |> Map.get("skill", body)
      |> candidate_from_item(source)
      |> Map.put(:id, text_field(body, ["id", "source_id"]) || id)

    files = files_from_body(body)
    skill_md = text_field(body, ["skill_md", "skillMd", "skill_markdown", "markdown"])

    files =
      if is_binary(skill_md) and not Map.has_key?(files, "SKILL.md") do
        Map.put(files, "SKILL.md", skill_md)
      else
        files
      end

    %{
      candidate: candidate,
      source: Source.summary(source),
      id: id,
      source_url: candidate.source_url || candidate.detail_url,
      files: files,
      skill_md: Map.get(files, "SKILL.md"),
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      raw: body
    }
  end

  defp detail_from_body(body, source, id) when is_binary(body) do
    skill_md = extract_skill_md(body)

    %{
      candidate: %{
        source: source.id,
        id: id,
        name: Path.basename(id),
        title: Path.basename(id),
        detail_url: detail_page_url(source, id),
        warnings: ["Detail page fallback parsed from HTML/text."]
      },
      source: Source.summary(source),
      id: id,
      source_url: detail_page_url(source, id),
      files: if(is_binary(skill_md), do: %{"SKILL.md" => skill_md}, else: %{}),
      skill_md: skill_md,
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      raw: nil
    }
  end

  defp files_from_body(body) do
    case Map.get(body, "files") || Map.get(body, "archive") do
      files when is_map(files) ->
        files
        |> Enum.map(fn {path, content} -> {to_string(path), to_string(content)} end)
        |> Map.new()

      _other ->
        %{}
    end
  end

  defp extract_skill_md(body) do
    body
    |> strip_tags()
    |> case do
      text ->
        case Regex.run(~r/SKILL\.md\s*(?<skill>---\s*\n.*)/s, text, capture: ["skill"]) do
          [skill] -> String.trim(skill)
          _other -> nil
        end
    end
  end

  defp strip_tags(html) do
    html
    |> String.replace(~r/<script\b[^>]*>.*?<\/script>/is, "")
    |> String.replace(~r/<style\b[^>]*>.*?<\/style>/is, "")
    |> String.replace(~r/<[^>]+>/, "\n")
    |> html_unescape()
  end

  defp html_unescape(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
  end

  defp matches_query?(_candidate, ""), do: true

  defp matches_query?(candidate, query) do
    haystack =
      [
        candidate.name,
        candidate.title,
        candidate.description,
        candidate.owner,
        candidate.repository
      ]
      |> Enum.join(" ")
      |> String.downcase()

    query
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.all?(&String.contains?(haystack, &1))
  end

  defp diagnostics([]), do: [%{severity: :info, code: :no_online_skills_found}]
  defp diagnostics(_results), do: []

  defp text_field(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
        value when is_binary(value) and value != "" -> value
        _value -> nil
      end
    end)
  end

  defp number_field(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
        value when is_integer(value) -> value
        value when is_float(value) -> value
        _value -> nil
      end
    end)
  end

  defp list_field(map, keys) do
    Enum.find_value(keys, [], fn key ->
      case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
        values when is_list(values) -> values
        value when is_binary(value) and value != "" -> [value]
        _value -> nil
      end
    end)
  end

  defp response_size(body) when is_binary(body), do: byte_size(body)
  defp response_size(body), do: body |> inspect(limit: :infinity) |> byte_size()
end
