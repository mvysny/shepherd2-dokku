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
    events = EventLog.new
    result = shepherd(dokku, events: events).destroy_app('demo', yes: true)

    assert_equal 'demo', result.app
    assert_includes dokku.mutations, 'apps:destroy --force demo'
    assert_equal 'demo', events[:nginx_reload_failed].first[:app]
  end

  def test_a_failed_cache_purge_does_not_stop_the_destroy
    dokku = DokkuDouble.new(exists: ['apps:exists', 'network:exists'], fail_on: ['repo:purge-cache'])
    events = EventLog.new
    shepherd(dokku, events: events).destroy_app('demo', yes: true)

    assert_includes dokku.mutations, 'apps:destroy --force demo'
    assert_includes dokku.mutations, 'network:destroy --force app-demo'
    assert_equal 1, events[:cache_purge_failed].size
  end

  def test_a_missing_network_is_not_an_error
    dokku = DokkuDouble.new(exists: ['apps:exists'])
    result = shepherd(dokku).destroy_app('demo', yes: true)

    assert_empty dokku.mutations.grep(/network:destroy/)
    refute result.network_destroyed
  end

  def test_an_unknown_app_is_refused_before_anything_is_destroyed
    dokku = DokkuDouble.new
    assert_raises(Shepherd2::Error) { shepherd(dokku).destroy_app('demo', yes: true) }

    assert_empty dokku.mutations
  end

  # Consent is asked for through the callback, and a refusal stops the teardown — the API never reads
  # a terminal itself, so there is nothing else for it to go on.
  def test_a_refused_confirmation_destroys_nothing
    dokku = DokkuDouble.new(exists: ['apps:exists'])

    assert_raises(Shepherd2::Error) { shepherd(dokku, confirm: ->(_id) { false }).destroy_app('demo') }
    assert_empty dokku.mutations
  end

  # With no way to ask and no :yes, the answer is no: consent is never assumed from silence.
  def test_no_confirm_callback_and_no_yes_refuses
    dokku = DokkuDouble.new(exists: ['apps:exists'])
    shepherd = Shepherd2.new(dokku: dokku, lock: LockDouble.new)

    assert_raises(Shepherd2::Error) { shepherd.destroy_app('demo') }
    assert_empty dokku.mutations
  end

  def test_the_id_is_what_the_confirmation_is_asked_about
    dokku = DokkuDouble.new(exists: ['apps:exists'])
    asked = []
    shepherd(dokku, confirm: lambda { |id|
      asked << id
      true
    }).destroy_app('demo')

    assert_equal ['demo'], asked
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

    assert_equal [Shepherd2::PollResult.new(app: 'demo', ok: true, error: nil),
                  Shepherd2::PollResult.new(app: 'other', ok: true, error: nil)],
                 shepherd(dokku).poll
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
    result = shepherd(dokku).poll

    refute result.find { |entry| entry.app == 'demo' }.ok
    assert result.find { |entry| entry.app == 'other' }.ok
    assert_includes dokku.mutations, 'git:sync --build-if-changes other https://github.com/me/other'
    assert_includes dokku.mutations, 'git:sync --build-if-changes handmade https://github.com/me/handmade'
  end

  # A front-end must not have to wait for the whole tick — which is minutes — to learn how the first
  # project went, so each project is reported as it starts and again as it ends.
  def test_progress_is_emitted_per_project_rather_than_only_at_the_end
    dokku = DokkuDouble.new(output: { 'apps:list' => "demo\nother\n",
                                      'config:get demo' => "https://github.com/me/demo\n",
                                      'config:get other' => "https://github.com/me/other\n" },
                            fail_on: ['git:sync --build-if-changes other'])
    events = EventLog.new
    shepherd(dokku, events: events).poll

    assert_equal [{ app: 'demo' }, { app: 'other' }], events[:polling]
    assert_equal [true, false], events[:polled].map { |fields| fields[:ok] }
    assert_equal %i[polling polled polling polled], events.kinds
  end

  # A tick that lands on a running build skips rather than queues: at 288 ticks a day, ticks that
  # queued would accumulate faster than they drain.
  def test_a_busy_box_skips_the_tick
    dokku = DokkuDouble.new

    assert_equal :busy, shepherd(dokku, lock: LockDouble.new(busy: true)).poll
    assert_empty dokku.calls
  end
end

class RebuildTest < Minitest::Test
  def test_forces_a_build_from_the_stored_url
    dokku = DokkuDouble.new(exists: ['apps:exists'],
                            output: { 'config:get demo' => "https://github.com/me/demo\n" })

    assert_equal :built, shepherd(dokku).rebuild('demo')
    assert_includes dokku.mutations, 'git:sync --build demo https://github.com/me/demo'
  end

  def test_an_app_shepherd2_did_not_register_is_refused
    dokku = DokkuDouble.new(exists: ['apps:exists'], fail_on: ['config:get demo'])
    error = assert_raises(Shepherd2::Error) { shepherd(dokku).rebuild('demo') }

    assert_match(/SHEPHERD_GIT_URL/, error.message)
    assert_empty dokku.mutations.grep(/git:sync/)
  end

  # Fails fast rather than queueing behind a five-minute cron.
  def test_a_busy_box_refuses
    dokku = DokkuDouble.new(exists: ['apps:exists'],
                            output: { 'config:get demo' => "https://github.com/me/demo\n" })

    assert_equal :busy, shepherd(dokku, lock: LockDouble.new(busy: true)).rebuild('demo')
    assert_empty dokku.mutations.grep(/git:sync/)
  end
