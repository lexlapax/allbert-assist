defmodule AllbertAssist.Test.ModelReadinessFake do
  @moduledoc false

  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Models

  def check(specs, context) when is_map(specs) and is_map(context) do
    Map.new(specs, fn {id, spec} -> {id, readiness(resolve(spec, context))} end)
  end

  defp resolve({:role, role}, context) do
    case Models.for(role, context) do
      {:ok, %{profile: profile}} -> {:ok, profile}
      {:error, _reason} -> {:error, :profile_unavailable}
    end
  end

  defp resolve({:profile, name}, _context) when is_binary(name) do
    case Settings.resolve_model_profile(name) do
      {:ok, profile} -> {:ok, profile}
      {:error, _reason} -> {:error, :profile_unavailable}
    end
  end

  defp resolve(_spec, _context), do: {:error, :profile_unavailable}

  defp readiness({:ok, profile}) do
    %{
      callable?: true,
      status: :callable,
      reason: nil,
      resolution_status: :resolved,
      profile: profile,
      doctor: nil
    }
  end

  defp readiness({:error, _reason}) do
    %{
      callable?: false,
      status: :unavailable,
      reason: :profile_unavailable,
      resolution_status: :unavailable,
      profile: nil,
      doctor: nil
    }
  end
end
