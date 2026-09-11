# frozen_string_literal: true

require_relative 'helper'

# `stats` has no commands to record — its whole output *is* the behaviour, like `last-build`. What the
# assertions defend is the arithmetic that cannot be seen by eye on a box: SI sizes parsed back out of
# Docker's human strings, binary limit suffixes summed into a committed figure, and a cache volume
# attributed to the app whose name it carries.
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

  def stats_output(dokku: dokku_double, docker: docker_double, machine: MachineDouble.new, json: false)
    out = StringIO.new
    assert_equal EXIT_OK, shepherd(dokku, docker: docker, machine: machine, out: out).stats(json: json)
    out.string
  end

  def test_a_cache_volume_is_attributed_to_its_app
    output = stats_output

    assert_match(/^  hello\s+1\.1 GiB$/, output)
    assert_match(/^  handmade \(unregistered\)\s+381\.5 MiB$/, output)
    assert_match(/^  total\s+1\.5 GiB$/, output)
  end

  def test_an_app_that_never_built_has_no_cache_volume
    output = stats_output(docker: docker_double(volumes: []))

    assert_match(/^  hello\s+no cache volume$/, output)
  end

  # apps:destroy removes the cache volume with the app, so a `cache-*` volume with no app means that
  # stopped being true — and a leak nobody would otherwise see.
  def test_a_cache_volume_with_no_app_is_named_as_an_orphan
    volumes = [{ 'Name' => 'cache-hello', 'Size' => '1.2GB' },
               { 'Name' => 'cache-gone', 'Size' => '900MB' }]

    assert_match(/^  cache-gone \(orphan, no such app\)\s+858\.3 MiB$/, stats_output(docker: docker_double(volumes: volumes)))
  end

  def test_an_unrelated_volume_is_not_a_project
    volumes = [{ 'Name' => 'postgres-data', 'Size' => '5GB' }]
    output = stats_output(docker: docker_double(volumes: volumes))

    refute_match(/postgres-data/, output)
    assert_match(/volumes\s+4\.7 GiB in 1/, output) # …but it still counts against the disk
  end

  def test_registered_and_unregistered_projects_are_counted_apart
    assert_match(/^projects\s+1 registered · 1 unregistered/, stats_output)
  end

  # The sum is what free memory cannot answer: 256m + 512m of runtime, plus one build's 2g, because
  # one build runs at a time box-wide.
  def test_committed_memory_sums_runtime_limits_and_one_build_peak
    assert_match(/^  committed\s+768\.0 MiB runtime \+ 2\.0 GiB build peak, of 8\.0 GiB$/, stats_output)
  end

  def test_an_app_with_no_limit_is_named_rather_than_counted_as_zero
    dokku = dokku_double(limits: { 'hello' => { '_default_.limit.memory' => '256m' }, 'handmade' => {} })
    output = stats_output(dokku: dokku)

    assert_match(/^  committed\s+256\.0 MiB runtime, of/, output)
    assert_match(/1 app\(s\) with no readable runtime limit: handmade/, output)
  end

  # Dokku 0.38 trims the plugin prefix from the report's keys; later versions also emit the legacy
  # `resource-`-prefixed spelling. Both have to read the same.
  def test_the_legacy_report_key_spelling_is_understood
    dokku = dokku_double(limits: { 'hello' => { 'resource-_default_.limit.memory' => '256m' },
                                   'handmade' => { 'resource-_default_.limit.memory' => '512m' } })

    assert_match(/^  committed\s+768\.0 MiB runtime, of/, stats_output(dokku: dokku))
  end

  def test_an_unreadable_resource_report_does_not_fail_the_verb
    dokku = DokkuDouble.new(output: { 'apps:list' => "hello\n", 'resource:report hello' => "not json\n" })

    assert_match(/no readable runtime limit: hello/, stats_output(dokku: dokku))
  end

  # `clearcache` reclaims dangling images, not every unused one, so that is the figure it may claim.
  def test_only_dangling_images_are_reported_as_reclaimable
    images = [{ 'Repository' => 'dokku/hello', 'UniqueSize' => '785.4MB' },
              { 'Repository' => '<none>', 'UniqueSize' => '300MB' }]

    assert_match(/^  images\s+1\.0 GiB in 2 · 286\.1 MiB dangling/, stats_output(docker: docker_double(images: images)))
  end

  def test_the_disk_reported_is_dockers_own
    machine = MachineDouble.new(filesystems: {
                                  '/var/lib/docker' => { path: '/var/lib/docker', device: '/dev/sdb1',
                                                         mount: '/var/lib/docker', total: 100, free: 40 },
                                  '/' => { path: '/', device: '/dev/sda1', mount: '/',
                                           total: 200, free: 100 }
                                })
    output = stats_output(machine: machine)

    assert_match(%r{^  disk\s+/var/lib/docker on /dev/sdb1 — 100 B total · 40 B free \(60% used\)$}, output)
    assert_match(%r{^  disk\s+/ on /dev/sda1 —}, output) # a separate device, so worth its own line
  end

  def test_one_device_under_two_paths_is_reported_once
    assert_equal 1, stats_output.lines.grep(/^  disk /).size
  end

  def test_swap_is_reported_only_when_the_box_has_some
    refute_match(/swap/, stats_output)
    assert_match(/^  swap\s+2\.0 GiB total · 1\.0 GiB free$/,
                 stats_output(machine: MachineDouble.new(memory: { swap_total: 2 * (1024**3),
                                                                   swap_free: 1024**3 })))
  end

  def test_json_is_bytes_and_nothing_else
    snapshot = JSON.parse(stats_output(json: true))

    assert_equal 8 * (1024**3), snapshot.dig('memory', 'total')
    assert_equal 805_306_368, snapshot.dig('memory', 'committed')
    assert_equal 1_600_000_000, snapshot.dig('projects', 'cache_total')
    assert_equal({ 'app' => 'hello', 'registered' => true, 'cache' => 1_200_000_000 },
                 snapshot.dig('projects', 'apps').first)
  end

  def test_json_carries_no_rendered_text
    refute_match(/GiB|·/, stats_output(json: true))
  end

  def test_a_box_with_no_apps_says_so
    dokku = DokkuDouble.new(output: { 'apps:list' => "=====> My Apps\n" })
    output = stats_output(dokku: dokku, docker: docker_double(volumes: []))

    assert_match(/^projects\s+0 registered$/, output)
    refute_match(/^  total/, output)
  end
end

# The parsing the report stands on, exercised directly: Docker prints SI sizes for people and Dokku
# stores binary limit suffixes, and mixing the two conventions up would be invisible on a real box.
class StatsUnitsTest < Minitest::Test
  def stats = shepherd(DokkuDouble.new)

  def parse_docker_size(value) = stats.send(:parse_docker_size, value)

  def parse_memory_limit(value) = stats.send(:parse_memory_limit, value)

  def human_bytes(bytes) = stats.send(:human_bytes, bytes)

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

  # Rendering is binary and says so, to match `free -h` and `df -h` rather than the SI strings the
  # cache sizes were parsed out of.
  def test_bytes_render_as_free_and_df_would_print_them
    assert_equal '512 B', human_bytes(512)
    assert_equal '8.0 GiB', human_bytes(8 * (1024**3))
    assert_equal '1.1 GiB', human_bytes(1_200_000_000) # what Docker calls 1.2GB
    assert_equal '—', human_bytes(nil)
  end
end
