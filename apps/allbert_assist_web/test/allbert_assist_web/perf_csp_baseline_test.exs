defmodule AllbertAssistWeb.PerfCspBaselineTest do
  use AllbertAssistWeb.ConnCase, async: false

  @moduletag :perf_csp_baseline

  alias AllbertAssist.Paths
  alias AllbertAssist.Portability.Export
  alias AllbertAssist.Portability.Import
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.VersionContract

  @export_import_floor_us 2_000_000
  @boot_overhead_floor_us 50_000

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-perf-csp-baseline-#{System.unique_integer([:positive])}"
      )

    home_a = Path.join(root, "home-a")
    home_b = Path.join(root, "home-b")
    evidence = Path.join(root, "evidence")

    Application.put_env(:allbert_assist, Paths, home: home_a)
    Application.delete_env(:allbert_assist, Settings)

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    Paths.ensure_home!()
    File.mkdir_p!(home_b)
    File.mkdir_p!(evidence)
    seed_representative_home!(home_a)

    {:ok, home_a: home_a, home_b: home_b, evidence: evidence}
  end

  test "perf-and-csp-baseline-001: portability thresholds and CSP targets are locked",
       %{conn: conn, home_a: home_a, home_b: home_b, evidence: evidence} do
    export_baseline_us = timed_us(fn -> export_envelope!(home_a) end)
    {export_us, envelope} = timed_value_us(fn -> export_envelope!(home_a) end)
    export_target = export_import_target(export_baseline_us)
    assert export_us <= export_target.limit_us

    envelope_path = Path.join(evidence, "home-a.envelope.json")
    File.write!(envelope_path, Jason.encode!(envelope, pretty: true))

    import_baseline_us = timed_us(fn -> dry_run_import!(envelope_path, home_b) end)
    {import_us, diagnostic} = timed_value_us(fn -> dry_run_import!(envelope_path, home_b) end)
    import_target = export_import_target(import_baseline_us)
    assert import_us <= import_target.limit_us
    assert diagnostic["dry_run"] == true
    assert diagnostic["applied"] == false

    boot_baseline_us = timed_us(fn -> VersionContract.inventory(user_settings: %{}) end)
    boot_check_us = timed_us(fn -> VersionContract.status_from_store() end)
    boot_overhead_us = max(0, boot_check_us - boot_baseline_us)
    boot_target_us = max(@boot_overhead_floor_us, trunc(boot_baseline_us * 1.10))
    assert boot_overhead_us <= boot_target_us

    landing = get(conn, ~p"/")
    workspace = conn |> recycle() |> get(~p"/workspace")
    landing_csp = single_csp!(landing)
    workspace_csp = single_csp!(workspace)

    assert landing_csp == workspace_csp
    assert_csp_target!(landing_csp)
    assert_csp_target!(workspace_csp)

    emit_perf_evidence("export", export_baseline_us, export_us, export_target)
    emit_perf_evidence("dry-run import", import_baseline_us, import_us, import_target)

    IO.puts(
      "perf-and-csp-baseline-001 boot-check baseline_ms=#{ms(boot_baseline_us)} " <>
        "overhead_ms=#{ms(boot_overhead_us)} target_ms=#{ms(boot_target_us)} " <>
        "formula=max(50ms, baseline * 1.10) " <>
        "evidence=#{threshold_evidence(boot_baseline_us, @boot_overhead_floor_us)}"
    )

    IO.puts(
      "perf-and-csp-baseline-001 content-security-policy workspace=present " <>
        "landing=present unsafe-inline=false allowlist=none wildcard=false remote source=false " <>
        "policy=#{workspace_csp}"
    )
  end

  defp seed_representative_home!(home) do
    File.mkdir_p!(Path.join(home, "memory/notes"))
    File.mkdir_p!(Path.join(home, "skills/demo-skill"))
    File.mkdir_p!(Path.join(home, "workspace/canvas"))
    File.mkdir_p!(Path.join(home, "traces"))

    File.write!(Path.join(home, "memory/notes/note.md"), "portable note\n")
    File.write!(Path.join(home, "skills/demo-skill/SKILL.md"), "# Demo\n")
    File.write!(Path.join(home, "workspace/canvas/state.json"), Jason.encode!(%{tiles: []}))
    File.write!(Path.join(home, "traces/trace.jsonl"), ~s({"status":"completed"}\n))
    File.write!(Path.join(home, "settings/secrets.yml.enc"), "sk-test raw-secret\n")
    File.write!(Path.join(home, "settings/.settings_key"), "raw-secret\n")

    assert {:ok, _settings} =
             Settings.write_user_settings(%{
               "providers" => %{
                 "openai" => %{
                   "enabled" => true,
                   "base_url" => "http://127.0.0.1:9999/v1",
                   "api_key_ref" => "secret://providers/openai/api_key"
                 }
               }
             })
  end

  defp export_envelope!(home) do
    assert {:ok, envelope} = Export.build(home: home)
    envelope
  end

  defp dry_run_import!(envelope_path, home) do
    assert {:ok, diagnostic} = Import.dry_run(envelope_path, target_home: home)
    diagnostic
  end

  defp export_import_target(baseline_us) do
    %{
      limit_us: max(@export_import_floor_us, trunc(baseline_us * 1.25)),
      rationale:
        if(baseline_us > @export_import_floor_us,
          do: "baseline_over_2s_recorded_with_rationale",
          else: "baseline_under_2s_floor_applies"
        ),
      evidence: threshold_evidence(baseline_us, @export_import_floor_us)
    }
  end

  defp emit_perf_evidence(label, baseline_us, measured_us, target) do
    IO.puts(
      "perf-and-csp-baseline-001 #{label} baseline_ms=#{ms(baseline_us)} " <>
        "measured_ms=#{ms(measured_us)} target_ms=#{ms(target.limit_us)} " <>
        "formula=max(2s, baseline * 1.25) rationale=#{target.rationale} " <>
        "evidence=#{target.evidence}"
    )
  end

  defp threshold_evidence(baseline_us, floor_us) do
    if baseline_us > floor_us, do: "regression_guard", else: "smoke_bound"
  end

  defp timed_us(fun) do
    {us, _value} = timed_value_us(fun)
    us
  end

  defp timed_value_us(fun) do
    {us, value} = :timer.tc(fun)
    {us, value}
  end

  defp ms(us), do: :erlang.float_to_binary(us / 1000, decimals: 3)

  defp single_csp!(conn) do
    assert [csp] = get_resp_header(conn, "content-security-policy")
    csp
  end

  defp assert_csp_target!(csp) do
    assert csp =~ "default-src 'self'"
    assert csp =~ "style-src 'self'"
    assert csp =~ "img-src 'self' data:"
    assert csp =~ "media-src 'self'"
    assert csp =~ "font-src 'self'"
    assert csp =~ "connect-src 'self'"
    assert csp =~ "script-src 'self'"
    assert csp =~ "frame-ancestors 'none'"
    assert csp =~ "object-src 'none'"
    refute csp =~ "unsafe-inline"
    refute remote_wildcard_source?(csp)
  end

  defp remote_wildcard_source?(csp) do
    csp
    |> String.split([";", " "], trim: true)
    |> Enum.any?(&(&1 in ["*", "http:", "https:", "ws:", "wss:"]))
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
