defmodule FnbErp.Sales.OrderTotalsTest do
  use FnbErp.DataCase, async: true

  import FnbErp.Fixtures

  alias FnbErp.Sales

  defp totals(order), do: Ash.load!(order, [:subtotal, :tax_amount, :total, :line_count])

  setup do
    location = location()
    %{location: location, order: order(customer(), location)}
  end

  test "an order with no lines has a zero subtotal and total", %{order: order} do
    order = totals(order)

    assert order.line_count == 0
    assert Decimal.equal?(order.subtotal, Decimal.new(0))
    assert Decimal.equal?(order.tax_amount, Decimal.new(0))
    assert Decimal.equal?(order.total, Decimal.new(0))
  end

  test "subtotal sums every line subtotal", %{order: order} do
    Sales.add_order_line!(%{
      order_id: order.id,
      product_id: product(%{unit_price: Decimal.new("10000.00")}).id,
      quantity: 2
    })

    Sales.add_order_line!(%{
      order_id: order.id,
      product_id: product(%{unit_price: Decimal.new("5000.00")}).id,
      quantity: 3
    })

    order = totals(order)

    assert order.line_count == 2
    assert Decimal.equal?(order.subtotal, Decimal.new("35000.00"))
  end

  test "tax_amount is subtotal * the default 0.11 rate and total is the sum", %{order: order} do
    Sales.add_order_line!(%{
      order_id: order.id,
      product_id: product(%{unit_price: Decimal.new("100000.00")}).id,
      quantity: 1
    })

    order = totals(order)

    assert Decimal.equal?(order.tax_rate, Decimal.new("0.11"))
    assert Decimal.equal?(order.tax_amount, Decimal.new("11000.00"))
    assert Decimal.equal?(order.total, Decimal.new("111000.00"))
    assert Decimal.equal?(order.total, Decimal.add(order.subtotal, order.tax_amount))
  end

  test "a custom tax_rate is honoured", %{location: location} do
    order =
      order(customer(), location, %{tax_rate: Decimal.new("0.05")})

    Sales.add_order_line!(%{
      order_id: order.id,
      product_id: product(%{unit_price: Decimal.new("100000.00")}).id,
      quantity: 1
    })

    order = totals(order)

    assert Decimal.equal?(order.tax_amount, Decimal.new("5000.00"))
    assert Decimal.equal?(order.total, Decimal.new("105000.00"))
  end

  test "a zero tax_rate means total equals subtotal", %{location: location} do
    order = order(customer(), location, %{tax_rate: Decimal.new(0)})

    Sales.add_order_line!(%{
      order_id: order.id,
      product_id: product(%{unit_price: Decimal.new("7500.00")}).id,
      quantity: 2
    })

    order = totals(order)

    assert Decimal.equal?(order.tax_amount, Decimal.new(0))
    assert Decimal.equal?(order.total, order.subtotal)
  end

  test "totals follow a line update and a line removal", %{order: order} do
    line =
      Sales.add_order_line!(%{
        order_id: order.id,
        product_id: product(%{unit_price: Decimal.new("1000.00")}).id,
        quantity: 1
      })

    assert Decimal.equal?(totals(order).subtotal, Decimal.new("1000.00"))

    line = Sales.update_order_line!(line, %{quantity: 4})
    assert Decimal.equal?(totals(order).subtotal, Decimal.new("4000.00"))

    :ok = Sales.remove_order_line(line)
    assert Decimal.equal?(totals(order).subtotal, Decimal.new(0))
  end
end
