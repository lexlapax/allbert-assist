defmodule AllbertAssist.Skills do
  @moduledoc """
  Facade for v0.03 Agent Skill discovery, lookup, and diagnostics.

  The registry loads standard Agent Skills from bounded directories, applies
  trust and enablement policy, and exposes only trusted model-facing skills.
  """

  alias AllbertAssist.Skills.Registry

  @doc "Return trusted and enabled skill declarations."
  defdelegate list(context \\ %{}), to: Registry

  @doc "Find a skill declaration by name, title, or snake-case alias."
  defdelegate get(name, context \\ %{}), to: Registry

  @doc "Read one skill declaration body and diagnostics."
  defdelegate read(name, context \\ %{}), to: Registry

  @doc "Return registry diagnostics for skipped or hidden skills."
  defdelegate diagnostics(context \\ %{}), to: Registry

  @doc "Normalize a public skill name to canonical kebab case."
  defdelegate normalize_name(name), to: Registry

  @doc "Activation is introduced in v0.03 M5."
  def activate(_name, _context \\ %{}), do: {:error, :activation_not_available}
end
