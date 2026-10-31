defmodule SystemOne.Models.LayaTest do
  use ExUnit.Case, async: true

  # Needs the real bundle in priv/models/laya (gitignored). Excluded in test_helper when absent.
  @moduletag :laya_bundle

  alias SystemOne.{Preview, Query, Question}
  alias SystemOne.Models.Laya

  @config %{max_len: 128, head_max_len: 64}

  defp mock_runtime do
    {:ok, tokenizer} =
      Tokenizers.Tokenizer.from_file("priv/models/laya/tokenizer/tokenizer.json")

    ids = %{
      cls: Tokenizers.Tokenizer.token_to_id(tokenizer, "[CLS]"),
      sep: Tokenizers.Tokenizer.token_to_id(tokenizer, "[SEP]"),
      mask: Tokenizers.Tokenizer.token_to_id(tokenizer, "[MASK]"),
      pad: Tokenizers.Tokenizer.token_to_id(tokenizer, "[PAD]"),
      mask_token: "[MASK]"
    }

    %{
      config: @config,
      tokenizer: tokenizer,
      ids: ids
    }
  end

  describe "preview/2 with runtime" do
    test "previews token breakdown across multiple question types" do
      runtime = mock_runtime()

      query =
        Query.new("state data", [
          Question.new(:sentiment, :choice, "Feeling?", criteria: ["happy", "sad"]),
          Question.new(:score, :score, "Level?", criteria: ["low", "high"]),
          Question.new(:safe, :noul, "Is safe?")
        ])

      assert {:ok, %Preview{} = preview} = Laya.preview(query, runtime: runtime)
      assert preview.total_tokens > 0
      assert preview.target_sequence_length in [64, 128]
      assert preview.truncated? == false

      assert Map.has_key?(preview.questions, :sentiment)
      assert Map.has_key?(preview.questions, :score)
      assert Map.has_key?(preview.questions, :safe)

      sentiment = preview.questions[:sentiment]
      assert sentiment.question_id == :sentiment
      assert sentiment.type == :choice
      assert sentiment.truncated? == false
      assert sentiment.total_tokens == sentiment.header_tokens + sentiment.state_tokens + 1

      assert length(preview.ordered_questions) == 3
      assert Enum.map(preview.ordered_questions, & &1.question_id) == [:sentiment, :score, :safe]
    end

    test "detects truncation when state exceeds available budget" do
      runtime = mock_runtime()
      long_state = String.duplicate("word ", 100)

      query =
        Query.new(long_state, [
          Question.new(:q, :noul, "Question?")
        ])

      assert {:ok, %Preview{} = preview} = Laya.preview(query, runtime: runtime)
      assert preview.truncated? == true

      q = preview.questions[:q]
      assert q.truncated? == true
      assert q.truncated_tokens > 0
      assert q.state_tokens == q.room
      assert q.total_tokens == @config.max_len
    end

    test "rejects invalid query inputs" do
      runtime = mock_runtime()

      empty = Query.new("state", [])

      assert {:error, {:invalid_query, "at least one question is required"}} =
               Laya.preview(empty, runtime: runtime)

      too_many = Query.new("state", Enum.map(1..65, &Question.new(&1, :noul, "?")))

      assert {:error, {:invalid_query, "Laya accepts at most 64 questions"}} =
               Laya.preview(too_many, runtime: runtime)

      invalid_state = Query.new(self(), [Question.new(:q, :noul, "?")])

      assert {:error, {:invalid_query, "state must be a string or JSON-encodable value"}} =
               Laya.preview(invalid_state, runtime: runtime)

      too_many_options =
        Query.new("state", [
          Question.new(:q, :choice, "?", criteria: Enum.map(1..21, &"opt#{&1}"))
        ])

      assert {:error, {:invalid_query, "question :q has more than 20 options"}} =
               Laya.preview(too_many_options, runtime: runtime)
    end
  end

  describe "preview/2 limits" do
    test "accepts exactly the maximum questions and options" do
      runtime = mock_runtime()

      max_questions = Query.new("state", Enum.map(1..64, &Question.new(&1, :noul, "?")))
      assert {:ok, %Preview{} = preview} = Laya.preview(max_questions, runtime: runtime)
      assert map_size(preview.questions) == 64
      assert length(preview.ordered_questions) == 64

      max_options =
        Query.new("state", [
          Question.new(:q, :choice, "?", criteria: Enum.map(1..20, &"o#{&1}"))
        ])

      assert {:ok, %Preview{}} = Laya.preview(max_options, runtime: runtime)
    end

    test "picks the smallest padding bucket that holds the longest question" do
      runtime = mock_runtime()
      short = Query.new("hi", [Question.new(:q, :noul, "?")])
      assert {:ok, preview} = Laya.preview(short, runtime: runtime)
      assert preview.target_sequence_length == 64
      assert preview.questions[:q].total_tokens <= 64

      medium = Query.new(String.duplicate("word ", 60), [Question.new(:q, :noul, "?")])
      assert {:ok, preview} = Laya.preview(medium, runtime: runtime)
      assert preview.questions[:q].total_tokens > 64
      assert preview.target_sequence_length == 128
    end

    test "scrubs mask tokens from state and instructions" do
      runtime = mock_runtime()
      plain = Query.new("safe text", [Question.new(:q, :noul, "Is it?")])
      masked = Query.new("safe [MASK] text", [Question.new(:q, :noul, "Is [MASK] it?")])

      assert {:ok, plain_preview} = Laya.preview(plain, runtime: runtime)
      assert {:ok, masked_preview} = Laya.preview(masked, runtime: runtime)

      assert masked_preview.questions[:q].header_tokens >=
               plain_preview.questions[:q].header_tokens

      assert masked_preview.truncated? == false
    end

    test "rejects malformed questions with the question id" do
      runtime = mock_runtime()
      bad = Query.new("state", [Question.new(:q, :choice, "?", criteria: [])])
      assert {:error, {:invalid_query, message}} = Laya.preview(bad, runtime: runtime)
      assert message =~ "choice requires non-empty criteria"
    end
  end

  describe "preview/2 with model_dir" do
    test "validates required model directory" do
      query = Query.new("state", [Question.new(:q, :noul, "?")])

      assert {:error, :model_dir_required} = Laya.preview(query, [])
      assert {:error, :model_dir_required} = Laya.preview(query, model_dir: "")

      assert {:error, {:missing_bundle_files, missing}} =
               Laya.preview(query, model_dir: "nonexistent_dir")

      assert "laya_config.json" in missing
      assert "tokenizer/tokenizer.json" in missing
    end

    @tag timeout: 300_000
    @tag :tmp_dir
    test "compile_cache writes compiled programs to disk", %{tmp_dir: tmp_dir} do
      name = Module.concat(__MODULE__, CachedLaya)
      prefix = Path.join(tmp_dir, "laya")

      start_supervised!(
        {SystemOne, name: name, model: Laya, model_dir: "priv/models/laya", compile_cache: prefix}
      )

      assert {:ok, _} = SystemOne.await_ready(name, timeout: 240_000)

      query = Query.new("short state", [Question.new(:q, :noul, "Is it?")])
      assert {:ok, _result} = SystemOne.query(name, query)

      assert [_ | _] = Path.wildcard(prefix <> "-*")
    end

    @tag timeout: 300_000
    test "preview total matches the real post-truncation input token count" do
      name = Module.concat(__MODULE__, RealLaya)
      start_supervised!({SystemOne, name: name, model: Laya, model_dir: "priv/models/laya"})
      assert {:ok, _} = SystemOne.await_ready(name, timeout: 240_000)

      query =
        Query.new(%{message: String.duplicate("The server is down again! ", 40)}, [
          Question.new(:sentiment, :choice, "How does this feel?",
            criteria: ["positive", "neutral", "negative"]
          ),
          Question.new(:spam, :noul, "Is this spam?")
        ])

      assert {:ok, %Preview{} = preview} = SystemOne.preview(name, query)
      assert {:ok, result} = SystemOne.query(name, query)
      assert preview.total_tokens == result.usage.input_tokens
    end

    test "previews from local priv bundle" do
      query =
        Query.new(%{message: "The server is down again!"}, [
          Question.new(:sentiment, :choice, "How does this feel?",
            criteria: ["positive", "neutral", "negative"]
          ),
          Question.new(:urgency, :score, "How urgent?", criteria: ["can wait", "right now"]),
          Question.new(:spam, :noul, "Is this spam?")
        ])

      assert {:ok, %Preview{} = preview} = Laya.preview(query, model_dir: "priv/models/laya")
      assert preview.total_tokens > 0
      assert preview.target_sequence_length in [64, 128, 256, 512]
      assert preview.truncated? == false
      assert Map.has_key?(preview.questions, :sentiment)
      assert preview.questions[:sentiment].header_tokens > 0
      assert preview.questions[:sentiment].state_tokens > 0
    end
  end
end
