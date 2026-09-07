defmodule DoitMcp.Tools.DescriptionsTest do
  @moduledoc """
  m03.04 3.6 — the published descriptions of every tool that shapes a client
  reply carry one short clause pointing at the fields to answer with. The full
  rule is stated once, in the server's `initialize` instructions, so it is
  never restated per tool. The pre-3.6 copy — "never provide only its raw ID",
  addressed to "the operator" — is gone from the whole surface, tools and
  their resource mirrors alike.
  """

  use ExUnit.Case, async: true

  # Whitespace collapsed so assertions survive the moduledocs' line wraps.
  defp published(type) do
    DoitMcp.Server.__components__(type)
    |> Map.new(&{&1.name, String.replace(&1.description, ~r/\s+/, " ")})
  end

  # Every tool whose reply names a Task or an Initiative back to the user.
  @shaping ~w(
    get_initiative_tree list_initiatives get_task_comments get_initiative_activity
    import_text create_task update_task complete_task move_task delete_task
    apply_operations
  )

  test "no published description carries the pre-3.6 raw-ID or operator copy" do
    for type <- [:tool, :resource], {name, description} <- published(type) do
      refute description =~ ~r/raw id/i, ~s(#{name} still says "raw ID")
      refute description =~ ~r/operator/i, ~s(#{name} still addresses "the operator")
    end
  end

  test "every response-shaping tool points at the reply fields" do
    descriptions = published(:tool)

    for name <- @shaping do
      assert Map.fetch!(descriptions, name) =~ "Reply with",
             "#{name} doesn't tell the client what to answer with"
    end
  end

  test "each clause names the fields that tool's reply actually carries" do
    descriptions = published(:tool)

    assert descriptions["get_initiative_tree"] =~
             "Reply with `index` and `title`, and the Initiative `url`."

    assert descriptions["list_initiatives"] =~ "Reply with the Initiative `url`, never its id."

    assert descriptions["import_text"] =~
             "Reply with the outline's labels and titles, and the Initiative `url`."

    for name <- ~w(get_task_comments get_initiative_activity create_task update_task
                   complete_task move_task delete_task apply_operations) do
      assert descriptions[name] =~ "Reply with `index` and `title`, never ids.",
             "#{name} doesn't carry the shared reply clause"
    end
  end

  test "the clause is stated once per tool — the instructions carry the rule" do
    for {name, description} <- published(:tool) do
      occurrences = description |> String.split("Reply with") |> length() |> Kernel.-(1)
      assert occurrences <= 1, "#{name} restates the reply rule #{occurrences} times"
    end
  end

  test "identity reads shape nothing and stay clause-free" do
    descriptions = published(:tool)

    for name <- ~w(get_me get_initiative_members) do
      refute descriptions[name] =~ "Reply with"
    end
  end
end
