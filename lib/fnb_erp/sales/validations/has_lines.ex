defmodule FnbErp.Sales.Validations.HasLines do
  @moduledoc "Rejects confirming an empty order."
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    order = Ash.load!(changeset.data, :lines)

    if order.lines == [] do
      {:error,
       Ash.Error.Changes.InvalidAttribute.exception(
         field: :lines,
         message: "an order needs at least one line before it can be confirmed"
       )}
    else
      :ok
    end
  end
end