end

class WaitIdleTest < Minitest::Test
  def test_returns_immediately_when_nothing_is_building
    dokku = DokkuDouble.new(output: { 'builds:list' => '[]' })

    assert_equal :idle, shepherd(dokku).wait_idle(timeout: 0)
  end

  # A `git push` deploy never touches our lock, so Dokku's own view of running builds is the second
  # condition — either can be true without the other.
  def test_a_running_build_outside_the_lock_still_counts_as_busy
    running = JSON.generate([{ 'id' => 'x', 'app' => 'demo',
                               'status' => 'running', 'display_status' => 'running' }])
    dokku = DokkuDouble.new(output: { 'builds:list' => running })

    assert_equal :timeout, shepherd(dokku).wait_idle(timeout: 0)
  end

  # Every no-op poll tick leaves a record at `status: "running"` for good, and the cron writes one
  # every five minutes — so keying off `status` made wait-idle time out on every healthy box.
  # `display_status` is Dokku's own liveness check on the recorded pid.
  def test_an_abandoned_no_op_tick_does_not_count_as_busy
    abandoned = JSON.generate([{ 'id' => 'x', 'app' => 'demo',
                                 'status' => 'running', 'display_status' => 'abandoned' }])
    dokku = DokkuDouble.new(output: { 'builds:list' => abandoned })

    assert_equal :idle, shepherd(dokku).wait_idle(timeout: 0)
  end

  # Older records, and anything that predates the computed field, still have to be read.
  def test_a_record_without_display_status_falls_back_to_status
    running = JSON.generate([{ 'id' => 'x', 'app' => 'demo', 'status' => 'running' }])
    dokku = DokkuDouble.new(output: { 'builds:list' => running })

    assert_equal :timeout, shepherd(dokku).wait_idle(timeout: 0)
  end

  def test_the_poll_lock_alone_counts_as_busy
    dokku = DokkuDouble.new(output: { 'builds:list' => '[]' })

    assert_equal :timeout, shepherd(dokku, lock: LockDouble.new(busy: true)).wait_idle(timeout: 0)
  end

  # A box whose builds plugin has nothing to say must not block a deliberate reboot for an hour.
  def test_unreadable_build_records_do_not_block_a_reboot
    dokku = DokkuDouble.new(fail_on: ['builds:list'])

    assert_equal :idle, shepherd(dokku).wait_idle(timeout: 0)
  end
end

