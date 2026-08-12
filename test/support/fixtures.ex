defmodule FnbErp.Fixtures do
  @moduledoc "Minimal fixtures for the domain tests: customers, locations, products, stock, orders."

  alias FnbErp.Catalog
  alias FnbErp.Sales
  alias FnbErp.Warehouse

  def uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  def customer(attrs \\ %{}) do
    Catalog.create_customer!(Enum.into(attrs, %{name: uniq("Cafe")}))
  end

  def location(attrs \\ %{}) do
    Warehouse.create_location!(
      Enum.into(attrs, %{name: uniq("Warehouse"), code: uniq("WH")})
    )
  end

  def product(attrs \\ %{}) do
    Catalog.create_product!(
      Enum.into(attrs, %{name: uniq("Cold Brew"), sku: uniq("SKU"), unit_price: Decimal.new("25000.00")})
    )
  end

  @doc "A product with `quantity` on hand at `location`."
  def stocked_product(location, quantity, attrs \\ %{}) do
    product = product(attrs)
    {:ok, _} = Warehouse.receive_stock(product.id, location.id, quantity)
    product
  end

  def order(customer, location, attrs \\ %{}) do
    Sales.create_order!(
      Enum.into(attrs, %{customer_id: customer.id, location_id: location.id})
    )
  end

  @doc "A draft order with one line for `quantity` of a product stocked with `on_hand`."
  def order_with_line(opts \\ []) do
    quantity = Keyword.get(opts, :quantity, 2)
    on_hand = Keyword.get(opts, :on_hand, 100)

    location = location()
    product = stocked_product(location, on_hand)
    order = order(customer(), location, Keyword.get(opts, :order_attrs, %{}))
    line = Sales.add_order_line!(%{order_id: order.id, product_id: product.id, quantity: quantity})

    %{location: location, product: product, order: order, line: line}
  end

  def on_hand(product, location), do: Warehouse.available_quantity(product.id, location.id)

  def movements(inventory_owner_product, location) do
    import Ash.Query

    inventory =
      FnbErp.Warehouse.Inventory
      |> Ash.Query.filter(
        product_id == ^inventory_owner_product.id and location_id == ^location.id
      )
      |> Ash.read_one!()

    FnbErp.Warehouse.StockMovement
    |> Ash.Query.filter(inventory_id == ^inventory.id)
    |> Ash.Query.sort(occurred_at: :asc)
    |> Ash.read!()
  end
end
