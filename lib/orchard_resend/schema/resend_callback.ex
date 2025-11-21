defmodule OrchardResend.Schema.ResendCallback do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "resend_callback" do
    field :entity_service_id, :integer
    field :exttrid, :string
    field :response, :string
    field :status, :string
    field :http_status, :integer

    belongs_to :callback_req, OrchardResend.Schema.ServiceCallbackPushReq, foreign_key: :callback_req_id

    field :created_at, :naive_datetime
    field :updated_at, :naive_datetime
  end

  def changeset(resend_callback, attrs) do
    resend_callback
    |> cast(attrs, [:entity_service_id, :exttrid, :response, :status, :http_status, :callback_req_id])
    |> validate_required([:entity_service_id, :response, :status, :callback_req_id])
    |> foreign_key_constraint(:callback_req_id)
  end
end
