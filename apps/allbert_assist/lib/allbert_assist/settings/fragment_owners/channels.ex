defmodule AllbertAssist.Settings.FragmentOwners.Channels do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "channels.cli.response_style" => %{
      allowed_values: ["concise", "balanced", "detailed"],
      default: "concise",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "channels.email.allow_html_replies" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "channels.email.enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "channels.email.from_address" => %{
      default: "",
      sensitive?: false,
      type: :email_or_empty,
      writable?: true
    },
    "channels.email.from_name" => %{
      default: "Allbert",
      sensitive?: false,
      type: :string,
      writable?: true
    },
    "channels.email.identity_map" => %{
      default: [],
      sensitive?: false,
      type: :channel_identity_map,
      writable?: true
    },
    "channels.email.imap_host" => %{
      default: "",
      sensitive?: false,
      type: :string_or_empty,
      writable?: true
    },
    "channels.email.imap_mailbox" => %{
      default: "INBOX",
      sensitive?: false,
      type: :string,
      writable?: true
    },
    "channels.email.imap_password_ref" => %{
      default: "secret://channels/email/imap_password",
      sensitive?: true,
      type: :channel_secret_ref,
      writable?: true
    },
    "channels.email.imap_poll_interval_ms" => %{
      default: 60_000,
      max: 3_600_000,
      min: 1000,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "channels.email.imap_port" => %{
      default: 993,
      max: 65_535,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "channels.email.imap_ssl" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "channels.email.imap_username" => %{
      default: "",
      sensitive?: false,
      type: :string_or_empty,
      writable?: true
    },
    "channels.email.max_body_bytes" => %{
      default: 65_536,
      max: 1_048_576,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "channels.email.response_style" => %{
      allowed_values: ["standard", "concise", "detailed"],
      default: "standard",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "channels.email.smtp_host" => %{
      default: "",
      sensitive?: false,
      type: :string_or_empty,
      writable?: true
    },
    "channels.email.smtp_password_ref" => %{
      default: "secret://channels/email/smtp_password",
      sensitive?: true,
      type: :channel_secret_ref,
      writable?: true
    },
    "channels.email.smtp_port" => %{
      default: 587,
      max: 65_535,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "channels.email.smtp_tls" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "channels.email.smtp_username" => %{
      default: "",
      sensitive?: false,
      type: :string_or_empty,
      writable?: true
    },
    "channels.live_view.response_style" => %{
      allowed_values: ["concise", "balanced", "detailed"],
      default: "concise",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "channels.telegram.allow_confirmation_callbacks" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "channels.telegram.allow_group_chats" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "channels.telegram.allowed_chat_ids" => %{
      default: [],
      sensitive?: false,
      type: :string_list,
      writable?: true
    },
    "channels.telegram.bot_token_ref" => %{
      default: "secret://channels/telegram/bot_token",
      sensitive?: true,
      type: :channel_secret_ref,
      writable?: true
    },
    "channels.telegram.enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "channels.telegram.identity_map" => %{
      default: [],
      sensitive?: false,
      type: :channel_identity_map,
      writable?: true
    },
    "channels.telegram.max_text_bytes" => %{
      default: 4096,
      max: 65_536,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "channels.telegram.poll_interval_ms" => %{
      default: 2000,
      max: 60_000,
      min: 250,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "channels.telegram.poll_timeout_seconds" => %{
      default: 25,
      max: 50,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "channels.telegram.render_approval_buttons" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "channels.telegram.response_style" => %{
      allowed_values: ["concise", "balanced", "detailed"],
      default: "concise",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "channels.whatsapp.app_secret_ref" => %{
      default: "secret://channels/whatsapp/app_secret",
      sensitive?: true,
      type: :channel_secret_ref,
      writable?: true
    },
    "channels.whatsapp.phone_number_id" => %{
      default: "",
      sensitive?: false,
      type: :string_or_empty,
      writable?: true
    },
    "channels.whatsapp.waba_id" => %{
      default: "",
      sensitive?: false,
      type: :string_or_empty,
      writable?: true
    },
    "channels.whatsapp.webhook_enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "channels.whatsapp.webhook_rate_limit.burst" => %{
      default: 10,
      max: 10_000,
      min: 0,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "channels.whatsapp.webhook_rate_limit.limit" => %{
      default: 60,
      max: 10_000,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "channels.whatsapp.webhook_rate_limit.period_ms" => %{
      default: 60_000,
      max: 86_400_000,
      min: 100,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "channels.whatsapp.webhook_verify_token_ref" => %{
      default: "secret://channels/whatsapp/webhook_verify_token",
      sensitive?: true,
      type: :channel_secret_ref,
      writable?: true
    }
  }
  @defaults %{
    "channels" => %{
      "cli" => %{"enabled" => true, "response_style" => "concise"},
      "email" => %{
        "allow_html_replies" => false,
        "enabled" => false,
        "from_address" => "",
        "from_name" => "Allbert",
        "identity_map" => [],
        "imap_host" => "",
        "imap_mailbox" => "INBOX",
        "imap_password_ref" => "secret://channels/email/imap_password",
        "imap_poll_interval_ms" => 60_000,
        "imap_port" => 993,
        "imap_ssl" => true,
        "imap_username" => "",
        "max_body_bytes" => 65_536,
        "response_style" => "standard",
        "smtp_host" => "",
        "smtp_password_ref" => "secret://channels/email/smtp_password",
        "smtp_port" => 587,
        "smtp_tls" => true,
        "smtp_username" => ""
      },
      "live_view" => %{"enabled" => true, "response_style" => "concise"},
      "telegram" => %{
        "allow_confirmation_callbacks" => true,
        "allow_group_chats" => false,
        "allowed_chat_ids" => [],
        "bot_token_ref" => "secret://channels/telegram/bot_token",
        "enabled" => false,
        "identity_map" => [],
        "max_text_bytes" => 4096,
        "poll_interval_ms" => 2000,
        "poll_timeout_seconds" => 25,
        "render_approval_buttons" => true,
        "response_style" => "concise"
      },
      "whatsapp" => %{
        "app_secret_ref" => "secret://channels/whatsapp/app_secret",
        "phone_number_id" => "",
        "waba_id" => "",
        "webhook_enabled" => false,
        "webhook_rate_limit" => %{"burst" => 10, "limit" => 60, "period_ms" => 60_000},
        "webhook_verify_token_ref" => "secret://channels/whatsapp/webhook_verify_token"
      }
    }
  }
  @safe_write_keys [
    "channels.cli.response_style",
    "channels.live_view.response_style",
    "channels.telegram.enabled",
    "channels.telegram.response_style",
    "channels.telegram.bot_token_ref",
    "channels.telegram.identity_map",
    "channels.telegram.allowed_chat_ids",
    "channels.telegram.allow_group_chats",
    "channels.telegram.poll_interval_ms",
    "channels.telegram.poll_timeout_seconds",
    "channels.telegram.max_text_bytes",
    "channels.telegram.render_approval_buttons",
    "channels.telegram.allow_confirmation_callbacks",
    "channels.email.enabled",
    "channels.email.response_style",
    "channels.email.imap_host",
    "channels.email.imap_port",
    "channels.email.imap_ssl",
    "channels.email.imap_username",
    "channels.email.imap_password_ref",
    "channels.email.imap_mailbox",
    "channels.email.imap_poll_interval_ms",
    "channels.email.smtp_host",
    "channels.email.smtp_port",
    "channels.email.smtp_tls",
    "channels.email.smtp_username",
    "channels.email.smtp_password_ref",
    "channels.email.from_address",
    "channels.email.from_name",
    "channels.email.identity_map",
    "channels.email.max_body_bytes",
    "channels.email.allow_html_replies",
    "channels.whatsapp.webhook_enabled",
    "channels.whatsapp.phone_number_id",
    "channels.whatsapp.waba_id",
    "channels.whatsapp.app_secret_ref",
    "channels.whatsapp.webhook_verify_token_ref",
    "channels.whatsapp.webhook_rate_limit.limit",
    "channels.whatsapp.webhook_rate_limit.period_ms",
    "channels.whatsapp.webhook_rate_limit.burst"
  ]
  @safe_write_rows [
    {401, "channels.cli.response_style"},
    {402, "channels.live_view.response_style"},
    {403, "channels.telegram.enabled"},
    {404, "channels.telegram.response_style"},
    {405, "channels.telegram.bot_token_ref"},
    {406, "channels.telegram.identity_map"},
    {407, "channels.telegram.allowed_chat_ids"},
    {408, "channels.telegram.allow_group_chats"},
    {409, "channels.telegram.poll_interval_ms"},
    {410, "channels.telegram.poll_timeout_seconds"},
    {411, "channels.telegram.max_text_bytes"},
    {412, "channels.telegram.render_approval_buttons"},
    {413, "channels.telegram.allow_confirmation_callbacks"},
    {414, "channels.email.enabled"},
    {415, "channels.email.response_style"},
    {416, "channels.email.imap_host"},
    {417, "channels.email.imap_port"},
    {418, "channels.email.imap_ssl"},
    {419, "channels.email.imap_username"},
    {420, "channels.email.imap_password_ref"},
    {421, "channels.email.imap_mailbox"},
    {422, "channels.email.imap_poll_interval_ms"},
    {423, "channels.email.smtp_host"},
    {424, "channels.email.smtp_port"},
    {425, "channels.email.smtp_tls"},
    {426, "channels.email.smtp_username"},
    {427, "channels.email.smtp_password_ref"},
    {428, "channels.email.from_address"},
    {429, "channels.email.from_name"},
    {430, "channels.email.identity_map"},
    {431, "channels.email.max_body_bytes"},
    {432, "channels.email.allow_html_replies"},
    {433, "channels.whatsapp.webhook_enabled"},
    {434, "channels.whatsapp.phone_number_id"},
    {435, "channels.whatsapp.waba_id"},
    {436, "channels.whatsapp.app_secret_ref"},
    {437, "channels.whatsapp.webhook_verify_token_ref"},
    {438, "channels.whatsapp.webhook_rate_limit.limit"},
    {439, "channels.whatsapp.webhook_rate_limit.period_ms"},
    {440, "channels.whatsapp.webhook_rate_limit.burst"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:channels",
      owner: "channels",
      source: :core,
      group: "channels",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Channels"}
    })
  end

  @impl true
  def dynamic_default_keys, do: ["channels.cli.enabled", "channels.live_view.enabled"]

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
