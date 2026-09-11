# frozen_string_literal: true

require_relative 'helper'
require 'tempfile'

# destroy-app must be create-app's exact inverse, and must leave no Docker network behind: the box
# leaks one per project destroyed otherwise (D_isolation).
class DestroyAppTest < Minitest::Test
  def test_destroys_cache_app_and_network_in_that_order
    dokku = DokkuDouble.new(exists: ['apps:exists', 'network:exists'])
    shepherd(dokku).destroy_app('demo', yes: true)

    assert_equal [
      'repo:purge-cache demo',
      'apps:destroy --force demo',
      'network:destroy --force app-demo',
      'nginx:reload'
    ], dokku.mutations
  end

  # apps:destroy removes the vhost file but leaves the running nginx serving it, so the destroyed
  # app's hostname hangs for proxy_connect_timeout instead of being refused. Verified on a box.
  def test_nginx_is_reloaded_even_when_there_was_no_network
    dokku = DokkuDouble.new(exists: ['apps:exists'])
    shepherd(dokku).destroy_app('demo', yes: true)

    assert_includes dokku.mutations, 'nginx:reload'
  end

  def test_a_failed_nginx_reload_does_not_fail_the_destroy
    dokku = DokkuDouble.new(exists: ['apps:exists', 'network:exists'], fail_on: ['nginx:reload'])

    assert_equal EXIT_OK, shepherd(dokku).destroy_app('demo', yes: true)
    assert_includes dokku.mutations, 'apps:destroy --force demo'
  end

  def test_a_failed_cache_purge_does_not_stop_the_destroy
    dokku = DokkuDouble.new(exists: ['apps:exists', 'network:exists'], fail_on: ['repo:purge-cache'])
    shepherd(dokku).destroy_app('demo', yes: true)

    assert_includes dokku.mutations, 'apps:destroy --force demo'
    assert_includes dokku.mutations, 'network:destroy --force app-demo'
  end

  def test_a_missing_network_is_not_an_error
    dokku = DokkuDouble.new(exists: ['apps:exists'])
    shepherd(dokku).destroy_app('demo', yes: true)

    assert_empty dokku.mutations.grep(/network:destroy/)
  end

  def test_an_unknown_app_is_refused_before_anything_is_destroyed
    dokku = DokkuDouble.new
    assert_raises(Shepherd2Error) { shepherd(dokku).destroy_app('demo', yes: true) }

    assert_empty dokku.mutations
  end
end

class PollTest < Minitest::Test
  APPS = "=====> My Apps\ndemo\nother\nhandmade\n"

  # Only apps create-app registered: one made by hand with `dokku apps:create` has no
  # SHEPHERD_GIT_URL and is not ours to poll.
  def test_polls_only_apps_with_a_git_url
    dokku = DokkuDouble.new(output: {
                              'apps:list' => APPS,
                              'config:get demo' => "https://github.com/me/demo\n",
                              'config:get other' => "https://github.com/me/other\n"
                            },
                            fail_on: ['config:get handmade'])

    assert_equal EXIT_OK, shepherd(dokku).poll
    assert_equal [
      'git:sync --build-if-changes demo https://github.com/me/demo',
      'git:sync --build-if-changes other https://github.com/me/other'
    ], dokku.mutations.grep(/git:sync/)
  end

  # One project's failure must not stop the projects after it in the list.
  def test_one_failing_app_does_not_stop_the_rest
    dokku = DokkuDouble.new(output: {
                              'apps:list' => APPS,
                              'config:get demo' => "https://github.com/me/demo\n",
                              'config:get other' => "https://github.com/me/other\n",
                              'config:get handmade' => "https://github.com/me/handmade\n"
                            },
                            fail_on: ['git:sync --build-if-changes demo'])

    assert_equal EXIT_FAILURE, shepherd(dokku).poll
    assert_includes dokku.mutations, 'git:sync --build-if-changes other https://github.com/me/other'
    assert_includes dokku.mutations, 'git:sync --build-if-changes handmade https://github.com/me/handmade'
  end

  # A tick that lands on a running build skips rather than queues, and says so with a zero exit code:
  # at 288 ticks a day, a noisy cron is a cron nobody reads.
  def test_a_busy_box_skips_the_tick_without_failing
    dokku = DokkuDouble.new
    result = shepherd(dokku, lock: LockDouble.new(busy: true)).poll

    assert_equal EXIT_OK, result
    assert_empty dokku.calls
  end
