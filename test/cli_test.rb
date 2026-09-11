# frozen_string_literal: true

require_relative 'helper'

# The executable, loaded on top of the library the other test files use on its own. Everything pinned
# here is something the API deliberately does not do: compose a sentence, and decide an exit code
# (D_api_surface).
load File.expand_path('../shepherd2-cli', __dir__)

# What the box says. A verb emits `(:polling, {app: 'demo'})` and renders nothing, so every word below
# is written here — which is also why a front-end that is not a terminal can say something else.
class ReportTest < Minitest::Test
  def report(out = StringIO.new, err = StringIO.new)
    [Report.new(out: out, err: err), out, err]
  end

  def test_progress_becomes_a_sentence_on_stdout
    reporter, out, = report
    reporter.event(:polling, { app: 'demo' })
    reporter.event(:app_exists, { app: 'demo' })

    assert_equal "shepherd2: polling demo\nshepherd2: app demo already exists\n", out.string
  end

  def test_a_warning_goes_to_stderr_and_says_what_it_cost
    reporter, out, err = report
    reporter.event(:nginx_reload_failed, { app: 'demo', error: 'nginx: [emerg]' })

    assert_empty out.string
    assert_includes err.string, "demo's hostname may hang until the next deploy"
  end

  def test_a_polled_project_is_only_mentioned_when_it_failed
    reporter, out, err = report
    reporter.event(:polled, { app: 'demo', ok: true, error: nil })

    assert_empty out.string
    assert_empty err.string

    reporter.event(:polled, { app: 'other', ok: false, error: 'git:sync failed' })

    assert_includes err.string, 'other: git:sync failed'
  end

  # `stats --json` emits JSON and nothing else, and the box half arrives as an event — so the event is
  # what has to fall silent, or the JSON is preceded by a page of prose and no longer parses.
  def test_json_only_silences_the_box_half
    reporter, out, = report
    reporter.json_only!
    reporter.event(:box_measured, snapshot)

    assert_empty out.string
  end

  # A verb that grows an event must not crash a front-end that has not learned it yet.
  def test_an_unknown_event_is_ignored_rather_than_fatal
    reporter, out, err = report
    reporter.event(:something_new, { app: 'demo' })

    assert_empty out.string
    assert_empty err.string
  end

  # A build record as Dokku reports it — string keys, which is why the overrides are converted rather
  # than merged as symbols onto them.
  def build(**overrides)
    { 'id' => 'b1', 'status' => 'succeeded', 'exit_code' => 0,
      'started_at' => '2026-09-11T10:05:30Z', 'duration' => '1m43s' }
      .merge(overrides.transform_keys(&:to_s))
  end

  def test_a_build_reads_as_one_line
    reporter, = report

    assert_equal 'demo: succeeded · id b1 · started 2026-09-11T10:05:30Z · duration 1m43s',
                 reporter.build_line('demo', build, live: false)
  end

  def test_a_failure_carries_its_exit_code_and_a_live_build_carries_no_duration
    reporter, = report

    assert_includes reporter.build_line('demo', build(status: 'failed', exit_code: 1), live: false),
                    'failed (exit 1)'
    assert_equal 'demo: building now · id b1 · started 2026-09-11T10:05:30Z',
                 reporter.build_line('demo', build, live: true)
  end

  def last_build_result(**overrides)
    Shepherd2::BuildReport.new(app: 'demo', build: build, live: false, error: nil,
                               log_path: '/var/lib/dokku/data/builds/demo/b1.log',
                               log_path_exists: true, log_status: :not_requested, log: nil)
                          .with(**overrides)
  end

  def test_without_the_log_it_offers_the_path_and_the_command
    reporter, out, = report
    reporter.last_build(last_build_result, log: false)

    assert_includes out.string, 'log: /var/lib/dokku/data/builds/demo/b1.log'
    assert_includes out.string, 'read it: shepherd2 last-build demo --log'
  end

  # The record outlives its log file, so a path that is no longer there is flagged rather than
  # offered as if it could be read.
  def test_a_log_no_longer_on_disk_is_flagged
    reporter, out, = report
    reporter.last_build(last_build_result(log_path_exists: false), log: false)

    assert_includes out.string, 'gone — builds:output falls back to the syslog copy'
  end

  def test_each_log_status_says_something_different
    { file: 'compiling…', syslog: 'journald still holds', running: 'follows it live',
      rotated: 'the log is gone', not_recorded: 'no log path on record' }.each do |status, expected|
      reporter, out, = report
      reporter.last_build(last_build_result(log_status: status, log: "compiling…\n"), log: true)

      assert_includes out.string, expected, "log_status #{status}"
    end
  end

  def snapshot
    dokku = DokkuDouble.new(output: {
                              'apps:list' => "=====> My Apps\nhello\nhandmade\n",
                              'config:get hello SHEPHERD_GIT_URL' => "https://github.com/me/hello\n",
                              'resource:report hello' => JSON.generate('_default_.limit.memory' => '256m',
                                                                      'build.limit.memory' => '2g'),
                              'resource:report handmade' => JSON.generate('_default_.limit.memory' => '512m')
                            })
    docker = DockerDouble.new(usage: { 'Images' => [{ 'Repository' => '<none>', 'UniqueSize' => '300MB' }],
                                       'Volumes' => [{ 'Name' => 'cache-hello', 'Size' => '1.2GB' }] })
    shepherd(dokku, docker: docker).stats
  end

  # Binary units, to match the `free -h` and `df -h` the operator checks this against — Docker's own
  # 1.2GB volume reads as 1.1 GiB here, and an 8 GiB box printed as "8.6 GB" would read as a bug.
  def test_the_box_section_renders_in_binary_units
    reporter, out, = report
    reporter.box(snapshot)

    assert_match(/^  memory\s+8\.0 GiB total · 4\.0 GiB available$/, out.string)
    assert_match(/^  committed\s+768\.0 MiB runtime \+ 2\.0 GiB build peak, of 8\.0 GiB$/, out.string)
    assert_match(%r{^  disk\s+/var/lib/docker on /dev/sda1 — 80\.0 GiB total}, out.string)
  end

  def test_an_app_with_no_readable_limit_is_named_under_the_committed_line
    reporter, out, = report
    reporter.box(snapshot.merge(memory: snapshot[:memory].merge(unmeasured: %w[handmade])))

    assert_match(/1 app\(s\) with no readable runtime limit: handmade/, out.string)
  end

  def test_swap_is_printed_only_when_the_box_has_some
    reporter, out, = report
    reporter.box(snapshot)

    refute_match(/swap/, out.string)

    reporter, out, = report
    reporter.box(snapshot.merge(memory: snapshot[:memory].merge(swap_total: 2 * (1024**3),
                                                                swap_free: 1024**3)))

    assert_match(/^  swap\s+2\.0 GiB total · 1\.0 GiB free$/, out.string)
  end

  def test_a_cache_volume_is_printed_against_its_app
    reporter, out, = report
    reporter.stats(snapshot)

    assert_match(/^projects\s+1 registered · 1 unregistered/, out.string)
    assert_match(/^  hello\s+1\.1 GiB$/, out.string)
    assert_match(/^  handmade \(unregistered\)\s+no cache volume$/, out.string)
    assert_match(/^  total\s+1\.1 GiB$/, out.string)
  end

  def test_dangling_images_are_named_with_the_verb_that_reclaims_them
    reporter, out, = report
    reporter.stats(snapshot)

    assert_match(/286\.1 MiB dangling, which `shepherd2 clearcache` reclaims/, out.string)
  end

  def test_bytes_render_as_free_and_df_would_print_them
    reporter, = report

    assert_equal '512 B', reporter.send(:human_bytes, 512)
    assert_equal '8.0 GiB', reporter.send(:human_bytes, 8 * (1024**3))
    assert_equal '1.1 GiB', reporter.send(:human_bytes, 1_200_000_000) # what Docker calls 1.2GB
    assert_equal '—', reporter.send(:human_bytes, nil)
  end
