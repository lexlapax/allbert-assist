defmodule AllbertAssist.Licenses do
  @moduledoc """
  Offline license catalog, final-artifact generator, verifier, and packaged viewer.

  This is deliberately one pure filesystem concern, not a process, registry,
  database, dependency scanner, or authority service. The reviewed catalog is
  the knowledge boundary. Finalization fails closed for catalogued applications,
  paths, texts, pinned payloads, and declared external-runtime boundaries while
  retaining the honest, bounded claim that arbitrary artifact bytes are not
  recursively attributed.
  """

  import Bitwise, only: [band: 2]

  @catalog_relative "apps/allbert_assist/priv/licenses/catalog.json"
  @union_name "THIRD-PARTY-LICENSES.md"
  @manifest_name "THIRD-PARTY-MANIFEST.json"
  @packaged_catalog "licenses/catalog.json"
  @packaged_text_root "licenses/texts"
  @schema_version 1
  @pack_source_keys ~w(descriptor_module id registry_order schema_version startup_role)
  @pack_manifest_keys ~w(app_sha256 descriptor_module id registry_order schema_version startup_role)
  @pack_startup_roles ~w(kernel_prerequisite native_effectful native_passive)
  @allbert_repository "https://github.com/lexlapax/allbert-assist"
  @pack_id_regex ~r/\A[a-z][a-z0-9]*(?:_[a-z0-9]+)*\z/
  @pack_descriptor_module_regex ~r/\AElixir\.[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*\z/
  @max_metadata_bytes 5_000_000
  @supported_targets ~w(linux-x64 linux-arm64 macos-arm64)
  @target_keys ~w(elixir_version erts_version otp_version triple)
  @warning "Inventory is bounded to reviewed applications and managed paths; " <>
             "unclassified artifact bytes are not recursively attributed."
  @license_expression_terms %{
    "Apache-2.0" => ["Apache-2.0"],
    "BSD-2-Clause" => ["BSD-2-Clause"],
    "BSD-3-Clause" => ["BSD-3-Clause"],
    "ISC" => ["ISC"],
    "LicenseRef-IANA-TZDB" => ["LicenseRef-IANA-TZDB"],
    "LicenseRef-IANA-TZDB AND BSD-3-Clause" => ["LicenseRef-IANA-TZDB", "BSD-3-Clause"],
    "LGPL-2.1-or-later" => ["LGPL-2.1-or-later"],
    "MIT" => ["MIT"],
    "MIT AND Apache-2.0" => ["MIT", "Apache-2.0"],
    "MIT AND LicenseRef-SQLite-Public-Domain" => [
      "MIT",
      "LicenseRef-SQLite-Public-Domain"
    ],
    "MPL-2.0" => ["MPL-2.0"],
    "NOASSERTION" => []
  }
  @approved_license_expressions MapSet.new(Map.keys(@license_expression_terms))
  @license_ids @license_expression_terms
               |> Map.values()
               |> List.flatten()
               |> Enum.uniq()
               |> Enum.sort()
  @excluded_tree_roots MapSet.new([
                         "LICENSE",
                         "NOTICE",
                         @union_name,
                         @manifest_name,
                         "licenses"
                       ])

  @type error :: %{
          required(:code) => atom(),
          required(:message) => String.t(),
          required(:exit_status) => pos_integer(),
          optional(:details) => map()
        }

  @doc "Resolve the exact native build target used to compose a release artifact."
  @spec build_target() :: {:ok, map()} | {:error, error()}
  def build_target, do: protect(&native_build_target!/0)

  @doc "Load and validate the reviewed source catalog without starting any application."
  @spec load_catalog(keyword()) :: {:ok, map()} | {:error, error()}
  def load_catalog(opts \\ []) do
    repo_root = repo_root(opts)
    path = Keyword.get(opts, :catalog_path, Path.join(repo_root, @catalog_relative))

    with {:ok, contents} <- read_bounded(path, @max_metadata_bytes, :catalog_missing),
         {:ok, catalog} <- decode_json(contents, :catalog_invalid),
         {:ok, _catalog} <- validate_catalog(catalog, Keyword.put(opts, :repo_root, repo_root)) do
      {:ok, catalog}
    end
  end

  @doc "Validate catalog schema, managed seams, and source text digests."
  @spec validate_catalog(map(), keyword()) :: {:ok, map()} | {:error, error()}
  def validate_catalog(catalog, opts \\ []) do
    protect(fn ->
      repo_root = repo_root(opts)
      require_map!(catalog, "catalog")
      require_equal!(catalog["schema_version"], @schema_version, "schema_version")
      require_nonempty_string!(catalog["claim"], "claim")

      reviewed_inputs = require_list!(catalog["reviewed_inputs"], "reviewed_inputs")
      texts = require_list!(catalog["texts"], "texts")
      components = require_list!(catalog["components"], "components")

      validate_unique_ids!(reviewed_inputs, "reviewed_inputs")
      validate_unique_ids!(texts, "texts")
      validate_unique_ids!(components, "components")

      Enum.each(reviewed_inputs, &validate_reviewed_input!(&1, repo_root, opts))

      text_index =
        texts
        |> Enum.map(&validate_text!(&1, repo_root, opts))
        |> Map.new()

      Enum.each(components, &validate_component!(&1, text_index))
      validate_unique_beam_applications!(components)
      validate_unique_packs!(components)
      catalog
    end)
  end

  @doc "Render deterministic source-review products entirely in memory."
  @spec repo_products(map(), keyword()) :: {:ok, map()} | {:error, error()}
  def repo_products(catalog, opts \\ []) do
    with {:ok, _catalog} <- validate_catalog(catalog, opts) do
      protect(fn ->
        repo_root = repo_root(opts)

        texts =
          catalog["texts"]
          |> Enum.sort_by(& &1["id"])
          |> Enum.map(&packaged_text!(&1, repo_root))

        canonical_catalog = %{
          catalog
          | "components" => Enum.sort_by(catalog["components"], & &1["id"]),
            "reviewed_inputs" => Enum.sort_by(catalog["reviewed_inputs"], & &1["id"]),
            "texts" => Enum.sort_by(catalog["texts"], & &1["id"])
        }

        %{
          union: render_union(catalog),
          catalog_json: canonical_json(canonical_catalog),
          texts: texts
        }
      end)
    end
  end

  @doc "Generate or drift-check the committed cross-target union."
  @spec generate_repo(keyword()) :: {:ok, map()} | {:error, error()}
  def generate_repo(opts \\ []) do
    with {:ok, catalog} <- load_catalog(opts),
         {:ok, products} <- repo_products(catalog, opts) do
      protect(fn ->
        root = repo_root(opts)
        path = Path.join(root, @union_name)

        persist_union!(path, products.union, Keyword.get(opts, :check, false))
      end)
    end
  end

  @doc "Finalize license evidence into an already assembled release tree."
  @spec finalize(map(), [map()], map(), keyword()) :: {:ok, map()} | {:error, error()}
  def finalize(catalog, actual_apps, target, opts \\ []) do
    with {:ok, _catalog} <- validate_catalog(catalog, opts),
         {:ok, products} <- repo_products(catalog, opts) do
      protect(fn ->
        release_root = required_release_root!(opts)
        repo_root = repo_root(opts)
        target = stringify(target)
        validate_target!(target)
        declared_apps = normalize_actual_apps!(actual_apps, release_root)
        apps = scan_release_apps!(release_root)
        validate_target_tree!(target, apps, release_root)
        components = target_components(catalog["components"], target)

        validate_application_closure!(components, apps)
        validate_declared_application_closure!(declared_apps, apps)

        validate_inactive_target_components!(
          catalog["components"],
          components,
          apps,
          release_root
        )

        validate_external_boundaries!(components, release_root)
        manifest_components = materialize_components!(components, apps, release_root)

        committed_union =
          repo_root
          |> Path.join(@union_name)
          |> read_file!(:union_missing)

        validate_committed_union!(committed_union, products.union)

        license = repo_root |> Path.join("LICENSE") |> read_file!(:project_license_missing)
        notice = repo_root |> Path.join("NOTICE") |> read_file!(:project_notice_missing)
        reset_generated_outputs!(release_root)
        payload = tree_fingerprint!(release_root)

        generated = generated_outputs(products, license, notice)

        generated_files = generated_file_records(generated)

        manifest = %{
          "schema_version" => @schema_version,
          "claim" => catalog["claim"],
          "target" => target,
          "payload" => payload,
          "components" => manifest_components,
          "texts" => products.texts |> Enum.map(&manifest_text/1) |> Enum.sort_by(& &1["id"]),
          "generated_files" => generated_files,
          "warnings" => [@warning]
        }

        write_generated!(release_root, generated)
        normalize_generated_directory_modes!(release_root)

        manifest_json = canonical_json(manifest)
        write_atomic!(Path.join(release_root, @manifest_name), manifest_json)

        %{manifest: manifest, manifest_sha256: sha256(manifest_json), release_root: release_root}
      end)
    end
  end

  @doc "Verify generated evidence and the unchanged post-finalizer payload tree."
  @spec verify(keyword()) :: {:ok, map()} | {:error, error()}
  def verify(opts \\ []) do
    protect(fn ->
      root = required_release_root!(opts)
      {manifest, manifest_json} = load_manifest!(root)
      verify_manifest_digest!(manifest_json, opts)
      verify_manifest_mode!(root)
      validate_manifest_shape!(manifest)
      verify_generated_files!(root, manifest)
      validate_packaged_evidence!(root, manifest)

      actual_payload = tree_fingerprint!(root)

      unless actual_payload == manifest["payload"] do
        fail!(:payload_mutated, "release payload changed after license finalization")
      end

      %{manifest: manifest, release_root: root}
    end)
  end

  @doc "Read and render packaged evidence without runtime, Repo, daemon, or network access."
  @spec view([String.t()], keyword()) :: {:ok, map()} | {:error, error()}
  def view(args, opts \\ []) when is_list(args) do
    protect(fn ->
      root = viewer_release_root(opts)
      {manifest, _manifest_json} = load_manifest!(root)
      verify_manifest_mode!(root)
      validate_manifest_shape!(manifest)
      verify_generated_files!(root, manifest)
      validate_packaged_evidence!(root, manifest)
      render_view!(args, root, manifest)
    end)
  end

  @doc false
  @spec canonical_json(term()) :: String.t()
  def canonical_json(value), do: encode_json(stringify(value)) <> "\n"

  defp validate_text!(text, repo_root, opts) do
    require_map!(text, "text")

    unless Enum.sort(Map.keys(text)) == ~w(id license_id path sha256),
      do: fail!(:invalid_schema, "text record has unexpected fields")

    id = require_identifier!(text["id"], "text.id")
    license_id = require_one_of!(text["license_id"], @license_ids, "text.license_id")
    path = normalize_relative!(text["path"], "text.path")
    expected = require_sha256!(text["sha256"], "text.sha256")
    validate_text_id!(id, license_id, expected)

    if Keyword.get(opts, :validate_files, true) do
      contents = read_file!(Path.join(repo_root, path), :license_text_missing)

      if sha256(contents) != expected do
        fail!(:license_text_digest_mismatch, "license text digest mismatch for #{id}")
      end
    end

    {id, license_id}
  end

  defp validate_text_id!("LicenseText-" <> digest_prefix = id, _license_id, digest) do
    if byte_size(digest_prefix) == 20 and digest_prefix == String.slice(digest, 0, 20),
      do: :ok,
      else: fail!(:invalid_text_id, "#{id} does not match its content digest")
  end

  defp validate_text_id!(id, license_id, _digest) do
    unless id == license_id,
      do: fail!(:invalid_text_id, "named license text #{id} must match license_id #{license_id}")
  end

  defp validate_reviewed_input!(input, repo_root, opts) do
    require_map!(input, "reviewed_input")
    id = require_identifier!(input["id"], "reviewed_input.id")
    path = normalize_relative!(input["path"], "reviewed_input.path")
    expected = require_sha256!(input["sha256"], "reviewed_input.sha256")

    if Keyword.get(opts, :validate_files, true) do
      actual = repo_root |> Path.join(path) |> read_file!(:reviewed_input_missing) |> sha256()

      if actual != expected,
        do: fail!(:reviewed_input_drift, "reviewed dependency input drift for #{id}")
    end
  end

  defp validate_component!(component, text_index) do
    require_map!(component, "component")
    id = require_identifier!(component["id"], "component.id")
    require_nonempty_string!(component["name"], "#{id}.name")
    kind = require_one_of!(component["kind"], ~w(beam_app managed_file external), "#{id}.kind")

    expression =
      require_nonempty_string!(component["license_expression"], "#{id}.license_expression")

    bundled = require_boolean!(component["bundled"], "#{id}.bundled")
    ids = require_list!(component["text_ids"], "#{id}.text_ids")

    validate_component_texts!(id, bundled, ids, Map.keys(text_index) |> MapSet.new())
    validate_component_license!(id, expression, ids, text_index)
    validate_targets!(component["targets"], id)
    validate_component_kind!(kind, component, id, bundled)
    validate_pack!(component, id)
    validate_presence!(kind, component, id)
    validate_mpl_scope!(component, id, expression)
  end

  defp validate_component_license!(id, expression, text_ids, text_index) do
    unless MapSet.member?(@approved_license_expressions, expression),
      do: fail!(:unapproved_license, "#{id} uses unapproved license expression #{expression}")

    expected = @license_expression_terms |> Map.fetch!(expression) |> MapSet.new()
    actual = text_ids |> Enum.map(&Map.fetch!(text_index, &1)) |> MapSet.new()

    unless actual == expected,
      do:
        fail!(
          :license_text_set_mismatch,
          "#{id} text classifications do not match #{expression}"
        )
  end

  defp validate_mpl_scope!(component, "castore-mozilla-ca", "MPL-2.0") do
    exact_file? =
      get_in(component, ["file", "application"]) == "castore" and
        get_in(component, ["file", "relative_path"]) == "priv/cacerts.pem" and
        get_in(component, ["file", "digest_required"]) == true

    if exact_file? and component["source_required"] == true and
         component["text_ids"] == ["MPL-2.0"],
       do: :ok,
       else: fail!(:invalid_mpl_scope, "Castore MPL exception must remain exact-file scoped")
  end

  defp validate_mpl_scope!(_component, id, expression) do
    if String.contains?(expression, "MPL-2.0"),
      do: fail!(:unapproved_license, "#{id} is outside the narrow Castore MPL exception")
  end

  defp native_build_target! do
    %{
      "triple" => native_target_triple!(),
      "otp_version" => exact_otp_version!(),
      "elixir_version" => System.version(),
      "erts_version" => :erlang.system_info(:version) |> to_string()
    }
  end

  defp native_target_triple! do
    architecture = :erlang.system_info(:system_architecture) |> to_string() |> String.downcase()

    cond do
      apple_arm?(architecture) ->
        "macos-arm64"

      linux_x64?(architecture) ->
        "linux-x64"

      linux_arm?(architecture) ->
        "linux-arm64"

      true ->
        fail!(:unsupported_build_target, "unsupported native build architecture #{architecture}")
    end
  end

  defp apple_arm?(architecture),
    do: String.contains?(architecture, "apple-darwin") and arm_architecture?(architecture)

  defp linux_x64?(architecture),
    do: String.contains?(architecture, "linux") and String.starts_with?(architecture, "x86_64")

  defp linux_arm?(architecture),
    do: String.contains?(architecture, "linux") and arm_architecture?(architecture)

  defp arm_architecture?(architecture),
    do: String.starts_with?(architecture, "aarch64") or String.starts_with?(architecture, "arm64")

  defp exact_otp_version! do
    root = :code.root_dir() |> to_string()
    path = Path.join([root, "releases", System.otp_release(), "OTP_VERSION"])

    case File.read(path) do
      {:ok, version} ->
        require_nonempty_string!(String.trim(version), "native OTP version")

      {:error, reason} ->
        fail!(:target_probe_failed, "could not read exact OTP version: #{reason}")
    end
  end

  defp validate_target!(target, status \\ 1) do
    require_map!(target, "target", status)

    unless Enum.sort(Map.keys(target)) == @target_keys,
      do:
        fail!(
          :invalid_target,
          "target must contain exactly #{Enum.join(@target_keys, ", ")}",
          status
        )

    require_one_of!(target["triple"], @supported_targets, "target.triple", status)
    require_nonempty_string!(target["otp_version"], "target.otp_version", status)
    require_nonempty_string!(target["elixir_version"], "target.elixir_version", status)
    require_nonempty_string!(target["erts_version"], "target.erts_version", status)
  end

  defp validate_target_tree!(target, apps, release_root) do
    unless target == native_build_target!(),
      do:
        fail!(
          :target_runtime_mismatch,
          "declared target does not match the exact native build runtime"
        )

    expected_erts = "erts-#{target["erts_version"]}"

    erts_dirs =
      release_root
      |> Path.join("erts-*")
      |> Path.wildcard()
      |> Enum.filter(&File.dir?/1)
      |> Enum.map(&Path.basename/1)

    unless erts_dirs == [expected_erts],
      do: fail!(:target_version_mismatch, "target ERTS version does not match release tree")

    expected_elixir = target["elixir_version"]

    case Enum.find(apps, &(&1["application"] == "elixir")) do
      %{"version" => ^expected_elixir} ->
        :ok

      %{"version" => _version} ->
        fail!(:target_version_mismatch, "target Elixir version mismatch")

      nil ->
        :ok
    end
  end

  defp validate_component_texts!(id, bundled, ids, known_text_ids) do
    if bundled and ids == [],
      do: fail!(:missing_required_text, "bundled component #{id} requires license text")

    if length(ids) != length(Enum.uniq(ids)),
      do: fail!(:duplicate_text, "#{id} contains duplicate text references")

    Enum.each(ids, &validate_component_text_id!(&1, id, known_text_ids))
  end

  defp validate_unique_beam_applications!(components) do
    applications =
      components
      |> Enum.filter(&(&1["kind"] == "beam_app"))
      |> Enum.map(& &1["application"])

    if length(applications) != length(Enum.uniq(applications)),
      do: fail!(:duplicate_application, "catalog contains duplicate BEAM applications")
  end

  defp validate_unique_packs!(components) do
    packs =
      components
      |> Enum.filter(&is_map(&1["pack"]))
      |> Enum.map(fn component ->
        Map.put(component["pack"], "application", component["application"])
      end)

    Enum.each(~w(id descriptor_module registry_order application), fn field ->
      values = Enum.map(packs, & &1[field])

      if length(values) != length(Enum.uniq(values)),
        do: fail!(:duplicate_pack, "catalog Pack projection contains duplicate #{field}")
    end)
  end

  defp validate_component_text_id!(text_id, component_id, known_text_ids) do
    require_identifier!(text_id, "#{component_id}.text_ids")

    unless MapSet.member?(known_text_ids, text_id),
      do: fail!(:unknown_text, "#{component_id} references unknown text #{text_id}")
  end

  defp validate_component_kind!("beam_app", component, id, bundled) do
    unless bundled, do: fail!(:invalid_component, "beam application #{id} must be bundled")
    require_identifier!(component["application"], "#{id}.application")
  end

  defp validate_component_kind!("managed_file", component, id, bundled) do
    unless bundled, do: fail!(:invalid_component, "managed file #{id} must be bundled")
    validate_file_rule!(component["file"], id)
    source_required = Map.get(component, "source_required", false)
    require_boolean!(source_required, "#{id}.source_required")

    if source_required and is_nil(component["source"]),
      do: fail!(:source_unavailable, "#{id} requires an exact source-availability path")

    validate_source!(component["source"], id)
  end

  defp validate_component_kind!("external", component, id, bundled) do
    if bundled,
      do: fail!(:invalid_component, "external component #{id} cannot be catalogued as bundled")

    component
    |> Map.get("forbidden_paths", [])
    |> require_list!("#{id}.forbidden_paths")
    |> Enum.each(&normalize_relative!(&1, "#{id}.forbidden_paths"))
  end

  defp validate_pack!(component, id) do
    case Map.fetch(component, "pack") do
      :error ->
        :ok

      {:ok, pack} ->
        pack = require_map!(pack, "#{id}.pack")

        first_party? =
          match?(
            %{"ecosystem" => "allbert", "repository" => @allbert_repository},
            component["provenance"]
          )

        unless component["kind"] == "beam_app" and first_party? do
          fail!(
            :invalid_schema,
            "#{id}.Pack requires an exact first-party BEAM application row"
          )
        end

        unless Enum.sort(Map.keys(pack)) == @pack_source_keys,
          do: fail!(:invalid_schema, "#{id}.pack has unexpected fields")

        require_equal!(pack["schema_version"], @schema_version, "#{id}.pack.schema_version")
        require_pack_id!(pack["id"], "#{id}.pack.id")

        require_pack_descriptor_module!(
          pack["descriptor_module"],
          "#{id}.pack.descriptor_module"
        )

        require_one_of!(
          pack["startup_role"],
          @pack_startup_roles,
          "#{id}.pack.startup_role"
        )

        require_nonnegative_integer!(pack["registry_order"], "#{id}.pack.registry_order", 1)
    end
  end

  defp require_pack_id!(value, field) do
    value = require_nonempty_string!(value, field)

    if byte_size(value) <= 64 and Regex.match?(@pack_id_regex, value),
      do: value,
      else: fail!(:invalid_schema, "#{field} is not a canonical Pack id")
  end

  defp require_pack_descriptor_module!(value, field) do
    value = require_nonempty_string!(value, field)

    if byte_size(value) <= 255 and Regex.match?(@pack_descriptor_module_regex, value),
      do: value,
      else: fail!(:invalid_schema, "#{field} is not a canonical Elixir module string")
  end

  defp validate_file_rule!(rule, id) do
    require_map!(rule, "#{id}.file")

    case {rule["path"], rule["application"], rule["relative_path"]} do
      {path, nil, nil} when is_binary(path) ->
        normalize_relative!(path, "#{id}.file.path")

      {nil, app, path} when is_binary(app) and is_binary(path) ->
        require_identifier!(app, "#{id}.file.application")
        normalize_relative!(path, "#{id}.file.relative_path")

      _other ->
        fail!(:invalid_component, "#{id}.file must name path or application + relative_path")
    end

    digest = rule["sha256"]
    if digest, do: require_sha256!(digest, "#{id}.file.sha256")

    if rule["digest_required"] == true and is_nil(digest) do
      fail!(:invalid_component, "#{id}.file requires a pinned sha256")
    end

    if Map.has_key?(rule, "digest_required"),
      do: require_boolean!(rule["digest_required"], "#{id}.file.digest_required")
  end

  defp validate_source!(nil, _id), do: :ok

  defp validate_source!(source, id) do
    require_map!(source, "#{id}.source")

    case {source["companion"], source["immutable_url"]} do
      {nil, url} when is_binary(url) ->
        require_immutable_url!(url, "#{id}.source.immutable_url")
        require_sha256!(source["sha256"], "#{id}.source.sha256")
        converter = require_map!(source["converter"], "#{id}.source.converter")
        require_nonempty_string!(converter["name"], "#{id}.source.converter.name")
        require_nonempty_string!(converter["version"], "#{id}.source.converter.version")
        require_immutable_url!(converter["immutable_url"], "#{id}.source.converter.immutable_url")
        require_sha256!(converter["sha256"], "#{id}.source.converter.sha256")

      {%{}, nil} ->
        fail!(
          :unsupported_source_mode,
          "#{id}.source.companion is not supported by catalog schema v1; use an immutable reference"
        )

      _other ->
        fail!(:invalid_source, "#{id}.source needs one immutable source-availability reference")
    end
  end

  defp validate_targets!(nil, _id), do: :ok

  defp validate_targets!(targets, id) do
    targets = require_list!(targets, "#{id}.targets")
    Enum.each(targets, &require_one_of!(&1, @supported_targets, "#{id}.targets"))

    if length(targets) != length(Enum.uniq(targets)),
      do: fail!(:duplicate_target, "#{id}.targets contains duplicate targets")
  end

  defp validate_presence!("managed_file", component, id) do
    require_one_of!(
      Map.get(component, "presence", "required"),
      ~w(required observed),
      "#{id}.presence"
    )
  end

  defp validate_presence!(_kind, component, id) do
    if Map.has_key?(component, "presence"),
      do: fail!(:invalid_component, "#{id}.presence is valid only for managed files")
  end

  defp render_union(catalog) do
    input_rows =
      catalog["reviewed_inputs"]
      |> Enum.sort_by(& &1["id"])
      |> Enum.map_join("\n", fn input ->
        "| `#{escape_markdown(input["id"])}` | `#{escape_markdown(input["path"])}` | `#{input["sha256"]}` |"
      end)

    text_rows =
      catalog["texts"]
      |> Enum.sort_by(& &1["id"])
      |> Enum.map_join("\n", fn text ->
        "| `#{escape_markdown(text["id"])}` | `#{text["license_id"]}` | `#{escape_markdown(text["path"])}` | `#{text["sha256"]}` |"
      end)

    component_sections =
      catalog["components"]
      |> Enum.sort_by(& &1["id"])
      |> Enum.map_join("\n\n", &render_union_component/1)

    normalize_lf("""
    # Third-Party Licenses And Provenance

    #{catalog["claim"]}

    This file is generated deterministically from
    `apps/allbert_assist/priv/licenses/catalog.json`. Component versions and
    target-specific file digests are recorded in each packaged
    `THIRD-PARTY-MANIFEST.json`.

    ## Reviewed Dependency Inputs

    Any digest change requires an explicit catalog/license disposition before
    the offline drift check can pass.

    | Identifier | Reviewed input | SHA-256 |
    | --- | --- | --- |
    #{input_rows}

    ## Required Texts

    | Identifier | License ID | Reviewed source path | SHA-256 |
    | --- | --- | --- | --- |
    #{text_rows}

    ## Known Components

    #{component_sections}
    """)
  end

  defp render_union_component(component) do
    disposition =
      cond do
        component["presence"] == "observed" ->
          "bundled only when observed in the selected final target"

        component["bundled"] ->
          "bundled when selected for the target"

        true ->
          "external / not bundled"
      end

    lines = [
      "### `#{escape_markdown(component["id"])}` — #{escape_markdown(component["name"])}",
      "",
      "- Kind: `#{component["kind"]}`",
      "- License expression: `#{escape_markdown(component["license_expression"])}`",
      "- Disposition: #{disposition}",
      "- Required texts: #{render_text_ids(component["text_ids"])}"
    ]

    extras =
      []
      |> maybe_union_line(component["application"], "Application")
      |> maybe_union_line(get_in(component, ["file", "path"]), "Managed path")
      |> maybe_union_line(get_in(component, ["file", "application"]), "Managed application")
      |> maybe_union_line(get_in(component, ["file", "relative_path"]), "Managed relative path")
      |> maybe_union_line(component["targets"], "Targets")
      |> maybe_union_line(component["presence"], "Presence")
      |> maybe_union_line(component["forbidden_paths"], "Forbidden bundled paths")
      |> maybe_union_line(component["provenance"], "Provenance")
      |> maybe_union_line(component["source"], "Source availability")

    Enum.join(lines ++ extras, "\n")
  end

  defp maybe_union_line(lines, nil, _label), do: lines
  defp maybe_union_line(lines, [], _label), do: lines

  defp maybe_union_line(lines, value, label) do
    rendered = if is_binary(value), do: value, else: canonical_json(value) |> String.trim()
    lines ++ ["- #{label}: `#{escape_markdown(rendered)}`"]
  end

  defp render_text_ids([]), do: "none (external declaration)"
  defp render_text_ids(ids), do: Enum.map_join(ids, ", ", &"`#{escape_markdown(&1)}`")

  defp normalize_actual_apps!(actual_apps, release_root) do
    actual_apps
    |> require_list!("actual applications")
    |> Enum.map(fn app ->
      require_map!(app, "actual application")
      name = app["application"] || app[:application] || app["name"] || app[:name]
      name = name |> normalize_app_name!()
      version = app["version"] || app[:version] || app["vsn"] || app[:vsn]
      release_path = find_release_app_dir!(release_root, name)
      path_version = version_from_path(release_path, name)

      if version && to_string(version) != path_version,
        do: fail!(:application_version_mismatch, "application version mismatch for #{name}")

      %{
        "application" => name,
        "version" => path_version,
        "path" => Path.relative_to(release_path, release_root)
      }
    end)
    |> Enum.sort_by(& &1["application"])
    |> ensure_unique_applications!()
  end

  defp scan_release_apps!(release_root) do
    lib_root = Path.join(release_root, "lib")

    case File.lstat(lib_root) do
      {:error, :enoent} ->
        []

      {:ok, %File.Stat{type: :directory}} ->
        lib_root
        |> File.ls!()
        |> Enum.sort()
        |> Enum.map(&scan_release_app!(release_root, lib_root, &1))
        |> Enum.sort_by(& &1["application"])
        |> ensure_unique_applications!()

      _other ->
        fail!(:unsafe_release_path, "release lib path is not a real directory")
    end
  rescue
    error ->
      fail!(
        :application_tree_invalid,
        "could not inspect release applications: #{Exception.message(error)}"
      )
  end

  defp scan_release_app!(release_root, lib_root, directory) do
    app_root = Path.join(lib_root, directory)

    unless regular_directory?(app_root),
      do: fail!(:unsafe_release_path, "release application path is not a real directory")

    app_files = Path.wildcard(Path.join([app_root, "ebin", "*.app"]))

    app_file =
      case app_files do
        [path] ->
          assert_regular_release_path!(
            release_root,
            Path.relative_to(path, release_root),
            :application_tree_invalid,
            1
          )

        [] ->
          fail!(:application_tree_invalid, "release application #{directory} has no .app file")

        _many ->
          fail!(
            :application_tree_invalid,
            "release application #{directory} has multiple .app files"
          )
      end

    {name, version} = consult_release_app!(app_file)
    expected_directory = "#{name}-#{version}"

    unless directory == expected_directory,
      do:
        fail!(:application_version_mismatch, "release application directory mismatch for #{name}")

    %{
      "application" => name,
      "version" => version,
      "path" => Path.relative_to(app_root, release_root),
      "app_sha256" => app_file |> read_file!(:application_tree_invalid) |> sha256()
    }
  end

  defp consult_release_app!(path) do
    case :file.consult(String.to_charlist(path)) do
      {:ok, [{:application, name, properties}]} when is_list(properties) ->
        name = normalize_app_name!(name)
        version = properties |> Keyword.fetch!(:vsn) |> to_string()
        require_nonempty_string!(version, "release application version")
        {name, version}

      _other ->
        fail!(:application_tree_invalid, "release .app metadata is invalid")
    end
  rescue
    error ->
      fail!(
        :application_tree_invalid,
        "could not read release .app metadata: #{Exception.message(error)}"
      )
  end

  defp validate_declared_application_closure!(declared_apps, tree_apps) do
    comparable_tree_apps = Enum.map(tree_apps, &Map.take(&1, ~w(application path version)))

    unless declared_apps == comparable_tree_apps,
      do:
        fail!(
          :application_input_mismatch,
          "declared release applications do not match the final release tree"
        )
  end

  defp validate_application_closure!(components, apps) do
    expected =
      components
      |> Enum.filter(&(&1["kind"] == "beam_app"))
      |> Map.new(&{&1["application"], &1})

    actual = Map.new(apps, &{&1["application"], &1})
    unknown = Map.keys(actual) -- Map.keys(expected)
    missing = Map.keys(expected) -- Map.keys(actual)

    if unknown != [],
      do:
        fail!(
          :unknown_application,
          "unknown shipped BEAM application(s): #{Enum.sort(unknown) |> Enum.join(", ")}"
        )

    if missing != [],
      do:
        fail!(
          :missing_application,
          "catalogued BEAM application(s) missing: #{Enum.sort(missing) |> Enum.join(", ")}"
        )
  end

  defp validate_external_boundaries!(components, root) do
    components
    |> Enum.filter(&(&1["kind"] == "external"))
    |> Enum.each(fn component ->
      paths = component["forbidden_paths"] || []

      found =
        Enum.find(paths, fn path -> File.exists?(Path.join(root, path)) end)

      if found do
        fail!(:external_runtime_bundled, "external runtime unexpectedly bundled: #{found}")
      end
    end)
  end

  defp validate_inactive_target_components!(all_components, active_components, apps, root) do
    active_ids = MapSet.new(active_components, & &1["id"])
    app_index = Map.new(apps, &{&1["application"], &1})

    all_components
    |> Enum.reject(&MapSet.member?(active_ids, &1["id"]))
    |> Enum.filter(&(&1["kind"] == "managed_file"))
    |> Enum.each(&reject_inactive_managed_path!(&1, app_index, root))
  end

  defp reject_inactive_managed_path!(component, app_index, root) do
    case inactive_managed_path(component["file"], app_index) do
      nil ->
        :ok

      path ->
        if File.exists?(Path.join(root, path)),
          do:
            fail!(
              :unexpected_target_component,
              "target-excluded managed component is present: #{component["id"]}"
            )
    end
  end

  defp inactive_managed_path(%{"path" => path}, _apps),
    do: normalize_relative!(path, "inactive managed path")

  defp inactive_managed_path(%{"application" => app, "relative_path" => relative}, apps) do
    case Map.fetch(apps, app) do
      {:ok, record} -> Path.join(record["path"], normalize_relative!(relative, "inactive path"))
      :error -> nil
    end
  end

  defp materialize_components!(components, apps, root) do
    app_index = Map.new(apps, &{&1["application"], &1})

    components
    |> Enum.map(&materialize_component!(&1, app_index, root))
    |> Enum.sort_by(& &1["id"])
  end

  defp materialize_component!(component, app_index, root) do
    base =
      Map.take(
        component,
        ~w(id name kind license_expression bundled text_ids targets provenance source source_required presence)
      )

    materialize_component_kind!(component["kind"], component, base, app_index, root)
  end

  defp materialize_component_kind!("beam_app", component, base, app_index, _root) do
    app = Map.fetch!(app_index, component["application"])
    materialized = Map.merge(base, Map.take(app, ~w(application path version)))

    case component["pack"] do
      nil -> materialized
      pack -> Map.put(materialized, "pack", Map.put(pack, "app_sha256", app["app_sha256"]))
    end
  end

  defp materialize_component_kind!("managed_file", component, base, app_index, root) do
    path = resolve_managed_path!(component["file"], app_index, root)

    case observed_managed_file(root, path, component) do
      :absent ->
        Map.merge(base, %{"bundled" => false, "path" => path, "sha256" => nil})

      {:present, actual} ->
        Map.merge(base, %{"bundled" => true, "path" => path, "sha256" => actual})
    end
  end

  defp materialize_component_kind!("external", component, base, _app_index, _root) do
    Map.merge(base, %{"forbidden_paths" => component["forbidden_paths"] || []})
  end

  defp observed_managed_file(root, path, component) do
    presence = component["presence"]
    state = if presence == "observed", do: release_leaf_state!(root, path, 1), else: :present

    case {state, presence} do
      {:absent, "observed"} ->
        :absent

      {_present_or_absent, _presence} ->
        contents = read_release_regular_file!(root, path, :managed_path_missing)
        actual = sha256(contents)
        expected = component["file"]["sha256"]

        if expected && expected != actual,
          do:
            fail!(
              :managed_digest_mismatch,
              "managed payload digest mismatch for #{component["id"]}"
            )

        {:present, actual}
    end
  end

  defp target_components(components, target) do
    triple = target["triple"]

    Enum.filter(components, fn component ->
      case component["targets"] do
        nil -> true
        targets -> is_binary(triple) and triple in targets
      end
    end)
  end

  defp resolve_managed_path!(%{"path" => path}, _apps, _root),
    do: normalize_relative!(path, "managed path")

  defp resolve_managed_path!(%{"application" => app, "relative_path" => relative}, apps, _root) do
    case Map.fetch(apps, app) do
      {:ok, record} ->
        Path.join(record["path"], normalize_relative!(relative, "managed relative path"))

      :error ->
        fail!(:missing_application, "managed path application missing: #{app}")
    end
  end

  defp ensure_unique_applications!(apps) do
    names = Enum.map(apps, & &1["application"])

    if length(names) != length(Enum.uniq(names)),
      do: fail!(:duplicate_application, "duplicate actual application")

    apps
  end

  defp find_release_app_dir!(root, app) do
    matches =
      [root, "lib", app <> "-*"]
      |> Path.join()
      |> Path.wildcard()
      |> Enum.filter(&regular_directory?/1)

    case matches do
      [path] ->
        assert_release_directory_path!(root, Path.relative_to(path, root), 1)

      [] ->
        fail!(:missing_application_path, "release application path missing for #{app}")

      _many ->
        fail!(:ambiguous_application_path, "multiple release application paths found for #{app}")
    end
  end

  defp version_from_path(path, app) do
    path |> Path.basename() |> String.replace_prefix(app <> "-", "")
  end

  defp tree_fingerprint!(root) do
    entries = collect_tree_entries!(root, root)

    bytes =
      Enum.map_join(entries, "", fn {kind, path, mode, digest} ->
        "#{kind}\0#{path}\0#{mode}\0#{digest}\n"
      end)

    %{"entry_count" => length(entries), "sha256" => sha256(bytes)}
  end

  defp collect_tree_entries!(root, directory) do
    directory
    |> File.ls!()
    |> Enum.sort()
    |> Enum.flat_map(&collect_tree_entry!(root, directory, &1))
  rescue
    error ->
      fail!(
        :payload_unreadable,
        "could not fingerprint release payload: #{Exception.message(error)}"
      )
  end

  defp collect_tree_entry!(root, directory, name) do
    path = Path.join(directory, name)
    relative = Path.relative_to(path, root)
    top = relative |> Path.split() |> List.first()

    if MapSet.member?(@excluded_tree_roots, top),
      do: [],
      else: fingerprint_tree_entry!(root, path, relative)
  end

  defp fingerprint_tree_entry!(root, path, relative) do
    case File.lstat!(path) do
      %File.Stat{type: :directory, mode: mode} ->
        [{"D", relative, permission_mode(mode), ""} | collect_tree_entries!(root, path)]

      %File.Stat{type: :regular, mode: mode} ->
        [{"F", relative, permission_mode(mode), path |> File.read!() |> sha256()}]

      %File.Stat{type: :symlink, mode: mode} ->
        [{"L", relative, permission_mode(mode), path |> File.read_link!() |> sha256()}]

      _other ->
        []
    end
  end

  defp permission_mode(mode), do: mode |> band(0o7777) |> Integer.to_string(8)

  defp load_manifest!(root) do
    contents =
      read_bounded_release_regular_file!(
        root,
        @manifest_name,
        @max_metadata_bytes,
        :manifest_missing,
        3
      )

    case Jason.decode(contents) do
      {:ok, manifest} ->
        {manifest, contents}

      {:error, _reason} ->
        fail!(:manifest_invalid, "packaged #{@manifest_name} is not valid JSON", 3)
    end
  end

  defp validate_manifest_shape!(manifest) do
    require_map!(manifest, "manifest", 3)
    require_equal!(manifest["schema_version"], @schema_version, "manifest.schema_version", 3)
    require_nonempty_string!(manifest["claim"], "manifest.claim", 3)
    validate_target!(manifest["target"], 3)
    payload = require_map!(manifest["payload"], "manifest.payload", 3)

    unless Enum.sort(Map.keys(payload)) == ["entry_count", "sha256"],
      do: fail!(:manifest_invalid, "manifest.payload has unexpected fields", 3)

    require_nonnegative_integer!(payload["entry_count"], "manifest.payload.entry_count", 3)
    require_sha256!(manifest["payload"]["sha256"], "manifest.payload.sha256", 3)
    require_list!(manifest["components"], "manifest.components", 3)
    require_list!(manifest["texts"], "manifest.texts", 3)
    require_list!(manifest["generated_files"], "manifest.generated_files", 3)
    require_equal!(manifest["warnings"], [@warning], "manifest.warnings", 3)

    unless Enum.sort(Map.keys(manifest)) ==
             ~w(claim components generated_files payload schema_version target texts warnings),
           do: fail!(:manifest_invalid, "manifest has unexpected fields", 3)
  end

  defp verify_manifest_digest!(contents, opts) do
    expected =
      case Keyword.get(opts, :manifest_sha256) do
        value when is_binary(value) -> require_sha256!(value, "manifest_sha256", 3)
        _missing -> fail!(:manifest_digest_required, "expected manifest_sha256 is required", 3)
      end

    if sha256(contents) != expected,
      do: fail!(:manifest_digest_mismatch, "packaged manifest digest mismatch", 3)
  end

  defp verify_manifest_mode!(root),
    do: verify_release_file_mode!(root, @manifest_name, "644", 3)

  defp verify_generated_files!(root, manifest) do
    Enum.each(manifest["generated_files"], fn entry ->
      require_map!(entry, "manifest.generated_file", 3)

      unless Enum.sort(Map.keys(entry)) == ["mode", "path", "sha256"],
        do: fail!(:manifest_invalid, "generated-file record has unexpected fields", 3)

      path = normalize_relative!(entry["path"], "manifest.generated_file.path", 3)
      expected = require_sha256!(entry["sha256"], "manifest.generated_file.sha256", 3)
      require_equal!(entry["mode"], "644", "manifest.generated_file.mode", 3)
      verify_release_file_mode!(root, path, "644", 3)

      contents =
        read_bounded_release_regular_file!(
          root,
          path,
          @max_metadata_bytes,
          :generated_file_missing,
          3
        )

      if sha256(contents) != expected do
        fail!(:generated_file_corrupt, "packaged license file digest mismatch: #{path}", 3)
      end
    end)

    Enum.each(manifest["texts"], fn text ->
      require_map!(text, "manifest.text", 3)
      require_identifier!(text["id"], "manifest.text.id", 3)
      path = normalize_relative!(text["path"], "manifest.text.path", 3)
      expected = require_sha256!(text["sha256"], "manifest.text.sha256", 3)

      contents =
        read_bounded_release_regular_file!(
          root,
          path,
          @max_metadata_bytes,
          :license_text_missing,
          3
        )

      if sha256(contents) != expected do
        fail!(:license_text_digest_mismatch, "packaged license text digest mismatch: #{path}", 3)
      end
    end)
  end

  defp validate_packaged_evidence!(root, manifest) do
    catalog = load_packaged_catalog!(root)

    unless manifest["claim"] == catalog["claim"],
      do: fail!(:manifest_invalid, "manifest claim differs from packaged catalog", 3)

    validate_manifest_texts!(root, manifest["texts"], catalog["texts"])
    validate_manifest_components!(root, manifest, catalog)
    validate_generated_path_set!(root, manifest)
  end

  defp load_packaged_catalog!(root) do
    contents =
      read_bounded_release_regular_file!(
        root,
        @packaged_catalog,
        @max_metadata_bytes,
        :packaged_catalog_missing,
        3
      )

    catalog =
      case Jason.decode(contents) do
        {:ok, value} ->
          value

        {:error, _reason} ->
          fail!(:packaged_catalog_invalid, "packaged catalog is not valid JSON", 3)
      end

    case validate_catalog(catalog, validate_files: false) do
      {:ok, validated} -> validated
      {:error, error} -> fail!(:packaged_catalog_invalid, error.message, 3)
    end
  end

  defp validate_manifest_texts!(root, manifest_texts, catalog_texts) do
    validate_unique_ids!(manifest_texts, "manifest.texts", 3)

    expected_ids = catalog_texts |> Enum.map(& &1["id"]) |> Enum.sort()
    actual_ids = manifest_texts |> Enum.map(& &1["id"]) |> Enum.sort()

    unless actual_ids == expected_ids,
      do: fail!(:manifest_invalid, "manifest text closure differs from packaged catalog", 3)

    Enum.each(manifest_texts, &validate_manifest_text!(root, &1))
  end

  defp validate_manifest_text!(root, text) do
    unless Enum.sort(Map.keys(text)) == ["id", "path", "sha256"],
      do: fail!(:manifest_invalid, "manifest text record has unexpected fields", 3)

    id = require_identifier!(text["id"], "manifest.text.id", 3)
    expected_path = packaged_text_path(id)
    require_equal!(text["path"], expected_path, "manifest.text.path", 3)

    contents =
      read_bounded_release_regular_file!(
        root,
        expected_path,
        @max_metadata_bytes,
        :license_text_missing,
        3
      )

    require_equal!(text["sha256"], sha256(contents), "manifest.text.sha256", 3)
  end

  defp validate_manifest_components!(root, manifest, catalog) do
    records = manifest["components"]
    validate_unique_ids!(records, "manifest.components", 3)
    expected = target_components(catalog["components"], manifest["target"])

    expected_ids = expected |> Enum.map(& &1["id"]) |> Enum.sort()
    actual_ids = records |> Enum.map(& &1["id"]) |> Enum.sort()

    unless actual_ids == expected_ids,
      do: fail!(:manifest_invalid, "manifest component closure differs from packaged catalog", 3)

    expected_index = Map.new(expected, &{&1["id"], &1})
    record_index = Map.new(records, &{&1["id"], &1})
    app_index = manifest_application_index!(records)

    Enum.each(expected_ids, fn id ->
      validate_manifest_component!(
        root,
        Map.fetch!(record_index, id),
        Map.fetch!(expected_index, id),
        app_index
      )
    end)
  end

  defp manifest_application_index!(records) do
    records
    |> Enum.filter(&(&1["kind"] == "beam_app"))
    |> Map.new(fn record ->
      application = require_identifier!(record["application"], "manifest.application", 3)
      {application, record}
    end)
  end

  defp validate_manifest_component!(root, record, catalog_component, app_index) do
    kind = catalog_component["kind"]
    dynamic_keys = manifest_dynamic_keys(kind)
    expected_static = manifest_component_base(catalog_component)

    unless Map.drop(record, dynamic_keys) == expected_static,
      do:
        fail!(
          :manifest_invalid,
          "manifest component differs from catalog: #{catalog_component["id"]}",
          3
        )

    validate_manifest_component_kind!(kind, root, record, catalog_component, app_index)
  end

  defp manifest_component_base(component) do
    Map.take(
      component,
      ~w(id name kind license_expression text_ids targets provenance source source_required presence)
    )
  end

  defp manifest_dynamic_keys("beam_app"), do: ~w(application bundled pack path version)
  defp manifest_dynamic_keys("managed_file"), do: ~w(bundled path sha256)
  defp manifest_dynamic_keys("external"), do: ~w(bundled forbidden_paths)

  defp validate_manifest_component_kind!("beam_app", root, record, catalog, _app_index) do
    require_equal!(record["bundled"], true, "manifest.application.bundled", 3)
    application = require_identifier!(record["application"], "manifest.application", 3)
    require_equal!(application, catalog["application"], "manifest.application", 3)
    version = require_nonempty_string!(record["version"], "manifest.version", 3)
    expected_path = Path.join("lib", "#{application}-#{version}")
    require_equal!(record["path"], expected_path, "manifest.application.path", 3)

    assert_release_directory_path!(root, expected_path, 3)
    validate_manifest_pack!(root, record, catalog, application, expected_path)
  end

  defp validate_manifest_component_kind!("managed_file", root, record, catalog, app_index) do
    expected_path = resolve_managed_path!(catalog["file"], app_index, root)
    require_equal!(record["path"], expected_path, "manifest.managed_file.path", 3)

    case {catalog["presence"], record["bundled"]} do
      {"observed", false} ->
        require_equal!(record["sha256"], nil, "manifest.managed_file.sha256", 3)

        unless release_leaf_state!(root, expected_path, 3) == :absent,
          do: fail!(:manifest_invalid, "unbundled observed component is present", 3)

      {_presence, true} ->
        contents = read_release_regular_file!(root, expected_path, :managed_path_missing, 3)
        require_equal!(record["sha256"], sha256(contents), "manifest.managed_file.sha256", 3)

      {_presence, _bundled} ->
        fail!(:manifest_invalid, "required managed component is not bundled", 3)
    end
  end

  defp validate_manifest_component_kind!("external", root, record, catalog, _app_index) do
    require_equal!(record["bundled"], false, "manifest.external.bundled", 3)
    expected_paths = catalog["forbidden_paths"] || []
    require_equal!(record["forbidden_paths"], expected_paths, "manifest.forbidden_paths", 3)

    if Enum.any?(expected_paths, &File.exists?(Path.join(root, &1))),
      do: fail!(:external_runtime_bundled, "manifest external runtime is present", 3)
  end

  defp validate_manifest_pack!(root, record, catalog, application, app_path) do
    case {catalog["pack"], record["pack"]} do
      {nil, nil} ->
        :ok

      {%{} = source_pack, %{} = materialized_pack} ->
        unless Enum.sort(Map.keys(materialized_pack)) == @pack_manifest_keys,
          do: fail!(:manifest_invalid, "manifest Pack object has unexpected fields", 3)

        expected =
          Map.put(
            source_pack,
            "app_sha256",
            release_app_sha256!(root, app_path, application, 3)
          )

        unless materialized_pack == expected,
          do: fail!(:manifest_invalid, "manifest Pack projection differs from raw application", 3)

      {_source_pack, _materialized_pack} ->
        fail!(:manifest_invalid, "manifest Pack closure differs from packaged catalog", 3)
    end
  end

  defp release_app_sha256!(root, app_path, application, status) do
    ebin_relative = Path.join(app_path, "ebin")
    ebin = assert_release_directory_path!(root, ebin_relative, status)

    app_files =
      case File.ls(ebin) do
        {:ok, entries} ->
          Enum.filter(entries, &String.ends_with?(&1, ".app"))

        {:error, _reason} ->
          fail!(:manifest_invalid, "could not inspect packaged .app files", status)
      end

    expected_name = application <> ".app"

    unless app_files == [expected_name],
      do:
        fail!(
          :manifest_invalid,
          "packaged application must contain exactly #{expected_name}",
          status
        )

    root
    |> read_release_regular_file!(
      Path.join(ebin_relative, expected_name),
      :manifest_invalid,
      status
    )
    |> sha256()
  end

  defp validate_generated_path_set!(root, manifest) do
    text_paths = Enum.map(manifest["texts"], & &1["path"])
    expected = Enum.sort([@union_name, "LICENSE", "NOTICE", @packaged_catalog] ++ text_paths)
    records = manifest["generated_files"]
    paths = Enum.map(records, &normalize_relative!(&1["path"], "generated path", 3))

    if length(paths) != length(Enum.uniq(paths)) or Enum.sort(paths) != expected,
      do: fail!(:manifest_invalid, "generated-file closure is not exact", 3)

    actual = generated_license_paths!(root)

    unless actual == Enum.sort(Enum.filter(expected, &String.starts_with?(&1, "licenses/"))),
      do:
        fail!(
          :generated_file_corrupt,
          "packaged licenses tree contains stale or missing files",
          3
        )

    reject_generated_temps!(root)
  end

  defp generated_license_paths!(root) do
    license_root = Path.join(root, "licenses")

    unless regular_directory?(license_root),
      do: fail!(:unsafe_release_path, "packaged licenses path is not a real directory", 3)

    verify_release_directory_mode!(root, "licenses", "755", 3)
    verify_release_directory_mode!(root, @packaged_text_root, "755", 3)

    collect_generated_license_paths!(root, license_root)
    |> Enum.sort()
  end

  defp collect_generated_license_paths!(root, directory) do
    directory
    |> File.ls!()
    |> Enum.flat_map(fn name ->
      path = Path.join(directory, name)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} -> collect_generated_license_paths!(root, path)
        {:ok, %File.Stat{type: :regular}} -> [Path.relative_to(path, root)]
        _other -> fail!(:unsafe_release_path, "packaged licenses tree contains a non-file", 3)
      end
    end)
  rescue
    error ->
      fail!(
        :generated_file_corrupt,
        "could not inspect packaged licenses: #{Exception.message(error)}",
        3
      )
  end

  defp reject_generated_temps!(root) do
    [@union_name, @manifest_name, "LICENSE", "NOTICE"]
    |> Enum.flat_map(&Path.wildcard(Path.join(root, &1) <> ".tmp-*"))
    |> case do
      [] -> :ok
      _paths -> fail!(:generated_file_corrupt, "stale generated temporary file is present", 3)
    end
  end

  defp render_view!(args, root, manifest) do
    case normalize_view_args(args) do
      :summary -> %{output: render_summary(manifest), format: :text, data: manifest}
      :list -> %{output: render_list(manifest), format: :text, data: manifest["components"]}
      :json -> %{output: canonical_json(manifest), format: :json, data: manifest}
      :notices -> %{output: render_notices!(root), format: :text, data: nil}
      {:show, component} -> render_component!(component, root, manifest)
      :usage -> fail!(:invalid_arguments, viewer_usage(), 2)
    end
  end

  defp normalize_view_args([]), do: :summary
  defp normalize_view_args(["summary"]), do: :summary
  defp normalize_view_args(["list"]), do: :list
  defp normalize_view_args(["notices"]), do: :notices
  defp normalize_view_args(["--json"]), do: :json
  defp normalize_view_args(["summary", "--json"]), do: :json
  defp normalize_view_args(["show", component]) when component != "", do: {:show, component}
  defp normalize_view_args(_other), do: :usage

  defp render_summary(manifest) do
    components = manifest["components"]
    bundled = Enum.count(components, &(&1["bundled"] == true))
    external = Enum.count(components, &(&1["bundled"] == false))
    target = get_in(manifest, ["target", "triple"]) || "unspecified"

    [
      "Allbert packaged license evidence",
      "Target: #{target}",
      "Known components: #{length(components)} (#{bundled} bundled, #{external} external)",
      "Required texts: #{length(manifest["texts"])}",
      "Claim: #{manifest["claim"]}",
      render_warnings(manifest["warnings"])
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp render_warnings([]), do: ""
  defp render_warnings(warnings), do: "Warnings: " <> Enum.join(Enum.take(warnings, 20), " | ")

  defp render_list(manifest) do
    manifest["components"]
    |> Enum.sort_by(& &1["id"])
    |> Enum.map_join("\n", fn component ->
      disposition = if component["bundled"], do: "bundled", else: "external"
      "#{component["id"]}\t#{component["license_expression"]}\t#{disposition}"
    end)
  end

  defp render_component!(query, root, manifest) do
    matches =
      Enum.filter(manifest["components"], fn component ->
        query in [component["id"], component["name"], component["application"]]
      end)

    case matches do
      [component] ->
        text_index = Map.new(manifest["texts"], &{&1["id"], &1})

        texts =
          component["text_ids"]
          |> Enum.map(&read_component_text!(&1, text_index, root))

        header =
          [
            "Component: #{component["id"]}",
            "Name: #{component["name"]}",
            "Kind: #{component["kind"]}",
            "License: #{component["license_expression"]}",
            "Disposition: #{if(component["bundled"], do: "bundled", else: "external")}",
            if(component["path"], do: "Path: #{component["path"]}", else: nil),
            if(component["sha256"], do: "SHA-256: #{component["sha256"]}", else: nil)
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.join("\n")

        output = Enum.join([header | texts], "\n\n")
        %{output: output, format: :text, data: component}

      [] ->
        fail!(:component_not_found, "unknown packaged component: #{query}", 2)

      _many ->
        fail!(:component_ambiguous, "ambiguous packaged component: #{query}", 2)
    end
  end

  defp render_notices!(root) do
    notice =
      read_bounded_release_regular_file!(
        root,
        "NOTICE",
        @max_metadata_bytes,
        :generated_file_missing,
        3
      )

    union =
      read_bounded_release_regular_file!(
        root,
        @union_name,
        @max_metadata_bytes,
        :generated_file_missing,
        3
      )

    normalize_lf(notice) <> "\n" <> normalize_lf(union)
  end

  defp read_component_text!(id, text_index, root) do
    case Map.fetch(text_index, id) do
      {:ok, text} ->
        read_bounded_release_regular_file!(
          root,
          text["path"],
          @max_metadata_bytes,
          :license_text_missing,
          3
        )

      :error ->
        fail!(:manifest_invalid, "component references missing packaged text: #{id}", 3)
    end
  end

  defp packaged_text!(text, repo_root) do
    path = Path.join(repo_root, text["path"])
    contents = read_file!(path, :license_text_missing)
    packaged_contents = normalize_lf(contents)

    %{
      "id" => text["id"],
      "source_path" => normalize_relative!(text["path"], "text.path"),
      "sha256" => sha256(packaged_contents),
      "contents" => packaged_contents
    }
  end

  defp persist_union!(path, contents, true) do
    if read_file!(path, :union_missing) != contents,
      do: fail!(:union_drift, "#{@union_name} does not match the reviewed catalog")

    %{path: path, changed?: false, mode: :check}
  end

  defp persist_union!(path, contents, false) do
    current =
      case File.read(path) do
        {:ok, value} -> value
        _error -> nil
      end

    write_atomic!(path, contents)
    %{path: path, changed?: current != contents, mode: :write}
  end

  defp generated_file_records(generated) do
    generated
    |> Enum.map(fn {path, contents} ->
      %{"path" => path, "sha256" => sha256(contents), "mode" => "644"}
    end)
    |> Enum.sort_by(& &1["path"])
  end

  defp validate_committed_union!(committed, expected) do
    if committed != expected,
      do: fail!(:union_drift, "#{@union_name} does not match the reviewed catalog")
  end

  defp generated_outputs(products, license, notice) do
    fixed = [
      {@union_name, products.union},
      {"LICENSE", normalize_lf(license)},
      {"NOTICE", normalize_lf(notice)},
      {@packaged_catalog, products.catalog_json}
    ]

    texts = Enum.map(products.texts, &{packaged_text_path(&1["id"]), &1["contents"]})
    fixed ++ texts
  end

  defp manifest_text(text) do
    %{
      "id" => text["id"],
      "path" => packaged_text_path(text["id"]),
      "sha256" => text["sha256"]
    }
  end

  defp write_generated!(release_root, generated) do
    Enum.each(generated, fn {path, contents} ->
      write_atomic!(Path.join(release_root, path), contents)
    end)
  end

  defp normalize_generated_directory_modes!(release_root) do
    ["licenses", @packaged_text_root]
    |> Enum.each(fn relative ->
      case File.chmod(Path.join(release_root, relative), 0o755) do
        :ok ->
          :ok

        {:error, reason} ->
          fail!(:write_failed, "could not normalize generated directory: #{reason}")
      end
    end)
  end

  defp reset_generated_outputs!(release_root) do
    remove_owned_path!(Path.join(release_root, "licenses"))

    [@union_name, @manifest_name, "LICENSE", "NOTICE"]
    |> Enum.each(fn name ->
      path = Path.join(release_root, name)
      remove_owned_path!(path)
      Enum.each(Path.wildcard(path <> ".tmp-*"), &remove_owned_path!/1)
    end)
  end

  defp remove_owned_path!(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        case File.rm_rf(path) do
          {:ok, _removed} ->
            :ok

          {:error, reason, _failed} ->
            fail!(:write_failed, "could not reset generated path: #{reason}")
        end

      {:ok, _stat} ->
        case File.rm(path) do
          :ok -> :ok
          {:error, reason} -> fail!(:write_failed, "could not reset generated path: #{reason}")
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        fail!(:write_failed, "could not inspect generated path: #{reason}")
    end
  end

  defp viewer_usage do
    "Usage: allbert licenses [summary | list | show <component> | notices | --json]"
  end

  defp viewer_release_root(opts) do
    Keyword.get(opts, :release_root) ||
      System.get_env("RELEASE_ROOT") ||
      inferred_release_root() ||
      File.cwd!()
  end

  defp inferred_release_root do
    case :code.priv_dir(:allbert_assist) do
      path when is_list(path) -> Path.expand("../../..", List.to_string(path))
      _error -> nil
    end
  rescue
    _error -> nil
  end

  defp required_release_root!(opts) do
    case Keyword.get(opts, :release_root) do
      root when is_binary(root) and root != "" -> Path.expand(root)
      _other -> fail!(:release_root_required, "release_root is required")
    end
  end

  defp repo_root(opts), do: opts |> Keyword.get(:repo_root, File.cwd!()) |> Path.expand()

  defp packaged_text_path(id), do: Path.join(@packaged_text_root, id <> ".txt")

  defp write_atomic!(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      File.write!(tmp, normalize_lf(contents), [:binary])
      File.rename!(tmp, path)
      File.chmod!(path, 0o644)
    after
      File.rm(tmp)
    end

    :ok
  rescue
    error ->
      fail!(:write_failed, "could not write #{Path.basename(path)}: #{Exception.message(error)}")
  end

  defp read_bounded(path, max_bytes, code) do
    protect(fn -> read_bounded!(path, max_bytes, code) end)
  end

  defp read_bounded!(path, max_bytes, code) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= max_bytes ->
        read_file!(path, code)

      {:ok, %File.Stat{size: size}} when size > max_bytes ->
        fail!(:metadata_too_large, "license metadata exceeds #{max_bytes} bytes")

      _error ->
        fail!(code, "required license file missing: #{Path.basename(path)}")
    end
  end

  defp read_file!(path, code, status \\ 1) do
    case File.read(path) do
      {:ok, contents} ->
        contents

      {:error, reason} ->
        fail!(
          code,
          "required license file unreadable: #{Path.basename(path)} (#{reason})",
          status
        )
    end
  end

  defp read_release_regular_file!(root, relative, code, status \\ 1) do
    relative = normalize_relative!(relative, "release file", status)
    path = assert_regular_release_path!(root, relative, code, status)
    read_file!(path, code, status)
  end

  defp read_bounded_release_regular_file!(root, relative, max_bytes, code, status) do
    relative = normalize_relative!(relative, "release file", status)
    path = assert_regular_release_path!(root, relative, code, status)

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size <= max_bytes ->
        read_file!(path, code, status)

      {:ok, %File.Stat{size: _size}} ->
        fail!(:metadata_too_large, "packaged evidence is too large", status)

      {:error, _reason} ->
        fail!(code, "required release file missing: #{relative}", status)
    end
  end

  defp assert_regular_release_path!(root, relative, code, status) do
    parts = Path.split(relative)

    parts
    |> Enum.with_index()
    |> Enum.reduce(root, fn {part, index}, parent ->
      path = Path.join(parent, part)
      final? = index == length(parts) - 1

      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular}} when final? ->
          path

        {:ok, %File.Stat{type: :directory}} when not final? ->
          path

        {:ok, _stat} ->
          fail!(:unsafe_release_path, "release evidence path is not a regular file", status)

        {:error, _reason} ->
          fail!(code, "required release file missing: #{relative}", status)
      end
    end)
  end

  defp release_leaf_state!(root, relative, status) do
    parts = relative |> normalize_relative!("release file", status) |> Path.split()
    last_index = length(parts) - 1

    parts
    |> Enum.with_index()
    |> Enum.reduce_while(root, fn {part, index}, parent ->
      path = Path.join(parent, part)
      final? = index == last_index

      case File.lstat(path) do
        {:error, :enoent} when final? ->
          {:halt, :absent}

        {:ok, _stat} when final? ->
          {:halt, :present}

        {:ok, %File.Stat{type: :directory}} ->
          {:cont, path}

        _missing_or_unsafe ->
          fail!(
            :unsafe_release_path,
            "release evidence path has a missing or unsafe parent",
            status
          )
      end
    end)
  end

  defp assert_release_directory_path!(root, relative, status) do
    relative = normalize_relative!(relative, "release directory", status)

    relative
    |> Path.split()
    |> Enum.reduce(root, fn part, parent ->
      path = Path.join(parent, part)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} ->
          path

        _other ->
          fail!(:unsafe_release_path, "release directory path is missing or unsafe", status)
      end
    end)
  end

  defp regular_directory?(path) do
    match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))
  end

  defp verify_release_file_mode!(root, relative, expected, status) do
    path = assert_regular_release_path!(root, relative, :generated_file_missing, status)

    case File.lstat(path) do
      {:ok, %File.Stat{mode: mode}} ->
        if permission_mode(mode) == expected,
          do: :ok,
          else:
            fail!(:generated_file_corrupt, "packaged evidence mode mismatch: #{relative}", status)

      _other ->
        fail!(:generated_file_corrupt, "packaged evidence mode mismatch: #{relative}", status)
    end
  end

  defp verify_release_directory_mode!(root, relative, expected, status) do
    path = assert_release_directory_path!(root, relative, status)

    case File.lstat(path) do
      {:ok, %File.Stat{mode: mode}} ->
        if permission_mode(mode) == expected,
          do: :ok,
          else:
            fail!(
              :generated_file_corrupt,
              "packaged directory mode mismatch: #{relative}",
              status
            )

      _other ->
        fail!(
          :unsafe_release_path,
          "packaged directory is missing or unsafe: #{relative}",
          status
        )
    end
  end

  defp decode_json(contents, code) do
    case Jason.decode(contents) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> {:error, error(code, "license catalog is not valid JSON")}
    end
  end

  defp protect(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, error(:unexpected_failure, Exception.message(error))}
  catch
    {:license_error, error} -> {:error, error}
  end

  @spec fail!(atom(), String.t()) :: no_return()
  @spec fail!(atom(), String.t(), pos_integer()) :: no_return()
  @spec fail!(atom(), String.t(), pos_integer(), map()) :: no_return()
  defp fail!(code, message, status \\ 1, details \\ %{}) do
    throw({:license_error, error(code, message, status, details)})
  end

  defp error(code, message, status \\ 1, details \\ %{}) do
    %{
      code: code,
      message: "license evidence error [#{code}]: #{message}",
      exit_status: status,
      details: details
    }
  end

  defp require_map!(value, field, status \\ 1)
  defp require_map!(value, _field, _status) when is_map(value), do: value

  defp require_map!(_value, field, status),
    do: fail!(:invalid_schema, "#{field} must be an object", status)

  defp require_list!(value, field, status \\ 1)
  defp require_list!(value, _field, _status) when is_list(value), do: value

  defp require_list!(_value, field, status),
    do: fail!(:invalid_schema, "#{field} must be a list", status)

  defp require_nonempty_string!(value, field, status \\ 1)

  defp require_nonempty_string!(value, _field, _status) when is_binary(value) and value != "",
    do: value

  defp require_nonempty_string!(_value, field, status),
    do: fail!(:invalid_schema, "#{field} must be a non-empty string", status)

  defp require_boolean!(value, field, status \\ 1)
  defp require_boolean!(value, _field, _status) when is_boolean(value), do: value

  defp require_boolean!(_value, field, status),
    do: fail!(:invalid_schema, "#{field} must be boolean", status)

  defp require_equal!(actual, expected, field, status \\ 1) do
    unless actual == expected,
      do: fail!(:invalid_schema, "#{field} must equal #{inspect(expected)}", status)

    actual
  end

  defp require_one_of!(value, allowed, field, status \\ 1) do
    if value in allowed,
      do: value,
      else: fail!(:invalid_schema, "#{field} must be one of #{Enum.join(allowed, ", ")}", status)
  end

  defp require_nonnegative_integer!(value, _field, _status)
       when is_integer(value) and value >= 0,
       do: value

  defp require_nonnegative_integer!(_value, field, status),
    do: fail!(:invalid_schema, "#{field} must be a non-negative integer", status)

  defp require_identifier!(value, field, status \\ 1) do
    value = require_nonempty_string!(value, field, status)

    if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/, value),
      do: value,
      else: fail!(:invalid_schema, "#{field} is not a safe identifier", status)
  end

  defp require_sha256!(value, field, status \\ 1) do
    if is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value),
      do: value,
      else: fail!(:invalid_schema, "#{field} must be a lowercase SHA-256 digest", status)
  end

  defp require_immutable_url!(value, field) do
    uri = URI.parse(require_nonempty_string!(value, field))

    if uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and immutable_url?(value),
      do: value,
      else: fail!(:invalid_source, "#{field} must be an immutable HTTPS reference")
  end

  defp immutable_url?(url) do
    Regex.match?(~r/[0-9a-f]{40}/, url) or Regex.match?(~r/[0-9a-f]{64}/, url)
  end

  defp normalize_relative!(value, field, status \\ 1) do
    value = require_nonempty_string!(value, field, status)
    normalized = value |> String.replace("\\", "/") |> Path.split() |> Path.join()

    cond do
      Path.type(normalized) != :relative ->
        fail!(:invalid_path, "#{field} must be relative", status)

      ".." in Path.split(normalized) ->
        fail!(:invalid_path, "#{field} may not traverse upward", status)

      normalized in ["", "."] ->
        fail!(:invalid_path, "#{field} must name a file", status)

      true ->
        normalized
    end
  end

  defp validate_unique_ids!(entries, field, status \\ 1) do
    ids =
      Enum.map(entries, fn entry ->
        entry
        |> require_map!(field, status)
        |> Map.get("id")
        |> require_identifier!("#{field}.id", status)
      end)

    if length(ids) != length(Enum.uniq(ids)),
      do: fail!(:duplicate_id, "#{field} contains duplicate ids", status)
  end

  defp normalize_app_name!(value) when is_atom(value),
    do: value |> Atom.to_string() |> require_identifier!("application")

  defp normalize_app_name!(value), do: require_identifier!(value, "application")

  defp sha256(contents), do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)

  defp normalize_lf(contents),
    do:
      contents
      |> String.replace("\r\n", "\n")
      |> String.replace("\r", "\n")
      |> ensure_final_newline()

  defp ensure_final_newline(contents), do: String.trim_trailing(contents, "\n") <> "\n"

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)

  defp stringify(atom) when is_atom(atom) and atom not in [true, false, nil],
    do: Atom.to_string(atom)

  defp stringify(value), do: value

  defp encode_json(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join(",", fn {key, value} -> Jason.encode!(key) <> ":" <> encode_json(value) end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp encode_json(list) when is_list(list),
    do: "[" <> Enum.map_join(list, ",", &encode_json/1) <> "]"

  defp encode_json(value), do: Jason.encode!(value)

  defp escape_markdown(value) do
    value
    |> to_string()
    |> String.replace("|", "\\|")
    |> String.replace("`", "\\`")
    |> String.replace("\n", " ")
  end
end
