# frozen_string_literal: true

require 'json'
require 'open3'

# shepherd2.rb — the Shepherd2 API: register, destroy, poll, rebuild, wait, prune, measure.
#
#   shepherd = Shepherd2.new
#   shepherd.create_app('demo', 'https://github.com/me/demo', 'main', buildpack: 'heroku/java')
#   shepherd.poll                 # => [{app: 'demo', ok: true, error: nil}, …], or :busy
#   shepherd.stats                # => {memory: {…}, disks: […], docker: {…}, projects: {…}}
#   shepherd.last_build('demo')   # => {app: 'demo', build: {…}, live: false, …}, or nil
#
# Every verb returns data and renders nothing: no printing, no prompting, no stdin, and no text in a
# return value that anyone would have to parse back. A failure raises Shepherd2::Error, a bad argument
# Shepherd2::UsageError; everything else comes back as a value (D_api_surface).
#
# THE VERBS
#   create_app(id, url, ref = nil, options = {})   register a project and build it for the first time
#   destroy_app(id, options = {})                  its exact inverse
#   poll                                           build every registered project whose ref moved
#   rebuild(id)                                    force a build of an unchanged ref
#   last_build(id = nil, log: false)               the last *real* build, past the poll's churn
#   wait_idle(timeout:, interval:, clock:)         block until no build is running
#   clearcache                                     prune dangling images and stopped containers
#   stats                                          what the box holds: memory, disk, per-project cache
#
# HOW LONG THEY TAKE
#   No verb belongs on a UI thread — `stats` walks every Docker volume and `clearcache` prunes the
#   daemon, so even the quiet ones run for seconds. Four hold the thread for *minutes*: `create_app`,
#   `poll`, `rebuild` and `wait_idle`, each saying so in its own rdoc. They are synchronous because
#   Dokku is — `git:sync` returns only once the container is up, and its exit code *is* the build's,
#   which is the one trustworthy build status there is (design/research.md → `git:sync`; D_poll_churn for why
#   the records are not).
#
# PROGRESS, AND ASKING
#   Shepherd2.new(on_event: ->(kind, fields) { … }, confirm: ->(id) { true })
#
#   on_event   a long verb's progress, as data: (:polling, {app: 'demo'}). Composing a sentence out of
#              that is the caller's job.
#   confirm    how `destroy_app` asks, unless it was passed :yes. With no callback and no :yes the
#              verb refuses: consent is never assumed.
#
#   Both run on whatever thread called the verb, and `confirm` blocks that thread until it answers.
#   This class knows nothing about threads; marshalling onto a UI thread is the caller's job.
#
# WHAT THIS STORES
#   Two config vars per app — SHEPHERD_GIT_URL and SHEPHERD_OWNER — and one lock file. Nothing else.
#   No project descriptor, no converger, no data directory: Dokku's state is the only source of truth,
#   and the way to read a project fact is `dokku *:report --format json` (D_dokku_is_truth).
#
# PREREQUISITES
#   Runs as root on a box built by shepherd2-install. Ruby 3.2 (Ubuntu 24.04's), standard library
#   only — no Gemfile, no gems, nothing to reinstall after a distro upgrade (D_ruby). Requiring this
#   file is enough; it loads nothing else of ours.
#
# SEE ALSO
#   design/solution.md — the flows these verbs implement, step by step
#   D_api_surface (why the rendering is elsewhere) · D_dokku_is_truth · D_isolation
#   D_builder (herokuish, and the cache volume) · D_admin_namespace · D_ruby
class Shepherd2
  VERSION = '0.1.0'

  POLL_LOCK_PATH = '/run/lock/shepherd2-poll.lock'
  GIT_URL_VAR    = 'SHEPHERD_GIT_URL'
  OWNER_VAR      = 'SHEPHERD_OWNER'

  DEFAULT_MEMORY       = '256m'
  DEFAULT_BUILD_MEMORY = '2g'
  DEFAULT_CPU          = '1'
  DEFAULT_BUILD_CPU    = '2'

  # The exit code Dokku's reaper writes onto a build record that never finished — which is every no-op
  # poll tick, once a later deploy reaps it. Nothing else on disk distinguishes such a record from a
  # build that really failed (D_poll_churn).
  REAPED_EXIT_CODE = -1

  # Docker prints sizes for people — `"785.4MB"` — and in SI units. `stats` parses them back so that
  # totals can be added up; the round trip keeps Docker's three or four significant figures, which is
  # plenty for a number that is printed rounded again.
  DOCKER_SIZE_UNITS = { 'b' => 1, 'kb' => 1000, 'mb' => 1000**2, 'gb' => 1000**3,
                        'tb' => 1000**4, 'pb' => 1000**5 }.freeze

  # A *limit* uses the other convention: b/k/m/g, binary, no trailing B. `resource:limit --memory 256m`
  # stores that string verbatim and passes it to `docker --memory` unchanged, so this is Docker's
  # parsing, reimplemented to add the limits up.
  MEMORY_LIMIT_UNITS = { 'b' => 1, 'k' => 1024, 'm' => 1024**2, 'g' => 1024**3 }.freeze

  # The statuses a record reaches once its build is over. A `running` record is either a live build or
  # an abandoned tick, and only `display_status` separates those two.
  FINISHED_BUILD_STATUSES = %w[succeeded failed canceled].freeze

  # Raised for anything the operator should read as "this went wrong", as opposed to a crash.
  class Error < StandardError; end

  # Raised for a bad argument — an id that is reserved or malformed, a missing URL. Separate from Error
  # because a front-end answers it differently: it is the caller's mistake, not the box's.
  class UsageError < Error; end

  # What `create_app` did — +app_created+ and +network_created+ are false on a re-run over something
  # that was already there, which is the ordinary retry after a failed first build.
  Registration = Data.define(:app, :network, :app_created, :network_created)

  # What `destroy_app` removed. +network_destroyed+ is false when there was no network to remove.
  Teardown = Data.define(:app, :network, :network_destroyed)

  # One project's turn in a `poll`. +error+ is Dokku's message when +ok+ is false, nil otherwise.
  PollResult = Data.define(:app, :ok, :error)

  # A project's last *real* build, past the poll's churn.
  #
  # +build+ is Dokku's own record, string-keyed as it parsed out of `builds:list --format json`, and
  # **nil when there is no real build to report** — either the project has never built, or a later
  # deploy pruned the last one (D_poll_churn). +error+ is set only where a project's records could not
  # be read at all.
  #
  # The four log members are filled by `last_build(log: true)`; +log_status+ says which of them mean
  # anything, and is +:not_requested+ otherwise.
  BuildReport = Data.define(:app, :build, :live, :error,
                            :log_path, :log_path_exists, :log_status, :log)

  # Runs `dokku` commands — guard with #ok?, mutate with #run, read with #json:
  #
  #   dokku = Shepherd2::Dokku.new                                # discards output
  #   dokku.ok?('apps:exists', 'demo')                            # => false
  #   dokku.run('apps:create', 'demo')
  #   dokku.json('resource:report', 'demo', '--format', 'json')   # => {"_default_.limit.memory" => …}
  #
  #   Shepherd2::Dokku.new(output: $stdout).run('git:sync', '--build', 'demo', url)   # watch it build
  #
  # Commands are given as argv, never as a command line, so an app id or a git URL is never interpreted
  # by a shell.
  #
  # Discarding a build's output loses nothing retrievable: Dokku captures every build's stdout and
  # stderr to `<build-id>.log` of its own accord, and `builds:output` reads it back.
  class Dokku
    # @param output [IO, nil] where a command's stdout and stderr go. nil discards both; an IO must be
    #   a real file or terminal, since the child inherits its descriptor (a StringIO cannot work).
    def initialize(output: nil)
      @output = output
    end

    # Runs a command for its exit status, with its output going wherever #initialize said.
    #
    # @param args [Array<String>] the dokku subcommand and its arguments.
    # @return [true]
    # @raise [Error] if the command exits non-zero. The message names the command and not the reason,
    #   which for a build is in `builds:output` rather than on any stream.
    def run(*args)
      ok = if @output
             system('dokku', *args, out: @output, err: @output)
           else
             system('dokku', *args, out: File::NULL, err: File::NULL)
           end
      raise Error, "dokku #{args.join(' ')} failed" unless ok

      true
    end

    # Runs a command for its exit status alone, output discarded — the +*:exists+ guards.
    #
    # @param args [Array<String>] the dokku subcommand and its arguments.
    # @return [Boolean] whether it exited zero.
    def ok?(*args)
      system('dokku', *args, out: File::NULL, err: File::NULL) ? true : false
    end

    # @param args [Array<String>] the dokku subcommand and its arguments.
    # @return [String] the command's stdout.
    # @raise [Error] if the command exits non-zero.
    def capture(*args)
      out, err, status = Open3.capture3('dokku', *args)
      raise Error, "dokku #{args.join(' ')} failed: #{err.strip}" unless status.success?

      out
    end

    # Like #capture, for a read that is allowed to come up empty — a config var an app does not have.
    #
    # @param args [Array<String>] the dokku subcommand and its arguments.
    # @return [String, nil] stdout, or nil if the command failed.
    def capture_or_nil(*args)
      out, _err, status = Open3.capture3('dokku', *args)
      status.success? ? out : nil
    end

    # @param args [Array<String>] the dokku subcommand and its arguments, including +--format json+.
    # @return [Hash, Array] the parsed report.
    # @raise [Error] if the command exits non-zero.
    # @raise [JSON::ParserError] if its output is not JSON.
    def json(*args)
      JSON.parse(capture(*args))
    end
  end

  # Prunes and measures the Docker daemon:
  #
  #   Shepherd2::Docker.new.prune        # dangling images and stopped containers, never volumes
  #   Shepherd2::Docker.new.disk_usage   # what images, containers and volumes cost
  #
  # Separate from Dokku so that reaching around Dokku to the daemon cannot happen by accident: these
  # are the things Dokku has no command for — it has no prune, and it does no monitoring at all.
  class Docker
    # @param output [IO, nil] where #prune's summary of what it reclaimed goes; nil discards it.
    def initialize(output: nil)
      @output = output
    end

    # @return [true]
    # @raise [Error] if the prune fails.
    def prune
      ok = if @output
             system('docker', 'system', 'prune', '-f', out: @output, err: @output)
           else
             system('docker', 'system', 'prune', '-f', out: File::NULL, err: File::NULL)
           end
      raise Error, 'docker system prune failed' unless ok

      true
    end

    # The daemon's disk usage — images, containers and volumes in one call:
    #
    #   {"Images" => [{"Repository" => "dokku/hello", "UniqueSize" => "785.4MB", …}, …],
    #    "Volumes" => [{"Name" => "cache-hello", "Mountpoint" => "/var/lib/docker/volumes/…",
    #                   "Size" => "1.2GB"}, …], …}
    #
    # Sizes are the human strings Docker prints, in SI units, never bytes. The daemon walks every
    # volume's directory to answer, so on a box with a warm multi-gigabyte build cache this takes
    # seconds — which is why nothing periodic calls it.
    #
    # @return [Hash{String => Array<Hash>}] `Images`, `Containers`, `Volumes`, `BuildCache`.
    # @raise [Error] if the command fails or its output is not JSON.
    def disk_usage
      JSON.parse(capture('system', 'df', '-v', '--format', '{{json .}}'))
    rescue JSON::ParserError
      raise Error, 'docker system df did not return JSON'
    end

    # Where the daemon keeps images, containers and volumes — `/var/lib/docker` on the box, but asked
    # rather than hardcoded: a rootless daemon puts it under the invoking user's home instead.
    #
    # @return [String] an absolute path.
    # @raise [Error] if the command fails.
    def root_dir = capture('info', '--format', '{{.DockerRootDir}}').strip

    private

    def capture(*args)
      out, err, status = Open3.capture3('docker', *args)
      raise Error, "docker #{args.join(' ')} failed: #{err.strip}" unless status.success?

      out
    end
  end

  # The host underneath Docker — the two numbers no daemon knows:
  #
  #   machine = Shepherd2::Machine.new
  #   machine.memory                 # => {total: 6785806336, available: 3324674048, swap_total: …}
  #   machine.filesystem('/var/lib/docker')
  #                                  # => {path: "/var/lib/docker", device: "/dev/vda2", mount: "/",
  #                                  #     total: 133569777664, free: 34647625728}
  #
  # Both read the source rather than a formatted-for-people summary: `/proc/meminfo` rather than
  # `free`, and `df` in bytes because Ruby's standard library has no statvfs and `D_ruby` rules out the
  # gem that would (`sys-filesystem`).
  class Machine
    MEMINFO_PATH = '/proc/meminfo'

    # @param meminfo_path [String] injected for tests.
    def initialize(meminfo_path: MEMINFO_PATH)
      @meminfo_path = meminfo_path
    end

    # @return [Hash{Symbol => Integer, nil}] bytes: +:total+, +:available+, +:swap_total+,
    #   +:swap_free+. +:available+ is the kernel's MemAvailable — what a new process could get without
    #   swapping — not "free", which on a box doing builds is mostly page cache and reads alarmingly
    #   low.
    # @raise [Error] if /proc/meminfo cannot be read.
    def memory
      fields = meminfo
      { total: fields['MemTotal'], available: fields['MemAvailable'],
        swap_total: fields['SwapTotal'], swap_free: fields['SwapFree'] }
    end

    # @param path [String] any path on the filesystem to measure.
    # @return [Hash{Symbol => Object}] +:path+, +:device+, +:mount+ and the byte counts +:total+,
    #   +:free+.
    # @raise [Error] if df fails or its output cannot be read.
    def filesystem(path)
      # -P is POSIX output: exactly one line per filesystem, never wrapped. -B1 makes it bytes, so
      # nothing here has to guess at a block size.
      out, err, status = Open3.capture3('df', '-P', '-B1', '--', path)
      raise Error, "df #{path} failed: #{err.strip}" unless status.success?

      fields = out.lines.last.to_s.split
      raise Error, "df #{path} returned no filesystem" if fields.size < 6

      # Read from the right: a device name may contain spaces, the five columns after it may not.
      { path: path, device: fields[0..-6].join(' '), mount: fields[-1],
        total: fields[-5].to_i, free: fields[-3].to_i }
    end

    private

    # `MemTotal:  16316092 kB` — the unit is always kB (kibibytes, despite the spelling) for every
    # field that carries one, and a handful of fields carry none.
    def meminfo
      File.readlines(@meminfo_path).each_with_object({}) do |line, fields|
        name, value = line.split(':', 2)
        next if value.nil?

        amount = value.strip.split
        next if amount.empty?

        fields[name] = amount[1] == 'kB' ? amount[0].to_i * 1024 : amount[0].to_i
      end
    rescue SystemCallError => e
      raise Error, "cannot read #{@meminfo_path}: #{e.message}"
    end
  end

  # The box-wide build lock — whoever holds it is the only one building:
  #
  #   Shepherd2::BuildLock.new.with_lock { build_every_app }   # => :busy if somebody else holds it
  #
  # Taking it is always non-blocking, and that is a design constraint rather than a convenience: at 288
  # poll ticks a day, a tick that lands on a running build has to skip rather than queue, or ticks
  # accumulate faster than they drain.
  class BuildLock
    # @param path [String] the lock file; created if absent.
    def initialize(path: POLL_LOCK_PATH)
      @path = path
    end

    # Runs the block under the lock if it is free.
    #
    # @return [Object, :busy] the block's value, or +:busy+ if somebody else holds the lock.
    def with_lock
      file = File.open(@path, File::RDWR | File::CREAT, 0o644)
      return :busy unless file.flock(File::LOCK_EX | File::LOCK_NB)

      begin
        yield
      ensure
        file.flock(File::LOCK_UN)
        file.close
      end
    end

    # @return [Boolean] whether a build is in progress somewhere else right now.
    def held_by_somebody_else?
      file = File.open(@path, File::RDWR | File::CREAT, 0o644)
      taken = file.flock(File::LOCK_EX | File::LOCK_NB)
      file.flock(File::LOCK_UN) if taken
      !taken
    ensure
      file&.close
    end
  end

  # @param dokku [Dokku] runs dokku commands.
  # @param docker [Docker] prunes and measures the daemon, for +clearcache+ and +stats+.
  # @param machine [Machine] reads the host's memory and disk, for +stats+.
  # @param lock [BuildLock] serialises builds box-wide.
  # @param on_event [#call, nil] progress, as +(kind, fields)+. See the file header.
  # @param confirm [#call, nil] how +destroy_app+ asks; returns true to proceed.
  def initialize(dokku: Dokku.new, docker: Docker.new, machine: Machine.new, lock: BuildLock.new,
                 on_event: nil, confirm: nil)
    @dokku = dokku
    @docker = docker
    @machine = machine
    @lock = lock
    @on_event = on_event
    @confirm = confirm
  end

  # --- create-app ------------------------------------------------------------------------------

  # Registers a project and builds it for the first time.
  #
  #   create_app('demo', 'https://github.com/me/demo', 'main', buildpack: 'heroku/java')
  #   # => #<data Shepherd2::Registration app='demo', network='app-demo',
  #   #           app_created=true, network_created=true>
  #
  # Re-runnable, which is the point: a first build that fails is the *normal* case — the Procfile /
  # buildpack / system.properties trio usually needs a couple of tries — so every step before the
  # build is guarded and running this again is the fix, not destroy-and-recreate.
  #
  # **Blocks until the project has been built and deployed** — minutes for a cold JVM build, because
  # `git:sync` returns only once the new container is up. Emits +:app_exists+ and +:network_exists+.
  #
  # @param id [String] the app id, which becomes the subdomain.
  # @param url [String] a publicly cloneable git URL; the box holds no credential.
  # @param ref [String, nil] branch or tag; Dokku's deploy-branch default of +master+ applies if nil.
  # @param options [Hash{Symbol => String}] +:owner+ (stored as SHEPHERD_OWNER), +:mem+, +:cpu+,
  #   +:build_mem+, +:build_cpu+ (a limit, or `clear` for none), +:buildpack+ (pinned rather than
  #   detected, which matters — see D_builder), +:build_dir+ (a subdirectory, for a monorepo).
  # @return [Registration] what it registered, and whether this run was the first one.
  # @raise [UsageError] if the id is reserved or malformed, or the URL is missing.
  # @raise [Error] if any dokku command fails.
  def create_app(id, url, ref = nil, options = {})
    validate_id!(id)
    raise UsageError, 'a git URL is required' if url.nil? || url.empty?

    app_created = !@dokku.ok?('apps:exists', id)
    if app_created
      @dokku.run('apps:create', id)
    else
      emit(:app_exists, app: id)
    end

    # Written *before* the first build, so a project whose first build fails is still in the poll and
    # can be retried by pushing a fix.
    config = { GIT_URL_VAR => url }
    config[OWNER_VAR] = options[:owner] if options[:owner]
    @dokku.run('config:set', '--no-restart', id, *config.map { |k, v| "#{k}=#{v}" })

    # All four limits are always emitted: the farm runs one profile, and a default nobody has to
    # remember is worth more than the ability to leave a limit unset by accident. `clear` as a value
    # is Dokku's own way to say "no limit" and passes straight through.
    @dokku.run('resource:limit',
               '--memory', options.fetch(:mem, DEFAULT_MEMORY),
               '--cpu', options.fetch(:cpu, DEFAULT_CPU).to_s, id)

    # Build CPU rides the herokuish path, which honours both cpu and memory against the `build`
    # process type (design/research.md, *Resource limits*) — confirmed on a box: the build container is
    # created with the memory limit and NanoCpus set, and a real build peaks at 200% CPU on a 4-core
    # host. The `docker-options:add <app> build '--cpus N'` route the punch list asked about is a
    # Dockerfile-builder artefact and is not needed.
    @dokku.run('resource:limit', '--process-type', 'build',
               '--memory', options.fetch(:build_mem, DEFAULT_BUILD_MEMORY),
               '--cpu', options.fetch(:build_cpu, DEFAULT_BUILD_CPU).to_s, id)

    # initial-network is persisted app state that Dokku re-applies at container creation, so nothing
    # ever has to re-attach anything afterwards (D_isolation). Set before the first build, or that
    # build's container joins the wrong network.
    network = network_name(id)
    network_created = !@dokku.ok?('network:exists', network)
    if network_created
      @dokku.run('network:create', network)
    else
      emit(:network_exists, network: network)
    end
    @dokku.run('network:set', id, 'initial-network', network)

    # Pinned rather than detected: herokuish tries nodejs before java, and a Vaadin app commits a
    # package.json (D_builder).
    @dokku.run('buildpacks:set', id, options[:buildpack]) if options[:buildpack]

    @dokku.run('builder:set', id, 'build-dir', options[:build_dir]) if options[:build_dir]

    # The ref is passed explicitly because git:sync with a ref *sets* deploy-branch, which otherwise
    # defaults to `master`; every later sync can then omit it.
    sync = ['git:sync', '--build', id, url]
    sync << ref if ref
    @dokku.run(*sync)

    Registration.new(app: id, network: network,
                     app_created: app_created, network_created: network_created)
  end

  # --- destroy-app -----------------------------------------------------------------------------

  # Destroys a project: its containers, its build cache and its network.
  #
  #   destroy_app('demo', yes: true)
  #   # => #<data Shepherd2::Teardown app='demo', network='app-demo', network_destroyed=true>
  #
  # Emits +:cache_purge_failed+ and +:nginx_reload_failed+ — both steps are best-effort, because an
  # app that is already gone is not worth failing the teardown over.
  #
  # @param id [String] the app id.
  # @param options [Hash{Symbol => Boolean}] +:yes+ proceeds without calling +confirm+.
  # @return [Teardown] what it removed.
  # @raise [Error] if the app does not exist, or consent was neither given nor obtainable.
  def destroy_app(id, options = {})
    validate_id!(id)
    raise Error, "no such app: #{id}" unless @dokku.ok?('apps:exists', id)

    confirm_destruction!(id) unless options[:yes]

    # apps:destroy does remove the cache-<app> volume by itself (verified on a box 2026-09-11, see
    # design/research.md), so this purge is belt-and-braces rather than load-bearing. Kept because it is
    # literally `docker volume rm -f cache-<app>` — it costs one call, tolerates a volume that was
    # never created, and keeps the teardown correct if that behaviour ever changes. A box where it
    # fails is still a box we want destroyed, so this is best-effort rather than fatal.
    begin
      @dokku.run('repo:purge-cache', id)
    rescue Error => e
      emit(:cache_purge_failed, app: id, error: e.message)
    end

    @dokku.run('apps:destroy', '--force', id)

    # The second half matters, or the box leaks a Docker network per project destroyed (D_isolation).
    # `--force` skips Dokku's own confirmation, which we have already asked for above.
    network = network_name(id)
    network_destroyed = @dokku.ok?('network:exists', network)
    @dokku.run('network:destroy', '--force', network) if network_destroyed

    # apps:destroy removes the app's vhost file but does not reload nginx, so the *running* nginx goes
    # on serving the destroyed app's hostname from a config it still holds in memory — proxying to a
    # container that no longer exists. Requests then hang for proxy_connect_timeout (60s) instead of
    # being refused, until some unrelated deploy happens to reload nginx. Verified on a box.
    # `apps:destroy` removes the file synchronously — it is gone the instant the command returns — so
    # there is no race to lose here; it simply never signals nginx. The reload itself *is*
    # asynchronous, though: it returns 0 immediately and the old config is still being served for
    # about a second afterwards. That is fine for a destroy, but do not write a test that asserts the
    # hostname is dead the moment this returns.
    # Best-effort: the app is already gone, and a box whose nginx will not reload is a bigger problem
    # than a stale vhost.
    begin
      @dokku.run('nginx:reload')
    rescue Error => e
      emit(:nginx_reload_failed, app: id, error: e.message)
    end

    Teardown.new(app: id, network: network, network_destroyed: network_destroyed)
  end

  # --- poll ------------------------------------------------------------------------------------

  # Builds every registered project whose ref moved — the */5 cron.
  #
  #   poll   # => [#<data Shepherd2::PollResult app='demo', ok=true, error=nil>,
  #          #     #<data Shepherd2::PollResult app='x', ok=false, error='…'>]
  #          # => :busy
  #
  # Serial, and tolerant: one project's failure must not stop the projects after it in the list.
  #
  # **Blocks for as long as every changed project takes to build**, which under the cron is the point —
  # the lock is held for the whole tick, so the next tick skips rather than building concurrently.
  # Emits +:polling+ before each project and +:polled+ after it, so a front-end need not wait for the
  # return value to know how the first project went.
  #
  # @return [Array<PollResult>, :busy] one per registered project, in the order they were polled; or
  #   +:busy+ when a build already holds the lock, which is not a failure.
  def poll
    @lock.with_lock do
      registered_apps.map do |app, url|
        emit(:polling, app: app)
        result = begin
          # Dokku fetches; if the ref did not move, nothing is built. A failed build is therefore not
          # retried until upstream commits again — `rebuild` is the override.
          #
          # A no-change tick still writes a build record and a log file — 288 of them a day per app,
          # which is why the install raises Dokku's retention to 300 and why `last_build` exists to
          # find the real build among them (D_poll_churn). Pre-checking the remote ref here, so a
          # no-op never enters git:sync at all, is that decision's deferred half.
          @dokku.run('git:sync', '--build-if-changes', app, url)
          PollResult.new(app: app, ok: true, error: nil)
        rescue Error => e
          PollResult.new(app: app, ok: false, error: e.message)
        end
        # Events carry a Hash whatever the verb returns, so that a listener reads every kind the same
        # way.
        emit(:polled, **result.to_h)
        result
      end
    end
  end

  # --- rebuild ---------------------------------------------------------------------------------

  # Forces a build: the retry after a failure, and the only way to rebuild an unchanged ref.
  #
  #   rebuild('demo')   # => :built, or :busy
  #
  # **Blocks for the build.** It takes the poll's lock, and *taking* it never waits: a rebuild that
  # lands on a running build answers +:busy+ at once rather than queueing behind a five-minute cron.
  #
  # @param id [String] the app id.
  # @return [:built, :busy] +:busy+ when another build holds the lock.
  # @raise [Error] if the app is unknown or was not registered by #create_app.
  def rebuild(id)
    validate_id!(id)
    raise Error, "no such app: #{id}" unless @dokku.ok?('apps:exists', id)

    url = git_url_for(id)
    raise Error, "#{id} has no #{GIT_URL_VAR}; it was not registered by create-app" if url.nil?

    @lock.with_lock { @dokku.run('git:sync', '--build', id, url) && :built }
  end

  # --- last-build ------------------------------------------------------------------------------

  # A project's last *real* build — the newest record that is not poll churn.
  #
  #   last_build('demo')
  #   # => #<data Shepherd2::BuildReport app='demo', build={'id' => 'mtwslbpulbzlek', …}, live=false,
  #   #           error=nil, log_path='/var/lib/dokku/data/builds/demo/mtwslbpulbzlek.log',
  #   #           log_path_exists=true, log_status=:not_requested, log=nil>
  #
  #   last_build   # one BuildReport per registered project
  #
  # A project with nothing but churn on record comes back as a report whose +build+ is nil, rather
  # than as nothing at all — so both forms answer in the same shape and neither needs a nil check.
  #
  # One build, never a history: +dokku builds:list ID+ lists them and +builds:output ID current+ tails
  # a live one.
  #
  # With +log:+ the output comes back **as a snapshot**, read once — a live build's is never fetched,
  # because `builds:output` would `tail -f` it and block. +log_status+ is what separates a build that
  # printed nothing from one whose log has been rotated away: `builds:output` exits 0 having printed
  # nothing for both (dokku#9031, design/research.md → *Build tracking*).
  #
  # @param id [String, nil] the app id, or +nil+ for every registered project.
  # @param log [Boolean] also read that build's output. Needs an id.
  # @return [BuildReport, Array<BuildReport>] one report, or one per registered project.
  # @raise [Error] if the named app does not exist.
  # @raise [UsageError] if the id is malformed.
  def last_build(id = nil, log: false)
    return last_build_everywhere if id.nil?

    validate_id!(id)
    raise Error, "no such app: #{id}" unless @dokku.ok?('apps:exists', id)

    build_report(id, notable_build(build_records(id)), log: log)
  end

  # --- wait-idle -------------------------------------------------------------------------------

  # **Blocks until no build is running**, so a deliberate reboot never lands mid-build.
  #
  # Two conditions, because either can be true without the other: the poll lock (a tick in progress)
  # and Dokku's own view of running builds (a +git push+ deploy, which never touches our lock).
  #
  # @param timeout [Integer] seconds to wait before giving up — an hour by default, which is how long
  #   this may hold its thread.
  # @param interval [Integer] seconds between checks.
  # @param clock [#now] injected for tests.
  # @return [:idle, :timeout] +:timeout+ if something was still building when the deadline passed.
  def wait_idle(timeout: 3600, interval: 5, clock: Time)
    deadline = clock.now + timeout
    loop do
      return :idle if idle?
      return :timeout if clock.now >= deadline

      sleep interval
    end
  end

  # --- clearcache ------------------------------------------------------------------------------

  # Prunes dangling images and stopped containers — the weekly cron.
  #
  # Never a blanket volume prune and never +--volumes+: under D_builder the build cache *is* the
  # per-app +cache-<app>+ volume, nothing garbage-collects it, and at a five-minute poll a build is
  # always about to want it. The per-app lever is +dokku repo:purge-cache <app>+, run deliberately.
  #
  # @return [true]
  # @raise [Error] if the prune fails.
  def clearcache
    @docker.prune
  end

  # --- stats -----------------------------------------------------------------------------------

  # What the box holds and what is left of it:
  #
  #   {memory: {total:, available:, swap_total:, swap_free:, committed:, build_peak:, unmeasured: []},
  #    disks: [{path:, device:, mount:, total:, free:}, …],
  #    docker: {images_count:, images_unique:, images_dangling:, volumes_count:, volumes:},
  #    projects: {registered:, unregistered:, cache_total:, apps: [{app:, registered:, cache:}, …],
  #               orphan_caches: [{volume:, cache:}, …]}}
  #
  # Every byte count is an Integer or nil; nil means *not readable*, which is never the same as zero —
  # an app with no readable runtime limit is named in +:unmeasured+ rather than counted as free
  # capacity. *Committed* is what answers "can another project fit", which free memory does not: the
  # apps are idle but capped. It is a report and never a refusal (`Q_quota`).
  #
  # **Takes seconds**: the daemon walks every volume's directory to answer. Emits +:box_measured+ with
  # the memory and disk half as soon as it is known, before that walk starts, so a front-end can show
  # the fast half immediately.
  #
  # @return [Hash{Symbol => Object}] as above.
  # @raise [Error] if the daemon or the host cannot be measured at all.
  def stats
    inventory = app_inventory
    box = box_stats(inventory)
    emit(:box_measured, **box)

    box.merge(project_stats(inventory, @docker.disk_usage))
  end

  # --- shared ----------------------------------------------------------------------------------

  private

  def network_name(id) = "app-#{id}"

  def emit(kind, **fields) = @on_event&.call(kind, fields)

  # Ours, not Dokku's: Dokku's own app-name rules (tightened in 0.38.2 against command injection)
  # apply underneath and are its business to enforce.
  def validate_id!(id)
    raise UsageError, 'an app id is required' if id.nil? || id.empty?

    # A namespace is far cheaper to reserve than to reclaim: reclaiming one means renaming a live app,
    # which changes its URL and is a destroy-and-recreate (D_admin_namespace).
    if id.start_with?('admin')
      raise UsageError, "'#{id}' is reserved: ids beginning with `admin` are kept for a future admin " \
                        'surface (D_admin_namespace)'
    end

    # The app name *is* the subdomain, and a wildcard certificate matches exactly one label:
    # `foo.bar.mydomain.me` is not covered by `*.mydomain.me`. So a dotted id would produce an app
    # that works over http and fails over https, which is the worst way to find out.
    raise UsageError, "'#{id}' contains a dot; the app name is one DNS label under the wildcard" if id.include?('.')

    return if id.match?(/\A[a-z0-9][a-z0-9-]*\z/)

    raise UsageError, "'#{id}' is not a valid app id: lowercase letters, digits and dashes, " \
                      'starting with a letter or digit'
  end

  # Consent is never assumed: with no callback there is no way to ask, and the answer is no.
  def confirm_destruction!(id)
    raise Error, "refusing to destroy #{id}: no way to confirm, and consent was not given" if @confirm.nil?
    raise Error, 'aborted' unless @confirm.call(id)
  end

  # Every app that create-app registered, as { app => url }. An app without SHEPHERD_GIT_URL was made
  # by hand with `dokku apps:create` and is not ours to poll.
  def registered_apps
    app_names.each_with_object({}) do |app, apps|
      url = git_url_for(app)
      apps[app] = url if url
    end
  end

  # `apps:list` prints a `=====>` header and then one app per line. This is the one place we read
  # human-formatted Dokku output; everything else that needs a fact reads a `--format json` report.
  def app_names
    @dokku.capture('apps:list').lines.map(&:strip)
          .reject { |line| line.empty? || line.start_with?('=====>') }
  end

  def git_url_for(app)
    url = @dokku.capture_or_nil('config:get', app, GIT_URL_VAR)&.strip
    url && !url.empty? ? url : nil
  end

  def idle?
    !@lock.held_by_somebody_else? && running_builds.empty?
  end

  # `builds:list` with no app lists every build box-wide, which is what makes this catch a deploy that
  # came from a `git push` rather than from us.
  def running_builds
    builds = @dokku.json('builds:list', '--format', 'json')
    builds = builds.values.flatten if builds.is_a?(Hash)
    Array(builds).select { |build| live_build?(build) }
  rescue Error, JSON::ParserError
    [] # A box with no builds yet, or a Dokku that has nothing to say. Not a reason to block a reboot.
  end

  # One entry per registered project, and tolerant like #poll: one project whose records will not read
  # must not hide the rest. An app without SHEPHERD_GIT_URL was made by hand and is nobody's to poll,
  # so it has no churn to see past either.
  def last_build_everywhere
    registered_apps.keys.map do |app|
      build_report(app, notable_build(build_records(app)))
    rescue Error => e
      build_report(app, nil, error: e.message)
    end
  end

  # The one place a BuildReport is built, so that both forms of #last_build answer in the same shape.
  def build_report(app, build, log: false, error: nil)
    if build.nil?
      return BuildReport.new(app: app, build: nil, live: false, error: error, log_path: nil,
                             log_path_exists: false, log_status: :not_requested, log: nil)
    end

    live = live_build?(build)
    path = build['log_path'].to_s
    path = nil if path.empty?
    exists = !path.nil? && File.exist?(path)
    contents, status = log ? read_build_log(app, build, live, path, exists) : [nil, :not_requested]

    BuildReport.new(app: app, build: build, live: live, error: error, log_path: path,
                    log_path_exists: exists, log_status: status, log: contents)
  end

  # `--kind build` is load-bearing twice over, and the first reason is not obvious. An unfiltered
  # `builds:list` **caps its output at the retention count** — but the cap is skipped for any filtered
  # listing (`plugins/builds/subcommands.go`: `if statusFilter == "" && kindFilter == ""`). Without the
  # flag, an app idle for more than `retention` ticks reports "no real build" while its record and log
  # sit untouched on disk, because poll ticks fill the whole visible window. Verified on a box: at 21
  # ticks with retention 20, the real build was invisible with 41 records on disk. The second reason is
  # the ordinary one — `git:sync` records are always `kind: build`, so this is also the right set.
  #
  # Newest first (live builds ahead of the rest), which Dokku sorts before it filters, and the only
  # ordering this relies on: `started_at` is RFC3339 with trailing zeros trimmed, so string order is
  # not chronological order, and it is never parsed here.
  def build_records(app)
    builds = @dokku.json('builds:list', app, '--kind', 'build', '--format', 'json')
    builds = builds.values.flatten if builds.is_a?(Hash)
    Array(builds)
  rescue JSON::ParserError
    raise Error, 'build records are not readable as JSON'
  end

  # The build worth reporting: one that is building right now, else the newest that really built.
  def notable_build(builds)
    builds.find { |build| live_build?(build) } || builds.find { |build| real_build?(build) }
  end

  # Whether a build is running *now* — `display_status`, which Dokku computes from whether the recorded
  # pid is alive, never the stored `status`, which a no-op tick holds at `running` forever. A live build
  # reads `running`/`running`; an abandoned tick reads `running`/`abandoned`.
  def live_build?(build) = (build['display_status'] || build['status']) == 'running'

  # A record some build actually produced. Two filters, because the churn hides behind both: a tick's
  # record stays `running` until a later deploy reaps it, and reaping writes it as `failed` with
  # exit_code -1, which is indistinguishable on disk from a build that really failed. So this
  # mislabels one thing as churn — a real build the box killed mid-flight, reaped the same way, for
  # which `dokku logs:failed ID` is what is left.
  def real_build?(build)
    FINISHED_BUILD_STATUSES.include?(build['status']) && build['exit_code'] != REAPED_EXIT_CODE
  end

  # A snapshot of one build's captured output, and an honest account of where it came from.
  #
  # `builds:output` tails a live build, so a live one is never asked for. For a finished one it cats
  # `<build-id>.log` if that still exists and otherwise falls back to `journalctl -t dokku-<id>`,
  # exiting 0 with nothing to say once journald has rotated that away too — so the file's existence is
  # what separates "this build printed nothing" from "this build's log is gone".
  def read_build_log(app, build, live, path, path_exists)
    return [nil, :running] if live
    return [nil, :not_recorded] if path.nil?

    contents = @dokku.capture('builds:output', app, build['id'])
    return [contents, :file] if path_exists

    contents.empty? ? [nil, :rotated] : [contents, :syslog]
  end

  # --- stats internals -------------------------------------------------------------------------

  # Every app on the box, ours or not: a hand-made `dokku apps:create` is invisible to the poll but
  # eats the box's memory and disk all the same, so it is counted — and named as unregistered.
  def app_inventory
    app_names.map do |app|
      limits = memory_limits(app)
      { name: app, registered: !git_url_for(app).nil?,
        memory: limits[:runtime], build_memory: limits[:build] }
    end
  end

  # `resource:report --format json` is a flat map — `{"_default_.limit.memory" => "256m",
  # "build.limit.memory" => "2g"}` — whose keys Dokku 0.38 trims and later versions also emit with a
  # legacy `resource-` prefix, so both spellings are read. An unset limit is **absent**, not zero,
  # which is why an app with none is named rather than added in as free capacity.
  def memory_limits(app)
    report = @dokku.json('resource:report', app, '--format', 'json')
    report = {} unless report.is_a?(Hash)
    { runtime: parse_memory_limit(report_value(report, '_default_.limit.memory')),
      build: parse_memory_limit(report_value(report, 'build.limit.memory')) }
  rescue Error, JSON::ParserError
    { runtime: nil, build: nil }
  end

  def report_value(report, key)
    _, value = report.find { |name, _| name == key || name.end_with?("-#{key}") }
    value
  end

  def parse_memory_limit(value)
    match = /\A(\d+(?:\.\d+)?)([bkmg])?\z/i.match(value.to_s.strip)
    return nil if match.nil?

    (match[1].to_f * (match[2] ? MEMORY_LIMIT_UNITS[match[2].downcase] : 1)).round
  end

  def parse_docker_size(value)
    match = /\A(\d+(?:\.\d+)?)\s*([kmgtp]?b)\z/i.match(value.to_s.strip)
    return nil if match.nil?

    (match[1].to_f * DOCKER_SIZE_UNITS[match[2].downcase]).round
  end

  def box_stats(inventory)
    limited = inventory.select { |app| app[:memory] }
    { memory: @machine.memory.merge(
        committed: limited.sum { |app| app[:memory] },
        build_peak: inventory.filter_map { |app| app[:build_memory] }.max,
        unmeasured: (inventory - limited).map { |app| app[:name] }
      ),
      disks: disks }
  end

  # The filesystem that fills up is Docker's, so that is the one reported. `/` follows only when it is
  # a different device — on a stock box it is the same one, and printing it twice would be noise.
  def disks
    root = @machine.filesystem(@docker.root_dir)
    slash = @machine.filesystem('/')
    slash[:device] == root[:device] ? [root] : [root, slash]
  end

  # A project's build cache is the `cache-<app>` volume Dokku names (D_builder). Nothing in Dokku
  # knows that, which is why the attribution happens here, by name, against the daemon's own listing.
  def project_stats(inventory, usage)
    volumes = Array(usage['Volumes'])
    sizes = volumes.to_h { |volume| [volume['Name'].to_s, parse_docker_size(volume['Size'])] }
    apps = inventory.map do |app|
      { app: app[:name], registered: app[:registered], cache: sizes["cache-#{app[:name]}"] }
    end

    { docker: docker_stats(usage, volumes, sizes),
      projects: {
        registered: apps.count { |app| app[:registered] },
        unregistered: apps.count { |app| !app[:registered] },
        cache_total: apps.filter_map { |app| app[:cache] }.sum,
        apps: apps,
        # `apps:destroy` removes the cache volume itself (design/research.md), so this list should stay empty
        # forever; it costs one filter, and an entry in it means that stopped being true.
        orphan_caches: orphan_caches(inventory, sizes)
      } }
  end

  def orphan_caches(inventory, sizes)
    known = inventory.map { |app| "cache-#{app[:name]}" }
    sizes.keys.select { |name| name.start_with?('cache-') && !known.include?(name) }
         .map { |name| { volume: name, cache: sizes[name] } }
  end

  # Two numbers Docker's own `system df` would print differently. Images are summed by *unique* size —
  # under-reporting a shared base layer rather than counting it once per image — because its totals are
  # the daemon's arithmetic and cannot be re-derived from this listing. Dangling is what
  # `clearcache` really reclaims: the untagged images, not every unused one.
  def docker_stats(usage, volumes, sizes)
    images = Array(usage['Images'])
    { images_count: images.size,
      images_unique: sum_sizes(images, 'UniqueSize'),
      images_dangling: sum_sizes(images.select { |image| image['Repository'] == '<none>' }, 'UniqueSize'),
      volumes_count: volumes.size,
      volumes: sizes.values.compact.sum }
  end

  def sum_sizes(entries, key) = entries.filter_map { |entry| parse_docker_size(entry[key]) }.sum
end
