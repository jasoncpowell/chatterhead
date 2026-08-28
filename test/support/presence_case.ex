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

  alias ChatterheadWeb.Presence

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

  # Presence's diff pipeline is async end to end: a tracked process dies, the
  # tracker updates its CRDT, a fetcher task computes the diff, and only then does
  # handle_metas/4 run and spawn the last_seen_at write. So "no tasks right now"
  # is not "settled" — we require the supervisors to stay empty across a few
  # consecutive polls before concluding.
  @quiet_polls 5

  @doc """
  Waits until presence has quiesced: every `Phoenix.Presence` fetcher task and
  every `Chatterhead.TaskSupervisor` task (the `last_seen_at` writes the presence
  client spawns on leave) has finished, and nothing new has appeared for
  #{@quiet_polls} consecutive polls.

  Call from `on_exit/1` in any test that tracks presence, so a late write does
  not race the sandbox teardown and log a spurious connection error.
  """
  def drain_presence_fetchers(timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_quiescent(deadline, 0)
  end

  defp await_quiescent(deadline, quiet_polls) do
    tasks =
      Presence.fetchers_pids() ++ Task.Supervisor.children(Chatterhead.TaskSupervisor)

    cond do
      tasks == [] and quiet_polls >= @quiet_polls ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :ok

      tasks == [] ->
        Process.sleep(@poll_interval_ms)
        await_quiescent(deadline, quiet_polls + 1)

      true ->
        Enum.each(tasks, &await_down/1)
        await_quiescent(deadline, 0)
    end
  end

  defp await_down(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      200 -> Process.demonitor(ref, [:flush])
    end
  end
end
