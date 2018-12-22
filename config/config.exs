use Mix.Config

import_config "./environment/#{Mix.env()}.exs"

if File.exists?(Path.expand("./environment/#{Mix.env()}.secret.exs", __DIR__)) do
  import_config "./environment/#{Mix.env()}.secret.exs"
end
