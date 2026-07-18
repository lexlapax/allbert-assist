defmodule AllbertAssist.Actions.Email.SendEmail do
  @moduledoc """
  v0.54 M10 (ADR 0063) — operator-initiated outbound email. Effectful + externally
  visible, so `confirmation: :required`: the confirmation gate (via
  `Actions.Outbound.Gate`) is the only execution boundary; routing grants no
  authority. On approval the opt-in generic resume re-runs this action and the send
  is delivered through `Channels.Email.SmtpClient`. Body is redacted from the
  confirmation summary; secrets never enter summaries/traces.
  """
  use AllbertAssist.Action,
    permission: :email_send,
    exposure: :agent,
    execution_mode: :smtp_send,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "send_email",
    description: "Send an outbound email (confirmation-gated).",
    category: "email",
    tags: ["email", "outbound", "send"],
    schema: [
      to: [type: :string, required: true],
      subject: [type: :string, required: false],
      body: [type: :string, required: true],
      cc: [type: :string, required: false],
      from_name: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Outbound.Gate
  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Email.SmtpClient
  alias AllbertAssist.Maps
  alias AllbertAssist.Settings.Secrets

  def intent_descriptors do
    [
      %{
        action_name: "send_email",
        label: "Send an outbound email",
        examples: [
          "send an email to alice@example.com saying hello",
          "email bob@example.com about lunch",
          "send an email to team@example.com with body deployment is complete"
        ],
        synonyms: ["send email", "email", "outbound email"],
        required_slots: [:to, :body],
        optional_slots: [:subject],
        slot_extractors: %{
          to: :email_address,
          body: :message_body_phrase
        },
        handoff_required?: true
      }
    ]
  end

  @impl true
  def run(params, context) do
    with {:ok, to} <- required(params, :to),
         {:ok, body} <- required(params, :body) do
      subject = field(params, :subject) || "(no subject)"

      Gate.run(
        %{
          action_name: "send_email",
          permission: :email_send,
          execution_mode: :smtp_send,
          summary: %{to: to, subject: subject},
          resume_params: %{
            to: to,
            subject: subject,
            body: body,
            cc: field(params, :cc),
            from_name: field(params, :from_name)
          }
        },
        context,
        fn -> deliver(to, subject, body, params) end
      )
    else
      {:error, reason} ->
        {:ok,
         %{message: "send_email: #{inspect(reason)}", status: :failed, error: reason, actions: []}}
    end
  end

  defp deliver(to, subject, body, params) do
    with {:ok, settings} <- Channels.channel_settings("email"),
         {:ok, password} <- secret(settings),
         {:ok, from} <- fetch(settings, "from_address") do
      opts =
        [
          host: Map.get(settings, "smtp_host"),
          port: Map.get(settings, "smtp_port"),
          username: Map.get(settings, "smtp_username"),
          password: password,
          tls: Map.get(settings, "smtp_tls", true),
          from_name: field(params, :from_name) || Map.get(settings, "from_name"),
          cc: field(params, :cc)
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      case SmtpClient.send(from, to, subject, body, opts) do
        :ok -> {:ok, %{to: to, subject: subject}}
        {:error, reason} -> {:error, {:delivery_failed, reason}}
      end
    end
  end

  defp secret(settings) do
    case Secrets.get_secret(Map.get(settings, "smtp_password_ref")) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing_smtp_password}
    end
  end

  defp fetch(settings, key) do
    case Map.get(settings, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:missing_setting, key}}
    end
  end

  defp required(params, key) do
    case field(params, key) do
      value when is_binary(value) and value != "" -> {:ok, String.trim(value)}
      _other -> {:error, {:missing, key}}
    end
  end

  defp field(map, key), do: Maps.field_truthy(map, key)
end
