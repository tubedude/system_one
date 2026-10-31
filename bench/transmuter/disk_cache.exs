# Run twice. The first process compiles and writes the cache; the second should only load it.
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

model = Transmuter.load!(System.fetch_env!("LAYA_ONNX"), backend: {EXLA.Backend, client: :cuda})

cache = Path.expand("xla_cache/laya")
File.mkdir_p!(Path.dirname(cache))
before = File.ls!(Path.dirname(cache)) |> length()

{tc, run} =
  :timer.tc(fn ->
    Transmuter.compile(model, inputs, compiler: EXLA, client: :cuda, cache: cache)
  end)

after_ = File.ls!(Path.dirname(cache)) |> length()
IO.puts("compile #{div(tc, 1000)} ms, cache files #{before} -> #{after_}")
{t1, _} = :timer.tc(fn -> run.(inputs) end)
IO.puts("first run #{div(t1, 1000)} ms")
