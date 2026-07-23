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

  # Pre-auth per-IP throttle (m03.01 worklist 1.5). Runs BEFORE :api_auth so the
  # unauthenticated path is metered too — caps requests by source IP before auth
  # spends a hash + DB lookup resolving a (possibly garbage) Bearer token.
  pipeline :api_ip_rate_limit do
    plug DoItWeb.Api.IpRateLimitPlug
  end

  # Bearer-token auth for the HTTP API (m03.01 worklist 1.3): resolves the token
  # to the acting user and assigns :current_user + :api_token_id, or 401s.
  pipeline :api_auth do
    plug DoItWeb.Api.AuthPlug
  end

  # Per-token rate limiting (m03.01 worklist 1.5). Runs after :api_auth so it
  # keys on the token; over-limit 429s with a Retry-After hint.
  pipeline :api_rate_limit do
    plug DoItWeb.Api.RateLimitPlug
  end

  scope "/api/v1", DoItWeb.Api do
    pipe_through [:api, :api_ip_rate_limit, :api_auth, :api_rate_limit]

    get "/me", MeController, :show

    # Read surface (m03.01 worklist 2). Every read is view-gated through
    # DoItWeb.Api.Authz (unknown id → 404, can't-view → 403).
    get "/initiatives", InitiativeController, :index
    get "/initiatives/:id", InitiativeController, :show
    get "/initiatives/:id/activity", InitiativeController, :activity
    get "/initiatives/:id/members", InitiativeController, :members
    get "/initiatives/:id/tasks/:task_id/comments", CommentController, :index

    # Task → Initiative resolver (m03.04 item 2.18.1): the one read keyed on a
    # bare task id, so the MCP import gate can count parent_id-anchored adds.
    # Deviates from the policy above on purpose: unknown ids AND tasks the
    # caller can't view are a UNIFORM 404 — a bare task id is no existence
    # oracle.
    get "/tasks/:id", TaskController, :show

    # Atomic mutation surface (m03.01 worklist 3). One endpoint over the
    # reversible op set; an ordered batch applied all-or-nothing. Per-op authz +
    # the per-op error contract live in DoItWeb.Api.Operations.
    post "/operations", OperationsController, :create
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
