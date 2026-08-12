defmodule FnbErp.Warehouse.Validations.SufficientStock do
  @moduledoc """
  Rejects a stock movement that would drive an inventory balance below zero.

  This is the friendly error; the `quantity_on_hand >= 0` check constraint is the
  one that holds under a concurrent race, since the balance is read here before
  the atomic update applies.
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
