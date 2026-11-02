defmodule ClementineSmoke.Repo.Migrations.CreateConversationMessages do
  use Ecto.Migration

  def change do
    create table(:conversation_messages) do
      add(:conversation_id, :string, null: false)
      add(:turn, :string)
      add(:message, :map, null: false)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:conversation_messages, [:conversation_id]))
    create(unique_index(:conversation_messages, [:conversation_id, :turn]))
  end
end
