defmodule FnbErp.Sales.Validations.StockAvailable do
  @moduledoc """
  Checks every line can be picked from the order's location before we let the
  order be confirmed. Stock is not reserved, so this is an early warning — the
  authoritative check happens again when stock is deducted on fulfil.
  """
  use Ash.Resource.Validation

  require Ash.Query

  @zero Decimal.new(0)

  @impl true
  def validate(changeset, _opts, _context) do
    order = Ash.load!(changeset.data, lines: [:product])
    on_hand = on_hand_by_product(order)

    order.lines
    |> Enum.reduce([], fn line, errors ->
      available = Map.get(on_hand, line.product_id, @zero)

      if Decimal.lt?(available, line.quantity) do
        ["#{line.product.sku}: #{available} available, #{line.quantity} ordered" | errors]
      else
        errors
      end
    end)
    |> case do
      [] ->
        :ok

      shortages ->
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :lines,
           message: "insufficient stock — %{shortages}",
           vars: [shortages: shortages |> Enum.reverse() |> Enum.join("; ")]
         )}
    end
  end

  # One read for the whole order rather than `Warehouse.available_quantity/2` per
  # line: this runs inside the confirm transaction, where 50 lines would mean 50
  # round trips. A product with no inventory row simply has no entry (zero).
  defp on_hand_by_product(%{lines: []}), do: %{}

  defp on_hand_by_product(order) do
    product_ids = Enum.map(order.lines, & &1.product_id)
    location_id = order.location_id

    FnbErp.Warehouse.Inventory
    |> Ash.Query.filter(product_id in ^product_ids and location_id == ^location_id)
    |> Ash.read!()
    |> Map.new(&{&1.product_id, &1.quantity_on_hand})
  end
end