end

class RebuildTest < Minitest::Test
  def test_forces_a_build_from_the_stored_url
    dokku = DokkuDouble.new(exists: ['apps:exists'],
                            output: { 'config:get demo' => "https://github.com/me/demo\n" })

    assert_equal EXIT_OK, shepherd(dokku).rebuild('demo')
    assert_includes dokku.mutations, 'git:sync --build demo https://github.com/me/demo'
  end

  def test_an_app_shepherd2_did_not_register_is_refused
    dokku = DokkuDouble.new(exists: ['apps:exists'], fail_on: ['config:get demo'])
    error = assert_raises(Shepherd2Error) { shepherd(dokku).rebuild('demo') }

    assert_match(/SHEPHERD_GIT_URL/, error.message)
    assert_empty dokku.mutations.grep(/git:sync/)
  end

  # Fails fast rather than queueing behind a five-minute cron; EXIT_BUSY distinguishes it from a
  # build that actually failed.
  def test_a_busy_box_refuses_with_its_own_exit_code
    dokku = DokkuDouble.new(exists: ['apps:exists'],
                            output: { 'config:get demo' => "https://github.com/me/demo\n" })

    assert_equal EXIT_BUSY, shepherd(dokku, lock: LockDouble.new(busy: true)).rebuild('demo')
    assert_empty dokku.mutations.grep(/git:sync/)
  end
end

class WaitIdleTest < Minitest::Test
  def test_returns_immediately_when_nothing_is_building
    dokku = DokkuDouble.new(output: { 'builds:list' => '[]' })

    assert_equal EXIT_OK, shepherd(dokku).wait_idle(timeout: 0)
  end

  # A `git push` deploy never touches our lock, so Dokku's own view of running builds is the second
  # condition — either can be true without the other.
  def test_a_running_build_outside_the_lock_still_counts_as_busy
    running = JSON.generate([{ 'id' => 'x', 'app' => 'demo',
                               'status' => 'running', 'display_status' => 'running' }])
    dokku = DokkuDouble.new(output: { 'builds:list' => running })

    assert_equal EXIT_FAILURE, shepherd(dokku).wait_idle(timeout: 0)
  end

  # Every no-op poll tick leaves a record at `status: "running"` for good, and the cron writes one
  # every five minutes — so keying off `status` made wait-idle time out on every healthy box.
  # `display_status` is Dokku's own liveness check on the recorded pid.
  def test_an_abandoned_no_op_tick_does_not_count_as_busy
    abandoned = JSON.generate([{ 'id' => 'x', 'app' => 'demo',
                                 'status' => 'running', 'display_status' => 'abandoned' }])
    dokku = DokkuDouble.new(output: { 'builds:list' => abandoned })

    assert_equal EXIT_OK, shepherd(dokku).wait_idle(timeout: 0)
  end

  # Older records, and anything that predates the computed field, still have to be read.
  def test_a_record_without_display_status_falls_back_to_status
    running = JSON.generate([{ 'id' => 'x', 'app' => 'demo', 'status' => 'running' }])
    dokku = DokkuDouble.new(output: { 'builds:list' => running })

    assert_equal EXIT_FAILURE, shepherd(dokku).wait_idle(timeout: 0)
  end

  def test_the_poll_lock_alone_counts_as_busy
    dokku = DokkuDouble.new(output: { 'builds:list' => '[]' })

    assert_equal EXIT_FAILURE, shepherd(dokku, lock: LockDouble.new(busy: true)).wait_idle(timeout: 0)
  end

  # A box whose builds plugin has nothing to say must not block a deliberate reboot for an hour.
  def test_unreadable_build_records_do_not_block_a_reboot
    dokku = DokkuDouble.new(fail_on: ['builds:list'])

    assert_equal EXIT_OK, shepherd(dokku).wait_idle(timeout: 0)
  end
end

class ClearcacheTest < Minitest::Test
  def test_prunes_once_and_never_touches_dokku
    dokku = DokkuDouble.new
    docker = DockerDouble.new

    assert_equal EXIT_OK, shepherd(dokku, docker: docker).clearcache
    assert_equal 1, docker.pruned
    assert_empty dokku.calls
  end
