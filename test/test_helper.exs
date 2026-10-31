bundle_present? =
  File.regular?("priv/models/laya/laya_config.json") and
    File.regular?("priv/models/laya/tokenizer/tokenizer.json")

exclude = if bundle_present?, do: [], else: [:laya_bundle]
ExUnit.start(exclude: exclude)
