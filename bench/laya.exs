# Compares Laya on CPU and on CUDA.
#
#     MIX_ENV=bench mix run bench/laya.exs
#
# Runs on CUDA only by default. Set PROVIDERS=cuda,cpu to compare with the
# CPU. The CPU run is heavy: the model needs about 2 GB of RAM, and the
# concurrent job is skipped on the CPU because it can take a minute per
# iteration and saturate the machine.
#
# Set MODEL_DIR to use another bundle. See guides/gpu.md for CUDA setup.

alias SystemOne.{Query, Question}

model_dir = System.get_env("MODEL_DIR", "priv/models/laya")

providers =
  System.get_env("PROVIDERS", "cuda") |> String.split(",") |> Enum.map(&String.to_atom/1)

message = %{
  from: "alice@example.com",
  subject: "Production is down",
  body: """
  Hi team, the checkout service has been returning 500 errors since 09:12.
  Customers cannot pay. I rolled back the last deploy but it did not help.
  Can someone from infra join the call now? Link is in the channel.
  """
}

questions = [
  Question.new(:urgent, :noul, "Does this message need a reply right now?"),
  Question.new(:sentiment, :choice, "How does the sender feel?",
    criteria: ["calm", "worried", "angry"]
  ),
  Question.new(:urgency, :score, "How urgent is this?",
    criteria: ["can wait", "this week", "today", "right now"]
  ),
  Question.new(:topic, :choice, "What is this about?",
    criteria: ["billing", "outage", "feature request", "hiring", "other"]
  ),
  Question.new(:spam, :noul, "Is this spam?"),
  Question.new(:action, :choice, "What should happen next?",
    criteria: ["ignore", "reply", "escalate", "schedule a meeting"]
  ),
  Question.new(:tone, :score, "How formal is the tone?",
    criteria: ["casual", "neutral", "formal"]
  ),
  Question.new(:customer, :noul, "Is the sender a customer?")
]

one_question = Query.new(message, Enum.take(questions, 1))
eight_questions = Query.new(message, questions)

run = fn name, query ->
  {:ok, _result} = SystemOne.query(name, query)
end

concurrent = fn name, query, count ->
  1..count
  |> Task.async_stream(fn _ -> run.(name, query) end, max_concurrency: count, timeout: :infinity)
  |> Stream.run()
end

save_path = Path.join(System.tmp_dir!(), "system_one_bench")

for {provider, index} <- Enum.with_index(providers) do
  name = Module.concat(Bench, provider |> to_string() |> Macro.camelize())

  {:ok, pid} =
    SystemOne.start_link(
      name: name,
      model: SystemOne.Models.Laya,
      model_dir: model_dir,
      execution_providers: [provider]
    )

  {:ok, _status} = SystemOne.await_ready(name, timeout: 300_000)

  # The first run on CUDA allocates GPU memory and tunes kernels.
  for _ <- 1..5, do: run.(name, eight_questions)

  jobs = %{
    "#{provider}: 1 query x 1 question" => fn -> run.(name, one_question) end,
    "#{provider}: 1 query x 8 questions" => fn -> run.(name, eight_questions) end
  }

  jobs =
    if provider == :cpu do
      jobs
    else
      Map.put(jobs, "#{provider}: 16 concurrent queries x 8 questions", fn ->
        concurrent.(name, eight_questions, 16)
      end)
    end

  Benchee.run(jobs,
    time: if(provider == :cpu, do: 5, else: 10),
    warmup: 2,
    save: [path: "#{save_path}_#{provider}.benchee", tag: to_string(provider)],
    load: Enum.map(Enum.take(providers, index), &"#{save_path}_#{&1}.benchee"),
    print: [configuration: index == 0]
  )

  Supervisor.stop(pid)
end
