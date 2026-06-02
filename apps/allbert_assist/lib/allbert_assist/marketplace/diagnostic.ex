defmodule AllbertAssist.Marketplace.Diagnostic do
  @moduledoc """
  Structured Marketplace Lite diagnostics.

  Diagnostics carry JSON Pointer context when the source is catalog or bundle
  JSON. They are data for actions, CLI, doctor output, and tests; they do not
  grant authority.
  """

  @type t :: %{
          required(:error_category) => atom(),
          required(:code) => atom(),
          required(:message) => String.t(),
          optional(:pointer) => String.t(),
          optional(:details) => map()
        }

  @spec new(atom(), atom(), String.t(), keyword()) :: t()
  def new(error_category, code, message, opts \\ []) do
    opts
    |> Enum.into(%{})
    |> Map.merge(%{
      error_category: error_category,
      code: code,
      message: message
    })
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @spec pointer([String.t() | non_neg_integer()]) :: String.t()
  def pointer([]), do: "/"

  def pointer(segments) when is_list(segments) do
    "/" <> Enum.map_join(segments, "/", &escape_segment/1)
  end

  defp escape_segment(value) do
    value
    |> to_string()
    |> String.replace("~", "~0")
    |> String.replace("/", "~1")
  end
end
