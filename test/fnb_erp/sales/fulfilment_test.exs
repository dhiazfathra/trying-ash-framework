defmodule FnbErp.Sales.FulfilmentTest do
  use FnbErp.DataCase, async: true

  import FnbErp.Fixtures

  alias FnbErp.Sales
  alias FnbErp.Warehouse

  defp message(error), do: Exception.message(error)

  defp two_line_order(on_hand_a, on_hand_b) do
    location = location()
    product_a = stocked_product(location, on_hand_a)
    product_b = stocked_product(location, on_hand_b)
    order = order(customer(), location)

    Sales.add_order_line!(%{order_id: order.id, product_id: product_a.id, quantity: 2})
    Sales.add_order_line!(%{order_id: order.id, product_id: product_b.id, quantity: 3})

    %{location: location, product_a: product_a, product_b: product_b, order: order}
  end

  test "deducts stock for every line and writes one ledger row per line" do
    %{location: location, product_a: a, product_b: b, order: order} = two_line_order(10, 10)

    fulfilled = order |> Sales.confirm_order!() |> Sales.fulfil_order!()

    assert fulfilled.status == :fulfilled
    assert Decimal.equal?(on_hand(a, location), Decimal.new(8))
    assert Decimal.equal?(on_hand(b, location), Decimal.new(7))

    for {product, quantity} <- [{a, -2}, {b, -3}] do
      assert [_receipt, sale] = movements(product, location)
      assert sale.reason == :sale
      assert sale.reference == fulfilled.order_number
      assert Decimal.equal?(sale.quantity, Decimal.new(quantity))
    end
  end

  test "rolls the whole fulfilment back when one line cannot be picked" do
    %{location: location, product_a: a, product_b: b, order: order} = two_line_order(10, 10)

    confirmed = Sales.confirm_order!(order)

    # Someone else empties product_b behind the order's back after confirmation.
    {:ok, _} = Warehouse.issue_stock(b.id, location.id, 10, "other order")

    assert {:error, error} = Sales.fulfil_order(confirmed)
    assert message(error) =~ "insufficient stock"

    assert Sales.get_order!(confirmed.id).status == :confirmed
    assert Decimal.equal?(on_hand(a, location), Decimal.new(10))
    assert Decimal.equal?(on_hand(b, location), Decimal.new(0))
    assert [_receipt_only] = movements(a, location)
  end

  test "fulfilment is refused when a line's product was never stocked at the location" do
    location = location()
    product = product()
    order = order(customer(), location)
    Sales.add_order_line!(%{order_id: order.id, product_id: product.id, quantity: 1})

    # Confirm against stock that exists, then move the whole balance away.
    {:ok, _} = Warehouse.receive_stock(product.id, location.id, 5)
    confirmed = Sales.confirm_order!(order)
    {:ok, _} = Warehouse.issue_stock(product.id, location.id, 5)

    assert {:error, error} = Sales.fulfil_order(confirmed)
    assert message(error) =~ "insufficient stock"
    assert Sales.get_order!(confirmed.id).status == :confirmed
  end
end
