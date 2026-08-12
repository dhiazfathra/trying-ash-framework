defmodule FnbErp.Sales.OrderLifecycleTest do
  use FnbErp.DataCase, async: true

  import FnbErp.Fixtures

  alias FnbErp.Sales

  defp message(error), do: Exception.message(error)

  describe "order_number" do
    test "is generated in SO-YYYYMM-NNNN form for the order date" do
      order = order(customer(), location(), %{order_date: ~D[2026-03-09]})
      assert order.order_number =~ ~r/^SO-202603-\d{4}$/
    end

    test "is unique across two orders" do
      customer = customer()
      location = location()

      first = order(customer, location)
      second = order(customer, location)

      assert first.order_number != second.order_number
      assert first.order_number =~ ~r/^SO-\d{6}-\d{4}$/
      assert second.order_number =~ ~r/^SO-\d{6}-\d{4}$/
    end
  end

  describe "creation" do
    test "starts as a draft with today's date and the default tax rate" do
      order = order(customer(), location())

      assert order.status == :draft
      assert order.order_date == Date.utc_today()
      assert Decimal.equal?(order.tax_rate, Decimal.new("0.11"))
    end

    test "requires a customer and a location" do
      assert {:error, error} = Sales.create_order(%{})
      assert message(error) =~ "customer"
      assert message(error) =~ "location"
    end

    test "rejects a tax_rate outside 0..1" do
      customer = customer()
      location = location()

      for rate <- ["1.5", "-0.1"] do
        assert {:error, error} =
                 Sales.create_order(%{
                   customer_id: customer.id,
                   location_id: location.id,
                   tax_rate: Decimal.new(rate)
                 })

        assert message(error) =~ "must be a rate between 0 and 1"
      end
    end
  end

  describe "happy path" do
    test "draft -> confirmed -> fulfilled -> paid" do
      %{order: order, product: product, location: location} =
        order_with_line(quantity: 3, on_hand: 10)

      assert {:ok, confirmed} = Sales.confirm_order(order)
      assert confirmed.status == :confirmed
      assert confirmed.confirmed_at

      assert {:ok, fulfilled} = Sales.fulfil_order(confirmed)
      assert fulfilled.status == :fulfilled
      assert fulfilled.fulfilled_at
      assert Decimal.equal?(on_hand(product, location), Decimal.new(7))

      assert {:ok, paid} = Sales.mark_order_paid(fulfilled)
      assert paid.status == :paid
      assert paid.paid_at
    end

    test "by_status finds the order at each step" do
      %{order: order} = order_with_line()

      assert order.id in Enum.map(Sales.orders_by_status!(:draft), & &1.id)

      confirmed = Sales.confirm_order!(order)
      assert confirmed.id in Enum.map(Sales.orders_by_status!(:confirmed), & &1.id)
      refute confirmed.id in Enum.map(Sales.orders_by_status!(:draft), & &1.id)
    end
  end

  describe "confirm" do
    test "is rejected when the order has no lines" do
      order = order(customer(), location())

      assert {:error, error} = Sales.confirm_order(order)
      assert message(error) =~ "an order needs at least one line before it can be confirmed"
      assert Sales.get_order!(order.id).status == :draft
    end

    test "is rejected when stock is short, naming the sku" do
      %{order: order, product: product} = order_with_line(quantity: 10, on_hand: 4)

      assert {:error, error} = Sales.confirm_order(order)
      msg = message(error)

      assert msg =~ "insufficient stock"
      assert msg =~ product.sku
      assert msg =~ "ordered"
      assert Sales.get_order!(order.id).status == :draft
    end

    test "is rejected when the product has no stock at the order's location" do
      location = location()
      product = product()
      order = order(customer(), location)
      Sales.add_order_line!(%{order_id: order.id, product_id: product.id, quantity: 1})

      assert {:error, error} = Sales.confirm_order(order)
      assert message(error) =~ product.sku
    end

    test "is rejected on an already confirmed order" do
      %{order: order} = order_with_line()
      confirmed = Sales.confirm_order!(order)

      assert {:error, error} = Sales.confirm_order(confirmed)
      assert message(error) =~ ~s(cannot be done on a :confirmed order)
    end
  end

  describe "wrong-status transitions" do
    test "fulfil is rejected on a draft" do
      %{order: order} = order_with_line()

      assert {:error, error} = Sales.fulfil_order(order)
      assert message(error) =~ ~s(cannot be done on a :draft order, only on: "confirmed")
    end

    test "mark_paid is rejected on a confirmed order" do
      %{order: order} = order_with_line()
      confirmed = Sales.confirm_order!(order)

      assert {:error, error} = Sales.mark_order_paid(confirmed)
      assert message(error) =~ ~s(cannot be done on a :confirmed order, only on: "fulfilled")
    end

    test "mark_paid is rejected on a draft" do
      %{order: order} = order_with_line()

      assert {:error, error} = Sales.mark_order_paid(order)
      assert message(error) =~ ~s(cannot be done on a :draft order)
    end

    test "cancel is rejected on a fulfilled order" do
      %{order: order} = order_with_line()
      fulfilled = order |> Sales.confirm_order!() |> Sales.fulfil_order!()

      assert {:error, error} = Sales.cancel_order(fulfilled)

      assert message(error) =~
               ~s(cannot be done on a :fulfilled order, only on: "draft, confirmed")
    end

    test "cancel is rejected on a paid order" do
      %{order: order} = order_with_line()

      paid =
        order |> Sales.confirm_order!() |> Sales.fulfil_order!() |> Sales.mark_order_paid!()

      assert {:error, error} = Sales.cancel_order(paid)
      assert message(error) =~ ~s(cannot be done on a :paid order)
    end

    test "update is rejected once the order leaves draft" do
      %{order: order} = order_with_line()
      confirmed = Sales.confirm_order!(order)

      assert {:error, error} = Ash.update(confirmed, %{notes: "late note"})
      assert message(error) =~ ~s(cannot be done on a :confirmed order)
    end
  end

  describe "cancel" do
    test "is allowed from draft, with a reason" do
      order = order(customer(), location())

      assert {:ok, cancelled} =
               Sales.cancel_order(order, %{cancellation_reason: "customer called"})

      assert cancelled.status == :cancelled
      assert cancelled.cancellation_reason == "customer called"
      assert cancelled.cancelled_at
    end

    test "is allowed from confirmed and does not move stock" do
      %{order: order, product: product, location: location} = order_with_line(on_hand: 10)
      confirmed = Sales.confirm_order!(order)

      assert {:ok, cancelled} = Sales.cancel_order(confirmed)
      assert cancelled.status == :cancelled
      assert Decimal.equal?(on_hand(product, location), Decimal.new(10))
    end
  end
end