class ClearcacheTest < Minitest::Test
  def test_prunes_once_and_never_touches_dokku
    dokku = DokkuDouble.new
    docker = DockerDouble.new

    assert shepherd(dokku, docker: docker).clearcache
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

  def last_build(dokku, id = 'demo', **options) = shepherd(dokku).last_build(id, **options)

  # The cap on `builds:list` is skipped for any *filtered* listing, so `--kind build` is what keeps an
  # idle app's real build visible once poll ticks outnumber the retention count — invisible in the
  # output, so it is pinned here. Verified on a box: without it, 21 ticks at retention 20 hid a build
  # whose record and log were still on disk.
  def test_the_listing_is_filtered_so_the_retention_cap_never_applies
    dokku = DokkuDouble.new(exists: ['apps:exists'], output: records(real('b1')))
    last_build(dokku)

    assert_includes dokku.commands, 'builds:list demo --kind build --format json'
  end

  def test_reports_the_newest_real_build_past_the_churn
    dokku = DokkuDouble.new(exists: ['apps:exists'],
                            output: records(abandoned('t3'), reaped('t2'), reaped('t1'), real('b1')))
    result = last_build(dokku)

    assert_equal 'b1', result.build['id']
    assert_equal '1m43s', result.build['duration']
    refute result.live
  end

  # The whole point: a reaped tick must never be reported as the last build, which is exactly what
  # `dokku builds:report demo` and `builds:list demo --status failed` both do.
  def test_a_reaped_tick_is_never_reported_as_a_failure
    dokku = DokkuDouble.new(exists: ['apps:exists'], output: records(reaped('t1'), real('b1')))

    assert_equal 'b1', last_build(dokku).build['id']
  end

  def test_a_real_failure_keeps_its_exit_code
    dokku = DokkuDouble.new(exists: ['apps:exists'],
                            output: records(reaped('t1'), real('b1', status: 'failed', exit_code: 1)))
    build = last_build(dokku).build

    assert_equal 'failed', build['status']
    assert_equal 1, build['exit_code']
  end

  # A build running right now outranks the last finished one — otherwise the verb reports history
  # while the answer is being computed.
  def test_a_live_build_outranks_the_last_finished_one
    live = { 'id' => 'now', 'status' => 'running', 'display_status' => 'running' }
    dokku = DokkuDouble.new(exists: ['apps:exists'], output: records(live, real('b1')))
    result = last_build(dokku)

    assert_equal 'now', result.build['id']
    assert result.live
  end

  # A report with no build in it, rather than no report — so a caller reads +build+ either way and
  # the two forms of the verb answer in one shape.
  def test_an_app_with_nothing_but_churn_reports_no_build_rather_than_lying
    dokku = DokkuDouble.new(exists: ['apps:exists'], output: records(abandoned('t2'), reaped('t1')))
    result = last_build(dokku)

    assert_equal 'demo', result.app
    assert_nil result.build
    assert_nil result.error
  end

  def test_the_log_is_read_only_when_asked_for
    dokku = DokkuDouble.new(exists: ['apps:exists'], output: records(real('b1')))
    result = last_build(dokku)

    assert_empty dokku.commands.grep(/builds:output/)
    assert_equal :not_requested, result.log_status
    assert_nil result.log

    dokku = DokkuDouble.new(exists: ['apps:exists'], output: records(real('b1')))
    last_build(dokku, log: true)

    assert_includes dokku.commands, 'builds:output demo b1'
  end

  def test_a_log_still_on_disk_is_read_from_the_file
    Tempfile.create('build.log') do |file|
      build = real('b1').merge('log_path' => file.path)
      dokku = DokkuDouble.new(exists: ['apps:exists'],
                              output: { 'builds:list demo' => JSON.generate([build]),
                                        'builds:output' => "compiling…\n" })
      result = last_build(dokku, log: true)

      assert result.log_path_exists
      assert_equal :file, result.log_status
      assert_equal "compiling…\n", result.log
    end
  end

  # The record outlives its log file — retention evicts by count and `builds:prune` deletes the `.log`
  # first — and `builds:output` then falls back to the copy journald holds.
  def test_a_log_no_longer_on_disk_is_flagged_as_the_syslog_copy
    dokku = DokkuDouble.new(exists: ['apps:exists'],
                            output: records(real('b1')).merge('builds:output' => "from journald\n"))
    result = last_build(dokku, log: true)

    refute result.log_path_exists
    assert_equal :syslog, result.log_status
    assert_equal "from journald\n", result.log
  end

  # dokku#9031: `builds:output` exits 0 having printed nothing for a pruned or mistyped id, so an
  # empty answer with no file behind it means the log is gone — not that the build printed nothing.
  # Nothing else on the box tells those two apart.
  def test_a_rotated_log_is_distinguishable_from_one_that_was_empty
    dokku = DokkuDouble.new(exists: ['apps:exists'], output: records(real('b1')))
    gone = last_build(dokku, log: true)

    assert_equal :rotated, gone.log_status
    assert_nil gone.log

    Tempfile.create('build.log') do |file|
      build = real('b1').merge('log_path' => file.path)
      dokku = DokkuDouble.new(exists: ['apps:exists'],
                              output: { 'builds:list demo' => JSON.generate([build]) })
      empty = last_build(dokku, log: true)

      assert_equal :file, empty.log_status
      assert_equal '', empty.log
    end
  end

  # `builds:output` tails a live build, so asking for one would block for the length of the build.
  def test_a_build_still_running_is_never_tailed
    live = { 'id' => 'now', 'status' => 'running', 'display_status' => 'running' }
    dokku = DokkuDouble.new(exists: ['apps:exists'], output: records(live))
    result = last_build(dokku, log: true)

    assert_equal :running, result.log_status
    assert_empty dokku.commands.grep(/builds:output/)
  end

  def test_an_unknown_app_is_refused_before_any_records_are_read
    dokku = DokkuDouble.new
    assert_raises(Shepherd2::Error) { shepherd(dokku).last_build('demo') }

    assert_empty dokku.commands.grep(/builds:list/)
  end

  def test_a_reserved_id_is_refused
    assert_raises(Shepherd2::UsageError) { shepherd(DokkuDouble.new).last_build('adminfoo') }
  end

  APPS = "=====> My Apps\ndemo\nother\nhandmade\n"

  # One entry per project create-app registered: a hand-made app has no SHEPHERD_GIT_URL and nothing
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
    results = shepherd(dokku).last_build

    assert_equal %w[demo other], results.map(&:app)
    assert_equal 'b1', results.first.build['id']
    assert_nil results.last.build
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
    results = shepherd(dokku).last_build

    assert_match(/failed/, results.find { |result| result.app == 'demo' }.error)
    assert_equal 'b1', results.find { |result| result.app == 'other' }.build['id']
    assert_equal 'b2', results.find { |result| result.app == 'handmade' }.build['id']
  end

  def test_records_that_are_not_json_are_a_failure_not_a_crash
    dokku = DokkuDouble.new(exists: ['apps:exists'], output: { 'builds:list demo' => 'not json' })

    assert_raises(Shepherd2::Error) { shepherd(dokku).last_build('demo') }
  end
end
