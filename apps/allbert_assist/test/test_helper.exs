ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(AllbertAssist.Repo, :manual)

test_home =
  Path.join(
    System.tmp_dir!(),
    "allbert-assist-test-home-#{System.unique_integer([:positive])}"
  )

Application.put_env(:allbert_assist, AllbertAssist.Paths, home: test_home)

Application.put_env(:allbert_assist, AllbertAssist.Skills.Registry,
  user_interoperable_root: Path.join(test_home, "agent-skills")
)
