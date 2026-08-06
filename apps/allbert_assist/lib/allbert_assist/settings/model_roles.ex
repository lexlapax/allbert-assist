defmodule AllbertAssist.Settings.ModelRoles do
  @moduledoc """
  Closed vocabulary and DTO helpers for additive model-role references.

  Roles are Settings-owned names over concrete model profiles. This module
  grants no provider or execution authority; callers still resolve and validate
  the concrete profile through `AllbertAssist.Settings.Models`.
  """

  @roles ~w[fast capable thinking]
  @references Enum.map(@roles, &"role:#{&1}")

  @spec roles() :: [String.t()]
  def roles, do: @roles

  @spec references() :: [String.t()]
  def references, do: @references

  @spec reference?(term()) :: boolean()
  def reference?(reference), do: reference in @references

  @spec role_for_reference(term()) :: {:ok, String.t()} | :error
  def role_for_reference("role:" <> role) when role in @roles, do: {:ok, role}
  def role_for_reference(_reference), do: :error

  @spec settings_key(String.t()) :: String.t()
  def settings_key(role) when role in @roles, do: "model_roles.#{role}.profile"

  @spec mapped_profile(map(), String.t()) :: String.t() | nil
  def mapped_profile(settings, role) when is_map(settings) and role in @roles do
    get_in(settings, ["model_roles", role, "profile"])
  end

  @spec catalog(map()) :: [map()]
  def catalog(settings) when is_map(settings) do
    Enum.map(@roles, fn role ->
      profile = mapped_profile(settings, role)

      %{
        role: role,
        reference: "role:#{role}",
        settings_key: settings_key(role),
        profile: profile,
        status: if(is_binary(profile), do: :assigned, else: :unconfigured)
      }
    end)
  end
end
