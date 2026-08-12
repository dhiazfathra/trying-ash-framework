defmodule FnbErp.CatalogTest do
  use FnbErp.DataCase, async: true

  import FnbErp.Fixtures

  alias FnbErp.Catalog

  defp message(error), do: Exception.message(error)

  describe "products" do
    test "requires name, sku and unit_price" do
      assert {:error, error} = Catalog.create_product(%{})
      msg = message(error)

      for field <- ~w(name sku unit_price) do
        assert msg =~ field
      end
    end

    test "rejects a negative unit_price" do
      assert {:error, error} =
               Catalog.create_product(%{name: "X", sku: uniq("SKU"), unit_price: -1})

      assert message(error) =~ "must not be negative"
    end

    test "accepts a zero unit_price" do
      assert product = product(%{unit_price: Decimal.new("0.00")})
      assert Decimal.equal?(product.unit_price, Decimal.new(0))
    end

    test "rejects an unknown unit_of_measure" do
      assert {:error, error} =
               Catalog.create_product(%{
                 name: "X",
                 sku: uniq("SKU"),
                 unit_price: 1,
                 unit_of_measure: :barrel
               })

      assert message(error) =~ "unit_of_measure"
    end

    test "creating with an existing sku upserts rather than failing" do
      sku = uniq("SKU")
      original = product(%{sku: sku, name: "Cold Brew 250ml"})
      updated = product(%{sku: sku, name: "Cold Brew 330ml"})

      assert updated.id == original.id
      assert updated.name == "Cold Brew 330ml"
      assert [_only_one] = Enum.filter(Catalog.list_products!(), &(&1.sku == sku))
    end

    test "defaults to a sellable finished good in pieces" do
      product = product()
      assert product.category == :finished_good
      assert product.unit_of_measure == :pcs
      assert product.active?
    end

    test ":sellable returns only active finished goods" do
      sellable = product()
      raw = product(%{category: :raw_material})
      inactive = Catalog.deactivate_product!(product())

      skus = Enum.map(Catalog.list_sellable_products!(), & &1.sku)

      assert sellable.sku in skus
      refute raw.sku in skus
      refute inactive.sku in skus
    end

    test "deactivate flips active? without deleting the row" do
      product = product()
      assert %{active?: false, id: id} = Catalog.deactivate_product!(product)
      assert {:ok, %{active?: false}} = Catalog.get_product(id)
    end

    test "get_product_by_sku finds the product" do
      product = product()
      assert {:ok, found} = Catalog.get_product_by_sku(product.sku)
      assert found.id == product.id
    end
  end

  describe "customers" do
    test "requires a name" do
      assert {:error, error} = Catalog.create_customer(%{})
      assert message(error) =~ "name"
    end

    test "rejects an invalid email" do
      assert {:error, error} = Catalog.create_customer(%{name: "Cafe", email: "not-an-email"})
      assert message(error) =~ "must be a valid email address"
    end

    test "accepts a valid email and a nil email" do
      assert %{email: "hi@cafe.co.id"} = customer(%{email: "hi@cafe.co.id"})
      assert %{email: nil} = customer()
    end

    test "email is unique when present" do
      email = "#{uniq("dup")}@cafe.co.id"
      customer(%{email: email})

      assert {:error, error} = Catalog.create_customer(%{name: "Other", email: email})
      assert message(error) =~ "email"
    end

    test "defaults to active and country ID" do
      assert %{active?: true, country: "ID"} = customer()
    end

    test ":active excludes deactivated customers" do
      active = customer()
      inactive = Catalog.deactivate_customer!(customer())

      ids = Enum.map(Catalog.list_active_customers!(), & &1.id)

      assert active.id in ids
      refute inactive.id in ids
    end

    test "deactivate and activate flip the flag without touching the email" do
      customer = customer(%{email: "flip@cafe.co.id"})

      assert %{active?: false, email: "flip@cafe.co.id"} = Catalog.deactivate_customer!(customer)

      assert %{active?: true} =
               customer |> Catalog.deactivate_customer!() |> Catalog.activate_customer!()
    end
  end
end
