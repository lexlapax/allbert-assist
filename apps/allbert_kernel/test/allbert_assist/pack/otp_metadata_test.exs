defmodule AllbertAssist.Pack.OTPMetadataTest do
  use ExUnit.Case, async: false
  @moduletag :home_fs_serial

  alias AllbertAssist.Pack.Kernel
  alias AllbertAssist.Pack.OTPMetadata
  alias AllbertAssist.Pack.OTPMetadata.ApplicationSpec
  alias AllbertAssist.Pack.OTPMetadata.ReleaseApplication
  alias AllbertAssist.Pack.OTPMetadata.ReleaseSpec

  test "parses one raw application term without losing Pack identity" do
    term =
      {:application, :allbert_kernel,
       [
         vsn: ~c"1.3.2",
         modules: [AllbertAssist.Pack, AllbertAssist.Pack.Descriptor, Kernel],
         applications: [:kernel, :stdlib, :elixir, :logger],
         env: [allbert_pack: Kernel]
       ]}

    assert {:ok,
            %ApplicationSpec{
              application: :allbert_kernel,
              version: "1.3.2",
              modules: [AllbertAssist.Pack, AllbertAssist.Pack.Descriptor, Kernel],
              applications: [:kernel, :stdlib, :elixir, :logger],
              included_applications: [],
              pack_module: Kernel,
              sha256: nil,
              raw_spec: ^term
            }} = OTPMetadata.parse_app(term)

    assert {:error, {:invalid_app, :duplicate_property}} =
             OTPMetadata.parse_app(
               {:application, :duplicate, [vsn: ~c"1", vsn: ~c"2", modules: [], env: []]}
             )

    assert {:error, {:invalid_app, :pack_module_not_owned}} =
             OTPMetadata.parse_app(
               {:application, :unowned, [vsn: ~c"1", modules: [], env: [allbert_pack: Kernel]]}
             )

    assert {:error, {:invalid_app, :pack_module}} =
             OTPMetadata.parse_app(
               {:application, :nil_pack,
                [vsn: ~c"1", modules: [Kernel], env: [allbert_pack: nil]]}
             )

    assert {:error, {:invalid_app, :atom_list}} =
             OTPMetadata.parse_app(
               {:application, :included,
                [vsn: ~c"1", modules: [], included_applications: ["not-an-atom"], env: []]}
             )
  end

  test "rejects pseudo-atoms as OTP application identities" do
    assert {:error, {:invalid_app, :shape}} =
             OTPMetadata.parse_app({:application, nil, [vsn: ~c"1", modules: [], env: []]})
  end

  test "rejects pseudo-atoms from application atom lists" do
    for field <- [:modules, :applications, :included_applications],
        pseudo_atom <- [nil, true, false] do
      properties =
        [
          vsn: ~c"1",
          modules: [],
          applications: [],
          included_applications: [],
          env: []
        ]
        |> Keyword.put(field, [pseudo_atom])

      assert {:error, {:invalid_app, :atom_list}} =
               OTPMetadata.parse_app({:application, :valid_application, properties})
    end
  end

  test "parses optional applications and defaults them to an empty list" do
    assert {:ok, %ApplicationSpec{optional_applications: [:inets]}} =
             OTPMetadata.parse_app(
               {:application, :valid_application,
                [
                  vsn: ~c"1",
                  modules: [],
                  applications: [:kernel, :inets],
                  optional_applications: [:inets],
                  env: []
                ]}
             )

    assert {:ok, %ApplicationSpec{optional_applications: []}} =
             OTPMetadata.parse_app(
               {:application, :valid_application,
                [vsn: ~c"1", modules: [], applications: [:kernel], env: []]}
             )
  end

  test "requires optional applications to be a unique valid atom list" do
    for malformed <- [[nil], [true], [false], ["inets"], [:inets, :inets]] do
      assert {:error, {:invalid_app, :atom_list}} =
               OTPMetadata.parse_app(
                 {:application, :valid_application,
                  [
                    vsn: ~c"1",
                    modules: [],
                    applications: [:inets],
                    optional_applications: malformed,
                    env: []
                  ]}
               )
    end

    assert {:error, {:invalid_app, :optional_applications}} =
             OTPMetadata.parse_app(
               {:application, :valid_application,
                [
                  vsn: ~c"1",
                  modules: [],
                  applications: [:inets],
                  optional_applications: :inets,
                  env: []
                ]}
             )
  end

  test "requires optional applications to be declared application dependencies" do
    assert {:error, {:invalid_app, :optional_applications_not_subset}} =
             OTPMetadata.parse_app(
               {:application, :valid_application,
                [
                  vsn: ~c"1",
                  modules: [],
                  applications: [:kernel],
                  optional_applications: [:inets],
                  env: []
                ]}
             )
  end

  test "normalizes every legal release application tuple without hiding start modes" do
    term =
      {:release, {~c"allbert", ~c"1.3.2"}, {:erts, ~c"16.1"},
       [
         {:allbert_kernel, ~c"1.3.2"},
         {:allbert_assist, ~c"1.3.2", :permanent},
         {:allbert_composition, ~c"1.3.2", [:allbert_assist]},
         {:allbert_assist_web, ~c"1.3.2", :permanent, [:allbert_assist]}
       ]}

    assert {:ok,
            %ReleaseSpec{
              name: "allbert",
              version: "1.3.2",
              erts_version: "16.1",
              applications: [
                %ReleaseApplication{
                  application: :allbert_kernel,
                  version: "1.3.2",
                  start_mode: :permanent,
                  included_applications: []
                },
                %ReleaseApplication{
                  application: :allbert_assist,
                  version: "1.3.2",
                  start_mode: :permanent,
                  included_applications: []
                },
                %ReleaseApplication{
                  application: :allbert_composition,
                  version: "1.3.2",
                  start_mode: :permanent,
                  included_applications: [:allbert_assist]
                },
                %ReleaseApplication{
                  application: :allbert_assist_web,
                  version: "1.3.2",
                  start_mode: :permanent,
                  included_applications: [:allbert_assist]
                }
              ]
            }} = OTPMetadata.parse_rel(term)

    assert {:error, {:invalid_rel, :duplicate_application}} =
             OTPMetadata.parse_rel(
               {:release, {~c"dup", ~c"1"}, {:erts, ~c"16"},
                [
                  {:duplicate, ~c"1"},
                  {:duplicate, ~c"1"}
                ]}
             )
  end

  test "rejects pseudo-atoms as release application identities" do
    for pseudo_atom <- [nil, true, false] do
      assert {:error, {:invalid_rel, :application_tuple}} =
               OTPMetadata.parse_rel(
                 {:release, {~c"allbert", ~c"1"}, {:erts, ~c"16"},
                  [
                    {pseudo_atom, ~c"1"}
                  ]}
               )
    end
  end

  test "rejects pseudo-atoms from release included-application lists" do
    for pseudo_atom <- [nil, true, false] do
      assert {:error, {:invalid_rel, :included_applications}} =
               OTPMetadata.parse_rel(
                 {:release, {~c"allbert", ~c"1"}, {:erts, ~c"16"},
                  [
                    {:allbert_kernel, ~c"1", [pseudo_atom]}
                  ]}
               )
    end
  end

  test "binds parsed bytes to a digest and rejects effective Pack overrides" do
    path =
      Path.join(
        System.tmp_dir!(),
        "allbert-v14-m1a1-#{System.unique_integer([:positive, :monotonic])}.app"
      )

    bytes =
      "{application,allbert_kernel,[{vsn,\"1.3.2\"}," <>
        "{modules,['Elixir.AllbertAssist.Pack.Kernel']},{applications,[]}," <>
        "{env,[{allbert_pack,'Elixir.AllbertAssist.Pack.Kernel'}]}]}.\n"

    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %ApplicationSpec{sha256: sha256} = application} = OTPMetadata.read_app(path)
    assert sha256 == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    assert :ok =
             OTPMetadata.verify_effective_pack(application, fn :allbert_kernel, :allbert_pack ->
               {:ok, Kernel}
             end)

    assert {:error,
            {:effective_pack_override, :allbert_kernel, Kernel, AllbertAssist.Pack.Descriptor}} =
             OTPMetadata.verify_effective_pack(application, fn :allbert_kernel, :allbert_pack ->
               {:ok, AllbertAssist.Pack.Descriptor}
             end)

    descriptorless = %{application | pack_module: nil}

    assert :ok = OTPMetadata.verify_effective_pack(descriptorless, fn _, _ -> :error end)

    assert {:error, {:unexpected_effective_pack, :allbert_kernel, Kernel}} =
             OTPMetadata.verify_effective_pack(descriptorless, fn _, _ -> {:ok, Kernel} end)
  end

  test "reads one raw release term and binds its exact bytes" do
    path =
      Path.join(
        System.tmp_dir!(),
        "allbert-v14-m1a1-#{System.unique_integer([:positive, :monotonic])}.rel"
      )

    bytes = ~s({release,{"allbert","1.3.2"},{erts,"16.1"},[{allbert_kernel,"1.3.2"}]}.
)

    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)

    assert {:ok,
            %ReleaseSpec{
              name: "allbert",
              sha256: sha256,
              applications: [
                %ReleaseApplication{
                  application: :allbert_kernel,
                  start_mode: :permanent
                }
              ]
            }} = OTPMetadata.read_rel(path)

    assert sha256 == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  end

  test "a sealed app digest is checked before textual atoms are scanned" do
    atom_name =
      "allbert_untrusted_atom_#{System.unique_integer([:positive, :monotonic])}"

    path = Path.join(System.tmp_dir!(), "#{atom_name}.app")
    bytes = "{application,#{atom_name},[]}.\n"
    expected = String.duplicate("0", 64)
    actual = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)

    assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end

    for malformed <- [nil, "not-a-sha", String.duplicate("A", 64)] do
      assert {:error, {:invalid_app_file, :expected_sha256}} =
               OTPMetadata.read_sealed_app(path, malformed)

      assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end
    end

    assert {:error, {:app_digest_mismatch, ^expected, ^actual}} =
             OTPMetadata.read_sealed_app(path, expected)

    assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end
  end

  test "OTP metadata readers reject symbolic links" do
    suffix = System.unique_integer([:positive, :monotonic])
    target = Path.join(System.tmp_dir!(), "allbert-v14-m1a1-target-#{suffix}.app")
    link = Path.join(System.tmp_dir!(), "allbert-v14-m1a1-link-#{suffix}.app")

    File.write!(target, "{application,allbert_kernel,[{vsn,\"1.3.2\"}]}.\n")
    File.ln_s!(target, link)

    on_exit(fn ->
      File.rm(link)
      File.rm(target)
    end)

    assert {:error, {:invalid_app_file, {:not_regular, :symlink}}} =
             OTPMetadata.read_app(link)
  end

  test "OTP metadata readers reject oversized regular files" do
    path =
      Path.join(
        System.tmp_dir!(),
        "allbert-v14-m1a1-large-#{System.unique_integer([:positive, :monotonic])}.app"
      )

    File.write!(path, :binary.copy("x", 1_048_577))
    on_exit(fn -> File.rm(path) end)

    assert {:error, {:invalid_app_file, {:too_large, 1_048_577}}} =
             OTPMetadata.read_app(path)
  end
end
