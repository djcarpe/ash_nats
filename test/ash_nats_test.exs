defmodule AshNatsTest do
  use ExUnit.Case, async: true

  defmodule Order do
    use Ash.Resource,
      domain: AshNatsTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshNats]

    nats do
      connection :gnat_test
      subject_prefix "test.sales"

      publish_all :create, ["orders", :id, "created"]
      publish :update, ["orders", :id, "updated"]

      expose :read, subject: "orders.list"
      expose :create, subject: "orders.create", endpoint: "order_create"
    end

    attributes do
      uuid_primary_key :id
      attribute :status, :string, public?: true
    end

    actions do
      defaults [:read, :create, :update, :destroy]
      default_accept [:status]
    end
  end

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshNatsTest.Order
    end
  end

  defmodule Service do
    use AshNats.Rpc.Service,
      name: "test-sales",
      version: "1.0.0",
      description: "test service",
      domains: [AshNatsTest.Domain]
  end

  describe "introspection" do
    test "notifier is injected" do
      assert AshNats.Notifier in Ash.Resource.Info.notifiers(Order)
    end

    test "publications are configured" do
      assert [_, _] = AshNats.Info.publications(Order)
    end

    test "exposure subjects include the prefix" do
      subjects =
        Order
        |> AshNats.Info.exposures()
        |> Enum.map(&AshNats.Info.exposure_subject(Order, &1))

      assert "test.sales.orders.list" in subjects
      assert "test.sales.orders.create" in subjects
    end

    test "connection and prefix resolve" do
      assert AshNats.Info.connection(Order) == :gnat_test
      assert AshNats.Info.subject_prefix(Order) == "test.sales"
    end
  end

  describe "service registration" do
    test "service_definition maps exposures to endpoints" do
      definition = Service.service_definition()

      assert %{name: "test-sales", version: "1.0.0", description: "test service"} = definition

      assert %{
               name: "order_read",
               subject: "test.sales.orders.list",
               metadata: %{"resource" => "order", "action" => "read"}
             } in definition.endpoints

      assert %{
               name: "order_create",
               subject: "test.sales.orders.create",
               metadata: %{"resource" => "order", "action" => "create"}
             } in definition.endpoints
    end

    test "service definition passes gnat's validation" do
      assert {:ok, _service} = Gnat.Services.Service.init(Service.service_definition())
    end

    test "child_spec starts a Gnat.ConsumerSupervisor with the service definition" do
      assert %{
               id: Service,
               start: {Gnat.ConsumerSupervisor, :start_link, [settings, []]}
             } = Service.child_spec(connection_name: :gnat_test)

      assert settings.module == Service
      assert settings.connection_name == :gnat_test
      assert settings.service_definition == Service.service_definition()
    end

    test "endpoint names default to <resource>_<action>, sanitized" do
      assert AshNats.Info.exposure_endpoint(Order, %AshNats.Exposure{action: :read}) ==
               "order_read"

      assert AshNats.Info.exposure_endpoint(Order, %AshNats.Exposure{action: :"weird action?"}) ==
               "order_weird_action_"

      assert AshNats.Info.exposure_endpoint(Order, %AshNats.Exposure{
               action: :read,
               endpoint: "custom"
             }) == "custom"
    end

    test "explicit endpoint names are rejected by the verifier" do
      dsl_state =
        put_in(
          Order.spark_dsl_config(),
          [[:nats], :entities],
          [%AshNats.Exposure{action: :read, endpoint: "has.dots"}]
        )

      assert {:error, %Spark.Error.DslError{} = error} =
               AshNats.Verifiers.VerifyActions.verify(dsl_state)

      assert Exception.message(error) =~ "not a valid NATS service endpoint name"
    end
  end

  describe "serializer" do
    test "serializes public attributes to string-keyed maps" do
      {:ok, order} =
        Order
        |> Ash.Changeset.for_create(:create, %{status: "open"})
        |> Ash.create()

      map = AshNats.Serializer.serialize(order)
      assert map["status"] == "open"
      assert is_binary(map["id"])
    end
  end
end
