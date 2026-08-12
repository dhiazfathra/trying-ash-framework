defmodule FnbErp.Sales.Changes.DeductStock do
  @moduledoc """
  Issues stock for every line from the order's location when the order is fulfilled.

  Runs inside the update's transaction, so a line that cannot be picked rolls the
  whole fulfilment back — an order is never half-shipped.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, order ->
      order = Ash.load!(order, :lines)

      Enum.reduce_while(order.lines, {:ok, order}, fn line, acc ->
        case FnbErp.Warehouse.issue_stock(
               line.product_id,
               order.location_id,
               line.quantity,
               order.order_number
             ) do
          {:ok, _inventory} -> {:cont, acc}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end)
  end
end
