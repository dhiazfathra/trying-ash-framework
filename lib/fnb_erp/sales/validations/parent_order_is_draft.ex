defmodule FnbErp.Sales.Validations.ParentOrderIsDraft do
  @moduledoc "Order lines are only writable while the order is still a draft."
  use Ash.Resource.Validation

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
    case Ash.get(FnbErp.Sales.Order, order_id) do
      {:ok, %{status: :draft}} ->
        :ok

      {:ok, order} ->
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :order_id,
           message: "lines cannot be changed on a %{status} order",
           vars: [status: order.status]
         )}

      {:error, error} ->
        {:error, error}
    end
  end
end
