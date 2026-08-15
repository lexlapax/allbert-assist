defmodule AllbertAssist.Pack.ProjectionTest.NativePack do
  alias AllbertAssist.Pack.Descriptor

  def descriptor do
    %Descriptor{
      schema_version: 1,
      id: "native_pack",
      application: :native_pack,
      application_version: "1.4.0",
      capability_tier: :native,
      provenance: %{source: :signed_release, component: "beam-native-pack"},
      registry_order: 100
    }
  end
end

defmodule AllbertAssist.Pack.ProjectionTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.Pack.Kernel
  alias AllbertAssist.Pack.OTPMetadata.ApplicationSpec
  alias AllbertAssist.Pack.OTPMetadata.ReleaseApplication
  alias AllbertAssist.Pack.OTPMetadata.ReleaseSpec
  alias AllbertAssist.Pack.Projection
  alias AllbertAssist.Pack.Projection.Closed
  alias AllbertAssist.Pack.Projection.Row
  alias AllbertAssist.Pack.ProjectionTest.NativePack

  test "reconciles source rows with trusted app, release, and descriptor records" do
    applications = [
      app(:allbert_kernel, Kernel),
      app(:native_pack, NativePack),
      app(:allbert_composition, nil),
      app(:allbert_assist_web, nil)
    ]

    release =
      %ReleaseSpec{
        name: "allbert",
        version: "1.4.0",
        erts_version: "16.1",
        applications:
          Enum.map(applications, fn application ->
            %ReleaseApplication{
              application: application.application,
              version: application.version,
              start_mode: :permanent,
              included_applications: []
            }
          end)
      }

    source_rows = [
      source_row(
        "beam-native-pack",
        "native_pack",
        "native_pack",
        NativePack,
        "native_effectful",
        100
      ),
      source_row(
        "beam-allbert-kernel",
        "allbert_kernel",
        "allbert_kernel",
        Kernel,
        "kernel_prerequisite",
        0
      )
    ]

    assert {:error, {:invalid_projection, :closed_applications_required}} =
             Projection.reconcile(source_rows, applications, release,
               effective_env_fetcher: env_fetcher(applications)
             )

    assert {:error, {:invalid_projection, {:missing_effective_pack, :native_pack, NativePack}}} =
             Projection.reconcile(source_rows, applications, release,
               closed_applications: application_names(applications)
             )

    assert {:ok,
            [
              %Row{
                component: "beam-allbert-kernel",
                application: :allbert_kernel,
                id: "allbert_kernel",
                descriptor_module: Kernel,
                startup_role: :kernel_prerequisite,
                registry_order: 0
              },
              %Row{
                component: "beam-native-pack",
                application: :native_pack,
                id: "native_pack",
                descriptor_module: NativePack,
                startup_role: :native_effectful,
                registry_order: 100
              }
            ]} =
             Projection.reconcile(source_rows, applications, release,
               closed_applications: application_names(applications),
               effective_env_fetcher: env_fetcher(applications)
             )
  end

  test "sealed projection digest includes the enclosing application identity" do
    kernel_sha = String.duplicate("a", 64)
    native_sha = String.duplicate("b", 64)

    applications = [
      app(:allbert_kernel, Kernel, kernel_sha),
      app(:native_pack, NativePack, native_sha)
    ]

    release =
      %ReleaseSpec{
        name: "allbert",
        version: "1.4.0",
        erts_version: "16.1",
        applications:
          Enum.map(applications, fn application ->
            %ReleaseApplication{
              application: application.application,
              version: application.version,
              start_mode: :permanent,
              included_applications: []
            }
          end)
      }

    sealed_rows = [
      source_row(
        "beam-native-pack",
        "native_pack",
        "native_pack",
        NativePack,
        "native_effectful",
        100,
        native_sha
      ),
      source_row(
        "beam-allbert-kernel",
        "allbert_kernel",
        "allbert_kernel",
        Kernel,
        "kernel_prerequisite",
        0,
        kernel_sha
      )
    ]

    assert {:ok, rows} =
             Projection.reconcile(sealed_rows, applications, release,
               sealed: true,
               closed_applications: application_names(applications),
               effective_env_fetcher: env_fetcher(applications)
             )

    expected =
      ~s([{"app_sha256":"#{kernel_sha}","application":"allbert_kernel","component":"beam-allbert-kernel","descriptor_module":"Elixir.AllbertAssist.Pack.Kernel","id":"allbert_kernel","registry_order":0,"schema_version":1,"startup_role":"kernel_prerequisite"},{"app_sha256":"#{native_sha}","application":"native_pack","component":"beam-native-pack","descriptor_module":"Elixir.AllbertAssist.Pack.ProjectionTest.NativePack","id":"native_pack","registry_order":100,"schema_version":1,"startup_role":"native_effectful"}])

    assert {:ok, expected} == Projection.canonical_bytes(rows)

    assert {:ok, Base.encode16(:crypto.hash(:sha256, expected), case: :lower)} ==
             Projection.digest(rows)

    [kernel_row, native_row] = rows

    assert {:error, {:invalid_projection, {:duplicate, :id}}} =
             Projection.canonical_bytes([kernel_row, %{native_row | id: kernel_row.id}])

    assert {:error, {:invalid_projection, :canonical_row}} =
             Projection.canonical_bytes([Map.put(kernel_row, :unknown, true)])
  end

  test "sealed reconciliation can bind its complete application closure" do
    kernel_sha = String.duplicate("a", 64)
    native_sha = String.duplicate("b", 64)

    applications = [
      app(:allbert_kernel, Kernel, kernel_sha),
      app(:native_pack, NativePack, native_sha),
      app(:allbert_composition, nil, String.duplicate("c", 64))
    ]

    source_rows = [
      source_row(
        "beam-native-pack",
        "native_pack",
        "native_pack",
        NativePack,
        "native_effectful",
        100,
        native_sha
      ),
      source_row(
        "beam-allbert-kernel",
        "allbert_kernel",
        "allbert_kernel",
        Kernel,
        "kernel_prerequisite",
        0,
        kernel_sha
      )
    ]

    opts = [
      sealed: true,
      closed_applications: application_names(applications),
      effective_env_fetcher: env_fetcher(applications)
    ]

    assert {:ok,
            %Closed{
              schema_version: 1,
              closed_applications: [:allbert_kernel, :native_pack, :allbert_composition],
              pack_applications: [:allbert_kernel, :native_pack],
              rows: rows,
              projection_sha256: projection_sha256,
              closure_sha256: closure_sha256
            } = closed} =
             Projection.reconcile_closed(
               source_rows,
               applications,
               release_for(applications),
               opts
             )

    assert {:ok, ^rows} =
             Projection.reconcile(source_rows, applications, release_for(applications), opts)

    assert {:ok, ^projection_sha256} = Projection.digest(rows)
    assert projection_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert closure_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert :ok = Projection.validate_closed(closed)

    assert {:error, {:invalid_projection, :closed_projection_digest}} =
             closed
             |> Map.update!(:rows, &tl/1)
             |> Projection.validate_closed()

    subset_rows = tl(rows)
    assert {:ok, subset_sha256} = Projection.digest(subset_rows)

    assert {:error, {:invalid_projection, :closed_application_closure}} =
             closed
             |> Map.put(:rows, subset_rows)
             |> Map.put(:projection_sha256, subset_sha256)
             |> Projection.validate_closed()

    extra_component = "beam-extra-pack"
    extra_id = "extra_pack"
    extra_order = 200
    template_row = List.last(rows)

    extra_descriptor = %{
      template_row.descriptor
      | application: :extra_pack,
        id: extra_id,
        provenance: %{source: :signed_release, component: extra_component},
        registry_order: extra_order
    }

    extra_row = %{
      template_row
      | component: extra_component,
        application: :extra_pack,
        id: extra_id,
        descriptor_module: __MODULE__,
        registry_order: extra_order,
        descriptor: extra_descriptor
    }

    rows_with_extra = [extra_row | rows]
    assert {:ok, extra_projection_sha256} = Projection.digest(rows_with_extra)

    assert {:error, {:invalid_projection, :closed_application_closure}} =
             closed
             |> Map.put(:rows, rows_with_extra)
             |> Map.put(:projection_sha256, extra_projection_sha256)
             |> Map.put(
               :closure_sha256,
               closure_digest(
                 closed.closed_applications,
                 closed.pack_applications,
                 extra_projection_sha256
               )
             )
             |> Projection.validate_closed()

    reversed_pack_applications = Enum.reverse(closed.pack_applications)

    assert {:error, {:invalid_projection, :closed_application_closure}} =
             closed
             |> Map.put(:pack_applications, reversed_pack_applications)
             |> Map.put(
               :closure_sha256,
               closure_digest(
                 closed.closed_applications,
                 reversed_pack_applications,
                 closed.projection_sha256
               )
             )
             |> Projection.validate_closed()

    assert {:error, {:invalid_projection, :closed_closure_digest}} =
             closed
             |> Map.put(:closure_sha256, String.duplicate("f", 64))
             |> Projection.validate_closed()

    assert {:error, {:invalid_projection, :closed_shape}} =
             closed
             |> Map.put(:unexpected, true)
             |> Projection.validate_closed()

    assert {:error, {:invalid_projection, :closed_requires_sealed}} =
             Projection.reconcile_closed(
               source_rows,
               applications,
               release_for(applications),
               Keyword.put(opts, :sealed, false)
             )
  end

  test "canonical projection rejects a descriptor that drifts from its reconciled row" do
    projection = sealed_kernel_projection()

    for {field, value, reason} <- [
          {:schema_version, 2, {:descriptor, :schema_version}},
          {:application, :other_application, :descriptor_application},
          {:application_version, "9.9.9", :descriptor_version},
          {:id, "other_id", :descriptor_id},
          {:capability_tier, :native, :descriptor_tier},
          {:provenance, %{source: :signed_release, component: "beam-other"},
           :descriptor_provenance},
          {:registry_order, 1, :descriptor_order}
        ] do
      descriptor = Map.put(projection.descriptor, field, value)
      drifted = %{projection | descriptor: descriptor}

      assert {:error, {:invalid_projection, ^reason}} =
               Projection.canonical_bytes([drifted])

      assert {:error, {:invalid_projection, ^reason}} = Projection.digest([drifted])
    end
  end

  test "an effective application environment cannot replace the raw Pack module" do
    applications = [app(:allbert_kernel, Kernel)]

    release = %ReleaseSpec{
      name: "allbert",
      version: "1.4.0",
      erts_version: "16.1",
      applications: [
        %ReleaseApplication{
          application: :allbert_kernel,
          version: "1.4.0",
          start_mode: :permanent,
          included_applications: []
        }
      ]
    }

    rows = [
      source_row(
        "beam-allbert-kernel",
        "allbert_kernel",
        "allbert_kernel",
        Kernel,
        "kernel_prerequisite",
        0
      )
    ]

    assert {:error,
            {:invalid_projection,
             {:effective_pack_override, :allbert_kernel, Kernel, AllbertAssist.Pack.Descriptor}}} =
             Projection.reconcile(rows, applications, release,
               closed_applications: application_names(applications),
               effective_env_fetcher: fn :allbert_kernel, :allbert_pack ->
                 {:ok, AllbertAssist.Pack.Descriptor}
               end
             )
  end

  test "reconciliation rejects included applications in the raw Pack record" do
    application = %{app(:allbert_kernel, Kernel) | included_applications: [:logger]}
    applications = [application]

    row =
      source_row(
        "beam-allbert-kernel",
        "allbert_kernel",
        "allbert_kernel",
        Kernel,
        "kernel_prerequisite",
        0
      )

    assert {:error, {:invalid_projection, {:raw_included_applications, :allbert_kernel}}} =
             Projection.reconcile([row], applications, release_for(applications),
               closed_applications: application_names(applications),
               effective_env_fetcher: env_fetcher(applications)
             )
  end

  test "reconciliation rejects included applications in the release Pack record" do
    applications = [app(:allbert_kernel, Kernel)]
    release = release_for(applications)
    [release_application] = release.applications

    release = %{
      release
      | applications: [%{release_application | included_applications: [:logger]}]
    }

    row =
      source_row(
        "beam-allbert-kernel",
        "allbert_kernel",
        "allbert_kernel",
        Kernel,
        "kernel_prerequisite",
        0
      )

    assert {:error, {:invalid_projection, {:release_included_applications, :allbert_kernel}}} =
             Projection.reconcile([row], applications, release,
               closed_applications: application_names(applications),
               effective_env_fetcher: env_fetcher(applications)
             )
  end

  test "reconciliation rejects a non-canonical component identity" do
    applications = [app(:allbert_kernel, Kernel)]

    row =
      source_row(
        "beam_allbert_kernel",
        "allbert_kernel",
        "allbert_kernel",
        Kernel,
        "kernel_prerequisite",
        0
      )

    assert {:error, {:invalid_projection, :component}} =
             Projection.reconcile([row], applications, release_for(applications),
               closed_applications: application_names(applications),
               effective_env_fetcher: env_fetcher(applications)
             )
  end

  test "reconciliation rejects a non-canonical application identity" do
    applications = [app(:allbert_kernel, Kernel)]

    row =
      source_row(
        "beam-allbert-kernel",
        "Allbert-Kernel",
        "allbert_kernel",
        Kernel,
        "kernel_prerequisite",
        0
      )

    assert {:error, {:invalid_projection, :application}} =
             Projection.reconcile([row], applications, release_for(applications),
               closed_applications: application_names(applications),
               effective_env_fetcher: env_fetcher(applications)
             )
  end

  test "closed application identity must be canonical before reconciliation" do
    invalid_application = :"Allbert-Kernel"
    application = %{app(:allbert_kernel, Kernel) | application: invalid_application}
    applications = [application]

    assert {:error, {:invalid_projection, :closed_applications}} =
             Projection.reconcile([], applications, release_for(applications),
               closed_applications: [invalid_application],
               effective_env_fetcher: env_fetcher(applications)
             )
  end

  test "reconciliation fails closed when an independent record drifts" do
    sha256 = String.duplicate("a", 64)
    applications = [app(:allbert_kernel, Kernel, sha256)]
    release = release_for(applications)

    row =
      source_row(
        "beam-allbert-kernel",
        "allbert_kernel",
        "allbert_kernel",
        Kernel,
        "kernel_prerequisite",
        0,
        sha256
      )

    opts = [
      sealed: true,
      closed_applications: application_names(applications),
      effective_env_fetcher: env_fetcher(applications)
    ]

    assert {:ok, [_projection]} = Projection.reconcile([row], applications, release, opts)

    assert {:error, {:invalid_projection, :pack_shape}} =
             Projection.reconcile([Map.put(row, "pack", nil)], applications, release, opts)

    row_with_extra_key = put_in(row, ["pack", "unexpected"], true)

    assert {:error, {:invalid_projection, :pack_shape}} =
             Projection.reconcile([row_with_extra_key], applications, release, opts)

    assert {:error, {:invalid_projection, {:descriptor_closure, [:allbert_kernel], []}}} =
             Projection.reconcile([], applications, release, opts)

    wrong_sha_row = put_in(row, ["pack", "app_sha256"], String.duplicate("b", 64))

    assert {:error, {:invalid_projection, {:app_sha256_mismatch, :allbert_kernel}}} =
             Projection.reconcile([wrong_sha_row], applications, release, opts)

    [release_application] = release.applications
    non_permanent = %{release | applications: [%{release_application | start_mode: :transient}]}

    assert {:error, {:invalid_projection, {:non_permanent_pack, :allbert_kernel}}} =
             Projection.reconcile([row], applications, non_permanent, opts)

    missing_release_application = %{release | applications: []}

    assert {:error, {:invalid_projection, {:release_application_closure, [:allbert_kernel], []}}} =
             Projection.reconcile([row], applications, missing_release_application, opts)

    for {field, value, reason} <- [
          {:application, :other_application, :descriptor_application},
          {:application_version, "9.9.9", :descriptor_version},
          {:id, "other_id", :descriptor_id},
          {:registry_order, 1, :descriptor_order},
          {:capability_tier, :native, :descriptor_tier},
          {:provenance, %{source: :signed_release, component: "beam-other"},
           :descriptor_provenance}
        ] do
      descriptor = Map.put(Kernel.descriptor(), field, value)
      drift_opts = Keyword.put(opts, :descriptor_fetcher, fn Kernel -> {:ok, descriptor} end)

      assert {:error, {:invalid_projection, ^reason}} =
               Projection.reconcile([row], applications, release, drift_opts)
    end

    assert {:error,
            {:invalid_projection,
             {:application_closure, [:allbert_kernel, :allbert_composition], [:allbert_kernel]}}} =
             Projection.reconcile(
               [row],
               applications,
               release,
               Keyword.put(opts, :closed_applications, [
                 :allbert_kernel,
                 :allbert_composition
               ])
             )

    duplicate_applications = [
      app(:allbert_kernel, Kernel),
      app(:native_pack, NativePack)
    ]

    duplicate_release = release_for(duplicate_applications)
    kernel_row = Map.delete(row, "pack") |> Map.put("pack", Map.delete(row["pack"], "app_sha256"))

    native_order_row =
      source_row(
        "beam-native-pack",
        "native_pack",
        "native_pack",
        NativePack,
        "native_effectful",
        0
      )

    duplicate_opts = [
      closed_applications: application_names(duplicate_applications),
      effective_env_fetcher: env_fetcher(duplicate_applications),
      descriptor_fetcher: fn
        Kernel -> {:ok, Kernel.descriptor()}
        NativePack -> {:ok, %{NativePack.descriptor() | registry_order: 0}}
      end
    ]

    assert {:error, {:invalid_projection, {:duplicate, :registry_order}}} =
             Projection.reconcile(
               [kernel_row, native_order_row],
               duplicate_applications,
               duplicate_release,
               duplicate_opts
             )

    native_id_row = put_in(native_order_row, ["pack", "id"], "allbert_kernel")

    duplicate_id_opts =
      Keyword.put(duplicate_opts, :descriptor_fetcher, fn
        Kernel -> {:ok, Kernel.descriptor()}
        NativePack -> {:ok, %{NativePack.descriptor() | id: "allbert_kernel"}}
      end)

    assert {:error, {:invalid_projection, {:duplicate, :id}}} =
             Projection.reconcile(
               [kernel_row, put_in(native_id_row, ["pack", "registry_order"], 100)],
               duplicate_applications,
               duplicate_release,
               duplicate_id_opts
             )
  end

  defp app(application, pack_module, sha256 \\ nil) do
    %ApplicationSpec{
      application: application,
      version: "1.4.0",
      modules: if(pack_module, do: [pack_module], else: []),
      applications: [],
      pack_module: pack_module,
      sha256: sha256
    }
  end

  defp sealed_kernel_projection do
    sha256 = String.duplicate("a", 64)
    applications = [app(:allbert_kernel, Kernel, sha256)]

    row =
      source_row(
        "beam-allbert-kernel",
        "allbert_kernel",
        "allbert_kernel",
        Kernel,
        "kernel_prerequisite",
        0,
        sha256
      )

    {:ok, [projection]} =
      Projection.reconcile([row], applications, release_for(applications),
        sealed: true,
        closed_applications: application_names(applications),
        effective_env_fetcher: env_fetcher(applications)
      )

    projection
  end

  defp source_row(
         component,
         application,
         id,
         descriptor_module,
         startup_role,
         order,
         app_sha256 \\ nil
       ) do
    row = %{
      "id" => component,
      "application" => application,
      "pack" => %{
        "schema_version" => 1,
        "id" => id,
        "descriptor_module" => Atom.to_string(descriptor_module),
        "startup_role" => startup_role,
        "registry_order" => order
      }
    }

    if app_sha256,
      do: put_in(row, ["pack", "app_sha256"], app_sha256),
      else: row
  end

  defp env_fetcher(applications) do
    fn application, :allbert_pack ->
      case Enum.find(applications, &(&1.application == application)) do
        %ApplicationSpec{pack_module: nil} -> :error
        %ApplicationSpec{pack_module: module} -> {:ok, module}
      end
    end
  end

  defp application_names(applications), do: Enum.map(applications, & &1.application)

  defp release_for(applications) do
    %ReleaseSpec{
      name: "allbert",
      version: "1.4.0",
      erts_version: "16.1",
      applications:
        Enum.map(applications, fn application ->
          %ReleaseApplication{
            application: application.application,
            version: application.version,
            start_mode: :permanent,
            included_applications: []
          }
        end)
    }
  end

  defp closure_digest(closed_applications, pack_applications, projection_sha256) do
    encode_applications = fn applications ->
      applications
      |> Enum.map(fn application -> [?\", Atom.to_string(application), ?\"] end)
      |> Enum.intersperse(",")
      |> then(&["[", &1, "]"])
    end

    bytes =
      IO.iodata_to_binary([
        ~s({"closed_applications":),
        encode_applications.(closed_applications),
        ~s(,"pack_applications":),
        encode_applications.(pack_applications),
        ~s(,"projection_sha256":"),
        projection_sha256,
        ~s(","schema_version":1})
      ])

    ("allbert.pack.projection-closure.v1\0" <> bytes)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
