defmodule FnbErp.Sales.Validations.ProductIsSellable do
  @moduledoc "Only active finished goods can be sold. See ASSUMPTIONS.md #12."
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    # See ParentOrderIsDraft: a nil id belongs to `allow_nil? false`, not here.
    case Ash.Changeset.get_attribute(changeset, :product_id) do
      nil -> :ok
      product_id -> check(product_id)
    end
  end

  defp check(product_id) do
    case Ash.get(FnbErp.Catalog.Product, product_id) do
      {:ok, %{active?: true, category: :finished_good}} ->
        :ok

      {:ok, product} ->
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :product_id,
           message: "%{sku} is not sellable (category %{category}, active %{active})",
           vars: [sku: product.sku, category: product.category, active: product.active?]
         )}

      {:error, error} ->
        {:error, error}
    end
  end
end
