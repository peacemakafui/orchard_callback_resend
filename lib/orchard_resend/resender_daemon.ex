defmodule OrchardResend.ResenderDaemon do
  @moduledoc """
  Background daemon for continuously resending failed callbacks.

  Usage:
    # Start the daemon
    OrchardResend.ResenderDaemon.start_link()

    # Stop the daemon
    OrchardResend.ResenderDaemon.stop()

    # Get daemon status
    OrchardResend.ResenderDaemon.status()
  """

  use GenServer
  require Logger

  @default_check_interval 60_000  # Check every 60 seconds
  @default_batch_size 1000
  @default_concurrency 20
  @default_timeout 60_000
  @default_batch_delay 1_000

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def stop do
    GenServer.stop(__MODULE__)
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  def pause do
    GenServer.call(__MODULE__, :pause)
  end

  def resume do
    GenServer.call(__MODULE__, :resume)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    check_interval = Keyword.get(opts, :check_interval, @default_check_interval)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    concurrency = Keyword.get(opts, :concurrency, @default_concurrency)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    batch_delay = Keyword.get(opts, :batch_delay, @default_batch_delay)

    state = %{
      check_interval: check_interval,
      batch_size: batch_size,
      concurrency: concurrency,
      timeout: timeout,
      batch_delay: batch_delay,
      paused: false,
      last_run: nil,
      total_processed: 0,
      total_success: 0,
      total_failed: 0
    }

    Logger.info("ResenderDaemon started with check_interval: #{check_interval}ms")

    # Schedule first check
    schedule_next_check(check_interval)

    {:ok, state}
  end

  @impl true
  def handle_info(:check_and_resend, %{paused: true} = state) do
    Logger.info("Daemon is paused, skipping this cycle")
    schedule_next_check(state.check_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:check_and_resend, state) do
    Logger.info("Daemon checking for pending callbacks...")

    # Get count of pending callbacks
    pending_count = OrchardResend.Resender.get_pending_count(nil, nil, [])

    if pending_count > 0 do
      Logger.info("Found #{pending_count} pending callbacks, starting resend...")

      # Run resend
      result = OrchardResend.Resender.resend_callbacks(nil, nil,
        batch_size: state.batch_size,
        concurrency: state.concurrency,
        timeout: state.timeout,
        batch_delay: state.batch_delay
      )

      case result do
        {:ok, summary} ->
          new_state = %{state |
            last_run: DateTime.utc_now(),
            total_processed: state.total_processed + summary.total,
            total_success: state.total_success + summary.success,
            total_failed: state.total_failed + summary.failed
          }

          Logger.info("Resend cycle completed: #{summary.success} success, #{summary.failed} failed")
          Logger.info("Total lifetime: #{new_state.total_processed} processed, #{new_state.total_success} success, #{new_state.total_failed} failed")

          schedule_next_check(state.check_interval)
          {:noreply, new_state}

        {:error, reason} ->
          Logger.error("Resend cycle failed: #{inspect(reason)}")
          schedule_next_check(state.check_interval)
          {:noreply, state}
      end
    else
      Logger.info("No pending callbacks found")
      schedule_next_check(state.check_interval)
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      paused: state.paused,
      last_run: state.last_run,
      total_processed: state.total_processed,
      total_success: state.total_success,
      total_failed: state.total_failed,
      check_interval: state.check_interval,
      batch_size: state.batch_size,
      concurrency: state.concurrency
    }
    {:reply, status, state}
  end

  @impl true
  def handle_call(:pause, _from, state) do
    Logger.info("Daemon paused")
    {:reply, :ok, %{state | paused: true}}
  end

  @impl true
  def handle_call(:resume, _from, state) do
    Logger.info("Daemon resumed")
    {:reply, :ok, %{state | paused: false}}
  end

  # Private Functions

  defp schedule_next_check(interval) do
    Process.send_after(self(), :check_and_resend, interval)
  end
end
