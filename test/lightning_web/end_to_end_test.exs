# This module will be re-introduced in https://github.com/OpenFn/Lightning/issues/1143
defmodule LightningWeb.EndToEndTest do
  use LightningWeb.ConnCase, async: false

  import Ecto.Query
  import Lightning.JobsFixtures
  import Lightning.Factories

  alias Lightning.Invocation
  alias Lightning.Runtime.RuntimeManager

  # workflow runs webhook then flow job
  defmacrop assert_has_expected_version?(string, dep) do
    quote do
      case unquote(dep) do
        :node ->
          assert unquote(string) =~ ~r/(?=.*node.js)(?=.*18.17)/

        :cli ->
          assert unquote(string) =~ ~r/(?=.*cli)(?=.*0.0.35)/

        :runtime ->
          assert unquote(string) =~ ~r/(?=.*runtime)(?=.*0.1.)/

        :compiler ->
          assert unquote(string) =~ ~r/(?=.*compiler)(?=.*0.0.29)/

        :adaptor ->
          assert unquote(string) =~ ~r/(?=.*language-http)(?=.*5.)/
      end
    end
  end

  setup_all context do
    start_runtime_manager(context)
  end

  describe "webhook triggered attempts" do
    setup :register_and_log_in_superuser

    test "complete an attempt on a simple workflow", %{conn: conn} do
      project = insert(:project)

      %{triggers: [%{id: webhook_trigger_id}]} =
        insert(:simple_workflow, project: project)

      # Post to webhook
      conn = post(conn, "/i/#{webhook_trigger_id}", %{"a" => 1})

      assert %{"work_order_id" => wo_id} = json_response(conn, 200)

      assert %{attempts: [%{id: attempt_id}]} =
               Lightning.WorkOrders.get(wo_id, include: [:attempts])

      assert %{runs: []} = Lightning.Attempts.get(attempt_id, include: [:runs])

      assert %{attempts: [%{id: attempt_id}]} =
               Lightning.WorkOrders.get(wo_id, include: [:attempts])

      # wait to complete
      assert Enum.any?(1..50, fn _i ->
               Process.sleep(100)
               %{state: state} = Lightning.Attempts.get(attempt_id)
               state == :success
             end)

      assert %{state: :success, attempts: [%{runs: [run]}]} =
               Lightning.WorkOrders.get(wo_id, include: [attempts: [:runs]])

      assert run.exit_reason == "success"
    end

    test "the whole thing", %{conn: conn} do
      project = insert(:project)

      project_credential =
        insert(:project_credential,
          credential: %{
            name: "test credential",
            body: %{"username" => "quux", "password" => "immasecret"}
          },
          project: project
        )

      %{
        job: first_job = %{workflow: workflow},
        trigger: webhook_trigger,
        edge: _edge
      } =
        workflow_job_fixture(
          project: project,
          name: "1st-job",
          adaptor: "@openfn/language-http@5.0.4",
          body: webhook_expression(),
          project_credential: project_credential
        )

      flow_job =
        insert(:job,
          name: "2nd-job",
          adaptor: "@openfn/language-http@5.0.4",
          body: flow_expression(),
          workflow: workflow,
          project_credential: project_credential
        )

      insert(:edge, %{
        workflow: workflow,
        source_job_id: first_job.id,
        target_job_id: flow_job.id,
        condition: :on_job_success
      })

      catch_job =
        insert(:job,
          name: "3rd-job",
          adaptor: "@openfn/language-http@5.0.4",
          body: catch_expression(),
          workflow: workflow,
          project_credential: project_credential
        )

      insert(:edge, %{
        source_job_id: flow_job.id,
        workflow: workflow,
        target_job_id: catch_job.id,
        condition: :on_job_failure
      })

      message = %{"a" => 1}

      conn = post(conn, "/i/#{webhook_trigger.id}", message)

      assert %{"work_order_id" => wo_id} = json_response(conn, 200)

      assert %{attempts: [%{id: attempt_id}]} =
               Lightning.WorkOrders.get(wo_id, include: [:attempts])

      assert %{runs: []} = Lightning.Attempts.get(attempt_id, include: [:runs])

      # wait to complete
      assert Enum.any?(1..50, fn _i ->
               Process.sleep(100)
               %{state: state} = Lightning.Attempts.get(attempt_id)
               IO.inspect(state)
               state == :success
             end)

      %{runs: runs} =
        attempt =
        Lightning.Attempts.get(attempt_id,
          include: [:runs, workflow: [:triggers, :jobs, :edges]]
        )

      Enum.each(runs, fn run ->
        assert run.exit_reason == "success"

        with attempt_run <-
               Lightning.Repo.get_by(Lightning.AttemptRun,
                 run_id: run.id,
                 attempt_id: attempt.id
               ) do
          from(r in Lightning.Invocation.Run, where: r.id == ^attempt_run.run_id)
          |> Lightning.Repo.all()
          |> then(fn [r] ->
            p =
              Ecto.assoc(r, [:job, :project])
              |> Lightning.Repo.one!()

            assert p.id == project.id,
                   "run is associated with a different project"
          end)
        end
      end)

      %{entries: [run_3, run_2, run_1]} =
        Invocation.list_runs_for_project(project)

      # Run 1 should succeed and use the appropriate packages
      assert run_1.finished_at != nil
      assert run_1.exit_reason == "success"

      assert Invocation.assemble_logs_for_run(run_1) =~ "Done in"

      r1_logs =
        Invocation.logs_for_run(run_1)
        |> Enum.map(fn line -> line.message end)

      # Check that versions are accurate and printed at the top of each run
      assert Enum.at(r1_logs, 0) == "[CLI] ℹ Versions:"
      Enum.at(r1_logs, 1) |> assert_has_expected_version?(:node)
      Enum.at(r1_logs, 2) |> assert_has_expected_version?(:cli)
      Enum.at(r1_logs, 3) |> assert_has_expected_version?(:runtime)
      Enum.at(r1_logs, 4) |> assert_has_expected_version?(:compiler)
      Enum.at(r1_logs, 5) |> assert_has_expected_version?(:adaptor)

      assert Enum.at(r1_logs, 11) =~ "[JOB] ℹ 2"
      assert Enum.at(r1_logs, 12) =~ "[JOB] ℹ {\"name\":\"ศผ่องรี มมซึฆเ\"}"
      assert Enum.at(r1_logs, 13) =~ "[R/T] ✔ Operation 1 complete in"
      assert Enum.at(r1_logs, 15) =~ "[CLI] ✔ Done in"

      # #  Run 2 should fail but not expose a secret
      assert run_2.finished_at != nil
      assert run_2.exit_reason == "success"

      log = Invocation.assemble_logs_for_run(run_2)
      assert log =~ ~S[{"password":"***","username":"quux"}]
      assert log =~ ~S[Error in runtime execution!]

      #  Run 3 should succeed and log "6"
      assert run_3.finished_at != nil
      assert run_3.exit_reason == "success"
      log = Invocation.assemble_logs_for_run(run_3)
      assert log =~ "[JOB] ℹ 6"
    end
  end

  defp webhook_expression do
    "fn(state => {
      state.x = state.data.a * 2;
      console.log(state.x);
      console.log({name: 'ศผ่องรี มมซึฆเ'})
      return state;
    });"
  end

  defp flow_expression do
    "fn(state => {
      console.log(state.configuration);
      throw 'fail!'
    });"
  end

  defp catch_expression do
    "fn(state => {
      state.x = state.x * 3;
      console.log(state.x);
      return state;
    });"
  end

  defp start_runtime_manager(_context) do
    rtm_args = "npm exec @openfn/ws-worker -- --backoff 0.5/5"

    Application.put_env(:lightning, RuntimeManager,
      start: true,
      args: String.split(rtm_args),
      cd: Path.expand("../../assets", __DIR__)
    )

    System.shell("kill $(lsof -n -i :2222 | grep LISTEN | awk '{print $2}')")
    {:ok, rtm_server} = RuntimeManager.start_link(name: TestRuntimeManager)

    Enum.any?(1..10, fn _i ->
      Process.sleep(50)

      %{runtime_port: port, runtime_os_pid: os_pid} =
        :sys.get_state(rtm_server)

      if port do
        {ps_out, 0} = System.cmd("ps", ["-s", "#{os_pid}", "-o", "cmd="])

        nodejs =
          ps_out
          |> String.split("\n")
          |> Enum.reject(&(&1 == ""))
          |> List.last()
          |> then(&String.trim/1)

        nodejs =~ "npm exec @openfn/ws-worker -- --backoff 0.5/5"
      end
    end)

    :ok
  end
end
