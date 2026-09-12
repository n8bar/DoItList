defmodule DoitMcp.Tools.ImportTextTest do
  @moduledoc """
  Coverage for `import_text` (m03.04 3.2) — the tool twin of
  `POST /api/v1/imports`. It checks the request this tool builds (each target
  form, the optionals it forwards only when given, and the source text
  reaching the wire unaltered), the reply plumbing on a 200 and on an API
  error, and the target rules it enforces before spending a round trip. It
  does not re-test `Client` or the endpoint itself.
  """

  use ExUnit.Case, async: true

  # m03.04 3.5.1 — the user-content marker opens every reply carrying titles,
  # descriptions, or comments.
  @user_content DoitMcp.ToolResult.user_content_line()

  alias Anubis.Server.Response
  alias DoitMcp.Tools.ImportText

  @frame %{test: true}

  # A document that survives only if nothing touches it: leading spaces, a
  # tab, a trailing newline, and a `%` (the cross-reference sigil).
  @gnarly_text "  1. Ship it\n\t- 100% of the way\n"

  describe "request body" do
    test "a new-Initiative target sends initiative_name and nothing else" do
      assert %{"text" => "1. Do it", "target" => %{"initiative_name" => "Q3 Plan"}} ==
               capture_body(%{text: "1. Do it", initiative_name: "Q3 Plan"})
    end

    test "an existing-Initiative target sends initiative_id" do
      assert %{"text" => "1. Do it", "target" => %{"initiative_id" => 12}} ==
               capture_body(%{text: "1. Do it", initiative_id: 12})
    end

    test "an existing-Initiative target under a Task sends parent_task_id with it" do
      assert %{
               "text" => "1. Do it",
               "target" => %{"initiative_id" => 12, "parent_task_id" => 34}
             } ==
               capture_body(%{text: "1. Do it", initiative_id: 12, parent_task_id: 34})
    end

    # m03.04 6.10 — one heading's content, passed through unchanged.
    test "section rides in the target only when given" do
      body = capture_body(%{text: "1. Do it", initiative_id: 12, section: "## Arc 4"})
      assert body["target"] == %{"initiative_id" => 12, "section" => "## Arc 4"}

      body = capture_body(%{text: "1. Do it", initiative_name: "Q3 Plan", section: "Arc 4"})
      assert body["target"] == %{"initiative_name" => "Q3 Plan", "section" => "Arc 4"}

      refute Map.has_key?(
               capture_body(%{text: "1. Do it", initiative_id: 12})["target"],
               "section"
             )
    end

    test "preview rides the request only when given" do
      body = capture_body(%{text: "1. Do it", initiative_id: 12, preview: true})
      assert body["preview"] == true

      body = capture_body(%{text: "1. Do it", initiative_id: 12, preview: false})
      assert body["preview"] == false

      refute Map.has_key?(capture_body(%{text: "1. Do it", initiative_id: 12}), "preview")
    end

    test "filename rides the request only when given" do
      body = capture_body(%{text: "1. Do it", initiative_id: 12, filename: "plan.md"})
      assert body["filename"] == "plan.md"

      refute Map.has_key?(capture_body(%{text: "1. Do it", initiative_id: 12}), "filename")
    end

    test "the source text reaches the wire byte for byte" do
      body = capture_body(%{text: @gnarly_text, initiative_name: "Verbatim"})

      assert body["text"] == @gnarly_text
    end

    # m03.04 6.7 — the stored preview carries its own source and target.
    test "a preview_id goes alone, with no target required" do
      assert %{"preview_id" => "abc123"} == capture_body(%{preview_id: "abc123"})
    end

    test "neither text nor preview_id is refused before any request" do
      assert {:error, text} = refuse(%{initiative_name: "Q3 Plan"})
      assert text =~ "text (the document to import) or preview_id"
    end
  end

  describe "reply" do
    test "a 200 body comes back as the tool's JSON, whole" do
      summary = %{
        "preview" => false,
        "initiative" => %{"id" => 12, "url" => "http://localhost:4000/initiatives/12"},
        "batches" => 1,
        "counts" => %{"items" => 2, "done" => 0, "depth" => 1, "title_overflow" => 0},
        "outline" => "1 Ship it\n2 Land it"
      }

      Req.Test.stub(DoitMcp.Client, fn conn -> Req.Test.json(conn, summary) end)

      assert {:reply, %Response{} = response, @frame} =
               ImportText.execute(%{text: "1. Ship it\n2. Land it", initiative_id: 12}, @frame)

      protocol = Response.to_protocol(response)
      assert protocol["isError"] == false

      assert [%{"text" => @user_content}, %{"type" => "text", "text" => text}] =
               protocol["content"]

      assert Jason.decode!(text) == summary
    end

    test "a preview body comes back as the tool's JSON, whole" do
      preview = %{
        "preview" => true,
        "title" => "Q3 Plan",
        "style" => "numerical",
        "outline" => "1 Ship it",
        "diff" => %{"clean" => false, "missing" => ["Land it"]}
      }

      Req.Test.stub(DoitMcp.Client, fn conn -> Req.Test.json(conn, preview) end)

      assert {:reply, %Response{} = response, @frame} =
               ImportText.execute(
                 %{text: "1. Ship it", initiative_id: 12, preview: true},
                 @frame
               )

      protocol = Response.to_protocol(response)
      assert protocol["isError"] == false

      assert [%{"text" => @user_content}, %{"type" => "text", "text" => text}] =
               protocol["content"]

      assert Jason.decode!(text) == preview
    end

    test "a 422 single-error becomes a tool error carrying the API's message" do
      Req.Test.stub(DoitMcp.Client, fn conn ->
        conn
        |> Plug.Conn.put_status(422)
        |> Req.Test.json(%{
          "error" => %{
            "status" => 422,
            "code" => "unprocessable_entity",
            "message" => "Source text has no items in it."
          }
        })
      end)

      assert {:reply, response, @frame} =
               ImportText.execute(%{text: "prose only", initiative_name: "Nope"}, @frame)

      protocol = Response.to_protocol(response)
      assert protocol["isError"] == true

      assert protocol["content"] == [
               %{"type" => "text", "text" => "(422) Source text has no items in it."}
             ]
    end
  end

  describe "target rules, enforced before any request" do
    test "no target at all" do
      assert {:error, text} = refuse(%{text: "1. Do it"})
      assert text =~ "exactly one target"
    end

    test "both target forms at once" do
      assert {:error, text} =
               refuse(%{text: "1. Do it", initiative_name: "Q3 Plan", initiative_id: 12})

      assert text =~ "exactly one target"
    end

    test "parent_task_id without initiative_id" do
      assert {:error, text} =
               refuse(%{text: "1. Do it", initiative_name: "Q3 Plan", parent_task_id: 34})

      assert text =~ "parent_task_id requires initiative_id"
    end
  end

  test "exposes a JSON object input schema for tools/list" do
    schema = ImportText.input_schema()

    assert %{"type" => "object"} = schema
    assert %{"type" => "string"} = schema["properties"]["text"]
    assert %{"type" => "string"} = schema["properties"]["preview_id"]
    assert %{"type" => "boolean"} = schema["properties"]["preview"]
    # One of text / preview_id is required; the schema can't say "one of", so
    # neither is marked required and the tool enforces it (m03.04 6.7.3).
    refute "text" in List.wrap(schema["required"])
  end

  # Runs the tool against a stub that records the decoded request body.
  defp capture_body(params) do
    test = self()

    Req.Test.stub(DoitMcp.Client, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/v1/imports"
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:body, Jason.decode!(raw)})
      Req.Test.json(conn, %{"preview" => false})
    end)

    assert {:reply, %Response{}, @frame} = ImportText.execute(params, @frame)
    assert_received {:body, body}
    body
  end

  # Runs the tool against a stub that must never be reached, and returns the
  # refusal text.
  defp refuse(params) do
    test = self()

    Req.Test.stub(DoitMcp.Client, fn conn ->
      send(test, :api_called)
      Req.Test.json(conn, %{"preview" => false})
    end)

    assert {:reply, response, @frame} = ImportText.execute(params, @frame)
    refute_received :api_called

    protocol = Response.to_protocol(response)
    assert protocol["isError"] == true
    assert [%{"type" => "text", "text" => text}] = protocol["content"]
    {:error, text}
  end
end
