defmodule Lightning.DemoTest do
  use Lightning.DataCase, async: true

  alias Lightning.Accounts
  alias Lightning.Projects
  alias Lightning.Workflows
  alias Lightning.Jobs
  alias Lightning.Accounts.User

  describe "Setup demo site seed data" do
    setup do
      Lightning.Demo.setup(create_super: true)
    end

    test "all initial data is present in database", %{
      users: [super_user, admin, editor, viewer] = users,
      projects: [openhie_project, dhis2_project] = projects,
      workflows: [openhie_workflow, dhis2_workflow] = workflows,
      jobs:
        [
          fhir_standard_data,
          send_to_openhim,
          notify_upload_successful,
          notify_upload_failed,
          get_dhis2_data,
          upload_to_google_sheet
        ] = jobs
    } do
      assert users |> Enum.count() == 4
      assert projects |> Enum.count() == 2
      assert workflows |> Enum.count() == 2
      assert jobs |> Enum.count() == 6

      assert super_user.email == "super@openfn.org"
      User.valid_password?(super_user, "welcome123")

      assert admin.email == "demo@openfn.org"
      User.valid_password?(admin, "welcome123")

      assert editor.email == "editor@openfn.org"
      User.valid_password?(editor, "welcome123")

      assert viewer.email == "viewer@openfn.org"
      User.valid_password?(viewer, "welcome123")

      assert Enum.map(
               openhie_project.project_users,
               fn project_user -> project_user.user_id end
             ) == [admin.id, editor.id, viewer.id]

      assert Enum.map(
               dhis2_project.project_users,
               fn project_user -> project_user.user_id end
             ) == [admin.id]

      assert fhir_standard_data.workflow_id == openhie_workflow.id
      assert send_to_openhim.workflow_id == openhie_workflow.id
      assert notify_upload_successful.workflow_id == openhie_workflow.id
      assert notify_upload_failed.workflow_id == openhie_workflow.id
      assert get_dhis2_data.workflow_id == dhis2_workflow.id
      assert upload_to_google_sheet.workflow_id == dhis2_workflow.id

      assert fhir_standard_data.trigger.type == :webhook

      assert send_to_openhim.trigger.type == :on_job_success
      assert send_to_openhim.trigger.upstream_job_id == fhir_standard_data.id

      assert notify_upload_successful.trigger.type == :on_job_success

      assert notify_upload_successful.trigger.upstream_job_id ==
               send_to_openhim.id

      assert notify_upload_failed.trigger.type == :on_job_failure
      assert notify_upload_failed.trigger.upstream_job_id == send_to_openhim.id

      assert get_dhis2_data.trigger.type == :cron
      assert get_dhis2_data.trigger.cron_expression == "0 * * * *"

      assert upload_to_google_sheet.trigger.type == :on_job_success
      assert upload_to_google_sheet.trigger.upstream_job_id == get_dhis2_data.id

      assert (Enum.map(users, fn user -> user.id end) --
                Enum.map(Accounts.list_users(), fn user -> user.id end))
             |> Enum.empty?()

      assert (Enum.map(projects, fn project -> project.id end) --
                Enum.map(Projects.list_projects(), fn project -> project.id end))
             |> Enum.empty?()

      assert (Enum.map(workflows, fn workflow -> workflow.id end) --
                Enum.map(Workflows.list_workflows(), fn workflow ->
                  workflow.id
                end))
             |> Enum.empty?()

      assert (Enum.map(jobs, fn job -> job.id end) --
                Enum.map(Jobs.list_jobs(), fn job -> job.id end))
             |> Enum.empty?()
    end
  end
end