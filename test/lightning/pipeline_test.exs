defmodule Lightning.PipelineTest do
  use Lightning.DataCase, async: true
  use Mimic

  alias Lightning.Pipeline

  import Lightning.InvocationFixtures
  import Lightning.JobsFixtures
  import Lightning.CredentialsFixtures
  import Lightning.ProjectsFixtures

  describe "process/1" do
    test "starts a run for a given event and executes its on_job_failure downstream job" do
      job =
        job_fixture(
          body: ~s[fn(state => { throw new Error("I'm supposed to fail.") })]
        )

      %{id: downstream_job_id} =
        job_fixture(
          trigger: %{type: :on_job_failure, upstream_job_id: job.id},
          body: ~s[fn(state => state)],
          project_credential_id:
            project_credential_fixture(
              name: "my credential",
              body: %{"credential" => "body"}
            ).id
        )

      invocation =
        Lightning.Invocation.Factory.build(:webhook, %{
          job: job,
          dataclip: dataclip_fixture()
        })
        |> Repo.insert!()

      Pipeline.process(invocation)

      expected_run =
        from(e in Lightning.Invocation.Run,
          where: e.job_id == ^downstream_job_id,
          preload: :output_dataclip
        )
        |> Repo.one!()

      assert %{
               "configuration" => %{"credential" => "body"},
               "data" => %{},
               "error" => error
             } = expected_run.output_dataclip.body

      error = Enum.slice(error, 0..4)

      [
        ~r/╭─[─]+─╮/,
        ~r/│ ◲ ◱ [ ]+@openfn\/core#v1.4.7 \(Node.js v1[\d\.]+\) │/,
        ~r/│ ◳ ◰ [ ]+@openfn\/language-common@[\d\.]+ │/,
        ~r/╰─[─]+─╯/,
        "Error: I'm supposed to fail."
      ]
      |> Enum.zip(error)
      |> Enum.each(fn {m, l} ->
        assert l =~ m
      end)
    end

    test "starts a run for a given event and executes its on_job_success downstream job" do
      project = project_fixture()

      project_credential =
        credential_fixture(project_credentials: [%{project_id: project.id}])
        |> Map.get(:project_credentials)
        |> List.first()

      other_project_credential =
        credential_fixture(
          name: "my credential",
          body: %{"credential" => "body"},
          project_credentials: [%{project_id: project.id}]
        )
        |> Map.get(:project_credentials)
        |> List.first()

      job =
        job_fixture(
          body: ~s[fn(state => { return {...state, extra: "data"} })],
          project_credential_id: project_credential.id,
          project_id: project.id
        )

      %{id: downstream_job_id} =
        job_fixture(
          trigger: %{type: :on_job_success, upstream_job_id: job.id},
          name: "on previous job success",
          body: ~s[fn(state => state)],
          project_id: project.id,
          project_credential_id: other_project_credential.id
        )

      invocation =
        Lightning.Invocation.Factory.build(:webhook, %{
          job: job,
          dataclip: dataclip_fixture()
        })
        |> Repo.insert!()

      source_run_id = invocation.run.id
      # event = event_fixture(job_id: job.id)
      # run_fixture(event_id: event.id)

      Pipeline.process(invocation)

      expected_invocation =
        from(i in Lightning.Invocation.Invocation,
          join: r in assoc(i, :run),
          on: r.source_run_id == ^source_run_id,
          where: i.job_id == ^downstream_job_id,
          preload: :output_dataclip
        )
        |> Repo.one!()

      assert %{
               "configuration" => %{"credential" => "body"},
               "data" => %{},
               "extra" => "data"
             } == expected_invocation.run.output_dataclip.body
    end
  end
end
