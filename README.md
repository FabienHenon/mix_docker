# mix docker

[![Build Status](https://travis-ci.org/Recruitee/mix_docker.svg?branch=master)](https://travis-ci.org/Recruitee/mix_docker)

Put your Elixir app inside minimal Docker image.
Based on [alpine linux](https://hub.docker.com/r/bitwalker/alpine-erlang/)
and [distillery](https://github.com/bitwalker/distillery) releases.

## Installation

  1. Add `mix_docker` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [{:mix_docker, "~> 0.3.0"}]
end
```

  2. Configure Docker image name

```elixir
# config/config.exs
config :myapp, :env, Mix.env
config :mix_docker, image: "recruitee/hello"
```

  3. Run `mix docker.init` to init distillery release configuration

  4. Run `mix docker.build` & `mix docker.release` to build the image. See [Usage](#Usage) for more.

  5. Configure prod correctly for release

```elixir
# config/prod.exs
config :myapp, :rancher_service_name, "${RANCHER_SERVICE_NAME}"

config :myapp, MyApp.Endpoint,
  http: [port: "${PORT}"],
  url: [host: "${HOST}", port: "${PORT}"],
  # cache_static_manifest: "priv/static/manifest.json", # If not needed
  secret_key_base: "${SECRET_KEY_BASE}",
  server: true,
  root: ".",
  version: Mix.Project.config[:version]

config :myapp, :env, :prod
```

**Be carefull of configuration variables that are used in macros (during compilation) because they won't be replaced by their environment variable value at this moment. Thus at runtime the configuration won't be correct**

  6. Add path to custom `vm.args` file in distillery config

```elixir
# rel/config.exs
environment :prod do
  set vm_args: "rel/vm.args"
end
```

  7. Create `rel/vm.args`

```
# rel/vm.args
## Name of the node - this is the only change
-name myapp@${RANCHER_IP}

## Cookie for distributed erlang
-setcookie something_to_change

## Heartbeat management; auto-restarts VM if it dies or becomes unresponsive
## (Disabled by default..use with caution!)
##-heart

## Enable kernel poll and a few async threads
##+K true
##+A 5

## Increase number of concurrent ports/sockets
##-env ERL_MAX_PORTS 4096

## Tweak GC to run more often
##-env ERL_FULLSWEEP_AFTER 10

# Enable SMP automatically based on availability
-smp auto

```

  8. Create `rel/rancher_boot.sh` with execution rights

```sh
#!/bin/sh
set -e

export RANCHER_IP=$(wget -qO- http://rancher-metadata.rancher.internal/latest/self/container/primary_ip)
export RANCHER_SERVICE_NAME=$(wget -qO- http://rancher-metadata.rancher.internal/latest/self/service/name)

/opt/app/bin/myapp $@
```

  9. Add deployment script for CI/CD tool:

```sh
#!/bin/bash

export PATH="$HOME/dependencies/erlang/bin:$HOME/dependencies/elixir/bin:$PATH"

mix docker.bump "[ci skip]"
mix docker.build
mix docker.release
mix docker.publish
mix docker.deploy
```

**Don't forget to update your `circle.yml` or travis equivalent to use this script for deployment and to configure docker and git:**

```
# Example for CircleCI
deployment:
  registry:
    branch: master
    commands:
      - git config user.name "circleci"
      - git config user.email "email@company.com"
      - docker login -e $DOCKER_EMAIL -u $DOCKER_USER -p $DOCKER_PASS registry_url
      - scripts/ci/deploy.sh

```

You must set the following environment variables and a [read/write SSH key for github](https://circleci.com/docs/1.0/adding-read-write-deployment-key/)

* `DOCKER_EMAIL`: Email used in the docker registry
* `DOCKER_USER`: User name used to authenticate in the registry
* `DOCKER_PASS`: Password used to authenticate in the registry
* `RANCHER_SERVICE_ID`: ID of the Rancher service to upgrade for deployment
* `RANCHER_ACCESS_KEY`: Access key for Rancher API
* `RANCHER_SECRET_KEY`: Secret key for Rancher API
* `RANCHER_URL`: Rancher API Url

You must also add support for docker in your CI/CD tool. For example with CircleCI:

```
machine:
  pre:
    - curl -sSL https://s3.amazonaws.com/circle-downloads/install-circleci-docker.sh | bash -s -- 1.10.0

  services:
    - docker
```

  10. Add `Dockerfile.build`

```
FROM bitwalker/alpine-erlang:19.2.1b

ENV HOME=/opt/app/ TERM=xterm

# Install Elixir and basic build dependencies
RUN \
    echo "@edge http://nl.alpinelinux.org/alpine/edge/community" >> /etc/apk/repositories && \
    apk update && \
    apk --no-cache --update add \
      git make g++ \
      elixir@edge && \
    rm -rf /var/cache/apk/*

# Install Hex+Rebar
RUN mix local.hex --force && \
    mix local.rebar --force

RUN elixir --version

WORKDIR /opt/app

ENV MIX_ENV=prod

# Cache elixir deps
COPY mix.exs mix.lock ./
RUN mix do deps.get, deps.compile

COPY . .

RUN mix release --env=prod --verbose
```

  11. Add `Dockerfile.release`

```
FROM bitwalker/alpine-erlang:19.2.1b

RUN apk update && \
    apk --no-cache --update add libgcc libstdc++ && \
    rm -rf /var/cache/apk/*

EXPOSE 4000
ENV PORT=4000 MIX_ENV=prod REPLACE_OS_VARS=true SHELL=/bin/sh

ADD myapp.tar.gz ./
RUN chown -R default ./releases

USER default

# the only change are these two lines
COPY rel/rancher_boot.sh /opt/app/bin/rancher_boot.sh
ENTRYPOINT ["/opt/app/bin/rancher_boot.sh"]
```

**Replace `myapp.tar.gz` by your app name**

  12. Add `rancher.ex` file in the `lib/` directory to add auto discovery with rancher

```elixir
defmodule MyApp.Rancher do
  use GenServer

  require Logger

  @connect_interval 5000 # try to connect every 5 seconds

  def start_link do
    GenServer.start_link __MODULE__, [], name: __MODULE__
  end

  def init([]) do
    name = Application.fetch_env!(:myapp, :rancher_service_name)
    send self(), :connect

    {:ok, to_char_list(name)}
  end

  def handle_info(:connect, name) do
    case :inet_tcp.getaddrs(name) do
      {:ok, ips} ->
        Logger.debug "Connecting to #{name}: #{inspect ips}"
        for {a,b,c,d} <- ips do
          Node.connect :"myapp@#{a}.#{b}.#{c}.#{d}"
        end

      {:error, reason} ->
        Logger.debug "Error resolving #{inspect name}: #{inspect reason}"
    end

    Logger.info "Nodes: #{inspect Node.list}"
    Process.send_after(self(), :connect, @connect_interval)

    {:noreply, name}
  end
end
```

  13. Add this code to your supervision tree

```elixir
# myapp.ex

# ...

children =
  if Application.get_env(:myapp, :env) == :prod do
    [worker(MyApp.Rancher, []) | children]
  else
    children
  end

# ...
```

  14. Eventually [create erlang commands to run migrations](https://github.com/bitwalker/distillery/blob/256f002c75b79d5b22b857a0e24d4b5d29a4215a/docs/Running%20Migrations.md) and what you may also need.

  15. Add these lines in the specified files if using `tzdata` lib (with `timex` or `calendar`)

```elixir
# config/prod.exs
config :tzdata, :data_dir, "/opt/app/elixir_tzdata_data"
```

```
# Dockerfile.release

#...
USER default

# Only this line is new
RUN mkdir /opt/app/elixir_tzdata_data

#...
```

  16. For umbrella apps you will need to copy mix.exs files from each app in `Dockerfile.build`:

```
# Dockerfile.build

# Cache elixir deps
COPY mix.exs mix.lock ./

# Add this line for each project
RUN mkdir -p apps/my_app/config
COPY apps/my_app/mix.exs apps/my_app/
```

You will also need to add an `app` name and a `version` to your root `mix.exs` file.

## Guides

- [Getting Started Tutorial](http://teamon.eu/2017/deploying-phoenix-to-production-using-docker/)
- [Setting up cluster with Rancher](http://teamon.eu/2017/setting-up-elixir-cluster-using-docker-and-rancher/)
- [Phoenix App Configuration Walkthrough](https://shovik.com/blog/8-deploying-phoenix-apps-with-docker)

## Usage

### Build a release
Run `mix docker.build` to build a release inside docker container

### Create minimal run container
Run `mix docker.release` to put the release inside minimal docker image

### Publish to docker registry
Run `mix docker.publish` to push newly created image to docker registry

### All three in one pass
Run `mix docker.shipit`

### Customize default Dockerfiles
Run `mix docker.customize`

### Deploy to Rancher
Run `mix docker.deploy`


## FAQ

#### How to configure my app?

Using ENV variables.
The provided Docker images contain `REPLACE_OS_VARS=true`, so you can use `"${VAR_NAME}"` syntax in `config/prod.exs`
like this:

```elixir
config :hello, Hello.Endpoint,
  server: true,
  url: [host: "${DOMAIN}"]

config :hello, Hello.Mailer,
  adapter: Bamboo.MailgunAdapter,
  api_key: "${MAILGUN_API_KEY}"
```


#### How to attach to running app using remote_console?

The easiest way is to `docker exec` into running container and run the following command,
where `CID` is the app container IO and `hello` is the name of your app.

```bash
docker exec -it CID /opt/app/bin/hello remote_console
```


#### How to install additional packages into build/release image?

First, run `mix docker.customize` to copy `Dockerfile.build` and `Dockerfile.release` into your project directory.
Now you can add whatever you like using standard Dockerfile commands.
Feel free to add some more apk packages or run some custom commands.
TIP: To keep the build process efficient check whether a given package is required only for
compilation (build) or runtime (release) or both.

#### How to move the Dockerfiles?

You can specify where to find the two Dockerfiles in the config.

```elixir
# config/config.exs
config :mix_docker,
  dockerfile_build: "path/to/Dockerfile.build",
  dockerfile_release: "path/to/Dockerfile.release"
```

The path is relative to the project root, and the files must be located inside
the root.


#### How to configure a Phoenix app?

To run a Phoenix app you'll need to install additional packages into the build image: run `mix docker.customize`.

Modify the `apk --no-cache --update add` command in the `Dockerfile.build` as follows (add `nodejs` and `python`):

```
# Install Elixir and basic build dependencies
RUN \
    echo "@edge http://nl.alpinelinux.org/alpine/edge/community" >> /etc/apk/repositories && \
    apk update && \
    apk --no-cache --update add \
      git make g++ \
      nodejs python \
      elixir@edge && \
    rm -rf /var/cache/apk/*
```

Install nodejs dependencies and cache them by adding the following lines before the `COPY` command:

```
# Cache node deps
COPY package.json ./
RUN npm install
```

Build and digest static assets by adding the following lines after the `COPY` command:

```
RUN ./node_modules/brunch/bin/brunch b -p && \
    mix phoenix.digest
```

Add the following directories to `.dockerignore`:

```
node_modules
priv/static
```

Remove `config/prod.secret.exs` file and remove a reference to it from `config/prod.exs`. Configure your app's secrets directly in `config/prod.exs` using the environment variables.

Make sure to add `server: true` to your app's Endpoint config.

Build the images and run the release image normally.

Check out [this post](https://shovik.com/blog/8-deploying-phoenix-apps-with-docker) for detailed walkthrough of the Phoenix app configuration.
