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

      define :record_movement,
        action: :record_movement,
        args: [:quantity, :reason, {:optional, :reference}]
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

  @doc "Adds stock at a location, creating the inventory row if this is the first receipt."
  @spec receive_stock(Ash.UUID.t(), Ash.UUID.t(), Decimal.t() | number(), String.t() | nil) ::
          {:ok, FnbErp.Warehouse.Inventory.t()} | {:error, term()}
  def receive_stock(product_id, location_id, quantity, reference \\ nil) do
    with {:ok, inventory} <- ensure_inventory(product_id, location_id) do
      record_movement(inventory, to_decimal(quantity), :receipt, reference)
    end
  end

  # The row is created empty and then filled by a movement, so the very first
  # receipt lands in the ledger like every later one.
  defp ensure_inventory(product_id, location_id) do
    case fetch_inventory(product_id, location_id) do
      {:ok, inventory} -> {:ok, inventory}
      :error -> create_inventory(%{product_id: product_id, location_id: location_id})
    end
  end

  @doc "Removes stock at a location. Fails if there is not enough on hand."
  @spec issue_stock(Ash.UUID.t(), Ash.UUID.t(), Decimal.t() | number(), String.t() | nil) ::
          {:ok, FnbErp.Warehouse.Inventory.t()} | {:error, term()}
  def issue_stock(product_id, location_id, quantity, reference \\ nil) do
    case fetch_inventory(product_id, location_id) do
      {:ok, inventory} ->
        record_movement(inventory, Decimal.negate(to_decimal(quantity)), :sale, reference)

      :error ->
        {:error,
         Ash.Error.Invalid.exception(
           errors: [
             Ash.Error.Changes.InvalidArgument.exception(
               field: :quantity,
               message: "no stock of this product at this location"
             )
           ]
         )}
    end
  end

  defp fetch_inventory(product_id, location_id) do
    FnbErp.Warehouse.Inventory
    |> Ash.Query.filter(product_id == ^product_id and location_id == ^location_id)
    |> Ash.read_one!()
    |> case do
      nil -> :error
      inventory -> {:ok, inventory}
    end
  end

  defp to_decimal(%Decimal{} = quantity), do: quantity
  defp to_decimal(quantity) when is_integer(quantity), do: Decimal.new(quantity)
  defp to_decimal(quantity) when is_float(quantity), do: Decimal.from_float(quantity)
  defp to_decimal(quantity) when is_binary(quantity), do: Decimal.new(quantity)
end
