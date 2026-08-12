defmodule FnbErp.Sales.FulfilmentConcurrencyTest do
  @moduledoc """
  Real two-connection race against `:fulfil`. This deliberately does not use
  `FnbErp.DataCase`: the sandbox hands every process one shared connection, which
  serialises the two tasks and would pass even without the row lock.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import FnbErp.Fixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias FnbErp.Sales

  setup do
    Sandbox.mode(FnbErp.Repo, :auto)
    on_exit(fn -> Sandbox.mode(FnbErp.Repo, :manual) end)
    :ok
  end

  test "two concurrent fulfils deduct stock once and write one ledger row per line" do
    %{order: order, product: product, location: location} =
      order_with_line(quantity: 2, on_hand: 10)

    # `:auto` escapes the sandbox, so nothing rolls these rows back for us.
    on_exit(fn -> delete_everything(order, product, location) end)

    confirmed = Sales.confirm_order!(order)

    results =
      [confirmed, confirmed]
      |> Enum.map(fn order -> Task.async(fn -> Sales.fulfil_order(order) end) end)
      |> Task.await_many(15_000)

    assert Enum.count(results, &match?({:ok, %{status: :fulfilled}}, &1)) == 1
    assert [{:error, error}] = Enum.filter(results, &match?({:error, _}, &1))
    assert Exception.message(error) =~ "cannot be done on a :fulfilled order"

    assert Decimal.equal?(on_hand(product, location), Decimal.new(8))
    assert [_receipt, sale] = movements(product, location)
    assert sale.reason == :sale
    assert Decimal.equal?(sale.quantity, Decimal.new(-2))
  end

  defp delete_everything(order, product, location) do
    inventories = from(i in FnbErp.Warehouse.Inventory, where: i.location_id == ^location.id)

    FnbErp.Repo.delete_all(
      from(m in FnbErp.Warehouse.StockMovement,
        where: m.inventory_id in subquery(select(inventories, [i], i.id))
      )
    )

    FnbErp.Repo.delete_all(from(l in FnbErp.Sales.OrderLine, where: l.order_id == ^order.id))
    FnbErp.Repo.delete_all(inventories)
    FnbErp.Repo.delete_all(from(o in FnbErp.Sales.Order, where: o.id == ^order.id))
    FnbErp.Repo.delete_all(from(p in FnbErp.Catalog.Product, where: p.id == ^product.id))

    FnbErp.Repo.delete_all(from(c in FnbErp.Catalog.Customer, where: c.id == ^order.customer_id))

    FnbErp.Repo.delete_all(from(l in FnbErp.Warehouse.Location, where: l.id == ^location.id))
  end
end
