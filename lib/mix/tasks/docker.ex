defmodule Mix.Tasks.Docker.Init do
  use Mix.Task

  @shortdoc "Initialize distillery release"

  defdelegate run(args), to: MixDocker, as: :init
end

defmodule Mix.Tasks.Docker.Build do
  use Mix.Task

  @shortdoc "Build docker image from distillery release"
  @preferred_cli_env :prod

  defdelegate run(args), to: MixDocker, as: :build
end

defmodule Mix.Tasks.Docker.Release do
  use Mix.Task

  @shortdoc "Build minimal, self-contained docker image"
  @preferred_cli_env :prod

  defdelegate run(args), to: MixDocker, as: :release
end

defmodule Mix.Tasks.Docker.Publish do
  use Mix.Task

  @shortdoc "Publish current image to docker registry"
  @preferred_cli_env :prod

  defdelegate run(args), to: MixDocker, as: :publish
end

defmodule Mix.Tasks.Docker.Shipit do
  use Mix.Task

  @shortdoc "Run build & release & publish"
  @preferred_cli_env :prod

  defdelegate run(args), to: MixDocker, as: :shipit
end

defmodule Mix.Tasks.Docker.Customize do
  use Mix.Task

  @shortdoc "Copy & customize Dockerfiles"
  @preferred_cli_env :prod

  defdelegate run(args), to: MixDocker, as: :customize
end

# defmodule Mix.Tasks.Docker.Deploy do
#   use Mix.Task
#
#   @shortdoc "Deploy the docker image in Rancher"
#   @preferred_cli_env :prod
#
#   defdelegate run(args), to: MixDocker, as: :deploy
# end

defmodule Mix.Tasks.Docker.Bump do
  use Mix.Task

  @shortdoc "Bumps the project version, create git tag and push everything. Can take a commit message suffix"
  @preferred_cli_env :prod

  defdelegate run(args), to: MixDocker, as: :bump
end

# Deploy cmd: release image in Rancher using docker image (access env given in parameters, as well as service id)
# Prod cmd: should upgrade given service with latest image (is image nma enot given in parameter to deploy)
