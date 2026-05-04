# Auto-exclude web-specific tests when the optional web app is absent
# (e.g. inside the web-removability sandbox).
web_app_dir = Path.expand("../../../apps/tet_web_phoenix", __DIR__)

unless File.dir?(web_app_dir) do
  ExUnit.configure(exclude: [:web_specific])
end

ExUnit.start()
