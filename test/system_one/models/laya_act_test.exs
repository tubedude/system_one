defmodule SystemOne.Models.LayaActTest do
  use ExUnit.Case, async: true

  alias SystemOne.Models.Laya

  test "the act probability of each question is column 0 of its row" do
    act_probs = Nx.tensor([[0.75, 0.25], [0.5, 0.5], [0.125, 0.875]])

    assert Laya.act_probabilities(act_probs) == [0.75, 0.5, 0.125]
  end
end
