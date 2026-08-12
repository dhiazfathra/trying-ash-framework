alias FnbErp.Catalog
alias FnbErp.Sales
alias FnbErp.Warehouse

require Ash.Query

locations =
  Map.new(
    [
      %{
        name: "Gudang Utama Cakung",
        code: "WH-JKT-01",
        address: "Jl. Raya Bekasi KM 21, Cakung, Jakarta Timur 13910"
      },
      %{
        name: "Cold Room Cakung",
        code: "CR-JKT-01",
        address: "Jl. Raya Bekasi KM 21, Blok C (2-8 °C), Jakarta Timur 13910"
      }
    ],
    &{&1.code, Warehouse.create_location!(&1)}
  )

main_warehouse = locations["WH-JKT-01"]

products =
  Map.new(
    [
      %{
        name: "Biji Kopi Arabika Gayo",
        sku: "RM-BEAN-GAYO-1K",
        description: "Arabika Gayo Aceh, medium roast, karung 1 kg",
        unit_price: "165000.00",
        unit_of_measure: :kg,
        category: :raw_material
      },
      %{
        name: "Biji Kopi Robusta Lampung",
        sku: "RM-BEAN-ROB-1K",
        description: "Robusta Lampung, dark roast, karung 1 kg",
        unit_price: "98000.00",
        unit_of_measure: :kg,
        category: :raw_material
      },
      %{
        name: "Susu UHT Full Cream",
        sku: "RM-MILK-UHT-1L",
        description: "Susu UHT full cream 1 liter",
        unit_price: "21500.00",
        unit_of_measure: :l,
        category: :raw_material
      },
      %{
        name: "Gula Aren Cair",
        sku: "RM-SYR-AREN-1L",
        description: "Sirup gula aren murni 1 liter",
        unit_price: "48000.00",
        unit_of_measure: :l,
        category: :raw_material
      },
      %{
        name: "Cup Plastik 16oz + Lid",
        sku: "RM-CUP-16OZ-50",
        description: "Cup PET 16oz beserta lid, isi 50 pcs per box",
        unit_price: "62000.00",
        unit_of_measure: :box,
        category: :raw_material
      },
      %{
        name: "Cold Brew Botol 250ml",
        sku: "FG-CB-250",
        description: "Cold brew Gayo tanpa gula, botol kaca 250 ml",
        unit_price: "28000.00",
        unit_of_measure: :pcs,
        category: :finished_good
      },
      %{
        name: "Es Kopi Susu Gula Aren 250ml",
        sku: "FG-LATTE-250",
        description: "Kopi susu gula aren siap minum, botol 250 ml",
        unit_price: "24000.00",
        unit_of_measure: :pcs,
        category: :finished_good
      },
      %{
        name: "Teh Lemon Serai 330ml",
        sku: "FG-TEA-330",
        description: "Teh hitam lemon serai, botol 330 ml",
        unit_price: "18000.00",
        unit_of_measure: :pcs,
        category: :finished_good
      }
    ],
    &{&1.sku, Catalog.create_product!(&1)}
  )

customers =
  Map.new(
    [
      %{
        name: "Kopi Sudut Senayan",
        contact_name: "Rani Kusuma",
        email: "purchasing@kopisudut.id",
        phone: "+62 21 5730118",
        address_line1: "Jl. Gelora Senayan No. 14",
        city: "Jakarta Pusat",
        province: "DKI Jakarta",
        postal_code: "10270"
      },
      %{
        name: "Warung Nasi Ibu Tati",
        contact_name: "Tati Herawati",
        email: "ibutati@warungnasitati.co.id",
        phone: "+62 812 9044 1177",
        address_line1: "Jl. Kebon Jeruk Raya No. 8",
        address_line2: "Ruko Blok B2",
        city: "Jakarta Barat",
        province: "DKI Jakarta",
        postal_code: "11530"
      },
      %{
        name: "Bakmi Kanton Pluit",
        contact_name: "Andi Wijaya",
        email: "andi@bakmikanton.id",
        phone: "+62 21 6690042",
        address_line1: "Jl. Pluit Karang Utara No. 55",
        city: "Jakarta Utara",
        province: "DKI Jakarta",
        postal_code: "14450"
      },
      %{
        name: "PT Nusantara Distribusi Segar",
        contact_name: "Bagus Santoso",
        email: "order@nusantarasegar.co.id",
        phone: "+62 22 7301885",
        address_line1: "Jl. Soekarno Hatta No. 412",
        address_line2: "Gudang 3",
        city: "Bandung",
        province: "Jawa Barat",
        postal_code: "40286"
      }
    ],
    fn attrs ->
      customer =
        Catalog.Customer
        |> Ash.Query.filter(email == ^attrs.email)
        |> Ash.read_one!()
        |> case do
          nil -> Catalog.create_customer!(attrs)
          existing -> existing
        end

      {attrs.email, customer}
    end
  )

