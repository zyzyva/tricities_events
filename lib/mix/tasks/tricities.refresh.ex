defmodule Mix.Tasks.Tricities.Refresh do
  @moduledoc """
  Fetches all configured sources, aggregates events, and writes the
  master `priv/static/tricities-events.ics` file.

  Usage:

      mix tricities.refresh
      mix tricities.refresh --output /tmp/tc.ics
  """

  use Mix.Task

  @shortdoc "Fetch all sources and rebuild the Tri-Cities events iCal file"

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [output: :string])

    Mix.Task.run("app.start")

    aggregator_opts =
      case Keyword.get(opts, :output) do
        nil -> []
        path -> [output: path]
      end

    result = TricitiesEvents.Aggregator.run(aggregator_opts)

    IO.puts("\n=== Tri-Cities Events Refresh ===")
    IO.puts("Output: #{result.output_path}")
    IO.puts("Total events (after dedup): #{result.total_events}\n")

    IO.puts("Per-source summary:")

    Enum.each(result.sources, fn s ->
      status = if s.error, do: "ERROR: #{inspect(s.error)}", else: "ok"
      IO.puts("  #{String.pad_trailing(s.name, 30)} #{String.pad_leading(to_string(s.count), 4)} events  [#{status}]")
    end)
  end
end
