defmodule FnbErp.Warehouse.Validations.SufficientStock do
  @moduledoc """
  Rejects a stock movement that would drive an inventory balance below zero.

  The balance it reads is authoritative because the caller holds a
  `SELECT … FOR UPDATE` lock on the row (see `FnbErp.Warehouse.apply_movement/5`);
  the `quantity_on_hand >= 0` check constraint remains as a backstop for any
  future writer that forgets the lock.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    delta = Ash.Changeset.get_argument(changeset, :quantity)
    on_hand = changeset.data.quantity_on_hand || Decimal.new(0)

    if Decimal.negative?(Decimal.add(on_hand, delta)) do
      {:error,
       Ash.Error.Changes.InvalidArgument.exception(
         field: :quantity,
         message: "insufficient stock: %{on_hand} on hand, %{requested} requested",
         vars: [on_hand: on_hand, requested: Decimal.abs(delta)]
       )}
    else
      :ok
    end
  end
end
