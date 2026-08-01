defmodule AllbertAssist.Settings.YamlCodecTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Settings.YamlCodec

  test "mixed line endings in scalar values cannot escape into the YAML document" do
    source = %{
      "payload" => "safe\ncontinuation\radmin: true",
      "sentinel" => "kept"
    }

    encoded = YamlCodec.encode!(source)

    assert {:ok, ^source} = YamlCodec.read_string(encoded)
  end

  test "nested scalar values with carriage returns round-trip exactly" do
    source = %{
      "nested" => %{
        "values" => [
          "bare\rcarriage-return",
          "windows\r\nline-ending",
          "line-feed\nthen-bare\rforged: true",
          "unicode λ\nsecond line\rthird line"
        ]
      }
    }

    assert {:ok, ^source} = source |> YamlCodec.encode!() |> YamlCodec.read_string()
  end

  test "document-comment tuples remain outside the map-only codec boundary" do
    assert_raise FunctionClauseError, fn ->
      YamlCodec.encode!({"comment\rforged: true", %{"sentinel" => "kept"}})
    end
  end
end
