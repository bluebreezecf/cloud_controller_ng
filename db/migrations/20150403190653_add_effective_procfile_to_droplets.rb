Sequel.migration do
  change do
    add_column :droplets, :effective_procfile, String, text: true
  end
end
