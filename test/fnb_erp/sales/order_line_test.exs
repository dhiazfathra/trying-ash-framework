defmodule FnbErp.Sales.OrderLineTest do
  use FnbErp.DataCase, async: true

  import FnbErp.Fixtures

  alias FnbErp.Catalog
  alias FnbErp.Sales

  defp message(error), do: Exception.message(error)

  setup do
    location = location()
    %{location: location, order: order(customer(), location)}
  end

  defp add(order, product, attrs \\ %{}) do
    Sales.add_order_line(
      Enum.into(attrs, %{order_id: order.id, product_id: product.id, quantity: 2})
    )
  end

  describe "sellability" do
    test "rejects a raw material", %{order: order} do
      product = product(%{category: :raw_material})

      assert {:error, error} = add(order, product)
      msg = message(error)
      assert msg =~ "is not sellable"
      assert msg =~ product.sku
      assert msg =~ "raw_material"
    end

    test "rejects an inactive product", %{order: order} do
      product = Catalog.deactivate_product!(product())

      assert {:error, error} = add(order, product)
      assert message(error) =~ "is not sellable"
      assert message(error) =~ "active false"
    end

    test "accepts an active finished good", %{order: order} do
      assert {:ok, _line} = add(order, product())
    end
  end

  describe "missing foreign keys" do
    test "a missing order_id reports only that it is required" do
      assert {:error, error} = Sales.add_order_line(%{product_id: product().id, quantity: 1})
      msg = message(error)

      assert msg =~ "order_id"
      assert msg =~ "is required"
      refute msg =~ "not found"
    end

    test "a missing product_id reports only that it is required", %{order: order} do
      assert {:error, error} = Sales.add_order_line(%{order_id: order.id, quantity: 1})
      msg = message(error)

      assert msg =~ "product_id"
      assert msg =~ "is required"
      refute msg =~ "not found"
    end
  end

  describe "quantity" do
    test "must be greater than zero", %{order: order} do
      product = product()

      for quantity <- [0, -1] do
        assert {:error, error} = add(order, product, %{quantity: quantity})
        assert message(error) =~ "must be greater than zero"
      end
    end

    test "is required", %{order: order} do
      assert {:error, error} = add(order, product(), %{quantity: nil})
      assert message(error) =~ "quantity"
    end
  end

  describe "pricing" do
    test "snapshots the product price when unit_price is omitted", %{order: order} do
      product = product(%{unit_price: Decimal.new("12500.00")})

      assert {:ok, line} = add(order, product)
      assert Decimal.equal?(line.unit_price, Decimal.new("12500.00"))
    end

    test "the snapshot survives a later product repricing", %{order: order} do
      product = product(%{unit_price: Decimal.new("10000.00")})
      {:ok, line} = add(order, product)

      Ash.update!(product, %{unit_price: Decimal.new("99000.00")})

      reloaded = Ash.reload!(line)
      assert Decimal.equal?(reloaded.unit_price, Decimal.new("10000.00"))
      assert Decimal.equal?(reloaded.subtotal, Decimal.new("20000.00"))
    end

    test "an explicit unit_price overrides the product price", %{order: order} do
      product = product(%{unit_price: Decimal.new("10000.00")})

      assert {:ok, line} = add(order, product, %{unit_price: Decimal.new("8000.00")})
      assert Decimal.equal?(line.unit_price, Decimal.new("8000.00"))
      assert Decimal.equal?(line.subtotal, Decimal.new("16000.00"))
    end

    test "rejects a negative unit_price", %{order: order} do
      assert {:error, error} = add(order, product(), %{unit_price: Decimal.new("-1.00")})
      assert message(error) =~ "must not be negative"
    end

    test "subtotal is quantity * unit_price, rounded to 2dp", %{order: order} do
      product = product(%{unit_price: Decimal.new("1999.99")})

      assert {:ok, line} = add(order, product, %{quantity: Decimal.new("2.500")})
      assert Decimal.equal?(line.subtotal, Decimal.new("4999.98"))
    end

    test "updating the quantity recomputes the subtotal", %{order: order} do
      product = product(%{unit_price: Decimal.new("1000.00")})
      {:ok, line} = add(order, product, %{quantity: 2})

      assert {:ok, updated} = Sales.update_order_line(line, %{quantity: 5})
      assert Decimal.equal?(updated.subtotal, Decimal.new("5000.00"))
      assert Decimal.equal?(updated.unit_price, Decimal.new("1000.00"))
    end

    test "updating the unit_price recomputes the subtotal", %{order: order} do
      {:ok, line} = add(order, product(), %{quantity: 3, unit_price: Decimal.new("100.00")})

      assert {:ok, updated} = Sales.update_order_line(line, %{unit_price: Decimal.new("200.00")})
      assert Decimal.equal?(updated.subtotal, Decimal.new("600.00"))
    end
  end

  describe "one line per product" do
    test "the same product cannot be added twice", %{order: order} do
      product = product()
      {:ok, _} = add(order, product)

      assert {:error, error} = add(order, product)
      assert message(error) =~ "has already been taken"
    end
  end

  describe "lines are frozen once the order leaves draft" do
    setup %{location: location} do
      product = stocked_product(location, 100)
      order = order(customer(), location)
      line = Sales.add_order_line!(%{order_id: order.id, product_id: product.id, quantity: 2})

      %{confirmed: Sales.confirm_order!(order), order_line: line, product: product}
    end

    test "cannot create a line", %{confirmed: confirmed} do
      other = product()

      assert {:error, error} =
               Sales.add_order_line(%{
                 order_id: confirmed.id,
                 product_id: other.id,
                 quantity: 1
               })

      assert message(error) =~ ~s(lines cannot be changed on a :confirmed order)
    end

    test "cannot update a line", %{order_line: line} do
      assert {:error, error} = Sales.update_order_line(line, %{quantity: 9})
      assert message(error) =~ ~s(lines cannot be changed on a :confirmed order)
    end

    test "cannot destroy a line", %{order_line: line} do
      assert {:error, error} = Sales.remove_order_line(line)
      assert message(error) =~ ~s(lines cannot be changed on a :confirmed order)
    end
  end

  describe "destroying a draft line" do
    test "removes the row", %{order: order} do
      {:ok, line} = add(order, product())

      assert :ok = Sales.remove_order_line(line)
      assert Enum.all?(Sales.list_order_lines!(), &(&1.id != line.id))
    end
  end
end
