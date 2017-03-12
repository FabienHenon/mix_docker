defmodule MixDocker do
  require Logger

  @dockerfile_path    :code.priv_dir(:mix_docker)
  @dockerfile_build   Application.get_env(:mix_docker, :dockerfile_build, "Dockerfile.build")
  @dockerfile_release Application.get_env(:mix_docker, :dockerfile_release, "Dockerfile.release")

  def init(args) do
    # copy .dockerignore
    unless File.exists?(".dockerignore") do
      File.cp(Path.join([@dockerfile_path, "dockerignore"]), ".dockerignore")
    end

    Mix.Task.run("release.init", args)
  end

  def build(args) do
    with_dockerfile @dockerfile_build, fn ->
      docker :build, @dockerfile_build, image(:build), args
    end

    Mix.shell.info "Docker image #{image(:build)} has been successfully created"
  end

  def release(args) do
    project = Mix.Project.get.project
    app     = project[:app]
    version = project[:version]

    cid = "mix_docker-#{:rand.uniform(1000000)}"

    with_dockerfile @dockerfile_release, fn ->
      docker :rm, cid
      docker :create, cid, image(:build)
      docker :cp, cid, "/opt/app/_build/prod/rel/#{app}/releases/#{version}/#{app}.tar.gz", "#{app}.tar.gz"
      docker :rm, cid
      docker :build, @dockerfile_release, image(:release), args
    end

    Mix.shell.info "Docker image #{image(:release)} has been successfully created"
    Mix.shell.info "You can now test your app with the following command:"
    Mix.shell.info "  docker run -it --rm #{image(:release)} foreground"
  end

  def publish(_args) do
    name = image(:version)

    docker :tag, image(:release), name
    docker :push, name

    name = image(:latest)

    docker :tag, image(:release), name
    docker :push, name

    Mix.shell.info "Docker images #{image(:version)} and #{image(:latest)} have been successfully created and pushed"
  end

  def shipit(args) do
    build(args)
    release(args)
    publish(args)
  end

  def bump(args) do
    suffix =
      if length(args) > 0 do
        [s | _] = args
        s
      else
        ""
      end

      version = bump_version()

      git :add, "mix.exs"
      git :commit, "Version #{version} #{suffix}"
      git :push

      git :tag, version
      git :push, ["--tags"]
  end

  def deploy(args) do
    default_args =
      %{service_id: System.get_env("RANCHER_SERVICE_ID"),
      image_name: image(:version),
      rancher_url: System.get_env("RANCHER_URL"),
      rancher_access_key: System.get_env("RANCHER_ACCESS_KEY"),
      rancher_secret_key: System.get_env("RANCHER_SECRET_KEY")}

    args = Enum.reduce(args, default_args, fn(arg, args) ->
      case arg do
        "--url=" <> url ->
          %{args | rancher_url: url}
        "--access-key=" <> access_key ->
          %{args | rancher_access_key: access_key}
        "--secret-key=" <> secret_key ->
          %{args | rancher_secret_key: secret_key}
        "--service=" <> service ->
          %{args | service_id: service}
        image_tag ->
          %{args | image_name: image(image_tag)}
      end
    end)

    if args |> Map.values |> Enum.any?(&is_nil/1), do: raise "Missing parameters. We need: --url, --access-key, --secret-key, --service. Or env variables: RANCHER_SERVICE_ID, RANCHER_URL, RANCHER_ACCESS_KEY, RANCHER_SECRET_KEY"

    docker :run, [
      "-e", "RANCHER_URL=#{args.rancher_url}",
      "-e", "RANCHER_ACCESS_KEY=#{args.rancher_access_key}",
      "-e", "RANCHER_SECRET_KEY=#{args.rancher_secret_key}",
      "etlweather/gaucho",
      "upgrade", "#{args.service_id}",
      "--complete_previous=True",
      "--imageUuid=docker:#{args.image_name}",
      "--auto_complete=True"]
  end

  def customize([]) do
    try_copy_dockerfile @dockerfile_build
    try_copy_dockerfile @dockerfile_release
  end

  defp git_head_sha do
    {sha, 0} = System.cmd "git", ["rev-parse", "HEAD"]
    String.slice(sha, 0, 10)
  end

  defp git_commit_count do
    {count, 0} = System.cmd "git", ["rev-list", "--count", "HEAD"]
    String.trim(count)
  end

  defp image(tag) do
    image_name() <> ":" <> to_string(image_tag(tag))
  end

  defp image_name do
    Application.get_env(:mix_docker, :image) || to_string(Mix.Project.get.project[:app])
  end

  defp image_tag(:version) do
    version = Mix.Project.get.project[:version]
    count   = git_commit_count()
    sha     = git_head_sha()

    "#{version}.#{count}-#{sha}"
  end
  defp image_tag(tag), do: tag


  defp docker(:cp, cid, source, dest) do
    system! "docker", ["cp", "#{cid}:#{source}", dest]
  end

  defp docker(:build, dockerfile, tag, args) do
    system! "docker", ["build", "-f", dockerfile, "-t", tag] ++ args ++ ["."]
  end

  defp docker(:create, name, image) do
    system! "docker", ["create", "--name", name, image]
  end

  defp docker(:tag, image, tag) do
    system! "docker", ["tag", image, tag]
  end

  defp docker(:rm, cid) do
    system "docker", ["rm", "-f", cid]
  end

  defp docker(:push, image) do
    system! "docker", ["push", image]
  end

  defp docker(:run, args) do
    system! "docker", ["run" | ["--rm" | ["-t" | args]]]
  end

  defp git(:add, file) do
    system! "git", ["add", file]
  end

  defp git(:commit, message) do
    system! "git", ["commit", "-m", message]
  end

  defp git(:push) do
    git :push, []
  end

  defp git(:push, opts) do
    system! "git", ["push" | opts]
  end

  defp git(:tag, tag) do
    system! "git", ["tag", tag]
  end

  defp with_dockerfile(name, fun) do
    if File.exists?(name) do
      fun.()
    else
      try do
        copy_dockerfile(name)
        fun.()
      after
        File.rm(name)
      end
    end
  end

  defp copy_dockerfile(name) do
    app = Mix.Project.get.project[:app]
    content = [@dockerfile_path, name]
      |> Path.join
      |> File.read!
      |> String.replace("${APP}", to_string(app))
    File.write!(name, content)
  end

  defp try_copy_dockerfile(name) do
    if File.exists?(name) do
      Logger.warn("#{name} already exists")
    else
      copy_dockerfile(name)
    end
  end

  defp system(cmd, args) do
    Logger.debug "$ #{cmd} #{args |> Enum.join(" ")}"
    System.cmd(cmd, args, into: IO.stream(:stdio, :line))
  end

  defp system!(cmd, args) do
    {_, 0} = system(cmd, args)
  end

  defp bump_version() do
    mix_exs_path = "mix.exs"

    unless File.exists?(mix_exs_path), do: raise "Impossible to open file #{mix_exs_path}!"

    Logger.debug "Bumping #{mix_exs_path}..."

    File.write mix_exs_path, (
      File.read!(mix_exs_path)
      |> String.split("\n")
      |> (Enum.map fn(line) ->
        Regex.replace(~r/version:\s*"(\d+)\.(\d+)\.(\d+)"/, line, fn(_, major, minor, sub) ->
          {sub, _} = Integer.parse(sub)
          old_version = "#{major}.#{minor}.#{sub}"
          new_version = "#{major}.#{minor}.#{sub + 1}"
          Logger.debug "Bumping from #{old_version} to #{new_version}"
          "version: \"#{major}.#{minor}.#{sub + 1}\""
        end)
      end)
      |> Enum.join("\n")
    )

    # Getting new version
    File.read!(mix_exs_path)
    |> String.split("\n")
    |> (Enum.reduce "", fn(line, version) ->
      case Regex.run(~r/version:\s*"(\d+)\.(\d+)\.(\d+)"/, line) do
        [_, major, minor, sub] ->
          "#{major}.#{minor}.#{sub}"
        nil ->
          version
      end
    end)
  end
end
