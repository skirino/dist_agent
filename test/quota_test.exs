defmodule DistAgent.QuotaTest do
  use ExUnit.Case
  alias DistAgent.Config

  @q "quota_test"

  test "should get/set quota settings" do
    assert DistAgent.list_quotas()            == []
    assert DistAgent.quota_usage(@q)          == nil
    assert DistAgent.command(@q, A, "key", 0) == {:error, :quota_not_found}
    assert DistAgent.query(  @q, A, "key", 0) == {:error, :agent_not_found}

    assert DistAgent.put_quota(@q, 10) == :ok
    assert DistAgent.list_quotas()     == [@q]
    assert DistAgent.quota_usage(@q)   == {0, 10}

    Enum.each(1..10, fn i ->
      assert DistAgent.command(@q, A, "#{i}", i) == {:ok, :ok}
      assert DistAgent.query(  @q, A, "#{i}", 0) == {:ok, i}
    end)
    :timer.sleep(Config.quota_collection_interval() * 2)
    assert DistAgent.quota_usage(@q) == {10, 10}
    assert DistAgent.command(@q, A, "11", 11) == {:error, :quota_limit_reached}
    assert DistAgent.query(  @q, A, "11", 11) == {:error, :agent_not_found}

    assert DistAgent.put_quota(@q, :infinity) == :ok
    assert DistAgent.quota_usage(@q)          == {10, :infinity}
    assert DistAgent.command(@q, A, "11", 11) == {:ok, :ok}
    assert DistAgent.query(  @q, A, "11", 0)  == {:ok, 11}

    [shard_name] = RaftKV.reduce_keyspace_shard_names(:dist_agent, [], &[&1 | &2])
    assert length(RaftKV.list_keys_in_shard(shard_name)) == 11
    assert DistAgent.delete_quota(@q) == :ok
    assert DistAgent.quota_usage(@q)  == nil
    assert DistAgent.list_quotas()    == []
    :timer.sleep(Config.quota_collection_interval() * 2)
    assert RaftKV.list_keys_in_shard(shard_name) == []
  end
end
