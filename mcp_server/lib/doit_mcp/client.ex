defmodule DoitMcp.Client do
  @moduledoc """
  The only module that speaks HTTP. Every tool/resource calls through here —
  this is the boundary that keeps the adapter a thin translation layer over
  the public API (Arc 1, `/api/v1`), never a shortcut into the Elixir contexts.
  """

  @doc "POST an ordered batch of operations to `/api/v1/operations`."
  @spec operations([map()]) :: {:ok, [map()]} | {:error, map()}
  def operations(ops) when is_list(ops) do
    request(:post, "/api/v1/operations", json: %{operations: ops})
  end

  @doc "GET a read endpoint under `/api/v1`."
  @spec get(String.t(), keyword()) :: {:ok, term()} | {:error, map()}
  def get(path, params \\ []) do
    request(:get, path, params: params)
  end

  defp request(method, path, opts) do
    req =
      [
        base_url: base_url(),
        auth: {:bearer, token()},
        method: method,
        url: path,
        # A tool call is a synchronous round trip for whoever is waiting on the
        # MCP response (an agent or a human at a prompt) — fail fast and let
        # the caller decide whether to retry, instead of Req's default silent
        # multi-second backoff-and-retry on a transient error.
        retry: false
      ]
      |> Keyword.merge(Application.get_env(:doit_mcp, :req_options, []))
      |> Req.new()
      |> Req.merge(opts)

    case Req.request(req) do
      {:ok, %Req.Response{status: status, body: %{"data" => data}}} when status in 200..299 ->
        {:ok, data}

      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, exception} ->
        {:error, %{status: nil, reason: Exception.message(exception)}}
    end
  end

  # The MCP client's process env — set once by whatever launches this adapter
  # (`claude mcp add`, a generic stdio config block, …). Never read from a
  # config file: a token is a per-user secret, not a build-time setting.
  defp base_url, do: System.get_env("DOITLIST_API_URL", "http://localhost:4000")
  defp token, do: System.fetch_env!("DOITLIST_API_TOKEN")
end
