defmodule DoItWeb.ClientHTML do
  @moduledoc """
  The bootstrap document for the React client (see `DoItWeb.ClientController`).

  A single template, `client_html/index.html.heex`. It renders the whole
  document itself — no root layout, no `<Layouts.app>` chrome — because the
  client paints the frame.
  """
  use DoItWeb, :html

  embed_templates "client_html/*"
end
