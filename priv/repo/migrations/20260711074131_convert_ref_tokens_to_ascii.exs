defmodule DoIt.Repo.Migrations.ConvertRefTokensToAscii do
  use Ecto.Migration

  # The cross-reference token's canonical form becomes ASCII `%<id>`; the Unicode
  # `%⟨id⟩` (U+27E8/U+27E9) form is abandoned (m03.03). Convert every stored token
  # in the text columns where tokens are valid content. Escaped refs (`\%⟨id⟩`)
  # convert too — the glyphs are abandoned everywhere, and the leading `\` keeps
  # the converted form escaped identically.

  @token_columns [
    {"tasks", "title"},
    {"tasks", "description"},
    {"comments", "body"},
    {"comment_versions", "body"},
    {"initiatives", "description"}
  ]

  def up do
    Enum.each(@token_columns, fn {table, column} ->
      execute("""
      UPDATE #{table}
      SET #{column} = regexp_replace(#{column}, '%⟨(\\d+)⟩', '%<\\1>', 'g')
      WHERE #{column} LIKE '%⟨%'
      """)
    end)
  end

  def down do
    Enum.each(@token_columns, fn {table, column} ->
      execute("""
      UPDATE #{table}
      SET #{column} = regexp_replace(#{column}, '%<(\\d+)>', '%⟨\\1⟩', 'g')
      WHERE #{column} LIKE '%<%'
      """)
    end)
  end
end
