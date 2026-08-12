defmodule FnbErp.WarehouseTest do
  use FnbErp.DataCase, async: true

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
  end

  describe "record_movement" do
    test "supports adjustments and returns", %{product: product, location: location} do
      {:ok, _} = Warehouse.receive_stock(product.id, location.id, 10)
      [inventory] = Warehouse.inventories_for_product!(product.id)

      assert {:ok, inventory} = Warehouse.record_movement(inventory, Decimal.new(-1), :adjustment)
      assert {:ok, inventory} = Warehouse.record_movement(inventory, Decimal.new(2), :return)
      assert Decimal.equal?(inventory.quantity_on_hand, Decimal.new(11))

      assert [:receipt, :adjustment, :return] ==
               Enum.map(movements(product, location), & &1.reason)
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
