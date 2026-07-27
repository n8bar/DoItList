defmodule DoitMcp.Redaction do
  @moduledoc """
  The one place credential shapes are named, shared by everything that
  writes them out: the per-session frame log (`DoitMcp.FrameLog`, m03.04
  item 23.5) and the Logger primary filter (`DoitMcp.LogRedaction`, item
  23.7).

  Two credentials exist on this service — the session's bearer header and
  the 401-recovery form's pasted `token` field — and they arrive in two
  shapes: as a field of a decoded term, and as text some dep has already
  formatted. Hence the split below: `replacement_for/1` decides by field
  name, `redact_value/1` replaces a value that IS a bearer header, and
  `scrub_text/1` finds both inside formatted text.
  """

  @redacted "[redacted]"
  @redacted_bearer "Bearer [redacted]"

  # A whole value that is itself a bearer header.
  @bearer_value ~r/\ABearer\s+\S+/

  # The same header inside formatted text. The charset is RFC 6750's
  # b64token, which stops the match at the quote or brace that follows it.
  @bearer_text ~r/Bearer\s+[A-Za-z0-9\-._~+\/]+=*/

  # The recovery form's answer once a dep has inspected or encoded it —
  # `"token" => "..."`, `token: "..."`, `"token": "..."`. The word boundary
  # keeps unrelated `*_token` fields out of it.
  @token_text ~r/((?:"token"|'token'|\btoken)\s*(?:=>|:)\s*)"(?:[^"\\]|\\.)*"/

  @doc "The redaction marker for a value with no bearer prefix to keep."
  @spec redacted() :: String.t()
  def redacted, do: @redacted

  @doc "The redaction marker that keeps a bearer header readable as one."
  @spec redacted_bearer() :: String.t()
  def redacted_bearer, do: @redacted_bearer

  @doc """
  The replacement for a credential-named field, or `nil` for a field that
  carries no credential. Field names match in any casing, as string or atom.
  """
  @spec replacement_for(term()) :: String.t() | nil
  def replacement_for(key) when is_binary(key), do: by_name(String.downcase(key))

  def replacement_for(key) when is_atom(key),
    do: key |> Atom.to_string() |> String.downcase() |> by_name()

  def replacement_for(_key), do: nil

  defp by_name("authorization"), do: @redacted_bearer
  defp by_name("token"), do: @redacted
  defp by_name(_other), do: nil

  @doc """
  Replace a value that IS a bearer header; anything else passes through.
  """
  @spec redact_value(term()) :: term()
  def redact_value(value) when is_binary(value) do
    if Regex.match?(@bearer_value, value), do: @redacted_bearer, else: value
  end

  def redact_value(value), do: value

  @doc """
  Replace every credential inside already-formatted text, leaving the rest
  of the line as it was.
  """
  @spec scrub_text(binary()) :: binary()
  def scrub_text(text) when is_binary(text) do
    if String.valid?(text) do
      text
      |> then(&Regex.replace(@bearer_text, &1, @redacted_bearer))
      |> then(&Regex.replace(@token_text, &1, "\\1\"#{@redacted}\""))
    else
      # Regexes need valid UTF-8; raw bytes that still smell of a credential
      # go whole rather than unscanned.
      if credentialish?(text), do: @redacted, else: text
    end
  end

  defp credentialish?(bytes) do
    Enum.any?(["Bearer", "token"], &(:binary.match(bytes, &1) != :nomatch))
  end
end