end

# The exit code is the CLI's alone: every verb returns a value, and the mapping onto 0/1/2/3 is here.
class ExitCodeTest < Minitest::Test
  APPS = "=====> My Apps\ndemo\n"
  URL = "https://github.com/me/demo\n"

  def cli(dokku, **options)
    CLI.new(shepherd: shepherd(dokku, **options), report: Report.new(out: StringIO.new, err: StringIO.new))
  end

  def test_a_clean_poll_exits_zero
    dokku = DokkuDouble.new(output: { 'apps:list' => APPS, 'config:get demo' => URL })

    assert_equal EXIT_OK, cli(dokku).run(['poll'])
  end

  def test_a_failed_project_makes_the_poll_exit_one
    dokku = DokkuDouble.new(output: { 'apps:list' => APPS, 'config:get demo' => URL },
                            fail_on: ['git:sync'])

    assert_equal EXIT_FAILURE, cli(dokku).run(['poll'])
  end

  # Skipping is the designed behaviour at 288 ticks a day, so cron must not be told it failed.
  def test_a_skipped_tick_is_not_a_failure
    dokku = DokkuDouble.new
    out = StringIO.new
    runner = CLI.new(shepherd: shepherd(dokku, lock: LockDouble.new(busy: true)),
                     report: Report.new(out: out, err: StringIO.new))

    assert_equal EXIT_OK, runner.run(['poll'])
    assert_includes out.string, 'skipping this tick'
  end

  # A rebuild that lands on a running build gets its own code, so a script can tell it from a build
  # that actually failed.
  def test_a_busy_rebuild_has_its_own_exit_code
    dokku = DokkuDouble.new(exists: ['apps:exists'], output: { 'config:get demo' => URL })

    assert_equal EXIT_BUSY, cli(dokku, lock: LockDouble.new(busy: true)).run(%w[rebuild demo])
  end

  def test_wait_idle_fails_on_timeout_and_succeeds_when_idle
    busy = JSON.generate([{ 'id' => 'x', 'status' => 'running', 'display_status' => 'running' }])

    assert_equal EXIT_FAILURE,
                 cli(DokkuDouble.new(output: { 'builds:list' => busy })).run(['wait-idle', '--timeout', '0'])
    assert_equal EXIT_OK,
                 cli(DokkuDouble.new(output: { 'builds:list' => '[]' })).run(['wait-idle', '--timeout', '0'])
  end

  # A red build is an answer, not a failure to answer: the question was asked and got a reply.
  def test_a_failed_build_still_exits_zero_from_last_build
    records = JSON.generate([{ 'id' => 'b1', 'status' => 'failed', 'display_status' => 'failed',
                               'exit_code' => 1 }])
    dokku = DokkuDouble.new(exists: ['apps:exists'], output: { 'builds:list demo' => records })

    assert_equal EXIT_OK, cli(dokku).run(%w[last-build demo])
  end

  def test_an_unreadable_project_makes_last_build_exit_one
    dokku = DokkuDouble.new(output: { 'apps:list' => APPS, 'config:get demo' => URL },
                            fail_on: ['builds:list'])

    assert_equal EXIT_FAILURE, cli(dokku).run(['last-build'])
  end

  def test_an_unknown_verb_is_a_usage_error
    _out, err = capture_io { assert_equal EXIT_USAGE, cli(DokkuDouble.new).run(['frobnicate']) }

    assert_includes err, 'unknown verb'
  end

  def test_a_failure_from_the_api_exits_one_with_its_message
    dokku = DokkuDouble.new
    _out, err = capture_io { assert_equal EXIT_FAILURE, cli(dokku).run(%w[destroy-app demo --yes]) }

    assert_includes err, 'no such app: demo'
  end

  # --log has nothing to print without an app id, and silently reporting every project instead would
  # be the wrong kind of helpful.
  def test_log_without_an_app_id_is_a_usage_error
    _out, err = capture_io { assert_equal EXIT_USAGE, cli(DokkuDouble.new).run(['last-build', '--log']) }

    assert_includes err, '--log needs an app id'
  end

  def test_stats_json_is_the_snapshot_and_nothing_else
    dokku = DokkuDouble.new(output: { 'apps:list' => "=====> My Apps\n" })
    out = StringIO.new
    runner = CLI.new(shepherd: shepherd(dokku), report: Report.new(out: out, err: StringIO.new))

    assert_equal EXIT_OK, runner.run(['stats', '--json'])
    parsed = JSON.parse(out.string)

    assert_equal 8 * (1024**3), parsed.dig('memory', 'total')
    refute_match(/GiB|·/, out.string)
  end
end
