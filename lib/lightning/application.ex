defmodule Lightning.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  import Cachex.Spec

  @impl true
  def start(_type, _args) do
    # Only add the Sentry backend if a dsn is provided.
    if Application.get_env(:sentry, :included_environments) |> Enum.any?(),
      do: Logger.add_backend(Sentry.LoggerBackend)

    adaptor_registry_childspec =
      {Lightning.AdaptorRegistry,
       Application.get_env(:lightning, Lightning.AdaptorRegistry, [])}

    adaptor_service_childspec =
      {Lightning.AdaptorService,
       [name: :adaptor_service]
       |> Keyword.merge(Application.get_env(:lightning, :adaptor_service))}

    auth_providers_cache_childspec =
      {Cachex,
       name: :auth_providers,
       warmers: [
         warmer(module: Lightning.AuthProviders.CacheWarmer)
       ]}

    events = [
      [:oban, :circuit, :open],
      [:oban, :circuit, :trip],
      [:oban, :job, :exception]
    ]

    :telemetry.attach_many(
      "oban-errors",
      events,
      &Lightning.ObanManager.handle_event/4,
      nil
    )

    :ok = Oban.Telemetry.attach_default_logger(:debug)

    children = [
      Lightning.Vault,
      # Start the Ecto repository
      Lightning.Repo,
      # Start Oban,
      {Oban, Application.fetch_env!(:lightning, Oban)},
      # Start the Telemetry supervisor
      LightningWeb.Telemetry,
      # Start the PubSub system
      {Phoenix.PubSub, name: Lightning.PubSub},
      auth_providers_cache_childspec,
      # Start the Endpoint (http/https)
      LightningWeb.Endpoint,
      adaptor_registry_childspec,
      adaptor_service_childspec
      # Start the rate limiter for email alerts
      # {ExRated, [[], [name: :ex_rated]]}
      # Start a worker by calling: Lightning.Worker.start_link(arg)
      # {Lightning.Worker, arg}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Lightning.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LightningWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
