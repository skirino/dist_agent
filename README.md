# DistAgent

Elixir framework to run distributed, fault-tolerant variant of `Agent`.

- [API Documentation](https://hexdocs.pm/dist_agent/)
- [Hex package information](https://hex.pm/packages/dist_agent)

[![Hex.pm](http://img.shields.io/hexpm/v/dist_agent.svg)](https://hex.pm/packages/dist_agent)
[![Coverage Status](https://coveralls.io/repos/github/skirino/dist_agent/badge.svg?branch=master)](https://coveralls.io/github/skirino/dist_agent?branch=master)

# Overview

`dist_agent` is an Elixir library (or framework) to run many "distributed agent"s within a cluster of ErlangVM nodes.
"Distributed agent" has the followings in common with Elixir's [`Agent`](https://hexdocs.pm/elixir/Agent.html):

- support for arbitrary data structure
- synchronous communication pattern

On the other hand, "distributed agent" offers the following features:

- synchronous state replication within multiple nodes for fault tolerance
- location transparency using logical agent IDs
- automatic placement and migration of processes for load balancing and failover
- agent lifecycle management (activated at 1st command, deactivated after a period of inactivity)
- upper limit ("quota") on number of distributed agents for multi-tenant use cases
- optional rate limiting on incoming messages to each distributed agent
- low-resolution timer, similar to `GenServer`'s `:timeout`, for distributed agents

# Concepts

- Distributed agent
    - Distributed agent represents a state and its associated behaviour.
      It can also take autonomous actions using the tick mechanism (explained below).
    - Each distributed agent is identified by the following triplet:
        - `quota_name`: a `String.t` that specifies the quota which this distributed agent belongs to
        - `module`: a callback module of `DistAgent.Behaviour`
        - `key`: an arbitrary `String.t` that uniquely identify the distributed agent within the same `quota_name` and `module`
    - Behaviour of a distributed agent is defined by the `module` part of its identity.
        - The callbacks are divided into "pure" ones and "side-effecting" ones.
    - Distributed agent is "activated" (initialized) when `DistAgent.command/5` is called with a nonexisting ID.
    - Distributed agent is "deactivated" (removed from memory) when it's told to do so by the callback.
- Quota
    - Quota defines an upper limit of number of distributed agents that can run within it (soft limit).
    - Each quota is identified by a `quota_name` (`String.t`).
    - Each distributed agent belongs to exactly one quota; quota must be created before activating distributed agents within it.
- Tick
    - Ticks are periodic events which all distributed agents receive.
    - Ticks are emitted by a limited number of dedicated processes (whose sole task is to periodically emit ticks),
      thus reducing number of timers that have to be maintained.
    - Each distributed agent specifies "what to do on the subsequent ticks" in callback's return value:
        1. do nothing
        1. trigger timeout after the specified number of ticks (i.e., use it as a low-resolution timer).
        1. deactivate itself when it has received the specified number of ticks without client commands

# Design

## Raft protocol and libraries

`dist_agent` heavily depends on [Raft consensus protocol](https://raft.github.io/) for synchronous replication
and failover.
The core protocol is implemented in [`rafted_value`](https://github.com/skirino/rafted_value) and
the cluster management and fault tolerance mechanism are provided by [`raft_fleet`](https://github.com/skirino/raft_fleet).

Although Raft consensus groups provide an important building block for distributed agents,
it's unclear how we should map the concept of "distributed agent"s to consensus groups.
It can be easily seen that the following 2 extremes are not optimal for wide range of use cases:

- only 1 consensus group for all distributed agents
    - Not scalable for large number of agents; obviously the leader process becomes the bottleneck.
- consensus group (which typically consists of 3 processes in 3 nodes) per distributed agent
    - Cost for timers and healthchecks scales linearly with number of consensus groups;
      for many agents, CPU resources are wasted by just maintaining consensus groups.

And (of course) number of distributed agents in a system changes over time.
We take an approach that

- each consensus group hosts multiple distributed agents, and
- number of consensus groups is dynamically adjusted according to the current load.

This dynamic "sharding" of distributed agents and also the agent ID-based data model
are defined by [`raft_kv`](https://github.com/skirino/raft_kv).
This design may introduce a potential problem:
a distributed agent can be blocked by a long-running operation of another agent
which happened to reside in the same consensus group.
It is the responsibility of implementers of the callback modules for distributed agents
to ensure that handlers of query/command/timeout don't take long time.

Even with reduced number of consensus groups explained above,
state replications and healthchecks involve high rate of inter-node communications.
In order to reduce network traffic and TCP overhead (with increased latency), remote communications between nodes can be batched
with the help of [`batched_communication`](https://github.com/skirino/batched_communication).
It's not included as a dependency of `dist_agent`; to use it you have to add it as a dependency of your project
and set `BatchedCommunication` module as the following options:

- messages from Raft members: `:communication_module` option in `t:RaftedValue.Config.t/0` of consensus groups
  (It should be set by `:rafted_value_config_maker` option for `:raft_fleet`.
  See also `RaftFleet.Config`, `RaftKV.Config` and `DistAgent.Config`.)
- messages from clients: `:call_module` option as argument to `DistAgent.command/5` and `DistAgent.query/5`

Since establishing a consensus (committing a command) in the Raft protocol requires
round trips to remote nodes, it is a relatively expensive operation.
In order not to overwhelm raft member processes, accesses to each agent may be rate-limited by
the [token bucket algorithm](https://en.wikipedia.org/wiki/Token_bucket).
Rate limiting is (when enabled) imposed on a per-node basis; in each node, there exists a bucket per distributed agent.
We use [`foretoken`](https://github.com/skirino/foretoken) as the token bucket implementation.

## Quota management

Current statuses of all quotas are managed by a special Raft consensus group named `DistAgent.Quota`.
It's internal state consists of

- `%{node => {%{quota_name => count}, time_reported}}`
- `%{quota_name => limit}`.

When adding a new distributed agent, the upper limit is checked by consulting with this Raft consensus group.
`%{quota_name => count}` reported from each node is valid for 15 minutes.
Counts in removed/unreachable nodes are thus automatically cleaned up.

In each node a `GenServer` named `DistAgent.Quota.Reporter` periodically aggregates
number of distributed agents queried from consensus leader processes that reside in the node.
It periodically publishes the aggregated value to `DistAgent.Quota`.

Quota is checked only when making a new distributed agent, i.e.,
on receipt of 1st message to a distributed agent, the quota limit violation is checked.
Already created distributed agent is never blocked/stopped due to quota limit.
Especially agent migration and failover won't be affected.

## Things `dist_agent` won't do

Currently we have no plan to:

- provide API to efficiently retrieve list of active distributed agents
- provide something like links/monitors that Erlang processes have
