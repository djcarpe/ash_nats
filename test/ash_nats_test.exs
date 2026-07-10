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
      expose :read, subject: "orders.get", get?: true, endpoint: "order_get", load: [:shouty]
      expose :create, subject: "orders.create", endpoint: "order_create"
      expose :boom, subject: "orders.boom"
    end

    attributes do
      uuid_primary_key :id
      attribute :status, :string, public?: true
    end

    calculations do
      calculate :shouty, :string, expr(status <> "!"), public?: true
    end

    actions do
      defaults [:read, :create, :update, :destroy]
      default_accept [:status]

      update :cancel do
        change set_attribute(:status, "cancelled")
      end

      action :boom, :string do
        run fn _input, _ctx -> raise "kaboom secret detail" end
      end
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

  defmodule Rpc do
    use AshNats.Rpc.Server, domains: [AshNatsTest.Domain]
  end

  defmodule DomainWithDefaults do
    use Ash.Domain, validate_config_inclusion?: false, extensions: [AshNats.Domain]

    nats do
      connection :gnat_domain
      subject_prefix "test.defaults"
    end

    resources do
      resource AshNatsTest.Widget
    end
  end

  defmodule Widget do
    use Ash.Resource,
      domain: AshNatsTest.DomainWithDefaults,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshNats]

    nats do
      expose :read
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :create]
    end
  end

  defp request(subject, input) do
    {:reply, binary} =
      AshNats.Rpc.Server.handle_request([Domain], [passthrough_headers: []], %{
        topic: subject,
        body: Jason.encode!(input)
      })

    Jason.decode!(binary)
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

    test "domain-level defaults apply when the resource doesn't configure them" do
      assert AshNats.Info.connection(Widget) == :gnat_domain
      assert AshNats.Info.subject_prefix(Widget) == "test.defaults"
      assert AshNats.Info.encoder(Widget) == AshNats.Encoder.Json

      exposure = List.first(AshNats.Info.exposures(Widget))
      assert AshNats.Info.exposure_subject(Widget, exposure) == "test.defaults.read"
    end
  end

  describe "publication matching" do
    test "publish matches by name, or by type when given a type atom" do
      cancel = Ash.Resource.Info.action(Order, :cancel)
      update = Ash.Resource.Info.action(Order, :update)

      # type atom matches every action of that type (cancel is an update)
      assert AshNats.Notifier.matches?(%AshNats.Publication{action: :update}, cancel)
      assert AshNats.Notifier.matches?(%AshNats.Publication{action: :update}, update)
      # non-type atoms match by name only
      assert AshNats.Notifier.matches?(%AshNats.Publication{action: :cancel}, cancel)
      refute AshNats.Notifier.matches?(%AshNats.Publication{action: :cancel}, update)
      refute AshNats.Notifier.matches?(%AshNats.Publication{action: :create}, cancel)
    end

    test "publish_all matches by action type" do
      cancel = Ash.Resource.Info.action(Order, :cancel)

      assert AshNats.Notifier.matches?(
               %AshNats.Publication{action: :update, all?: true},
               cancel
             )

      refute AshNats.Notifier.matches?(
               %AshNats.Publication{action: :create, all?: true},
               cancel
             )
    end
  end

  describe "request handling" do
    test "get? exposure filters by primary key from the input" do
      order = Ash.create!(Ash.Changeset.for_create(Order, :create, %{status: "open"}))
      _other = Ash.create!(Ash.Changeset.for_create(Order, :create, %{status: "other"}))

      assert %{"ok" => true, "data" => data} =
               request("test.sales.orders.get", %{"id" => order.id})

      assert data["id"] == order.id
      assert data["status"] == "open"
    end

    test "load option includes calculations in the reply" do
      order = Ash.create!(Ash.Changeset.for_create(Order, :create, %{status: "open"}))

      assert %{"ok" => true, "data" => data} =
               request("test.sales.orders.get", %{"id" => order.id})

      assert data["shouty"] == "open!"
    end

    test "emits rpc telemetry" do
      handler = "ash-nats-test-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        [:ash_nats, :rpc, :stop],
        fn _event, _measurements, metadata, _config -> send(parent, {:rpc_stop, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      request("test.sales.orders.list", %{})

      assert_received {:rpc_stop, %{resource: Order, action: :read, ok?: true}}
    end
  end

  describe "error replies" do
    test "invalid input returns structured errors without internals" do
      assert %{"ok" => false, "error" => error} =
               request("test.sales.orders.create", %{"nope" => 1})

      assert error["class"] == "invalid"
      assert [%{"message" => message} | _] = error["errors"]
      assert message =~ "No such input"
      refute error["message"] =~ "Bread Crumbs"
      refute error["message"] =~ ~r/\.exs?:\d/
    end

    test "crashes reply with a generic message" do
      assert %{"ok" => false, "error" => error} = request("test.sales.orders.boom", %{})

      assert error["class"] == "unknown"
      assert error["message"] == "something went wrong"
      refute inspect(error) =~ "kaboom"
    end

    test "undecodable payloads reply invalid_request" do
      {:reply, binary} =
        AshNats.Rpc.Server.handle_request([Domain], [], %{
          topic: "test.sales.orders.create",
          body: "{not json"
        })

      assert %{"ok" => false, "error" => %{"class" => "invalid_request"}} =
               Jason.decode!(binary)
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
  end

  describe "verifiers" do
    defp verify_with(entities) do
      dsl_state = put_in(Order.spark_dsl_config(), [[:nats], :entities], entities)
      AshNats.Verifiers.VerifyActions.verify(dsl_state)
    end

    test "explicit endpoint names are rejected" do
      assert {:error, error} =
               verify_with([%AshNats.Exposure{action: :read, endpoint: "has.dots"}])

      assert Exception.message(error) =~ "not a valid NATS service endpoint name"
    end

    test "duplicate exposure subjects are rejected" do
      assert {:error, error} =
               verify_with([
                 %AshNats.Exposure{action: :read, subject: "orders.same"},
                 %AshNats.Exposure{action: :create, subject: "orders.same"}
               ])

      assert Exception.message(error) =~ "exposed by both"
    end

    test "get? on a non-read action is rejected" do
      assert {:error, error} = verify_with([%AshNats.Exposure{action: :create, get?: true}])
      assert Exception.message(error) =~ "only supported on read actions"
    end

    test "unknown identities are rejected" do
      assert {:error, error} =
               verify_with([%AshNats.Exposure{action: :read, identity: :nope}])

      assert Exception.message(error) =~ "not an identity"
    end

    test "publish segments must be resource fields" do
      assert {:error, error} =
               verify_with([%AshNats.Publication{action: :update, subject: ["orders", :nope]}])

      assert Exception.message(error) =~ "not a field"
    end

    test "publish must name an action, publish_all a type" do
      assert {:error, error} =
               verify_with([%AshNats.Publication{action: :create_thing, subject: "s"}])

      assert Exception.message(error) =~ "not an action"

      assert {:error, error} =
               verify_with([%AshNats.Publication{action: :cancel, all?: true, subject: "s"}])

      assert Exception.message(error) =~ "not an action type"
    end
  end

  describe "serializer" do
    test "serializes public attributes to string-keyed maps" do
      order =
        Order
        |> Ash.Changeset.for_create(:create, %{status: "open"})
        |> Ash.create!()

      map = AshNats.Serializer.serialize(order)
      assert map["status"] == "open"
      assert is_binary(map["id"])
    end

    test "omits unloaded calculations, includes loaded ones" do
      order =
        Order
        |> Ash.Changeset.for_create(:create, %{status: "open"})
        |> Ash.create!()

      refute Map.has_key?(AshNats.Serializer.serialize(order), "shouty")

      loaded = Ash.load!(order, [:shouty])
      assert AshNats.Serializer.serialize(loaded)["shouty"] == "open!"
    end
  end
end
