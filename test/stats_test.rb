# frozen_string_literal: true

require_relative 'helper'

# `stats` has no commands to record — its whole *return value* is the behaviour. What the assertions
# defend is the arithmetic that cannot be seen by eye on a box: SI sizes parsed back out of Docker's
# human strings, binary limit suffixes summed into a committed figure, and a cache volume attributed
# to the app whose name it carries. How any of it is printed is `cli_test.rb`'s business.
class StatsTest < Minitest::Test
  # Two apps, one of them made by hand (no SHEPHERD_GIT_URL) and therefore unpolled but still eating
  # the box's memory and disk.
  def dokku_double(apps: %w[hello handmade], limits: nil)
    limits ||= {
      'hello' => { '_default_.limit.memory' => '256m', 'build.limit.memory' => '2g' },
      'handmade' => { '_default_.limit.memory' => '512m' }
    }
    output = { 'apps:list' => "=====> My Apps\n#{apps.join("\n")}\n",
               'config:get hello SHEPHERD_GIT_URL' => "https://github.com/me/hello\n" }
    limits.each { |app, report| output["resource:report #{app}"] = "#{JSON.generate(report)}\n" }
    DokkuDouble.new(output: output)
  end

  def docker_double(volumes: nil, images: [])
    volumes ||= [{ 'Name' => 'cache-hello', 'Size' => '1.2GB' },
                 { 'Name' => 'cache-handmade', 'Size' => '400MB' }]
    DockerDouble.new(usage: { 'Images' => images, 'Volumes' => volumes })
  end

  def snapshot(dokku: dokku_double, docker: docker_double, machine: MachineDouble.new, events: EventLog.new)
    shepherd(dokku, docker: docker, machine: machine, events: events).stats
  end

  def test_a_cache_volume_is_attributed_to_its_app
    projects = snapshot[:projects]

    assert_equal({ app: 'hello', registered: true, cache: 1_200_000_000 }, projects[:apps].first)
    assert_equal({ app: 'handmade', registered: false, cache: 400_000_000 }, projects[:apps].last)
    assert_equal 1_600_000_000, projects[:cache_total]
  end

  # Not readable is never the same as zero, here or anywhere else in the snapshot.
  def test_an_app_that_never_built_has_no_cache_volume
    assert_nil snapshot(docker: docker_double(volumes: []))[:projects][:apps].first[:cache]
  end

  # apps:destroy removes the cache volume with the app, so a `cache-*` volume with no app means that
  # stopped being true — and a leak nobody would otherwise see.
  def test_a_cache_volume_with_no_app_is_named_as_an_orphan
    volumes = [{ 'Name' => 'cache-hello', 'Size' => '1.2GB' },
               { 'Name' => 'cache-gone', 'Size' => '900MB' }]

    assert_equal [{ volume: 'cache-gone', cache: 900_000_000 }],
                 snapshot(docker: docker_double(volumes: volumes))[:projects][:orphan_caches]
  end

  def test_an_unrelated_volume_is_not_a_project
    volumes = [{ 'Name' => 'postgres-data', 'Size' => '5GB' }]
    result = snapshot(docker: docker_double(volumes: volumes))

    assert_empty result[:projects][:orphan_caches]
    assert_equal 5_000_000_000, result[:docker][:volumes] # …but it still counts against the disk
  end

  def test_registered_and_unregistered_projects_are_counted_apart
    projects = snapshot[:projects]

    assert_equal 1, projects[:registered]
    assert_equal 1, projects[:unregistered]
  end

  # The sum is what free memory cannot answer: 256m + 512m of runtime, plus one build's 2g, because
  # one build runs at a time box-wide.
  def test_committed_memory_sums_runtime_limits_and_one_build_peak
    memory = snapshot[:memory]

    assert_equal 768 * (1024**2), memory[:committed]
    assert_equal 2 * (1024**3), memory[:build_peak]
  end

  def test_an_app_with_no_limit_is_named_rather_than_counted_as_zero
    dokku = dokku_double(limits: { 'hello' => { '_default_.limit.memory' => '256m' }, 'handmade' => {} })
    memory = snapshot(dokku: dokku)[:memory]

    assert_equal 256 * (1024**2), memory[:committed]
    assert_equal ['handmade'], memory[:unmeasured]
  end

  # Dokku 0.38 trims the plugin prefix from the report's keys; later versions also emit the legacy
  # `resource-`-prefixed spelling. Both have to read the same.
  def test_the_legacy_report_key_spelling_is_understood
    dokku = dokku_double(limits: { 'hello' => { 'resource-_default_.limit.memory' => '256m' },
                                   'handmade' => { 'resource-_default_.limit.memory' => '512m' } })

    assert_equal 768 * (1024**2), snapshot(dokku: dokku)[:memory][:committed]
  end

  def test_an_unreadable_resource_report_does_not_fail_the_verb
    dokku = DokkuDouble.new(output: { 'apps:list' => "hello\n", 'resource:report hello' => "not json\n" })

    assert_equal ['hello'], snapshot(dokku: dokku)[:memory][:unmeasured]
  end

  # `clearcache` reclaims dangling images, not every unused one, so that is the figure it may claim.
  def test_only_dangling_images_are_reported_as_reclaimable
    images = [{ 'Repository' => 'dokku/hello', 'UniqueSize' => '785.4MB' },
              { 'Repository' => '<none>', 'UniqueSize' => '300MB' }]
    docker = snapshot(docker: docker_double(images: images))[:docker]

    assert_equal 2, docker[:images_count]
    assert_equal 1_085_400_000, docker[:images_unique]
    assert_equal 300_000_000, docker[:images_dangling]
  end

  def test_the_disk_reported_is_dockers_own
    machine = MachineDouble.new(filesystems: {
                                  '/var/lib/docker' => { path: '/var/lib/docker', device: '/dev/sdb1',
                                                         mount: '/var/lib/docker', total: 100, free: 40 },
                                  '/' => { path: '/', device: '/dev/sda1', mount: '/',
                                           total: 200, free: 100 }
                                })
    disks = snapshot(machine: machine)[:disks]

    assert_equal '/var/lib/docker', disks.first[:path]
    assert_equal '/', disks.last[:path] # a separate device, so worth its own entry
  end

  def test_one_device_under_two_paths_is_reported_once
    assert_equal 1, snapshot[:disks].size
  end

  def test_swap_is_carried_whether_the_box_has_any_or_not
    assert_equal 0, snapshot[:memory][:swap_total]

    machine = MachineDouble.new(memory: { swap_total: 2 * (1024**3), swap_free: 1024**3 })

    assert_equal 2 * (1024**3), snapshot(machine: machine)[:memory][:swap_total]
  end

  # Every number is an Integer or nil — no rendered strings anywhere, which is what lets `--json` be a
  # dump of exactly this and nothing else.
  def test_the_snapshot_carries_no_rendered_text
    result = snapshot
    numbers = result[:memory].reject { |key, _| key == :unmeasured }.values +
              result[:disks].flat_map { |disk| [disk[:total], disk[:free]] } +
              result[:docker].values +
              result[:projects][:apps].map { |app| app[:cache] }

    numbers.each { |value| assert_kind_of Integer, value }
  end

  # The box half is known before the daemon's per-volume walk, which is the slow part, so it is
  # emitted rather than held back — proven here by a daemon that never answers at all.
  def test_the_box_half_is_emitted_before_the_slow_daemon_walk
    docker = Class.new(DockerDouble) do
      def disk_usage = raise(Shepherd2::Error, 'daemon is wedged')
    end.new
    events = EventLog.new

    assert_raises(Shepherd2::Error) { snapshot(docker: docker, events: events) }
    assert_equal 8 * (1024**3), events[:box_measured].first[:memory][:total]
  end

  def test_a_box_with_no_apps_measures_to_nothing_rather_than_failing
    dokku = DokkuDouble.new(output: { 'apps:list' => "=====> My Apps\n" })
    projects = snapshot(dokku: dokku, docker: docker_double(volumes: []))[:projects]

    assert_equal 0, projects[:registered]
    assert_empty projects[:apps]
    assert_equal 0, projects[:cache_total]
  end
