defmodule DoitMcp.ToolResultTest do
  use ExUnit.Case, async: true

  alias DoitMcp.ToolResult
  alias Anubis.Server.Response

  # A genuine unhandled server crash (past Phoenix's default error view)
  # never matches the app's own {"error": ...} envelope -- reproduces the
  # real body a 500 from an oversized `apply_operations` batch returned.
  @crash_body %{"errors" => %{"detail" => "Internal Server Error"}}

  describe "reply/2" do
    test "an app-shaped error is a clean, readable message" do
      frame = %{}

      assert {:reply, response, ^frame} =
               ToolResult.reply(
                 frame,
                 {:error, %{status: 422, body: %{"error" => %{"message" => "bad"}}}}
               )

      assert response.isError
    end

    test "a crash-shaped body (no \"error\" key) doesn't raise -- falls to the generic clause" do
      frame = %{}

      assert {:reply, response, ^frame} =
               ToolResult.reply(frame, {:error, %{status: 500, body: @crash_body}})

      assert response.isError
      protocol = Response.to_protocol(response)
      assert [%{"text" => text}] = protocol["content"]
      assert text =~ "500"
    end
  end

  describe "reply_batch/2" do
    test "a crash-shaped body (no \"error\" key) doesn't raise -- falls to the generic clause" do
      frame = %{}

      assert {:reply, response, ^frame} =
               ToolResult.reply_batch(frame, {:error, %{status: 500, body: @crash_body}})

      assert response.isError
      protocol = Response.to_protocol(response)
      assert [%{"text" => text}] = protocol["content"]
      assert text =~ "500"
    end
  end
end
