defmodule OrchardResend.Schema.ServiceCallbackPushReq do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  schema "service_callback_push_req" do
    field :entity_service_id, :integer
    field :payload, :string
    field :callback_url, :string
    field :exttrid, :string
    field :attempts, :integer
    field :status, :boolean

    has_many :resend_callbacks, OrchardResend.Schema.ResendCallback, foreign_key: :callback_req_id

    field :created_at, :naive_datetime
    field :updated_at, :naive_datetime
  end
end
