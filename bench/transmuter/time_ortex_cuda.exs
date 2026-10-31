# Run from a project whose Ortex was built with the "cuda" feature.
ref = :erlang.binary_to_term(File.read!(Path.join(__DIR__, "laya_ref.bin")))
de = fn %{bin: b, type: t, shape: s} -> Nx.from_binary(b, t) |> Nx.reshape(s) end
inputs = ref.inputs |> Enum.map(de) |> List.to_tuple()
[ref_logits, ref_act] = Enum.map(ref.outputs, de)
path = System.fetch_env!("LAYA_ONNX")

{tl, model} = :timer.tc(fn -> Ortex.load(path, [:cuda]) end)
IO.puts("load #{div(tl, 1000)} ms")
{t1, out} = :timer.tc(fn -> Ortex.run(model, inputs) end)
{t2, _} = :timer.tc(fn -> Ortex.run(model, inputs) end)
IO.puts("run first #{div(t1, 1000)} ms, second #{div(t2, 1000)} ms")
for _ <- 1..3, do: Ortex.run(model, inputs)
{t3, _} = :timer.tc(fn -> for _ <- 1..10, do: Ortex.run(model, inputs) end)
IO.puts("steady avg over 10 runs #{Float.round(t3 / 10_000, 1)} ms")

{logits, act} = out

diff = fn a, b ->
  Nx.backend_transfer(a, Nx.BinaryBackend)
  |> Nx.subtract(b)
  |> Nx.abs()
  |> Nx.reduce_max()
  |> Nx.to_number()
end

IO.puts("logits: max abs diff vs Ortex CPU #{diff.(logits, ref_logits)}")
IO.puts("act: max abs diff vs Ortex CPU #{diff.(act, ref_act)}")
