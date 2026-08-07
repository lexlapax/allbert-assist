defmodule AllbertAssist.Pack.Identity do
  @moduledoc false

  @id_pattern ~r/\A[a-z][a-z0-9]*(?:_[a-z0-9]+)*\z/
  @component_pattern ~r/\Abeam-[a-z0-9]+(?:-[a-z0-9]+)*\z/

  @spec canonical_id?(term()) :: boolean()
  def canonical_id?(id) when is_binary(id) and byte_size(id) in 1..64,
    do: Regex.match?(@id_pattern, id)

  def canonical_id?(_id), do: false

  @spec canonical_application?(term()) :: boolean()
  def canonical_application?(application)
      when is_atom(application) and application not in [nil, true, false],
      do: application |> Atom.to_string() |> canonical_id?()

  def canonical_application?(_application), do: false

  @spec canonical_component?(term()) :: boolean()
  def canonical_component?(component)
      when is_binary(component) and byte_size(component) in 1..255,
      do: Regex.match?(@component_pattern, component)

  def canonical_component?(_component), do: false
end
