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

  # The browser client's bootstrap document (m04.01 worklist 2). Like :browser
  # but deliberately WITHOUT `:require_authenticated_user` and without the
  # LiveView root layout: signed out is a 200 with `user: null`, and the client
  # paints its own "Signed out" screen. No live flash either — nothing on this
  # document is server-rendered product chrome.
  # "json" is accepted alongside "html" so a `fetch()` that misses the JSON
  # scope above — `Accept: application/json` on an unknown /app/api path —
  # reaches the controller and gets the API's JSON 404 instead of a 406 from
  # content negotiation. The document itself always renders HTML regardless of
  # what was asked for (`put_format(:html)` in the controller).
  pipeline :client_browser do
    plug :accepts, ["html", "json"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # The browser client's private data boundary (m04.01 worklist 5). Session
  # cookie only — no bearer token is ever read here, and the :api pipeline above
  # never fetches the session, so neither surface can pick up the other's
  # credential. Both auth failures render JSON, never HTML: the browser client
  # calls these with fetch(). The contract lives in `DoItWeb.Client.Api`.
  pipeline :client_api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :fetch_current_user
    plug DoItWeb.Client.AuthPlug
    plug DoItWeb.Client.CsrfPlug
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
    get "/initiatives/:id/task_count", InitiativeController, :task_count
    get "/initiatives/:id/tasks/:task_id/comments", CommentController, :index

    # Task → Initiative resolver (m03.04 2.8.1.1): the one read keyed on a
    # bare task id, so the MCP import gate can count parent_id-anchored adds.
    # Deviates from the policy above on purpose: unknown ids AND tasks the
    # caller can't view are a UNIFORM 404 — a bare task id is no existence
    # oracle.
    get "/tasks/:id", TaskController, :show

    # Atomic mutation surface (m03.01 worklist 3). One endpoint over the
    # reversible op set; an ordered batch applied all-or-nothing. Per-op authz +
    # the per-op error contract live in DoItWeb.Api.Operations.
    post "/operations", OperationsController, :create

    # Text import (m03.04 2.3): a source document in, a Task tree out. Parsed
    # by DoIt.Imports.Parser, applied through the operations engine above in
    # cap-sized batches. Preview mode writes nothing.
    post "/imports", ImportController, :create
  end

  # The browser client's private JSON surface (m04.01 worklist 5). Thin edges
  # over the SAME contexts, Authz, Serializer, and Operations engine /api/v1
  # uses — see `DoItWeb.Client.Api` for the endpoint and error contract.
  scope "/app/api", DoItWeb.Client do
    pipe_through :client_api

    get "/session", SessionController, :show
    get "/initiatives", InitiativeController, :index
    get "/initiatives/:id", InitiativeController, :show
    post "/operations", OperationsController, :create
  end

  # The React client's bootstrap document (m04.01 worklist 2). Declared AFTER
  # "/app/api" above so the JSON surface wins those paths; everything else under
  # /app is one document and the client routes it in the browser.
  scope "/app", DoItWeb do
    pipe_through :client_browser

    get "/", ClientController, :index
    get "/*path", ClientController, :index
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
