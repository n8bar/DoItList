defmodule DoitMcp.Resources.TaskCommentsTest do
  use ExUnit.Case, async: true

  alias DoitMcp.Resources.TaskComments

  test "read/2 fetches a task's comments and relays the reply/frame through" do
    comments = [%{"id" => 1, "body" => "Looks good", "deleted_at" => nil}]

    Req.Test.stub(DoitMcp.Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/v1/initiatives/42/tasks/7/comments"

      Req.Test.json(conn, %{"data" => comments})
    end)

    frame = %{test: true}

    assert {:reply, %Anubis.Server.Response{type: :resource} = response, ^frame} =
             TaskComments.read(%{"params" => %{"id" => "42", "task_id" => "7"}}, frame)

    assert Jason.decode!(response.contents["text"]) == comments
  end
end
