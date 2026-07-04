defmodule AllbertAssistWeb.V061b.ChatTypeHierarchyTest do
  @moduledoc """
  v0.61b M1 proof (feedback #2): the chat message bubble type hierarchy is
  strictly body > sender label > timestamp, driven by the Direction C type
  tokens (no hardcoded sizes in the touched rules), with the timestamp on the
  muted color token. Sizes are compared as token-RESOLVED rem values — a small
  `var(--allbert-font-size-*)` → rem resolver over the parsed `:root` block —
  not as raw strings, per the plan's `chat-type-hierarchy-001` eval row.
  """
  use ExUnit.Case, async: true

  @moduletag :chat_type

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)

  test "chat bubble type ranks strictly body > label > timestamp on token-resolved values" do
    # First block = the M1 token rule; the last is the M9.5 scope-matched
    # family override (no font-size).
    body_rule = first_block!(".workspace-message-body pre")
    label_rule = last_block!(".workspace-message-label")
    time_rule = last_block!(".workspace-message-time")

    body_rem = resolved_font_size_rem!(body_rule, ".workspace-message-body pre")
    label_rem = resolved_font_size_rem!(label_rule, ".workspace-message-label")
    time_rem = resolved_font_size_rem!(time_rule, ".workspace-message-time")

    assert body_rem > label_rem,
           "body (#{body_rem}rem) must out-rank the sender label (#{label_rem}rem)"

    assert label_rem > time_rem,
           "sender label (#{label_rem}rem) must out-rank the timestamp (#{time_rem}rem)"

    IO.puts(
      "chat-type-hierarchy-001 status=pass body=#{body_rem}rem label=#{label_rem}rem " <>
        "time=#{time_rem}rem tokens_only=true"
    )
  end

  test "the timestamp rule exists, is muted, and the touched rules are token-driven" do
    time_rule = last_block!(".workspace-message-time")
    assert time_rule =~ "color: var(--workspace-muted);"

    for {selector, rule} <- [
          {".workspace-message-body pre", first_block!(".workspace-message-body pre")},
          {".workspace-message-label", last_block!(".workspace-message-label")},
          {".workspace-message-time", time_rule}
        ] do
      assert rule =~ ~r/font-size:\s*var\(--allbert-font-size-/,
             "#{selector} font-size must be a Direction C token reference"

      refute Regex.match?(~r/font-size:\s*[\d.]+(px|rem)/, rule),
             "#{selector} must not hardcode a font-size"
    end
  end

  test "message bodies read in the product sans face (monospace reserved for code)" do
    body_rule = first_block!(".workspace-message-body pre")
    assert body_rule =~ "font-family: var(--allbert-font-family);"

    # v0.61b M9.5 (S3 finding): the declaration above LOST the cascade — the
    # `#workspace-shell pre` mono rule (1-0-1) beat the class-scoped sans
    # declaration (0-1-1), so every prose body still rendered monospace while
    # this rule-level assert stayed green. Guard the scope-matched winner
    # (1-1-1) explicitly.
    winner = last_block!("#workspace-shell .workspace-message-body pre")
    assert winner =~ "font-family: var(--allbert-font-family);"
  end

  # -- helpers ---------------------------------------------------------------

  # Last declaration block for a selector (the grouped shared rule earlier in
  # the file may also end with the selector; the last block is the override
  # that carries the M1 tokens).
  defp last_block!(selector), do: block!(selector, &List.last/1)
  defp first_block!(selector), do: block!(selector, &List.first/1)

  defp block!(selector, pick) do
    css = File.read!(@css_path)
    pattern = ~r/#{Regex.escape(selector)}\s*\{(?<body>.*?)\n(?:\s*)\}/s

    case Regex.scan(pattern, css, capture: :all_but_first) do
      [] -> flunk("missing CSS block for #{selector}")
      matches -> matches |> pick.() |> hd()
    end
  end

  defp resolved_font_size_rem!(rule, selector) do
    case Regex.named_captures(
           ~r/font-size:\s*var\((?<token>--allbert-font-size-[a-z0-9]+)\)/,
           rule
         ) do
      %{"token" => token} -> token_rem!(token)
      nil -> flunk("#{selector} has no token-driven font-size declaration")
    end
  end

  defp token_rem!(token) do
    # The canonical token definitions live in the FIRST `:root` block (a later
    # `:root` branch exists inside the prefers-contrast media query).
    root = first_block!(":root")

    case Regex.named_captures(~r/#{Regex.escape(token)}:\s*(?<rem>[\d.]+)rem/, root) do
      %{"rem" => rem} ->
        {value, ""} = Float.parse(rem)
        value

      nil ->
        flunk("token #{token} is not defined as a rem value in :root")
    end
  end
end