end

# The parsing the report stands on, exercised directly: Docker prints SI sizes for people and Dokku
# stores binary limit suffixes, and mixing the two conventions up would be invisible on a real box.
class StatsUnitsTest < Minitest::Test
  def stats = shepherd(DokkuDouble.new)

  def parse_docker_size(value) = stats.send(:parse_docker_size, value)

  def parse_memory_limit(value) = stats.send(:parse_memory_limit, value)

  def test_docker_sizes_are_si
    assert_equal 1_200_000_000, parse_docker_size('1.2GB')
    assert_equal 785_400_000, parse_docker_size('785.4MB')
    assert_equal 0, parse_docker_size('0B')
    assert_equal 67, parse_docker_size('67B')
  end

  def test_an_unparsable_docker_size_is_nil_rather_than_zero
    assert_nil parse_docker_size('N/A')
    assert_nil parse_docker_size(nil)
  end

  def test_memory_limits_are_binary
    assert_equal 256 * (1024**2), parse_memory_limit('256m')
    assert_equal 2 * (1024**3), parse_memory_limit('2G')
    assert_equal 100, parse_memory_limit('100') # no suffix is bytes, which is Docker's own reading
  end

  def test_a_cleared_limit_is_no_limit
    assert_nil parse_memory_limit('clear')
    assert_nil parse_memory_limit(nil)
  end
end
