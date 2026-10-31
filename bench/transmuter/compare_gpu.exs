ref = :erlang.binary_to_term(File.read!(Path.join(__DIR__, "laya_ref.bin")))
de = fn %{bin: b, type: t, shape: s} -> Nx.from_binary(b, t) |> Nx.reshape(s) end
[ids, att, pos, mmask, qtype] = Enum.map(ref.inputs, de)

inputs = %{
  "input_ids" => ids,
  "attention_mask" => att,
  "marker_pos" => pos,
  "marker_mask" => mmask,
  "qtype" => qtype
}

backend = {EXLA.Backend, client: :cuda}

{tl, model} =
  :timer.tc(fn -> Transmuter.load!(System.fetch_env!("LAYA_ONNX"), backend: backend) end)

IO.puts("load #{div(tl, 1000)} ms, mem #{div(:erlang.memory(:total), 1_048_576)} MB")
{tc, run} = :timer.tc(fn -> Transmuter.compile(model, inputs, compiler: EXLA, client: :cuda) end)
IO.puts("compile #{div(tc, 1000)} ms")
{t1, out} = :timer.tc(fn -> run.(inputs) end)
{t2, _} = :timer.tc(fn -> run.(inputs) end)
IO.puts("run first #{div(t1, 1000)} ms, second #{div(t2, 1000)} ms")
IO.inspect(Map.keys(out), label: "outputs")
out = Map.new(out, fn {k, v} -> {k, Nx.backend_copy(v, Nx.BinaryBackend)} end)

[ref_logits, ref_act] = Enum.map(ref.outputs, de)

cmp = fn name, got, want ->
  got = Nx.backend_transfer(got, Nx.BinaryBackend) |> Nx.as_type(:f32)
  # Masked option slots hold -1e4 in both; compare only real values.
  diff = Nx.abs(Nx.subtract(got, want)) |> Nx.reduce_max() |> Nx.to_number()
  IO.puts("#{name}: max abs diff #{diff}")
end

cmp.("logits", out["logits"], ref_logits)
cmp.("act", out["act_probs"], ref_act)
IO.inspect(out["logits"][[.., 0..3]], label: "transmuter logits[:, 0..3]")
IO.inspect(ref_logits[[.., 0..3]], label: "ortex logits[:, 0..3]")

for _ <- 1..3, do: run.(inputs)
{t3, _} = :timer.tc(fn -> for _ <- 1..10, do: run.(inputs) end)
IO.puts("steady avg over 10 runs #{div(t3, 10_000)} ms")
