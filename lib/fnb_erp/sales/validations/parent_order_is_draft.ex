defmodule FnbErp.Sales.Validations.ParentOrderIsDraft do
  @moduledoc """
  Order lines are only writable while the order is still a draft.

  Reads the order under `FOR UPDATE`, inside the line action's own transaction,
  so this serialises against `Changes.LockOrder` in `confirm`/`fulfil`/`cancel`:
  whichever transaction gets the order row first wins, and the loser sees the
  post-transition status and fails. Without the lock a line write and a status
  transition could each read `:draft` and both commit, adding a line to an
  order that's already left the draft state.
  """
  use Ash.Resource.Validation

  require Ash.Query

  @impl true
  def validate(changeset, _opts, _context) do
    # A nil id is `allow_nil? false`'s error to report — querying for it would
    # only add a confusing "not found" next to the real "is required".
    case Ash.Changeset.get_attribute(changeset, :order_id) do
      nil -> :ok
      order_id -> check(order_id)
    end
  end

  defp check(order_id) do
    order =
      FnbErp.Sales.Order
      |> Ash.Query.filter(id == ^order_id)
      |> Ash.Query.lock("FOR UPDATE")
      |> Ash.read_one!()

    case order do
      %{status: :draft} ->
        :ok

      %{status: status} ->
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :order_id,
           message: "lines cannot be changed on a %{status} order",
           vars: [status: status]
         )}

      nil ->
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :order_id,
           message: "order does not exist"
         )}
    end
  end
end
