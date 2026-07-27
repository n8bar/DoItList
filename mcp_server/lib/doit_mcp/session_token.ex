defmodule DoitMcp.SessionToken do
  @moduledoc """
  The per-request API credential on the HTTP transport (m03.04 item 23.2).

  On streamable HTTP every MCP request arrives with its own `Authorization`
  header, which anubis surfaces to handlers through the frame
  (`frame.context.headers`, lowercased keys). Each request — tool call,
  resource read — runs in its own task process, and every `DoitMcp.Client`
  call it makes happens in that same process, so
  `DoitMcp.Server.handle_request/2` installs the parsed bearer token in the
  request process before dispatch and the client fetches it without any
  per-tool threading.

  The stdio path is untouched: its frames carry no headers, and
  `DoitMcp.Client` only consults this module in HTTP mode — the boot-env
  token keeps flowing through `DoitMcp.TokenRecovery` there. A request
  without a usable bearer header installs `:absent`, never an env fallback:
  a session that presented nothing must get the 401 guidance, not another
  credential.
  """

  @key :doit_mcp_session_token

  @doc "Parse the frame's Authorization header and install it for this request process."
  @spec install(Anubis.Server.Frame.t()) :: :ok
  def install(frame) do
    Process.put(@key, from_headers(frame))
    :ok
  end

  @doc """
  This request's credential: `{:ok, token}` when it carried a usable bearer
  header, `:absent` otherwise (including a process nothing was installed in).
  """
  @spec fetch() :: {:ok, String.t()} | :absent
  def fetch do
    Process.get(@key, :absent)
  end

  defp from_headers(%{context: %{headers: %{"authorization" => header}}})
       when is_binary(header) do
    case String.split(header, ~r/\s+/, parts: 2) do
      [scheme, token] ->
        token = String.trim(token)

        if String.downcase(scheme) == "bearer" and token != "" do
          {:ok, token}
        else
          :absent
        end

      _ ->
        :absent
    end
  end

  defp from_headers(_frame), do: :absent
end
