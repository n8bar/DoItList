defmodule DoItWeb.Router do
  use DoItWeb, :router

  import DoItWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DoItWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", DoItWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/", DoItWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    get "/users/register", UserRegistrationController, :new
    post "/users/register", UserRegistrationController, :create
    get "/users/log_in", UserSessionController, :new
    post "/users/log_in", UserSessionController, :create
  end

  scope "/", DoItWeb do
    pipe_through [:browser, :require_authenticated_user]

    delete "/users/log_out", UserSessionController, :delete

    live_session :authenticated, on_mount: [{DoItWeb.UserAuth, :require_authenticated}] do
      live "/account", AccountLive, :show
      live "/assigned", AssignedLive, :index
      # M02.09 WL5.3/5.4: ONE kept-mounted shell LiveView serves both the list
      # and the detail, so list<->detail is a same-module push_patch (no remount).
      live "/initiatives", InitiativeWorkspaceLive, :index
      live "/initiatives/:id", InitiativeWorkspaceLive, :show
    end
  end

  if Application.compile_env(:doit, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: DoItWeb.Telemetry
    end
  end
end
