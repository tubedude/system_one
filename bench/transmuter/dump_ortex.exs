alias SystemOne.Question
alias SystemOne.Models.Laya.Sequence

dir = "priv/models/laya"
{:ok, tok} = Tokenizers.Tokenizer.from_file(Path.join(dir, "tokenizer/tokenizer.json"))
config = dir |> Path.join("laya_config.json") |> File.read!() |> Jason.decode!(keys: :atoms)
id = &Tokenizers.Tokenizer.token_to_id(tok, &1)

ids = %{
  cls: id.("[CLS]"),
  sep: id.("[SEP]"),
  mask: id.("[MASK]"),
  pad: id.("[PAD]"),
  mask_token: "[MASK]"
}

encode = fn text ->
  {:ok, e} = Tokenizers.Tokenizer.encode(tok, text, add_special_tokens: false)
  Tokenizers.Encoding.get_ids(e)
end

state = Jason.encode!(%{message: "The server is down again and nobody is answering the pager!"})

questions = [
  Question.new(:sentiment, :choice, "How does this feel?",
    criteria: ["positive", "neutral", "negative"]
  ),
  Question.new(:urgency, :score, "How urgent?", criteria: ["can wait", "soon", "right now"]),
  Question.new(:spam, :noul, "Is this spam?")
]

prepared =
  Enum.map(questions, fn q ->
    {:ok, q} = Sequence.normalize(q)
    {:ok, seq} = Sequence.build(encode, q, state, ids, config)
    %{question: q, sequence: seq}
  end)

max_options = 20
target_len = 128

rows =
  Enum.map(prepared, fn item ->
    seq = item.sequence.ids
    pos = item.sequence.markers
    pad = target_len - length(seq)

    {seq ++ List.duplicate(ids.pad, pad),
     List.duplicate(1, length(seq)) ++ List.duplicate(0, pad),
     pos ++ List.duplicate(0, max_options - length(pos)),
     List.duplicate(1, length(pos)) ++ List.duplicate(0, max_options - length(pos)),
     Sequence.qtype(item.question)}
  end)

inputs = {
  Nx.tensor(Enum.map(rows, &elem(&1, 0)), type: :s64),
  Nx.tensor(Enum.map(rows, &elem(&1, 1)), type: :s64),
  Nx.tensor(Enum.map(rows, &elem(&1, 2)), type: :s64),
  Nx.tensor(Enum.map(rows, &elem(&1, 3)), type: :u8),
  Nx.tensor(Enum.map(rows, &elem(&1, 4)), type: :s64)
}

model = Ortex.load(Path.join(dir, "laya.onnx"))
{t, out} = :timer.tc(fn -> Ortex.run(model, inputs) end)
{t2, _} = :timer.tc(fn -> Ortex.run(model, inputs) end)
IO.puts("ortex first run #{div(t, 1000)} ms, second #{div(t2, 1000)} ms")

ser = fn t ->
  t = Nx.backend_transfer(t)
  %{bin: Nx.to_binary(t), type: Nx.type(t), shape: Nx.shape(t)}
end

File.write!(
  "laya_ref.bin",
  :erlang.term_to_binary(%{
    inputs: Tuple.to_list(inputs) |> Enum.map(ser),
    outputs: Tuple.to_list(out) |> Enum.map(ser)
  })
)

IO.puts("saved laya_ref.bin")
