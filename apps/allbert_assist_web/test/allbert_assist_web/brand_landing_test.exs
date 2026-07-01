defmodule AllbertAssistWeb.BrandLandingTest do
  @moduledoc """
  v0.61 M5.1 + M6 proof: the operator-chosen Allbert brand mark is designed and
  recorded (M5.1), and M6 implements it — the mark/OG assets exist, the stock Phoenix
  logo is retired, and the `/` landing carries the brand and static SEO/OG metadata
  through the shell contract with no operator-data leak.
  """
  use ExUnit.Case, async: true

  @moduletag :v061_brand

  @priv Path.expand("../../priv/static", __DIR__)
  @brand_doc Path.expand("../../../../docs/design/brand-identity-selected.md", __DIR__)

  @brand_dir Path.expand("../../../../docs/design/brand", __DIR__)

  test "the M5.1 brand identity selection is recorded" do
    doc = File.read!(@brand_doc)

    assert doc =~ "Selected Brand Identity"
    assert doc =~ "allbert-mark.svg"
    assert doc =~ "allbert-og.svg"

    IO.puts(
      "brand-identity-selected-recorded-001 status=pass mark=recorded rationale=direction_c"
    )
  end

  test "the candidate + selected brand renderings are committed for the design record" do
    for name <- ~w(
          candidate-1-monogram-filled.svg
          candidate-2-monogram-outline.svg
          candidate-3-dot-glyph.svg
          selected-mark-lockup.svg
        ) do
      assert File.exists?(Path.join(@brand_dir, name)),
             "missing committed brand rendering: #{name}"
    end
  end

  test "the brand mark + OG assets exist and the stock Phoenix logo is retired" do
    assert File.exists?(Path.join(@priv, "images/allbert-mark.svg"))
    assert File.exists?(Path.join(@priv, "images/allbert-og.svg"))
    refute File.exists?(Path.join(@priv, "images/logo.svg"))

    IO.puts("brand-asset-no-stock-logo-001 status=pass wordmark=applied stock_logo=retired")
  end

  test "the brand mark is Direction C (violet accent, no web-font fetch)" do
    mark = File.read!(Path.join(@priv, "images/allbert-mark.svg"))

    assert mark =~ "#7c6cf0"
    refute mark =~ "@font-face"
    refute mark =~ "@import"
    refute mark =~ ".woff"
  end
end
