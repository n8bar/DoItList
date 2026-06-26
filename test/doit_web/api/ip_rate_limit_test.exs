defmodule DoItWeb.Api.IpRateLimitTest do
  @moduledoc """
  The pre-auth per-IP throttle (m03.01 worklist 1.5). Driven directly with a
  `:limit` override and an isolated `remote_ip` per test so the cap is
  deterministic and never bleeds into the shared 127.0.0.1 budget the rest of
  the suite uses.
  """
  use ExUnit.Case, async: true

  import Plug.Test

  alias DoItWeb.Api.IpRateLimitPlug

  # A remote_ip unique to each test, so the per-IP counter never bleeds between
  # tests sharing the process-wide ETS table.
  defp ip, do: {10, 0, 0, System.unique_integer([:positive])}

  defp request(remote_ip, limit) do
    %{conn(:get, "/api/v1/me") | remote_ip: remote_ip}
    |> IpRateLimitPlug.call(limit: limit)
  end

  test "meters by source IP: allows up to the limit, then 429s with Retry-After" do
    remote_ip = ip()

    for _ <- 1..2 do
      conn = request(remote_ip, 2)
      refute conn.halted
      assert conn.status == nil
    end

    over = request(remote_ip, 2)
    assert over.halted
    assert over.status == 429
    assert %{"error" => %{"code" => "rate_limited"}} = Jason.decode!(over.resp_body)
    assert [retry_after] = Plug.Conn.get_resp_header(over, "retry-after")
    assert String.to_integer(retry_after) > 0
  end

  test "a different source IP keeps its own budget" do
    hot = ip()
    cold = ip()

    for _ <- 1..3, do: request(hot, 1)

    # cold is untouched by hot's exhaustion.
    conn = request(cold, 1)
    refute conn.halted
  end
end
