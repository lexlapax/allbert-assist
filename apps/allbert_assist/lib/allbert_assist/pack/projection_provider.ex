defmodule AllbertAssist.Pack.ProjectionProvider do
  @moduledoc """
  Builds the sealed Pack projection used by the production composition owner.

  The provider reads only the trusted first-party component catalog and raw OTP
  metadata already present in the running code path. In a packaged release it
  also consumes the exact `.rel`; source/test boots synthesize the equivalent
  four-application permanent release record from those raw `.app` files.
  """

  alias AllbertAssist.Pack.OTPMetadata
  alias AllbertAssist.Pack.OTPMetadata.{ReleaseApplication, ReleaseSpec}
  alias AllbertAssist.Pack.Projection

  @applications [:allbert_kernel, :allbert_assist, :allbert_composition, :allbert_assist_web]

  @spec closed() :: {:ok, Projection.Closed.t()} | {:error, term()}
  def closed do
    with {:ok, components} <- catalog_components(),
         {:ok, applications} <- application_specs(),
         {:ok, release} <- release_spec(applications),
         components <- seal_components(components, applications) do
      Projection.reconcile_closed(components, applications, release,
        sealed: true,
        closed_applications: @applications,
        effective_env_fetcher: effective_env_fetcher(applications)
      )
    end
  rescue
    error -> {:error, {:projection_provider, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:projection_provider, kind, reason}}
  end

  defp catalog_components do
    path = Application.app_dir(:allbert_assist, "priv/licenses/catalog.json")

    with {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) <= 5_000_000,
         {:ok, %{"schema_version" => 1, "components" => components}} <- Jason.decode(bytes),
         true <- is_list(components) do
      {:ok, components}
    else
      _ -> {:error, :invalid_component_catalog}
    end
  end

  defp application_specs do
    @applications
    |> Enum.reduce_while({:ok, []}, fn application, {:ok, specs} ->
      with {:ok, path} <- application_metadata_path(application),
           {:ok, spec} <- OTPMetadata.read_app(path) do
        {:cont, {:ok, [spec | specs]}}
      else
        {:error, reason} ->
          {:halt, {:error, {:application_metadata, application, reason}}}
      end
    end)
    |> case do
      {:ok, specs} -> {:ok, Enum.reverse(specs)}
      error -> error
    end
  end

  defp application_metadata_path(application) do
    {:ok, Application.app_dir(application, "ebin/#{application}.app")}
  rescue
    ArgumentError -> {:error, {:unknown_application, application}}
  end

  defp release_spec(applications) do
    case packaged_rel_path() do
      {:ok, path} -> OTPMetadata.read_rel(path)
      :source -> {:ok, source_release_spec(applications)}
      {:error, _reason} = error -> error
    end
  end

  defp packaged_rel_path do
    with root when is_binary(root) <- System.get_env("RELEASE_ROOT"),
         version when is_binary(version) <- System.get_env("RELEASE_VSN") do
      case Path.wildcard(Path.join([root, "releases", version, "*.rel"])) do
        [path] -> {:ok, path}
        paths -> {:error, {:release_metadata_paths, length(paths)}}
      end
    else
      _ -> :source
    end
  end

  defp source_release_spec(applications) do
    %ReleaseSpec{
      name: "allbert",
      version: applications |> hd() |> Map.fetch!(:version),
      erts_version: System.otp_release(),
      applications:
        Enum.map(applications, fn application ->
          %ReleaseApplication{
            application: application.application,
            version: application.version,
            start_mode: :permanent,
            included_applications: application.included_applications
          }
        end)
    }
  end

  defp seal_components(components, applications) do
    specs = Map.new(applications, &{Atom.to_string(&1.application), &1})

    Enum.map(components, fn component ->
      with %{"application" => application, "pack" => pack} when is_map(pack) <- component,
           {:ok, spec} <- Map.fetch(specs, application) do
        Map.put(component, "pack", Map.put(pack, "app_sha256", spec.sha256))
      else
        _ -> component
      end
    end)
  end

  defp effective_env_fetcher(applications) do
    fn application, :allbert_pack ->
      case Enum.find(applications, &(&1.application == application)) do
        %{pack_module: nil} -> :error
        %{pack_module: module} -> {:ok, module}
        nil -> :error
      end
    end
  end
end
