defmodule AllbertAssistWeb.Router do
  use AllbertAssistWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AllbertAssistWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug AllbertAssistWeb.Plugs.ContentSecurityPolicy, :browser
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :public_protocol_api do
    plug AllbertAssistWeb.Plugs.PublicProtocolHeaders
  end

  pipeline :theme_css do
    plug :put_secure_browser_headers
    plug AllbertAssistWeb.Plugs.ContentSecurityPolicy, :theme
  end

  scope "/", AllbertAssistWeb do
    pipe_through :theme_css

    get "/theme/user.css", ThemeController, :user
    get "/theme/snippets.css", ThemeController, :snippets
    get "/theme/snippets/:name", ThemeController, :snippet
  end

  scope "/", AllbertAssistWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/workspace/media/:message_id/:index", WorkspaceMediaController, :show
    live "/workspace", WorkspaceLive
    live "/jobs", JobsLive
    live "/objectives/:id", ObjectiveLive
  end

  scope "/" do
    pipe_through :browser

    live "/apps/artifacts/:sha", AllbertArtifactsWeb.ArtifactLive, :show
    live "/apps/stocksage/analyses/:id", StockSageWeb.AnalysisLive, :show
  end

  scope "/", AllbertAssistWeb.PublicProtocol do
    pipe_through [:api, :public_protocol_api]

    post "/mcp", McpHttpController, :handle
    delete "/mcp", McpHttpController, :delete
    get "/webhooks/whatsapp/:phone_number_id", WhatsAppWebhookController, :verify
    post "/webhooks/whatsapp/:phone_number_id", WhatsAppWebhookController, :handle
  end

  scope "/v1", AllbertAssistWeb.PublicProtocol do
    pipe_through [:api, :public_protocol_api]

    get "/models", OpenAIController, :models
    post "/chat/completions", OpenAIController, :chat_completions
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:allbert_assist_web, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AllbertAssistWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
