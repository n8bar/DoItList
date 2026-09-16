defmodule DoItWeb.ChannelCase do
  @moduledoc """
  Test case for the browser client's channels (m04.01 item 1.5).

  Brings in `Phoenix.ChannelTest` against `DoItWeb.Endpoint` and the SQL
  sandbox, so a channel test can create real Initiatives and drive real
  context writes.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint DoItWeb.Endpoint

      import Phoenix.ChannelTest
      import DoItWeb.ChannelCase
    end
  end

  setup tags do
    DoIt.DataCase.setup_sandbox(tags)
    :ok
  end
end
