defmodule FnbErp.WarehouseTest do
  # async: false — the concurrency test below steps outside the SQL sandbox, which
  # only one test may do at a time.
  use FnbErp.DataCase, async: false

  import FnbErp.Fixtures

  alias FnbErp.Warehouse

  defp message(error), do: Exception.message(error)

  setup do
    location = location()
    %{location: location, product: product()}
  end

  describe "available_quantity/2" do
    test "is zero when no inventory row exists", %{product: product, location: location} do
      assert Decimal.equal?(Warehouse.available_quantity(product.id, location.id), Decimal.new(0))
    end

    test "reflects the materialised balance", %{product: product, location: location} do
      {:ok, _} = Warehouse.receive_stock(product.id, location.id, 7)
      assert Decimal.equal?(Warehouse.available_quantity(product.id, location.id), Decimal.new(7))
    end

    test "is scoped per location", %{product: product, location: location} do
      other = location()
      {:ok, _} = Warehouse.receive_stock(product.id, location.id, 7)

      assert Decimal.equal?(Warehouse.available_quantity(product.id, other.id), Decimal.new(0))
    end
  end

  describe "receive_stock/4" do
    test "creates the inventory row and a :receipt ledger row on first receipt", %{
      product: product,
      location: location
    } do
      assert {:ok, inventory} = Warehouse.receive_stock(product.id, location.id, 10, "GRN-1")

      assert Decimal.equal?(inventory.quantity_on_hand, Decimal.new(10))
      assert [movement] = movements(product, location)
      assert movement.reason == :receipt
      assert movement.reference == "GRN-1"
      assert Decimal.equal?(movement.quantity, Decimal.new(10))
    end

    test "repeated receipts accumulate and append to the ledger", %{
      product: product,
      location: location
    } do
      {:ok, _} = Warehouse.receive_stock(product.id, location.id, 10)
      {:ok, inventory} = Warehouse.receive_stock(product.id, location.id, "5.500")

      assert Decimal.equal?(inventory.quantity_on_hand, Decimal.new("15.5"))
      assert [first, second] = movements(product, location)
      assert Decimal.equal?(first.quantity, Decimal.new(10))
      assert Decimal.equal?(second.quantity, Decimal.new("5.5"))
      assert Enum.all?([first, second], &(&1.reason == :receipt))
    end

    test "accepts float and Decimal quantities", %{product: product, location: location} do
      {:ok, _} = Warehouse.receive_stock(product.id, location.id, 1.5)
      {:ok, inventory} = Warehouse.receive_stock(product.id, location.id, Decimal.new("2.5"))

      assert Decimal.equal?(inventory.quantity_on_hand, Decimal.new(4))
    end

    # A negative receipt would write a `:receipt` ledger row that removes stock —
    # a lie in an append-only ledger.
    test "rejects zero and negative quantities", %{product: product, location: location} do
      for quantity <- [0, -5, Decimal.new("-0.001")] do
        assert {:error, error} = Warehouse.receive_stock(product.id, location.id, quantity)
        assert message(error) =~ "quantity must be greater than zero"
      end

      # Nothing was created at all: the sign is checked before the inventory row.
      assert Decimal.equal?(Warehouse.available_quantity(product.id, location.id), Decimal.new(0))
      assert Warehouse.list_inventories!() == []
    end
  end

  describe "issue_stock/4" do
    test "decrements the balance and writes a negative :sale row", %{
      product: product,
      location: location
    } do
      {:ok, _} = Warehouse.receive_stock(product.id, location.id, 10)

      assert {:ok, inventory} = Warehouse.issue_stock(product.id, location.id, 4, "SO-1")

      assert Decimal.equal?(inventory.quantity_on_hand, Decimal.new(6))
      assert [_receipt, sale] = movements(product, location)
      assert sale.reason == :sale
      assert sale.reference == "SO-1"
      assert Decimal.equal?(sale.quantity, Decimal.new(-4))
    end

    test "issuing everything on hand is allowed", %{product: product, location: location} do
      {:ok, _} = Warehouse.receive_stock(product.id, location.id, 10)

      assert {:ok, inventory} = Warehouse.issue_stock(product.id, location.id, 10)
      assert Decimal.equal?(inventory.quantity_on_hand, Decimal.new(0))
    end

    test "fails when more is requested than is on hand", %{product: product, location: location} do
      {:ok, _} = Warehouse.receive_stock(product.id, location.id, 3)

      assert {:error, error} = Warehouse.issue_stock(product.id, location.id, 4)
      assert message(error) =~ "insufficient stock"

      assert Decimal.equal?(Warehouse.available_quantity(product.id, location.id), Decimal.new(3))
      assert [_receipt_only] = movements(product, location)
    end

    test "fails when the product has never been stocked at that location", %{
      product: product,
      location: location
    } do
      assert {:error, error} = Warehouse.issue_stock(product.id, location.id, 1)
      assert message(error) =~ "no stock of this product at this location"
    end

    # A negative issue would negate to a positive `:sale` that *adds* stock.
    test "rejects zero and negative quantities", %{product: product, location: location} do
      {:ok, _} = Warehouse.receive_stock(product.id, location.id, 10)

      for quantity <- [0, -5, Decimal.new("-0.001")] do
        assert {:error, error} = Warehouse.issue_stock(product.id, location.id, quantity)
        assert message(error) =~ "quantity must be greater than zero"
      end

      assert Decimal.equal?(
               Warehouse.available_quantity(product.id, location.id),
               Decimal.new(10)
             )

      assert [_receipt_only] = movements(product, location)
    end
  end

  describe "record_movement" do
    test "supports adjustments and returns", %{product: product, location: location} do
      {:ok, _} = Warehouse.receive_stock(product.id, location.id, 10)

      assert {:ok, _} =
               Warehouse.record_movement(product.id, location.id, Decimal.new(-1), :adjustment)

      assert {:ok, inventory} =
               Warehouse.record_movement(product.id, location.id, Decimal.new(2), :return)

      assert Decimal.equal?(inventory.quantity_on_hand, Decimal.new(11))

      assert [:receipt, :adjustment, :return] ==
               Enum.map(movements(product, location), & &1.reason)
    end
  end

  describe "concurrent movements" do
    # The sandbox lends every process one connection, so sandboxed "concurrency"
    # is serialised by the connection rather than by the row lock and would pass
    # even without it. This test therefore talks to the real database in `:auto`
    # mode and deletes what it created.
    test "are serialised, so the ledger always matches the balance" do
      Ecto.Adapters.SQL.Sandbox.mode(FnbErp.Repo, :auto)
      location = location()
      product = product()

      on_exit(fn ->
        purge(product.id, location.id)
        Ecto.Adapters.SQL.Sandbox.mode(FnbErp.Repo, :manual)
      end)

      {:ok, _} = Warehouse.receive_stock(product.id, location.id, 10)
      supervisor = start_supervised!(Task.Supervisor)

      # Both issues read a balance of 10 and both are individually valid; only one
      # can win, and the loser must not corrupt the balance.
      results =
        [7, 7]
        |> Enum.map(
          &Task.Supervisor.async_nolink(supervisor, fn ->
            Warehouse.issue_stock(product.id, location.id, &1, "concurrent")
          end)
        )
        |> Task.await_many(:timer.seconds(10))

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert [{:error, error}] = Enum.filter(results, &match?({:error, _}, &1))
      assert message(error) =~ "insufficient stock"

      on_hand = Warehouse.available_quantity(product.id, location.id)
      assert Decimal.equal?(on_hand, Decimal.new(3))
      assert Decimal.equal?(ledger_sum(product, location), on_hand)
    end

    defp ledger_sum(product, location) do
      movements(product, location)
      |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1.quantity))
    end

    defp purge(product_id, location_id) do
      sql!(
        "delete from stock_movements where inventory_id in (select id from inventories where product_id = $1)",
        [product_id]
      )

      sql!("delete from inventories where product_id = $1", [product_id])
      sql!("delete from products where id = $1", [product_id])
      sql!("delete from locations where id = $1", [location_id])
    end

    defp sql!(statement, uuids) do
      Ecto.Adapters.SQL.query!(FnbErp.Repo, statement, Enum.map(uuids, &Ecto.UUID.dump!/1))
    end
  end

  describe "inventories_for_product/1" do
    test "returns one row per location", %{product: product, location: location} do
      other = location()
      {:ok, _} = Warehouse.receive_stock(product.id, location.id, 1)
      {:ok, _} = Warehouse.receive_stock(product.id, other.id, 2)

      assert length(Warehouse.inventories_for_product!(product.id)) == 2
    end
  end
end
