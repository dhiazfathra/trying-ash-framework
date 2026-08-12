defmodule FnbErpWeb.JsonApiTest do
  use FnbErpWeb.ConnCase, async: true

  import FnbErp.Fixtures

  @content_type "application/vnd.api+json"

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", @content_type)}
  end

  describe "GET /api/json/products" do
    test "returns a JSON:API document listing products", %{conn: conn} do
      product = product()

      conn = get(conn, "/api/json/products")

      assert conn.status == 200
      assert response_content_type(conn, :json) =~ @content_type

      assert %{"data" => data} = Jason.decode!(conn.resp_body)
      assert Enum.any?(data, &(&1["type"] == "product" and &1["id"] == product.id))
    end
  end

  describe "GET /api/json/orders" do
    test "returns a JSON:API document listing orders", %{conn: conn} do
      %{order: order} = order_with_line()

      conn = get(conn, "/api/json/orders")

      assert conn.status == 200
      assert response_content_type(conn, :json) =~ @content_type

      assert %{"data" => data} = Jason.decode!(conn.resp_body)
      assert entry = Enum.find(data, &(&1["id"] == order.id))
      assert entry["type"] == "order"
      assert entry["attributes"]["order_number"] == order.order_number
    end
  end

  describe "POST /api/json/customers" do
    test "creates a customer", %{conn: conn} do
      name = uniq("Api Cafe")

      conn =
        conn
        |> put_req_header("content-type", @content_type)
        |> post("/api/json/customers", %{
          "data" => %{"type" => "customer", "attributes" => %{"name" => name}}
        })

      assert conn.status == 201

      assert %{"data" => %{"id" => id, "attributes" => attributes}} =
               Jason.decode!(conn.resp_body)

      assert attributes["name"] == name
      assert {:ok, _} = FnbErp.Catalog.get_customer(id)
    end

    test "rejects an invalid email with a 4xx and an errors document", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", @content_type)
        |> post("/api/json/customers", %{
          "data" => %{
            "type" => "customer",
            "attributes" => %{"name" => uniq("Bad"), "email" => "nope"}
          }
        })

      assert conn.status >= 400 and conn.status < 500
      assert %{"errors" => [_ | _]} = Jason.decode!(conn.resp_body)
    end
  end
end
