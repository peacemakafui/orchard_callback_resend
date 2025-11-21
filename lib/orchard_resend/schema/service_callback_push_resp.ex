# defmodule OrchardResend.Schema.ServiceCallbackPushResp do
#   use Ecto.Schema

#   @primary_key {:id, :id, autogenerate: true}
#   schema "service_callback_push_resp" do
#     field :entity_service_id, :integer
#     field :exttrid, :string
#     field :response_message, :string
#     field :created_at, :naive_datetime
#   end
# end

defmodule OrchardResend.Schema.ServiceCallbackPushResp do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "service_callback_push_resp" do
    field :entity_service_id, :integer
    field :exttrid, :string
    field :response_msg, :string
    field :created_at, :naive_datetime
  end

  def changeset(resp, attrs) do
    resp
    |> cast(attrs, [:entity_service_id, :exttrid, :response_msg])
    |> validate_required([:entity_service_id, :exttrid])
    |> unique_constraint([:entity_service_id, :exttrid])
  end
end
