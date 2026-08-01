defmodule AllbertAssist.Confirmations.ResumeParamsBindingTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Confirmations.ResumeParamsBinding

  test "digest is canonical across JSON key representation and map order" do
    first = %{request: "GET https://example.test", nested: %{b: 2, a: 1}}

    second = %{
      "nested" => %{"a" => 1, "b" => 2},
      "request" => "GET https://example.test"
    }

    assert {:ok, digest} = ResumeParamsBinding.digest(first)
    assert {:ok, ^digest} = ResumeParamsBinding.digest(second)
    assert ResumeParamsBinding.valid_digest?(digest)
    assert :ok = ResumeParamsBinding.verify(digest, second)
  end

  test "verify rejects changed, absent, and non-map resume packets" do
    assert {:ok, digest} = ResumeParamsBinding.digest(%{"user_id" => "alice"})

    assert {:error, :confirmation_resume_params_mismatch} =
             ResumeParamsBinding.verify(digest, %{"user_id" => "mallory"})

    assert {:error, :confirmation_resume_params_unbound} =
             ResumeParamsBinding.verify(nil, %{"user_id" => "alice"})

    assert {:error, :invalid_confirmation_resume_params} =
             ResumeParamsBinding.verify(digest, ["alice"])
  end
end
