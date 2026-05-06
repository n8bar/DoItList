defmodule DoItWeb.PageController do
  use DoItWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
