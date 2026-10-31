defmodule SystemOne.Models.Laya.SequenceTest do
  use ExUnit.Case, async: true

  alias SystemOne.Models.Laya.Sequence
  alias SystemOne.Question

  @ids %{cls: 1, sep: 2, mask: 3, pad: 0, mask_token: "[MASK]"}
  @config %{max_len: 128, head_max_len: 96}

  test "builds Laya's sequence, scrubs mask tokens, and preserves the final separator" do
    parent = self()

    encode = fn text ->
      send(parent, {:encoded, text})
      text |> String.graphemes() |> Enum.map(&(:erlang.phash2(&1, 100) + 10))
    end

    question =
      Question.new(:route, :choice, "Should [MASK] act?",
        criteria: [{"ignore", "do nothing"}, {"watch", "review later"}]
      )

    assert {:ok, normalized} = Sequence.normalize(question)

    assert {:ok, %{ids: [1 | _] = ids, markers: [first, second]}} =
             Sequence.build(encode, normalized, %{body: "[MASK] hello"}, @ids, @config)

    assert List.last(ids) == 2
    assert first < second
    assert length(ids) <= @config.max_len

    encoded = collect_encoded([])
    refute Enum.any?(encoded, &String.contains?(&1, "[MASK]"))
  end

  test "choice maps are deterministic while lists retain semantic order" do
    mapped =
      Question.new(:route, :choice, "Route?", criteria: %{"zebra" => "last", "alpha" => "first"})

    assert {:ok, mapped} = Sequence.normalize(mapped)
    assert Sequence.labels(mapped) == ["alpha", "zebra"]

    listed =
      Question.new(:route, :choice, "Route?",
        criteria: [{"zebra", "first semantically"}, {"alpha", "second semantically"}]
      )

    assert {:ok, listed} = Sequence.normalize(listed)
    assert Sequence.labels(listed) == ["zebra", "alpha"]
  end

  test "renders score and noul options in model order" do
    score = Question.new(:score, :score, "Urgency?", criteria: ["low", "high"])
    assert {:ok, score} = Sequence.normalize(score)
    assert Sequence.render_options(score) == ["level 0: low", "level 1: high"]
    assert Sequence.labels(score) == ["0", "1"]

    assert {:ok, noul} = Sequence.normalize(Question.new(:urgent, :noul, "Is urgent?"))

    assert Sequence.render_options(noul) == [
             "false: no, the statement does not hold",
             "true: yes, the statement holds"
           ]

    assert Sequence.labels(noul) == ["false", "true"]
  end

  test "normalizes every supported criterion shape and rejects invalid questions" do
    assert Sequence.qtype(Question.new(:q, :choice, "Choose", criteria: ["one"])) == 0
    assert Sequence.qtype(Question.new(:q, :score, "Score", criteria: ["low"])) == 1
    assert Sequence.qtype(Question.new(:q, :noul, "True?")) == 2

    assert {:ok, choice} =
             Sequence.normalize(
               Question.new(:q, :choice, "Choose",
                 criteria: ["plain", {"empty", ""}, {"nil", nil}]
               )
             )

    assert Sequence.render_options(choice) == ["plain", "empty", "nil"]

    assert {:ok, noul} =
             Sequence.normalize(
               Question.new(:q, :noul, "True?", criteria: %{false => "never", true => "always"})
             )

    assert Sequence.render_options(noul) == ["false: never", "true: always"]

    assert {:error, "question type must be :choice, :score, or :noul"} =
             Sequence.normalize(%Question{id: :q, type: :unknown, instructions: "?"})

    assert {:error, "instructions must be a string or map"} =
             Sequence.normalize(Question.new(:q, :noul, 123))

    assert {:error, "choice requires non-empty criteria"} =
             Sequence.normalize(Question.new(:q, :choice, "?", criteria: []))

    assert {:error, "choice criteria must be strings or label tuples"} =
             Sequence.normalize(Question.new(:q, :choice, "?", criteria: [123]))

    assert {:error, "score requires ordered criteria"} =
             Sequence.normalize(Question.new(:q, :score, "?", criteria: nil))

    assert {:error, "score criteria must be strings"} =
             Sequence.normalize(Question.new(:q, :score, "?", criteria: ["low", 2]))

    assert {:error, "noul criteria supports only boolean keys and string values"} =
             Sequence.normalize(Question.new(:q, :noul, "?", criteria: %{maybe: "perhaps"}))

    assert {:error, "noul criteria must be a map"} =
             Sequence.normalize(Question.new(:q, :noul, "?", criteria: []))
  end

  test "rejects options that cannot fit in the configured head" do
    encode = fn text -> String.to_charlist(text) end
    criteria = Enum.map(1..5, &{"option-#{&1}", String.duplicate("detail", 10)})

    assert {:ok, question} =
             Sequence.normalize(Question.new(:q, :choice, "?", criteria: criteria))

    assert {:error, "options do not fit in head_max_len=4 tokens"} =
             Sequence.build(encode, question, "state", @ids, %{max_len: 8, head_max_len: 4})
  end

  test "uses Laya's temperature buckets and bounded confidence" do
    assert Sequence.temperature_bucket(:choice, 2) == "choice:2"
    assert Sequence.temperature_bucket(:choice, 5) == "choice:3-5"
    assert Sequence.temperature_bucket(:choice, 10) == "choice:6-10"
    assert Sequence.temperature_bucket(:choice, 11) == "choice:11+"
    assert_in_delta Sequence.confidence([0.5, 0.5]), 0.0, 1.0e-12
    assert Sequence.confidence([1.0, 0.0]) == 1.0
    assert Sequence.confidence([1.0]) == 1.0
  end

  test "returns a clear error for state that cannot be JSON encoded" do
    encode = fn text -> String.to_charlist(text) end
    question = Question.new(:safe, :noul, "Safe?")
    assert {:ok, question} = Sequence.normalize(question)

    assert {:error, "state must be a string or JSON-encodable value"} =
             Sequence.build(encode, question, self(), @ids, @config)
  end

  test "returns a clear error for instructions that cannot be JSON encoded" do
    question = Question.new(:safe, :noul, %{pid: self()})
    assert {:error, "instructions map must be JSON-encodable"} = Sequence.normalize(question)
  end

  test "reserves structural tokens when head_max_len approaches max_len" do
    encode = fn text -> String.to_charlist(text) end
    question = Question.new(:safe, :noul, "Safe?")
    assert {:ok, question} = Sequence.normalize(question)

    assert {:ok, %{ids: ids}} =
             Sequence.build(encode, question, "state", @ids, %{max_len: 32, head_max_len: 32})

    assert length(ids) <= 32
    assert List.last(ids) == @ids.sep
  end

  test "preview accurately calculates token budgets and matches build/5 total" do
    encode = fn text -> String.to_charlist(text) end
    question = Question.new(:urgency, :score, "How urgent?", criteria: ["low", "high"])
    assert {:ok, normalized} = Sequence.normalize(question)
    state = "short state"

    assert {:ok, %{ids: built_ids}} =
             Sequence.build(encode, normalized, state, @ids, @config)

    assert {:ok, preview} =
             Sequence.preview(encode, normalized, encode.(state), @ids, @config)

    assert preview.question_id == :urgency
    assert preview.type == :score
    assert preview.truncated? == false
    assert preview.truncated_tokens == 0
    assert preview.state_tokens == preview.raw_state_tokens
    assert preview.total_tokens == length(built_ids)
    assert preview.total_tokens == preview.header_tokens + preview.state_tokens + 1
    assert preview.room == @config.max_len - preview.header_tokens - 1
  end

  test "preview detects and measures truncation when state exceeds available room" do
    encode = fn text -> String.to_charlist(text) end
    question = Question.new(:sentiment, :choice, "Feeling?", criteria: ["good", "bad"])
    assert {:ok, normalized} = Sequence.normalize(question)
    long_state = String.duplicate("very long state text ", 20)

    config = %{max_len: 64, head_max_len: 32}

    assert {:ok, %{ids: built_ids}} =
             Sequence.build(encode, normalized, long_state, @ids, config)

    assert {:ok, preview} =
             Sequence.preview(encode, normalized, encode.(long_state), @ids, config)

    assert preview.truncated? == true
    assert preview.truncated_tokens > 0
    assert preview.state_tokens == preview.room
    assert preview.raw_state_tokens == preview.state_tokens + preview.truncated_tokens
    assert preview.total_tokens == length(built_ids)
    assert preview.total_tokens == config.max_len
  end

  test "preview returns clear error for oversized options" do
    encode = fn text -> String.to_charlist(text) end

    oversized =
      Question.new(:q, :choice, "?",
        criteria: Enum.map(1..5, &{"option-#{&1}", String.duplicate("detail", 10)})
      )

    assert {:ok, oversized} = Sequence.normalize(oversized)

    assert {:error, "options do not fit in head_max_len=4 tokens"} =
             Sequence.preview(encode, oversized, encode.("state"), @ids, %{
               max_len: 8,
               head_max_len: 4
             })
  end

  defp collect_encoded(acc) do
    receive do
      {:encoded, text} -> collect_encoded([text | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
