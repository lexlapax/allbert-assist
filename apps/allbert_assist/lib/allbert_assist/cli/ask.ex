defmodule AllbertAssist.CLI.Ask do
  @moduledoc """
  Release-safe one-shot `allbert ask "prompt"` (v0.62 M8.7).

  Re-fronts the same `Runtime.submit_user_input/1` turn the `mix allbert.ask`
  task runs, and renders `{output, exit_code}` for the packaged dispatcher. The
  text flags (`--trace`, `--user`, `--operator`, `--thread`, `--new-thread`,
  `--session`, `--active-app`, `--channel`) are supported; voice input/output
  stays on the Mix task (it needs local audio files, out of scope for the
  one-shot binary path).
  """

  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.Runtime
  alias AllbertAssist.Surface.Renderer, as: SurfaceRenderer

  @switches [
    trace: :boolean,
    user: :string,
    operator: :string,
    thread: :string,
    new_thread: :boolean,
    session: :string,
    active_app: :string,
    channel: :string
  ]

  @usage ~S(Usage: allbert ask [--trace] [--user local|--operator local] [--thread ID|--new-thread] [--session ID] [--active-app APP_ID] "prompt")

  @spec run([String.t()]) :: {String.t(), non_neg_integer()}
  def run(argv) do
    {opts, prompt_parts, invalid} = OptionParser.parse(argv, switches: @switches)

    prompt = prompt_parts |> Enum.join(" ") |> String.trim()

    cond do
      invalid != [] -> Render.usage(["Invalid option(s): #{inspect(invalid)}", @usage])
      prompt == "" -> Render.usage(@usage)
      true -> submit(prompt, opts)
    end
  end

  defp submit(prompt, opts) do
    channel = channel(opts[:channel])

    request =
      %{text: prompt, channel: channel}
      |> put_present(:user_id, blank_to_nil(opts[:user]))
      |> put_present(:operator_id, blank_to_nil(opts[:operator]))
      |> put_present(:trace, opts[:trace])
      |> put_present(:thread_id, blank_to_nil(opts[:thread]))
      |> put_present(:session_id, blank_to_nil(opts[:session]))
      |> put_present(:active_app, blank_to_nil(opts[:active_app]))
      |> put_present(:new_thread, opts[:new_thread])

    case Runtime.submit_user_input(request) do
      {:ok, response} -> render(response)
      {:error, reason} -> Render.error("Allbert request failed: #{inspect(reason)}")
    end
  end

  defp render(response) do
    Render.ok(
      [
        "Status: #{response.status}",
        "",
        SurfaceRenderer.response_text(response, %{payload: :surface_payload}),
        "",
        "Signal: #{response.signal_id}",
        "Trace: #{response.trace_id || "none"}",
        "User: #{response.user_id}",
        "Thread: #{response.thread_id}"
      ] ++ action_lines(response)
    )
  end

  defp action_lines(%{actions: []}), do: []

  defp action_lines(%{actions: actions}) do
    ["Actions:"] ++
      Enum.map(actions, fn action ->
        "- #{Map.get(action, :name, "action")} #{Map.get(action, :status, "")}"
      end)
  end

  defp channel(nil), do: :cli
  defp channel(value) when is_binary(value), do: String.to_existing_atom(value)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)
end
