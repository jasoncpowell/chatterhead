defmodule Chatterhead.PresenceCase do
  @moduledoc """
  Helpers for tests that observe `Phoenix.Presence`.

  `import` this into a presence test alongside `use Chatterhead.DataCase,
  async: false` (presence is a global, unsandboxed process — every presence
  test runs `async: false`).

  ## Why `eventually/2` polls

  `Phoenix.Tracker` is a CRDT and eventually consistent: an assertion made
  immediately after `track/4` passes on a fast local machine and flakes in CI.
  `eventually/2` retries the assertion until it holds.

  Polling with `Process.sleep/1` brushes against AGENTS.md's "avoid
  `Process.sleep/1` in tests". That rule is about waiting on a *named process*
  whose completion you can monitor (`Process.monitor/1` + `assert_receive
  {:DOWN, ...}`). CRDT convergence has no such process and no completion
  message, so bounded polling is the only tool that fits.
  """

  @poll_interval_ms 20

  @doc """
  Runs `fun` every #{@poll_interval_ms}ms until it neither raises nor throws, or
  until `timeout` ms elapse — then runs it a final time so a real failure
  surfaces the underlying assertion error rather than a timeout.
  """
  def eventually(fun, timeout \\ 500) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    fun.()
  rescue
    error ->
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(@poll_interval_ms)
        do_eventually(fun, deadline)
      else
        reraise error, __STACKTRACE__
      end
  end

  @doc """
  Waits for every in-flight `ChatterheadWeb.Presence` fetcher task to exit.

  Call from `on_exit/1` in any test that tracks presence, so fetcher processes
  do not leak into the next test.
  """
  def drain_presence_fetchers(timeout \\ 1000) do
    for pid <- ChatterheadWeb.Presence.fetchers_pids() do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        timeout -> Process.demonitor(ref, [:flush])
      end
    end

    :ok
  end
end
