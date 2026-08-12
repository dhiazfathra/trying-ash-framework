defmodule FnbErp.Warehouse.Changes.RecordStockMovement do
  @moduledoc """
  Writes the ledger row for a balance change, in the same transaction as the
  balance update — so the ledger can never disagree with `quantity_on_hand`.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    quantity = Ash.Changeset.get_argument(changeset, :quantity)
    reason = Ash.Changeset.get_argument(changeset, :reason)
    reference = Ash.Changeset.get_argument(changeset, :reference)

    Ash.Changeset.after_action(changeset, fn _changeset, inventory ->
      FnbErp.Warehouse.StockMovement
      |> Ash.Changeset.for_create(:create, %{
        inventory_id: inventory.id,
        quantity: quantity,
        reason: reason,
        reference: reference
      })
      |> Ash.create()
      |> case do
        {:ok, _movement} -> {:ok, inventory}
        {:error, error} -> {:error, error}
      end
    end)
  end
end