receipts = %{
  "RM-BEAN-GAYO-1K" => 250,
  "RM-BEAN-ROB-1K" => 400,
  "RM-MILK-UHT-1L" => 600,
  "RM-SYR-AREN-1L" => 180,
  "RM-CUP-16OZ-50" => 120,
  "FG-CB-250" => 2400,
  "FG-LATTE-250" => 3000,
  "FG-TEA-330" => 1800
}

# Top up to the target level rather than receiving the full quantity every run,
# so re-seeding leaves stock where the demo expects it instead of inflating it.
for {sku, target} <- receipts do
  product = products[sku]
  shortfall = Decimal.sub(target, Warehouse.available_quantity(product.id, main_warehouse.id))

  if Decimal.positive?(shortfall) do
    {:ok, _} = Warehouse.receive_stock(product.id, main_warehouse.id, shortfall, "PO-SEED")
  end
end

orders =
  case Sales.list_orders!() do
    [] ->
      order = fn customer_email, attrs, lines ->
        order =
          Sales.create_order!(
            Map.merge(
              %{customer_id: customers[customer_email].id, location_id: main_warehouse.id},
              attrs
            )
          )

        for {sku, quantity} <- lines do
          Sales.add_order_line!(%{
            order_id: order.id,
            product_id: products[sku].id,
            quantity: quantity
          })
        end

        order
      end

      draft =
        order.("purchasing@kopisudut.id", %{notes: "Draft — menunggu konfirmasi budget cabang"}, [
          {"FG-CB-250", 24},
          {"FG-LATTE-250", 36}
        ])

      confirmed =
        order.("ibutati@warungnasitati.co.id", %{notes: "Kirim pagi sebelum jam 09.00"}, [
          {"FG-LATTE-250", 48},
          {"FG-TEA-330", 60}
        ])
        |> Sales.confirm_order!()

      fulfilled =
        order.("andi@bakmikanton.id", %{notes: "Faktur menyusul, termin 14 hari"}, [
          {"FG-CB-250", 60},
          {"FG-TEA-330", 120},
          {"FG-LATTE-250", 90}
        ])
        |> Sales.confirm_order!()
        |> Sales.fulfil_order!()

      paid =
        order.("order@nusantarasegar.co.id", %{notes: "Transfer BCA, lunas di muka"}, [
          {"FG-CB-250", 480},
          {"FG-LATTE-250", 600},
          {"FG-TEA-330", 360}
        ])
        |> Sales.confirm_order!()
        |> Sales.fulfil_order!()
        |> Sales.mark_order_paid!()

      cancelled =
        order.("purchasing@kopisudut.id", %{notes: "Order event Car Free Day"}, [
          {"FG-TEA-330", 200},
          {"FG-CB-250", 100}
        ])
        |> Sales.confirm_order!()
        |> Sales.cancel_order!(%{cancellation_reason: "Event dibatalkan karena cuaca"})

      [draft, confirmed, fulfilled, paid, cancelled]

    existing ->
      IO.puts("Orders already present (#{length(existing)}) — skipping order seeding.")
      existing
  end

IO.puts("""

FnB ERP seed complete
  locations: #{map_size(locations)}
  products:  #{map_size(products)} (#{Enum.count(products, fn {_, p} -> p.category == :finished_good end)} finished goods)
  customers: #{map_size(customers)}
  stock receipts: #{map_size(receipts)} products into #{main_warehouse.code} (ref PO-SEED)
""")

orders
|> Ash.load!([:subtotal, :tax_amount, :total])
|> Enum.each(fn order ->
  IO.puts(
    "  #{order.order_number}  #{String.pad_trailing(to_string(order.status), 10)}" <>
      " subtotal IDR #{order.subtotal}  tax IDR #{order.tax_amount}  total IDR #{order.total}"
  )
end)
