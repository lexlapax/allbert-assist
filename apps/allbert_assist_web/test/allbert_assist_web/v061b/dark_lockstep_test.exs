defmodule AllbertAssistWeb.V061b.DarkLockstepTest do
  @moduledoc """
  v0.61b M3 proof (feedback #8): the `[data-theme="dark"]` block and the
  `[data-theme="system"]` OS-dark media block carry IDENTICAL token values,
  asserted as parsed token→value maps (raw-text equality fails on comments and
  nesting), so `dark` and `system`-resolved dark cannot drift. Also pins the
  M3 subtle-set intent: surface-0, accent-contrast, and the semantic status
  tokens are unchanged from v0.61 so the dark a11y cells keep their AA
  contrast denominators (the conformance test computes the ratios; subtlety
  itself is the operator's S3 judgment, not this proof).
  """
  use ExUnit.Case, async: true

  @moduletag :dark_tokens

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)

  test "the two dark token blocks are value-identical (parsed token map, no drift)" do
    css = File.read!(@css_path)

    dark = token_map(block(css, ~s([data-theme="dark"] {)))

    system_dark =
      css
      |> media_region("@media (prefers-color-scheme: dark) {")
      |> block(~s([data-theme="system"] {))
      |> token_map()

    assert dark == system_dark,
           "dark vs system-dark token drift: #{inspect(map_diff(dark, system_dark))}"

    assert map_size(dark) > 0

    IO.puts(
      "dark-mode-lockstep-aa-001 status=pass tokens=#{map_size(dark)} drift=none " <>
        "subtlety=operator_s3_judgment"
    )
  end

  test "the M3 subtle set holds the AA anchors: surface-0, accent-contrast, status tokens" do
    css = File.read!(@css_path)
    dark = token_map(block(css, ~s([data-theme="dark"] {)))

    # Unchanged by design — the dark a11y cells' contrast denominators.
    assert dark["--allbert-surface-0"] == "#14121f"
    assert dark["--allbert-accent-contrast"] == "#14121f"
    assert dark["--allbert-warn"] == "#fbbf24"
    assert dark["--allbert-danger"] == "#f87171"
    assert dark["--allbert-success"] == "#4ade80"
    assert dark["--allbert-info"] == "#5eead4"

    # The subtle set (v0.61b M3): narrower ladder, softer text, dimmer line,
    # desaturated accent.
    assert dark["--allbert-surface-1"] == "#1a1828"
    assert dark["--allbert-surface-2"] == "#211e31"
    assert dark["--allbert-text-strong"] == "#e7e2f2"
    assert dark["--allbert-text-soft"] == "#a29ac0"
    assert dark["--allbert-line"] == "#2b2643"
    assert dark["--allbert-accent"] == "#9d90e2"
  end

  # -- helpers ---------------------------------------------------------------

  defp block(css, opener) do
    [_, after_sel] = String.split(css, opener, parts: 2)

    after_sel
    |> String.split("}", parts: 2)
    |> hd()
  end

  defp media_region(css, opener) do
    [_, after_open] = String.split(css, opener, parts: 2)
    take_balanced(after_open, 1, "")
  end

  defp take_balanced("}" <> _rest, 1, acc), do: acc
  defp take_balanced("{" <> rest, depth, acc), do: take_balanced(rest, depth + 1, acc <> "{")
  defp take_balanced("}" <> rest, depth, acc), do: take_balanced(rest, depth - 1, acc <> "}")

  defp take_balanced(<<c::utf8, rest::binary>>, depth, acc),
    do: take_balanced(rest, depth, acc <> <<c::utf8>>)

  defp token_map(block_body) do
    ~r/(--[\w-]+):\s*([^;]+);/
    |> Regex.scan(block_body, capture: :all_but_first)
    |> Map.new(fn [token, value] -> {token, String.trim(value)} end)
  end

  defp map_diff(a, b) do
    keys = Enum.uniq(Map.keys(a) ++ Map.keys(b))

    for key <- keys, Map.get(a, key) != Map.get(b, key) do
      {key, Map.get(a, key), Map.get(b, key)}
    end
  end
end
