defmodule AllbertAssist.Plugin.Manifest do
  @moduledoc false

  alias AllbertAssist.Plugin.Validator

  @spec read(Path.t(), keyword()) ::
          {:ok, AllbertAssist.Plugin.Entry.t()} | {:error, term(), [map()]}
  def read(path, opts \\ []) when is_binary(path) do
    root_path = Keyword.get(opts, :root_path, Path.dirname(path))

    with {:ok, body} <- File.read(path),
         {:ok, manifest} <- Jason.decode(body) do
      opts =
        opts
        |> Keyword.put_new(:manifest_path, Path.expand(path))
        |> Keyword.put_new(:root_path, Path.expand(root_path))

      Validator.normalize_manifest(manifest, opts)
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, :invalid_json,
         [
           Validator.diagnostic(:error, :invalid_json, "Invalid plugin manifest JSON.",
             error: Exception.message(error)
           )
         ]}

      {:error, reason} ->
        {:error, reason,
         [
           Validator.diagnostic(:error, :manifest_read_failed, "Could not read plugin manifest.",
             reason: reason
           )
         ]}
    end
  end
end
