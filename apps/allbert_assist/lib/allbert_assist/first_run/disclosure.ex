defmodule AllbertAssist.FirstRun.Disclosure do
  @moduledoc """
  Durable, per-surface disclosure state for detection-based enablement.

  A failed render leaves the marker pending. Hosted callers invoke
  `render_and_ack/2` before transport, so egress cannot precede disclosure.
  """

  alias AllbertAssist.CLI.FirstRun

  @surfaces ~w(web tui cli)

  @spec mark_pending(%{
          required(:profile) => term(),
          required(:provider) => term(),
          required(:provider_class) => atom()
        }) :: :ok
  def mark_pending(selection) when is_map(selection) do
    record = %{
      "state" => "pending",
      "profile" => selection.profile,
      "provider" => selection.provider,
      "provider_class" => Atom.to_string(selection.provider_class)
    }

    disclosures = Map.new(@surfaces, &{&1, record})
    FirstRun.merge_marker(%{"model_disclosure" => disclosures})
  end

  @spec pending?(atom() | String.t()) :: boolean()
  def pending?(surface), do: get_in(record(surface), ["state"]) == "pending"

  @spec hosted_pending?(atom() | String.t()) :: boolean()
  def hosted_pending?(surface) do
    disclosure = record(surface)
    disclosure["state"] == "pending" and disclosure["provider_class"] == "hosted"
  end

  @spec text(atom() | String.t()) :: String.t() | nil
  def text(surface) do
    case record(surface) do
      %{"state" => "pending"} = disclosure -> disclosure_text(disclosure)
      _other -> nil
    end
  end

  @spec render_and_ack(atom() | String.t(), (String.t() -> term())) ::
          :ok | {:error, term()}
  def render_and_ack(surface, output_fun) when is_function(output_fun, 1) do
    case text(surface) do
      nil ->
        :ok

      disclosure ->
        try do
          case output_fun.(disclosure) do
            {:error, reason} -> {:error, {:disclosure_render_failed, reason}}
            _delivered -> acknowledge(surface)
          end
        rescue
          exception -> {:error, {:disclosure_render_failed, exception.__struct__}}
        catch
          kind, reason -> {:error, {:disclosure_render_failed, {kind, reason}}}
        end
    end
  end

  @spec acknowledge(atom() | String.t()) :: :ok
  def acknowledge(surface) do
    surface = normalize_surface(surface)
    marker = FirstRun.read_marker()

    updated =
      marker
      |> get_in(["model_disclosure", surface])
      |> case do
        %{} = disclosure -> Map.put(disclosure, "state", "acknowledged")
        _missing -> %{"state" => "acknowledged"}
      end

    FirstRun.merge_marker(%{
      "model_disclosure" =>
        marker
        |> Map.get("model_disclosure", %{})
        |> Map.put(surface, updated)
    })
  end

  @spec prepare_web_delivery() :: {:ok, %{text: String.t(), handle: String.t()}} | :none
  def prepare_web_delivery do
    case text(:web) do
      nil ->
        :none

      disclosure_text ->
        handle = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
        marker = FirstRun.read_marker()
        disclosures = Map.get(marker, "model_disclosure", %{})
        web = disclosures |> Map.get("web", %{}) |> Map.put("delivery_handle", handle)
        :ok = FirstRun.merge_marker(%{"model_disclosure" => Map.put(disclosures, "web", web)})
        {:ok, %{text: disclosure_text, handle: handle}}
    end
  end

  @spec acknowledge_web(String.t()) :: :ok | {:error, :stale_delivery_handle}
  def acknowledge_web(handle) when is_binary(handle) do
    expected = record(:web)["delivery_handle"]

    if is_binary(expected) and byte_size(expected) == byte_size(handle) and
         Plug.Crypto.secure_compare(expected, handle) do
      acknowledge(:web)
    else
      {:error, :stale_delivery_handle}
    end
  end

  def acknowledge_web(_handle), do: {:error, :stale_delivery_handle}

  @spec cancel_pending() :: :ok
  def cancel_pending, do: FirstRun.merge_marker(%{"model_disclosure" => %{}})

  defp record(surface) do
    FirstRun.read_marker()
    |> get_in(["model_disclosure", normalize_surface(surface)])
    |> case do
      %{} = disclosure -> disclosure
      _missing -> %{}
    end
  end

  defp disclosure_text(%{
         "profile" => profile,
         "provider" => provider,
         "provider_class" => "hosted"
       }) do
    "Allbert selected #{profile} from #{provider} because its configured key was detected. " <>
      "Your message will leave this device for #{provider}. Change the model in Models, or disable model answers with `allbert settings set intent.direct_answer_model_enabled false`."
  end

  defp disclosure_text(%{"profile" => profile, "provider" => provider}) do
    "Allbert selected #{profile} from #{provider} because a ready local model was detected. " <>
      "Inference stays on this device. Change the model in Models, or disable model answers with `allbert settings set intent.direct_answer_model_enabled false`."
  end

  defp normalize_surface(surface) when is_atom(surface), do: Atom.to_string(surface)
  defp normalize_surface(surface) when is_binary(surface), do: surface
end
