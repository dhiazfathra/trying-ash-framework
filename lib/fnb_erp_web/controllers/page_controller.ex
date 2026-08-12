defmodule FnbErpWeb.PageController do
  use FnbErpWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
