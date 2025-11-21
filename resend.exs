#!/usr/bin/env elixir

# Quick CLI script for running callback resends without IEx
# Usage: ./resend.exs service_id [processing_id1,processing_id2,...]

Mix.install([
  {:ecto, "~> 3.12"},
  {:postgrex, "~> 0.20"},
  {:httpoison, "~> 2.2"},
  {:jason, "~> 1.4"},
  {:ecto_sql, "~> 3.12"}
])

defmodule CLI do
  def main(args) do
    case args do
      [service_id] ->
        IO.puts("Resending all callbacks for service: #{service_id}")
        run_resend(service_id, nil)

      [service_id, processing_ids_str] ->
        processing_ids = String.split(processing_ids_str, ",")
        IO.puts("Resending callbacks for service: #{service_id}")
        IO.puts("Processing IDs: #{inspect(processing_ids)}")
        run_resend(service_id, processing_ids)

      _ ->
        IO.puts("""
        Usage:
          ./resend.exs <service_id>
          ./resend.exs <service_id> <processing_id1,processing_id2,...>

        Examples:
          ./resend.exs payment_service_v2
          ./resend.exs payment_service_v2 TXN001,TXN002,TXN003
        """)
        System.halt(1)
    end
  end

  defp run_resend(service_id, processing_ids) do
    # Load the main application modules
    Code.require_file("../lib/orchard_resend/repo.ex", __DIR__)
    Code.require_file("../lib/orchard_resend/schema/callback_req.ex", __DIR__)
    Code.require_file("../lib/orchard_resend/schema/resend_callback.ex", __DIR__)
    Code.require_file("../lib/orchard_resend/resender.ex", __DIR__)

    # Start dependencies
    Application.ensure_all_started(:postgrex)
    Application.ensure_all_started(:ecto)
    Application.ensure_all_started(:httpoison)

    # Start the repo
    {:ok, _} = OrchardResend.Repo.start_link()

    # Run the resend
    case OrchardResend.Resender.resend_callbacks(service_id, processing_ids) do
      {:ok, result} ->
        IO.puts("\n✅ Resend completed successfully!")
        IO.puts("Total: #{result.total}")
        IO.puts("Success: #{result.success}")
        IO.puts("Failed: #{result.failed}")

        if result.failed > 0 do
          IO.puts("\nFailed callbacks:")
          Enum.each(result.results, fn
            {:error, id, reason} ->
              IO.puts("  - Callback ID #{id}: #{inspect(reason)}")
            _ ->
              :ok
          end)
        end

        System.halt(0)

      {:error, reason} ->
        IO.puts("\n❌ Resend failed: #{inspect(reason)}")
        System.halt(1)
    end
  end
end

CLI.main(System.argv())
