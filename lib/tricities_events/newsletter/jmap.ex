defmodule TricitiesEvents.Newsletter.Jmap do
  @moduledoc """
  Pulls recent chamber-newsletter emails from Fastmail via JMAP.

  Newsletters are forwarded to a dedicated alias (`newslettersubs@zyzyva.com`); we
  query mail addressed to that alias, received within a recent window, and return
  a normalized map per email for `Extractor`. Filtering on the alias (rather than a
  folder) is robust to whether the filing rule is active.

  Needs a Fastmail API token in `FASTMAIL_API_TOKEN`
  (Fastmail → Settings → Privacy & Security → API tokens; read-only mail scope).
  """

  require Logger

  @session_url "https://api.fastmail.com/jmap/session"
  @alias "newslettersubs@zyzyva.com"
  @lookback_days 45
  @limit 25

  @doc "Returns {:ok, [email_map]} | {:error, reason}. email_map matches Extractor input."
  def recent_newsletters(opts \\ []) do
    with {:ok, token} <- token(),
         {:ok, %{api_url: api_url, account_id: account_id}} <- session(token),
         {:ok, emails} <- query(api_url, account_id, token, opts) do
      {:ok, Enum.map(emails, &normalize/1)}
    end
  end

  defp token do
    case System.get_env("FASTMAIL_API_TOKEN") do
      nil -> {:error, :no_fastmail_token}
      "" -> {:error, :no_fastmail_token}
      t -> {:ok, t}
    end
  end

  defp session(token) do
    case Req.get(@session_url, headers: auth(token), receive_timeout: 30_000) do
      {:ok, %{status: 200, body: %{"apiUrl" => api_url, "primaryAccounts" => accts}}} ->
        {:ok, %{api_url: api_url, account_id: accts["urn:ietf:params:jmap:mail"]}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:jmap_session, status, body}}

      {:error, e} ->
        {:error, e}
    end
  end

  defp query(api_url, account_id, token, opts) do
    lookback = Keyword.get(opts, :lookback_days, @lookback_days)
    after_date = DateTime.utc_now() |> DateTime.add(-lookback, :day) |> DateTime.to_iso8601()

    request = %{
      using: ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"],
      methodCalls: [
        [
          "Email/query",
          %{
            accountId: account_id,
            filter: %{to: @alias, after: after_date},
            sort: [%{property: "receivedAt", isAscending: false}],
            limit: Keyword.get(opts, :limit, @limit)
          },
          "q"
        ],
        [
          "Email/get",
          %{
            accountId: account_id,
            "#ids": %{resultOf: "q", name: "Email/query", path: "/ids"},
            properties: ["subject", "receivedAt", "textBody", "htmlBody", "bodyValues", "from"],
            fetchTextBodyValues: true,
            fetchHTMLBodyValues: true
          },
          "g"
        ]
      ]
    }

    case Req.post(api_url, json: request, headers: auth(token), receive_timeout: 60_000) do
      {:ok, %{status: 200, body: %{"methodResponses" => responses}}} ->
        {:ok, extract_list(responses)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:jmap_query, status, body}}

      {:error, e} ->
        {:error, e}
    end
  end

  defp extract_list(responses) do
    Enum.find_value(responses, [], fn
      ["Email/get", %{"list" => list}, "g"] -> list
      _ -> false
    end)
  end

  defp normalize(email) do
    body_values = Map.get(email, "bodyValues", %{})
    text = part_value(email["textBody"], body_values)
    html = part_value(email["htmlBody"], body_values)

    %{
      id: email["id"],
      source: source_of(text <> html),
      subject: clean_subject(email["subject"]),
      received_at: email["receivedAt"],
      text: text,
      image_urls: content_images(html)
    }
  end

  defp part_value(nil, _values), do: ""

  defp part_value(parts, values) do
    parts
    |> Enum.map(fn %{"partId" => id} -> get_in(values, [id, "value"]) || "" end)
    |> Enum.join("\n")
  end

  defp content_images(html) do
    ~r/https:\/\/(?:mcusercontent\.com|files\.constantcontact\.com)\/[^\s"'<>)]+/
    |> Regex.scan(html)
    |> Enum.map(&List.first/1)
    |> Enum.reject(&decorative?/1)
    |> Enum.uniq()
  end

  # Drop logos, social icons, spacers, tracking pixels — they hold no event data.
  defp decorative?(url) do
    url =~ ~r/social|icon|spacer|logo|tracking|open\.php|\/S\.gif/i
  end

  defp source_of(blob) do
    cond do
      blob =~ "elizabethtonchamber.com" -> "Elizabethton Chamber"
      blob =~ "johnsoncitytnchamber.com" -> "Johnson City Chamber"
      blob =~ "incredibletowns.com" -> "Incredible Towns"
      true -> "Chamber Newsletter"
    end
  end

  defp clean_subject(nil), do: ""
  defp clean_subject(s), do: String.replace(s, ~r/^(Fwd:\s*)+/i, "")

  defp auth(token), do: [{"authorization", "Bearer #{token}"}]
end
