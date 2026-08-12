defmodule FnbErp.Warehouse do
  @moduledoc """
  Stock: where it is, how much there is, and every movement that changed it.
  """
  use Ash.Domain, otp_app: :fnb_erp, extensions: [AshJsonApi.Domain]

  require Ash.Query

  resources do
    resource FnbErp.Warehouse.Location do
      define :create_location, action: :create
      define :list_locations, action: :read
      define :get_location, action: :read, get_by: [:id]
    end

    resource FnbErp.Warehouse.Inventory do
      define :create_inventory, action: :create
      define :list_inventories, action: :read
      define :inventories_for_product, action: :for_product, args: [:product_id]

      # Deliberately not `define`d: `:record_movement` is a raw read-modify-write
      # (see Changes.ApplyStockDelta) that must always run under the `FOR UPDATE`
      # lock taken in `apply_movement/5` below. A code-interface function here
      # would let a caller reach the action without the lock. Use
      # `Warehouse.record_movement/5`, `receive_stock/4`, or `issue_stock/4`.
    end

    resource FnbErp.Warehouse.StockMovement do
      define :list_stock_movements, action: :read
    end
  end

  @doc """
  Stock on hand for a product at a location. Returns zero when no inventory row
  exists — "we have never stocked it here" and "we have none left" are the same
  answer to the only question callers ask.
  """
  @spec available_quantity(Ash.UUID.t(), Ash.UUID.t()) :: Decimal.t()
  def available_quantity(product_id, location_id) do
    case fetch_inventory(product_id, location_id) do
      {:ok, inventory} -> inventory.quantity_on_hand
      :error -> Decimal.new(0)
    end
  end

  @doc """
  Adds stock at a location, creating the inventory row if this is the first receipt.

  `quantity` is the magnitude of the receipt and must be positive — the sign is
  the caller's *intent*, and a negative receipt would write a `:receipt` ledger
  row that removes stock.
  """
  @spec receive_stock(Ash.UUID.t(), Ash.UUID.t(), Decimal.t() | number(), String.t() | nil) ::
          {:ok, FnbErp.Warehouse.Inventory.t()} | {:error, term()}
  def receive_stock(product_id, location_id, quantity, reference \\ nil) do
    with {:ok, quantity} <- positive_quantity(quantity),
         {:ok, _inventory} <- ensure_inventory(product_id, location_id) do
      apply_movement(product_id, location_id, quantity, :receipt, reference)
    end
  end

  # The row is created empty and then filled by a movement, so the very first
  # receipt lands in the ledger like every later one. Idempotent: the upsert
  # leaves an existing row's balance alone (see Inventory's `:create`).
  defp ensure_inventory(product_id, location_id) do
    create_inventory(%{product_id: product_id, location_id: location_id})
  end

  @doc """
  Removes stock at a location. Fails if there is not enough on hand.

  `quantity` is the magnitude of the issue and must be positive; see
  `receive_stock/4`.
  """
  @spec issue_stock(Ash.UUID.t(), Ash.UUID.t(), Decimal.t() | number(), String.t() | nil) ::
          {:ok, FnbErp.Warehouse.Inventory.t()} | {:error, term()}
  def issue_stock(product_id, location_id, quantity, reference \\ nil) do
    with {:ok, quantity} <- positive_quantity(quantity) do
      apply_movement(product_id, location_id, Decimal.negate(quantity), :sale, reference)
    end
  end

  @doc """
  Writes a signed quantity delta to the ledger and updates the balance, under
  the same row lock as `receive_stock/4` and `issue_stock/4`.

  Public for movement reasons (e.g. `:adjustment`, `:return`) that aren't a
  plain receipt or sale; those two helpers cover the common signed-quantity
  cases and should be preferred when they fit.
  """
  @spec record_movement(
          Ash.UUID.t(),
          Ash.UUID.t(),
          Decimal.t() | number(),
          atom(),
          String.t() | nil
        ) :: {:ok, FnbErp.Warehouse.Inventory.t()} | {:error, term()}
  def record_movement(product_id, location_id, quantity, reason, reference \\ nil) do
    apply_movement(product_id, location_id, to_decimal(quantity), reason, reference)
  end

  # The balance is a read-modify-write (see Changes.ApplyStockDelta), so the read
  # has to hold the inventory row until the ledger row is committed. Without the
  # lock two movements can read the same balance and one delta is silently lost,
  # leaving `quantity_on_hand` disagreeing with the sum of the ledger.
  defp apply_movement(product_id, location_id, delta, reason, reference) do
    result =
      Ash.transaction(FnbErp.Warehouse.Inventory, fn ->
        with {:ok, inventory} <- lock_inventory(product_id, location_id) do
          Ash.update(
            inventory,
            %{quantity: delta, reason: reason, reference: reference},
            action: :record_movement
          )
        end
      end)

    case result do
      {:ok, inner} -> inner
      {:error, error} -> {:error, error}
    end
  end

  defp lock_inventory(product_id, location_id) do
    inventory_query(product_id, location_id)
    |> Ash.Query.lock("FOR UPDATE")
    |> Ash.read_one!()
    |> case do
      nil -> {:error, invalid_quantity("no stock of this product at this location")}
      inventory -> {:ok, inventory}
    end
  end

  defp fetch_inventory(product_id, location_id) do
    inventory_query(product_id, location_id)
    |> Ash.read_one!()
    |> case do
      nil -> :error
      inventory -> {:ok, inventory}
    end
  end

  defp inventory_query(product_id, location_id) do
    Ash.Query.filter(
      FnbErp.Warehouse.Inventory,
      product_id == ^product_id and location_id == ^location_id
    )
  end

  defp positive_quantity(quantity) do
    quantity = to_decimal(quantity)

    if Decimal.positive?(quantity) do
      {:ok, quantity}
    else
      {:error, invalid_quantity("quantity must be greater than zero")}
    end
  end

  defp invalid_quantity(message) do
    Ash.Error.Invalid.exception(
      errors: [
        Ash.Error.Changes.InvalidArgument.exception(field: :quantity, message: message)
      ]
    )
  end

  defp to_decimal(%Decimal{} = quantity), do: quantity
  defp to_decimal(quantity) when is_integer(quantity), do: Decimal.new(quantity)
  defp to_decimal(quantity) when is_float(quantity), do: Decimal.from_float(quantity)
  defp to_decimal(quantity) when is_binary(quantity), do: Decimal.new(quantity)
end
