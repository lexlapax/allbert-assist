defmodule AllbertAssist.Settings.SystemIntegrityTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.KeyCustody
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Settings.Store
  alias AllbertAssist.Settings.StoreLock
  alias AllbertAssist.Settings.YamlCodec

  @integrity_ref "secret://system/integrity_v1"
  @key_version 1
  @aad "settings:v1"
  @cipher "aes-256-gcm"
  @tag_bytes 16
  @domains [
    "allbert.tui.receipt-payload.v1",
    "allbert.memory.claim-transition.v1",
    "allbert.memory.manual-confirmation.v1",
    "allbert.memory.destination-chain-confirmation.v1",
    "allbert.memory.forget-suppression.v1",
    "allbert.search.cursor.v1",
    "allbert.search.query-scope.v1",
    "allbert.search.purge-preview.v1",
    "allbert.conversations.delete-preview.v1"
  ]

  @env_vars [
    "ALLBERT_HOME",
    "ALLBERT_HOME_DIR",
    "ALLBERT_SETTINGS_ROOT",
    "ALLBERT_SETTINGS_MASTER_KEY"
  ]

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)

    home = temp_path("home")
    System.put_env("ALLBERT_HOME", home)
    KeyCustody.invalidate(:all)

    on_exit(fn ->
      KeyCustody.invalidate(:all)
      File.rm_rf!(home)
      restore_env(original_env)
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
    end)

    {:ok, home: home}
  end

  test "first system HMAC use commits one encrypted Home key before returning", %{home: home} do
    assert {:ok,
            %{
              tag: tag,
              key_ref: @integrity_ref,
              key_version: @key_version
            }} =
             KeyCustody.system_hmac(
               "allbert.tui.receipt-payload.v1",
               ["tui-input-v1", "remember this"],
               @key_version
             )

    assert byte_size(tag) == 32

    secrets_path = Path.join([home, "settings", "secrets.yml.enc"])
    assert File.exists?(secrets_path)

    assert {:ok, envelope} = YamlCodec.read_file(secrets_path)
    assert envelope["version"] == 1
    assert envelope["cipher"] == "aes-256-gcm"
    refute File.read!(secrets_path) =~ @integrity_ref

    assert Secrets.status(@integrity_ref) == :invalid_ref
    assert {:error, {:invalid_secret_ref, @integrity_ref}} = Secrets.get_secret(@integrity_ref)
    assert {:ok, statuses} = Secrets.list_secret_status()
    refute Enum.any?(statuses, &(&1.secret_ref == @integrity_ref))

    refute inspect(:sys.get_state(Process.whereis(KeyCustody))) =~ @integrity_ref
    refute inspect(:sys.get_status(Process.whereis(KeyCustody))) =~ @integrity_ref
  end

  test "verification uses the referenced key without exposing it" do
    domain = "allbert.tui.receipt-payload.v1"
    fields = ["tui-input-v1", "remember this"]

    assert {:ok, %{tag: tag}} = KeyCustody.system_hmac(domain, fields, @key_version)

    assert {:ok, true} =
             KeyCustody.verify_system_hmac(
               domain,
               fields,
               tag,
               @integrity_ref,
               @key_version
             )

    assert {:ok, false} =
             KeyCustody.verify_system_hmac(
               domain,
               ["tui-input-v1", "changed"],
               tag,
               @integrity_ref,
               @key_version
             )
  end

  test "verification of missing referenced material fails closed without replacement", %{
    home: home
  } do
    domain = "allbert.tui.receipt-payload.v1"
    fields = ["tui-input-v1", "already-referenced-payload"]

    assert {:ok, %{tag: tag}} = KeyCustody.system_hmac(domain, fields, @key_version)

    secrets_path = Path.join([home, "settings", "secrets.yml.enc"])
    assert :ok = File.rm(secrets_path)
    KeyCustody.invalidate(:all)

    assert {:error, {:system_integrity_key_unavailable, @key_version}} =
             KeyCustody.verify_system_hmac(
               domain,
               fields,
               tag,
               @integrity_ref,
               @key_version
             )

    refute File.exists?(secrets_path)
  end

  test "malformed decrypted top-level data fails closed without overwrite", %{home: home} do
    key = :crypto.strong_rand_bytes(32)
    System.put_env("ALLBERT_SETTINGS_MASTER_KEY", Base.encode64(key))

    malformed_plaintexts = [
      %{},
      %{"version" => 2, "secrets" => %{}},
      %{"version" => 1, "secrets" => []},
      %{"version" => 1, "secrets" => %{}, "unexpected" => true}
    ]

    Enum.each(malformed_plaintexts, fn plaintext ->
      secrets_path = write_encrypted_plaintext!(home, key, plaintext)
      encrypted_before = File.read!(secrets_path)
      KeyCustody.invalidate(:all)

      assert {:error, {:invalid_system_integrity_store, :plaintext_shape}} =
               KeyCustody.system_hmac(
                 "allbert.tui.receipt-payload.v1",
                 ["tui-input-v1", "must-not-overwrite"],
                 @key_version
               )

      assert File.read!(secrets_path) == encrypted_before

      assert {:error, {:invalid_system_integrity_store, :plaintext_shape}} =
               Secrets.put_secret(
                 "secret://channels/telegram/bot_token",
                 "must-not-overwrite",
                 %{audit?: false}
               )

      assert File.read!(secrets_path) == encrypted_before

      assert {:error, {:invalid_system_integrity_store, :plaintext_shape}} =
               Secrets.delete_secret("secret://channels/telegram/bot_token")

      assert File.read!(secrets_path) == encrypted_before
    end)
  end

  test "concurrent first use converges on one durable key and preserves user secrets" do
    user_ref = "secret://channels/telegram/bot_token"

    assert {:ok, %{status: :configured}} =
             Secrets.put_secret(user_ref, "keep-user-secret", %{audit?: false})

    calls =
      for _index <- 1..24 do
        Task.async(fn ->
          KeyCustody.system_hmac(
            "allbert.tui.receipt-payload.v1",
            ["tui-input-v1", "same-payload"],
            @key_version
          )
        end)
      end

    tags =
      Enum.map(calls, fn call ->
        assert {:ok, %{tag: tag, key_ref: @integrity_ref, key_version: @key_version}} =
                 Task.await(call)

        tag
      end)

    assert tags |> MapSet.new() |> MapSet.size() == 1
    [tag | _rest] = tags

    KeyCustody.invalidate(:all)

    assert {:ok, %{tag: ^tag}} =
             KeyCustody.system_hmac(
               "allbert.tui.receipt-payload.v1",
               ["tui-input-v1", "same-payload"],
               @key_version
             )

    assert {:ok, "keep-user-secret"} = Secrets.get_secret(user_ref, %{audit?: false})
  end

  test "the frozen v1.3 domains are separated and arbitrary domains are rejected" do
    tags =
      Enum.map(@domains, fn domain ->
        assert {:ok, %{tag: tag}} =
                 KeyCustody.system_hmac(domain, ["same", "ordered", "fields"], @key_version)

        tag
      end)

    assert tags |> MapSet.new() |> MapSet.size() == length(@domains)

    assert {:error, {:unsupported_system_integrity_domain, "allbert.plugin.chosen.v1"}} =
             KeyCustody.system_hmac(
               "allbert.plugin.chosen.v1",
               ["same", "ordered", "fields"],
               @key_version
             )
  end

  test "ordered fields use an unambiguous length-prefixed encoding" do
    domain = "allbert.tui.receipt-payload.v1"

    assert {:ok, %{tag: left_tag}} =
             KeyCustody.system_hmac(domain, ["ab", "c"], @key_version)

    assert {:ok, %{tag: right_tag}} =
             KeyCustody.system_hmac(domain, ["a", "bc"], @key_version)

    assert {:ok, %{tag: reordered_tag}} =
             KeyCustody.system_hmac(domain, ["c", "ab"], @key_version)

    refute left_tag == right_tag
    refute left_tag == reordered_tag

    assert {:ok, %{tag: ^left_tag}} =
             KeyCustody.system_hmac(domain, ["ab", "c"], @key_version)
  end

  test "invalid system-integrity inputs fail before key creation", %{home: home} do
    domain = "allbert.tui.receipt-payload.v1"

    assert {:error, {:invalid_system_integrity_fields, :not_a_list}} =
             KeyCustody.system_hmac(domain, "already-concatenated", @key_version)

    assert {:error, {:invalid_system_integrity_fields, :non_binary_field}} =
             KeyCustody.system_hmac(domain, ["valid", 1], @key_version)

    assert {:error, {:unsupported_system_integrity_key_version, 2}} =
             KeyCustody.system_hmac(domain, ["valid"], 2)

    assert {:error, {:invalid_system_integrity_tag, :expected_32_bytes}} =
             KeyCustody.verify_system_hmac(
               domain,
               ["valid"],
               <<0>>,
               @integrity_ref,
               @key_version
             )

    assert {:error, {:unsupported_system_integrity_key_ref, "secret://system/other"}} =
             KeyCustody.verify_system_hmac(
               domain,
               ["valid"],
               :binary.copy(<<0>>, 32),
               "secret://system/other",
               @key_version
             )

    refute File.exists?(Path.join([home, "settings", "secrets.yml.enc"]))
  end

  test "system-key creation and user-secret writes share one store transaction lock" do
    parent = self()

    holder =
      Task.async(fn ->
        StoreLock.with_lock(Store.root(), fn ->
          send(parent, :store_lock_held)

          receive do
            :release_store_lock -> :ok
          end
        end)
      end)

    assert_receive :store_lock_held

    user_ref = "secret://channels/telegram/bot_token"

    user_write =
      Task.async(fn ->
        send(parent, :user_write_started)
        result = Secrets.put_secret(user_ref, "preserved-user-secret", %{audit?: false})
        send(parent, {:user_write_finished, result})
        result
      end)

    assert_receive :user_write_started
    refute_receive {:user_write_finished, _result}, 100

    system_write =
      Task.async(fn ->
        KeyCustody.system_hmac(
          "allbert.tui.receipt-payload.v1",
          ["tui-input-v1", "concurrent-payload"],
          @key_version
        )
      end)

    send(holder.pid, :release_store_lock)

    assert :ok = Task.await(holder)
    assert {:ok, %{status: :configured}} = Task.await(user_write)
    assert {:ok, %{tag: tag}} = Task.await(system_write)

    KeyCustody.invalidate(:all)

    assert {:ok, true} =
             KeyCustody.verify_system_hmac(
               "allbert.tui.receipt-payload.v1",
               ["tui-input-v1", "concurrent-payload"],
               tag,
               @integrity_ref,
               @key_version
             )

    assert {:ok, "preserved-user-secret"} = Secrets.get_secret(user_ref, %{audit?: false})
  end

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-system-integrity-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  defp write_encrypted_plaintext!(home, key, plaintext) do
    nonce = :crypto.strong_rand_bytes(12)
    plaintext_yaml = YamlCodec.encode!(plaintext)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        nonce,
        plaintext_yaml,
        @aad,
        @tag_bytes,
        true
      )

    envelope = %{
      "version" => 1,
      "cipher" => @cipher,
      "nonce" => Base.encode64(nonce),
      "tag" => Base.encode64(tag),
      "ciphertext" => Base.encode64(ciphertext)
    }

    path = Path.join([home, "settings", "secrets.yml.enc"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, YamlCodec.encode!(envelope))
    path
  end

  defp restore_env(original_env) do
    Enum.each(original_env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