end

# `last-build` exists because the poll's churn breaks both of Dokku's answers to "was the last build
# OK?" — `builds:report` names the newest record, which is always an abandoned tick, and
# `--status failed` selects reaped ticks alongside real failures (D_poll_churn). So what these tests
# pin is the *filter*: canned records in the shapes a real box produces, and the one that must win.
class LastBuildTest < Minitest::Test
  # A reaped no-op tick, as it lands on disk: `failed` with exit_code -1, indistinguishable from a
  # real failure by anything else.
  def reaped(id) = { 'id' => id, 'status' => 'failed', 'display_status' => 'failed', 'exit_code' => -1 }

  # A tick not yet reaped: `running` forever, because no `finished_at` is ever written for it.
  def abandoned(id) = { 'id' => id, 'status' => 'running', 'display_status' => 'abandoned' }

  def real(id, status: 'succeeded', exit_code: 0)
    { 'id' => id, 'status' => status, 'display_status' => status, 'exit_code' => exit_code,
      'started_at' => '2026-09-11T10:05:30Z', 'duration' => '1m43s',
      'log_path' => "/var/lib/dokku/data/builds/demo/#{id}.log" }
  end

  def records(*builds) = { 'builds:list demo' => JSON.generate(builds) }

  def report(dokku, id = 'demo', **options)
    out = StringIO.new
    exit_code = shepherd(dokku, out: out).last_build(id, **options)
    [out.string, exit_code]
  end

  # The cap on `builds:list` is skipped for any *filtered* listing, so `--kind build` is what keeps an
  # idle app's real build visible once poll ticks outnumber the retention count — invisible in the
  # output, so it is pinned here. Verified on a box: without it, 21 ticks at retention 20 hid a build
  # whose record and log were still on disk.
  def test_the_listing_is_filtered_so_the_retention_cap_never_applies
    dokku = DokkuDouble.new(exists: ['apps:exists'], output: records(real('b1')))
    report(dokku)

    assert_includes dokku.commands, 'builds:list demo --kind build --format json'
  end

  def test_reports_the_newest_real_build_past_the_churn
    dokku = DokkuDouble.new(exists: ['apps:exists'],
                            output: records(abandoned('t3'), reaped('t2'), reaped('t1'), real('b1')))
    output, exit_code = report(dokku)

    assert_equal EXIT_OK, exit_code
    assert_includes output, 'demo: succeeded · id b1'
    assert_includes output, 'duration 1m43s'
  end

  # The whole point: a reaped tick must never be reported as the last build, which is exactly what
  # `dokku builds:report demo` and `builds:list demo --status failed` both do.
  def test_a_reaped_tick_is_never_reported_as_a_failure
    dokku = DokkuDouble.new(exists: ['apps:exists'], output: records(reaped('t1'), real('b1')))
    output, = report(dokku)

    assert_includes output, 'id b1'
    refute_includes output, 't1'
    refute_includes output, 'exit -1'
  end

  def test_a_real_failure_is_reported_with_its_exit_code_and_still_exits_zero
    dokku = DokkuDouble.new(exists: ['apps:exists'],
                            output: records(reaped('t1'), real('b1', status: 'failed', exit_code: 1)))
    output, exit_code = report(dokku)

    assert_equal EXIT_OK, exit_code
    assert_includes output, 'demo: failed (exit 1) · id b1'
  end

  # A build running right now outranks the last finished one — otherwise the verb reports history
  # while the answer is being computed.
  def test_a_live_build_outranks_the_last_finished_one
    live = { 'id' => 'now', 'status' => 'running', 'display_status' => 'running' }
    dokku = DokkuDouble.new(exists: ['apps:exists'], output: records(live, real('b1')))
    output, = report(dokku)

    assert_includes output, 'demo: building now · id now'
    refute_includes output, 'b1'
  end

  def test_an_app_with_nothing_but_churn_says_so_rather_than_lying
    dokku = DokkuDouble.new(exists: ['apps:exists'], output: records(abandoned('t2'), reaped('t1')))
    output, exit_code = report(dokku)

    assert_equal EXIT_OK, exit_code
    assert_includes output, 'no real build on record'
  end

  def test_the_log_is_printed_only_when_asked_for
    dokku = DokkuDouble.new(exists: ['apps:exists'], output: records(real('b1')))
    report(dokku)

    assert_empty dokku.mutations.grep(/builds:output/)

    dokku = DokkuDouble.new(exists: ['apps:exists'], output: records(real('b1')))
    report(dokku, log: true)

    assert_includes dokku.mutations, 'builds:output demo b1'
  end

  # The record can outlive its log file: retention evicts by count, and `builds:prune` deletes the
  # `.log` first. Saying so beats printing a path that isn't there.
  def test_a_log_no_longer_on_disk_is_flagged_rather_than_offered
    dokku = DokkuDouble.new(exists: ['apps:exists'], output: records(real('b1')))
    output, = report(dokku)

    assert_includes output, 'gone — builds:output falls back to the syslog copy'
  end

  def test_a_log_still_on_disk_is_offered_by_path
    Tempfile.create('build.log') do |file|
      build = real('b1').merge('log_path' => file.path)
      dokku = DokkuDouble.new(exists: ['apps:exists'],
                              output: { 'builds:list demo' => JSON.generate([build]) })
      output, = report(dokku)

      assert_includes output, "log: #{file.path}\n"
      refute_includes output, 'syslog'
    end
  end

  def test_an_unknown_app_is_refused_before_any_records_are_read
    dokku = DokkuDouble.new
    assert_raises(Shepherd2Error) { shepherd(dokku).last_build('demo') }

    assert_empty dokku.calls.map { |args| args.join(' ') }.grep(/builds:list/)
  end

  def test_a_reserved_id_is_refused
    assert_raises(UsageError) { shepherd(DokkuDouble.new).last_build('adminfoo') }
  end

  APPS = "=====> My Apps\ndemo\nother\nhandmade\n"

  # One line per project create-app registered: a hand-made app has no SHEPHERD_GIT_URL and nothing
  # of ours polls it, so it has no churn to see past either.
  def test_with_no_app_it_reports_every_registered_project
    dokku = DokkuDouble.new(output: {
                              'apps:list' => APPS,
                              'config:get demo' => "https://github.com/me/demo\n",
                              'config:get other' => "https://github.com/me/other\n",
                              'builds:list demo' => JSON.generate([real('b1')]),
                              'builds:list other' => JSON.generate([reaped('t1')])
                            },
                            fail_on: ['config:get handmade'])
    out = StringIO.new
    exit_code = shepherd(dokku, out: out).last_build

    assert_equal EXIT_OK, exit_code
    assert_includes out.string, 'demo: succeeded · id b1'
    assert_includes out.string, 'other: no real build on record'
    refute_includes out.string, 'handmade'
  end

  def test_one_unreadable_project_does_not_hide_the_others
    dokku = DokkuDouble.new(output: {
                              'apps:list' => APPS,
                              'config:get demo' => "https://github.com/me/demo\n",
                              'config:get other' => "https://github.com/me/other\n",
                              'config:get handmade' => "https://github.com/me/handmade\n",
                              'builds:list other' => JSON.generate([real('b1')]),
                              'builds:list handmade' => JSON.generate([real('b2')])
                            },
                            fail_on: ['builds:list demo'])
    out = StringIO.new
    exit_code = shepherd(dokku, out: out).last_build

    assert_equal EXIT_FAILURE, exit_code
    assert_includes out.string, 'other: succeeded · id b1'
    assert_includes out.string, 'handmade: succeeded · id b2'
  end

  def test_records_that_are_not_json_are_a_failure_not_a_crash
    dokku = DokkuDouble.new(exists: ['apps:exists'], output: { 'builds:list demo' => 'not json' })

    assert_raises(Shepherd2Error) { shepherd(dokku).last_build('demo') }
  end
end

# The only rule that lives in the parser rather than in the verb: --log has nothing to print without
# an app id, and silently reporting every project instead would be the wrong kind of helpful.
class LastBuildParsingTest < Minitest::Test
  def test_log_without_an_app_id_is_a_usage_error
    cli = CLI.new(shepherd: shepherd(DokkuDouble.new))

    _out, err = capture_io { assert_equal EXIT_USAGE, cli.run(['last-build', '--log']) }
    assert_includes err, '--log needs an app id'
  end
end
