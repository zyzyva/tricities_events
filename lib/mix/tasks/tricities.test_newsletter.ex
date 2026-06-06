defmodule Mix.Tasks.Tricities.TestNewsletter do
  @moduledoc """
  Manual test harness for the newsletter Extractor: runs Groq extraction against
  the saved real-newsletter fixtures (test/fixtures/newsletters/*.json) and prints
  the events + per-email token/cost. Exercises the production extractor code path
  without needing a Fastmail token.

      GROQ_API_KEY=... mix tricities.test_newsletter
  """
  use Mix.Task
  alias TricitiesEvents.Newsletter.Extractor

  @shortdoc "Run the newsletter Extractor against fixtures"
  @fixtures "test/fixtures/newsletters"

  @impl true
  def run(_args) do
    Application.ensure_all_started(:req)
    Application.ensure_all_started(:tzdata)

    files = Path.wildcard(Path.join(@fixtures, "*.json"))

    if files == [] do
      Mix.shell().info("No fixtures in #{@fixtures}")
    end

    Enum.each(files, fn path ->
      email = path |> File.read!() |> JSON.decode!() |> atomize()

      IO.puts("\n══════════════════════════════════════════")
      IO.puts("#{email[:source]} — #{email[:subject]}")
      IO.puts("images: #{length(email[:image_urls] || [])}")

      case Extractor.extract(email) do
        {:ok, events} ->
          IO.puts("→ #{length(events)} events extracted:")

          events
          |> Enum.sort_by(& &1.starts_at, DateTime)
          |> Enum.each(fn e ->
            IO.puts("   • #{DateTime.to_date(e.starts_at)} #{time(e.starts_at)}  #{e.summary}")
            if e.location, do: IO.puts("       @ #{e.location}")
          end)

        {:error, reason} ->
          IO.puts("✗ extract failed: #{inspect(reason, limit: 8)}")
      end
    end)
  end

  defp atomize(map) do
    Map.new(map, fn {k, v} -> {String.to_atom(k), v} end)
  end

  defp time(dt) do
    dt
    |> DateTime.shift_zone!("America/New_York")
    |> Calendar.strftime("%I:%M %p %Z")
  end
end
