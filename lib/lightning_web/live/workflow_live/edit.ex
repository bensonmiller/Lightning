defmodule LightningWeb.WorkflowLive.Edit do
  @moduledoc false
  use LightningWeb, :live_view

  alias Lightning.Policies.ProjectUsers
  alias Lightning.Policies.Permissions
  alias Lightning.Projects
  alias Lightning.Workflows
  alias Lightning.Workflows.Workflow
  alias LightningWeb.Components.Form
  alias LightningWeb.WorkflowNewLive.WorkflowParams

  import LightningWeb.WorkflowLive.Components

  on_mount({LightningWeb.Hooks, :project_scope})

  attr :changeset, :map, required: true
  attr :project_user, :map, required: true

  def follow_run(attempt_run) do
    send(self(), {:follow_run, attempt_run})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <LayoutComponents.page_content>
      <:header>
        <LayoutComponents.header socket={@socket}>
          <:title>
            <.workflow_name_field changeset={@changeset} />
          </:title>
          <.with_changes_indicator changeset={@changeset}>
            <Form.submit_button
              class=""
              phx-disable-with="Saving..."
              disabled={!@changeset.valid?}
              form="workflow-form"
            >
              Save
            </Form.submit_button>
          </.with_changes_indicator>
        </LayoutComponents.header>
      </:header>
      <div class="relative h-full flex">
        <div
          phx-hook="WorkflowEditor"
          class="grow"
          id={"editor-#{@project.id}"}
          phx-update="ignore"
        >
          <%!-- Before Editor component has mounted --%>
          <div class="flex place-content-center h-full cursor-wait">
            <.box_loader />
          </div>
        </div>
        <%!-- Job Edit View --%>
        <div class="flex-none" id="job-editor-pane">
          <div
            :if={@selected_job && @selection_mode == "expand"}
            class="absolute hidden inset-0 z-20"
            phx-mounted={fade_in()}
            phx-remove={fade_out()}
          >
            <LightningWeb.WorkflowLive.JobView.job_edit_view
              job={@selected_job}
              current_user={@current_user}
              project={@project}
              socket={@socket}
              on_run={&follow_run/1}
              follow_run_id={@follow_run_id}
              close_url={
                "#id=#{@selected_job.id}"
              }
              form={to_form(@changeset)}
            />
          </div>
        </div>
        <.form
          :let={f}
          :if={@selected_job}
          id="workflow-form"
          for={@changeset}
          phx-submit="save"
          phx-hook="SubmitViaCtrlS"
          phx-change="validate"
        >
          <.panel
            title={
              single_inputs_for(f, :jobs, @selected_job.id)
              |> input_value(:name)
              |> then(fn
                "" -> "Untitled Job"
                name -> name
              end)
            }
            id={"job-pane-#{@selected_job.id}"}
            cancel_url={~p"/projects/#{@project.id}/w/#{@workflow.id || "new"}"}
          >
            <!-- Show only the currently selected one -->
            <.job_form
              on_change={&send_form_changed/1}
              form={single_inputs_for(f, :jobs, @selected_job.id)}
              project_user={@project_user}
            />
            <:footer>
              <.link
                href={
                  "#id=#{@selected_job.id}&mode=expand"
                }
                class="px-4 py-1.5 h-10 inline-flex items-center gap-x-1.5
                rounded-md bg-indigo-600 text-sm font-semibold text-white
                shadow-sm hover:bg-indigo-500
                focus-visible:outline focus-visible:outline-2
                focus-visible:outline-offset-2 focus-visible:outline-indigo-600"
              >
                <Heroicons.pencil_square class="w-4 h-4 -ml-0.5" /> Edit
              </.link>
            </:footer>
          </.panel>
        </.form>

        <.form
          :let={f}
          :if={@selected_trigger}
          id="workflow-form"
          for={@changeset}
          phx-submit="save"
          phx-change="validate"
        >
          <.panel
            id={"trigger-pane-#{@selected_trigger.id}"}
            title={
              single_inputs_for(f, :triggers, @selected_trigger.id)
              |> input_value(:type)
              |> to_string()
              |> then(fn
                "" -> "New Trigger"
                "webhook" -> "Webhook Trigger"
                "cron" -> "Cron Trigger"
              end)
            }
            cancel_url={~p"/projects/#{@project.id}/w/#{@workflow.id || "new"}"}
          >
            <div class="w-auto h-full" id={"trigger-pane-#{@workflow.id}"}>
              <!-- Show only the currently selected one -->
              <.trigger_form
                form={single_inputs_for(f, :triggers, @selected_trigger.id)}
                on_change={&send_form_changed/1}
                requires_cron_job={@selected_trigger.type == :cron}
                disabled={!@can_edit_job}
                webhook_url={webhook_url(@selected_trigger)}
                cancel_url={~p"/projects/#{@project.id}/w/#{@workflow.id || "new"}"}
              />
            </div>
          </.panel>
        </.form>

        <.form
          :let={f}
          :if={@selected_edge}
          id="workflow-form"
          for={@changeset}
          phx-submit="save"
          phx-change="validate"
        >
          <.panel
            id={"edge-pane-#{@selected_edge.id}"}
            cancel_url={~p"/projects/#{@project.id}/w/#{@workflow.id || "new"}"}
            title="Edge"
          >
            <div class="w-auto h-full" id={"edge-pane-#{@workflow.id}"}>
              <!-- Show only the currently selected one -->
              <.edge_form
                form={single_inputs_for(f, :edges, @selected_edge.id)}
                disabled={!@can_edit_job}
                cancel_url={~p"/projects/#{@project.id}/w/#{@workflow.id || "new"}"}
              />
            </div>
          </.panel>
        </.form>
      </div>
    </LayoutComponents.page_content>
    """
  end

  defp single_inputs_for(form, field, id) do
    form
    |> inputs_for(field)
    |> Enum.find(&(Ecto.Changeset.get_field(&1.source, :id) == id))
  end

  @impl true
  def mount(_params, _session, socket) do
    project = socket.assigns.project

    project_user =
      Projects.get_project_user(project, socket.assigns.current_user)

    can_edit_job =
      ProjectUsers
      |> Permissions.can(
        :edit_job,
        socket.assigns.current_user,
        project
      )

    {:ok,
     socket
     |> assign(
       active_menu_item: :projects,
       can_edit_job: can_edit_job,
       expanded_job: nil,
       follow_run_id: nil,
       page_title: "",
       project: project,
       project_user: project_user,
       selected_edge: nil,
       selected_job: nil,
       selected_trigger: nil,
       selection_mode: nil
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  def apply_action(socket, :new, _params) do
    assign(socket,
      page_title: "New Workflow"
    )
    |> assign_workflow(%Workflow{project_id: socket.assigns.project.id})
    |> unselect_all()
  end

  def apply_action(socket, :edit, %{"id" => workflow_id}) do
    # TODO we shouldn't be calling Repo from here
    workflow =
      Workflows.get_workflow(workflow_id)
      |> Lightning.Repo.preload([
        :triggers,
        :edges,
        jobs: [:credential]
      ])

    assign(socket,
      page_title: "New Workflow"
    )
    |> assign_workflow(workflow)
    |> unselect_all()
  end

  @impl true
  def handle_event("get-initial-state", _params, socket) do
    {:noreply,
     socket
     |> push_event("current-workflow-params", %{
       workflow_params: socket.assigns.workflow_params
     })}
  end

  def handle_event("close_job_editor", _, socket) do
    {:noreply, socket |> assign(selection_mode: nil)}
  end

  def handle_event("set_expanded_job", %{"show" => show}, socket)
      when show in ["true", "false"] do
    {:noreply, socket |> assign(selection_mode: "expand")}
  end

  def handle_event("hash-changed", %{"hash" => hash}, socket) do
    with {"#", query} <- String.split_at(hash, 1),
         %{"id" => id, "mode" => mode} <-
           URI.decode_query(query) |> Enum.into(%{"mode" => nil}),
         [type, selected] <- find_item_in_changeset(socket.assigns.changeset, id) do
      {:noreply,
       socket
       |> select_node({type, selected}, mode)
       |> maybe_unfollow_run()}
    else
      _ -> {:noreply, socket |> unselect_all()}
    end
  end

  def handle_event("validate", %{"workflow" => params}, socket) do
    initial_params = socket.assigns.workflow_params

    next_params =
      WorkflowParams.apply_form_params(socket.assigns.workflow_params, params)

    {:noreply,
     socket
     |> apply_params(next_params)
     |> push_patches_applied(initial_params)}
  end

  def handle_event("save", %{"workflow" => params}, socket) do
    initial_params = socket.assigns.workflow_params

    next_params =
      WorkflowParams.apply_form_params(socket.assigns.workflow_params, params)

    socket = socket |> apply_params(next_params)

    socket =
      Lightning.Repo.insert_or_update(socket.assigns.changeset)
      |> case do
        {:ok, workflow} ->
          socket
          |> assign_workflow(workflow)
          |> put_flash(:info, "Workflow saved")

        {:error, changeset} ->
          socket
          |> assign_changeset(changeset)
          |> put_flash(:error, "Workflow could not be saved")
      end
      |> push_patches_applied(initial_params)

    {:noreply, socket}
  end

  def handle_event("push-change", %{"patches" => patches}, socket) do
    # Apply the incoming patches to the current workflow params producing a new
    # set of params.
    {:ok, params} =
      WorkflowParams.apply_patches(socket.assigns.workflow_params, patches)

    socket = socket |> apply_params(params)

    # Calculate the difference between the new params and changes introduced by
    # the changeset/validation.
    patches = WorkflowParams.to_patches(params, socket.assigns.workflow_params)

    {:reply, %{patches: patches}, socket}
  end

  def handle_event("copied_to_clipboard", _, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Copied webhook URL to clipboard")}
  end

  @impl true
  def handle_info({"form_changed", %{"workflow" => params}}, socket) do
    initial_params = socket.assigns.workflow_params

    next_params =
      WorkflowParams.apply_form_params(socket.assigns.workflow_params, params)

    {:noreply,
     socket
     |> apply_params(next_params)
     |> push_patches_applied(initial_params)}
  end

  def handle_info({:follow_run, attempt_run}, socket) do
    {:noreply, socket |> assign(follow_run_id: attempt_run.run_id)}
  end

  defp webhook_url(trigger) do
    with %{type: :webhook, id: id} <- trigger do
      Routes.webhooks_url(LightningWeb.Endpoint, :create, [id])
    else
      _ -> nil
    end
  end

  defp send_form_changed(params) do
    send(self(), {"form_changed", params})
  end

  defp assign_workflow(socket, workflow) do
    changeset = Workflow.changeset(workflow, %{})

    socket
    |> assign(
      workflow: workflow,
      changeset: changeset,
      workflow_params: WorkflowParams.to_map(changeset)
    )
  end

  defp apply_params(socket, params) do
    # Build a new changeset from the new params
    changeset =
      socket.assigns.workflow
      |> Workflow.changeset(
        params
        |> Map.put("project_id", socket.assigns.project.id)
      )

    socket |> assign_changeset(changeset)
  end

  defp assign_changeset(socket, changeset) do
    # Prepare a new set of workflow params from the changeset
    workflow_params = changeset |> WorkflowParams.to_map()

    socket |> assign(changeset: changeset, workflow_params: workflow_params)
  end

  defp push_patches_applied(socket, initial_params) do
    next_params = socket.assigns.workflow_params

    patches = WorkflowParams.to_patches(initial_params, next_params)

    socket
    |> push_event("patches-applied", %{patches: patches})
  end

  defp unselect_all(socket) do
    socket
    |> assign(selected_job: nil, selected_trigger: nil, selected_edge: nil)
  end

  defp select_node(socket, {type, value}, selection_mode) do
    case type do
      :jobs ->
        socket
        |> assign(selected_job: value, selected_trigger: nil, selected_edge: nil)

      :triggers ->
        socket
        |> assign(selected_job: nil, selected_trigger: value, selected_edge: nil)

      :edges ->
        socket
        |> assign(selected_job: nil, selected_trigger: nil, selected_edge: value)
    end
    |> assign(selection_mode: selection_mode)
  end

  defp maybe_unfollow_run(socket) do
    if changed?(socket, :selected_job) do
      socket |> assign(follow_run_id: nil)
    else
      socket
    end
  end

  # find the changeset for the selected item
  # it could be an edge, a job or a trigger
  defp find_item_in_changeset(changeset, id) do
    [:jobs, :triggers, :edges]
    |> Enum.reduce_while(nil, fn field, _ ->
      Ecto.Changeset.get_assoc(changeset, field, :struct)
      |> Enum.find(&(&1.id == id))
      |> case do
        nil ->
          {:cont, nil}

        changeset ->
          {:halt, [field, changeset]}
      end
    end)
  end

  defp box_loader(assigns) do
    ~H"""
    <span class="inline-block top-[50%] w-10 h-10 relative border-4
                 border-gray-400 animate-spin-pause">
      <span class="align-top inline-block w-full bg-gray-400 animate-fill-up"></span>
    </span>
    """
  end

  defp with_changes_indicator(assigns) do
    ~H"""
    <div class="relative">
      <div
        :if={@changeset.changes |> Enum.any?()}
        class="absolute -m-1 rounded-full bg-danger-500 w-3 h-3 top-0 right-0"
      >
      </div>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end
end