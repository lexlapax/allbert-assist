# The Web owner depends downward on composition, so composition cannot declare
# Web as a Mix/OTP dependency. Owner-scoped composition tests still exercise the
# complete four-application product projection: add only the compiled Web ebin,
# then restart composition after Mix's dependency-only startup attempt.
_ = Application.stop(:allbert_composition)

web_ebin = Path.join([Mix.Project.build_path(), "lib", "allbert_assist_web", "ebin"])

unless Code.prepend_path(web_ebin) do
  raise "could not add test Web product code path: #{web_ebin}"
end

case Application.ensure_all_started(:allbert_composition) do
  {:ok, _started} -> :ok
  {:error, reason} -> raise "could not start test Pack composition: #{inspect(reason)}"
end

pack_ready_deadline = System.monotonic_time(:millisecond) + 60_000

pack_ready_wait = fn wait ->
  case AllbertAssist.Pack.Readiness.status(timeout: 1_000) do
    {:ok, %{phase: :ready}} ->
      :ok

    _other ->
      if System.monotonic_time(:millisecond) < pack_ready_deadline do
        Process.sleep(25)
        wait.(wait)
      else
        raise "Pack readiness did not open for composition owner tests"
      end
  end
end

pack_ready_wait.(pack_ready_wait)
ExUnit.start()
