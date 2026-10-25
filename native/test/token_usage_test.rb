# frozen_string_literal: true

require_relative 'test_helper'
require 'json'
require 'tab_out_proxy/token_usage'

class TokenUsageTest < Minitest::Test
  def usage(root, query, name: 'Sample User', local_query: ->(**) { raise 'local unavailable' })
    config = File.join(root, 'config.json')
    File.write(config, JSON.generate('username' => name, 'read_token' => 'never-display'))
    TabOutProxy::TokenUsage.new(
      root: root,
      config_path: config,
      query: query,
      local_query: local_query,
      clock: -> { Time.utc(2026, 9, 17, 3) }
    )
  end

  def wide(items, total: items.length)
    { 'code' => 0, 'data' => { 'result' => { 'total' => total, 'items' => items } } }
  end

  def local(items)
    { 'code' => 0, 'data' => { 'result' => { 'items' => items } } }
  end

  def day(date, total)
    {
      'period_start' => date,
      'input_tokens' => total - 10,
      'cached_input_tokens' => 2,
      'output_tokens' => 10,
      'total_tokens' => total,
      'session_count' => 1,
      'turns' => 3,
      'employee_no' => 'private-employee-id',
      'access_token' => 'never-display'
    }
  end

  def local_day(date, total, coverage: 'complete')
    day(date, total).merge('coverage_status' => coverage)
  end

  def test_local_scan_backfills_missing_server_days_and_never_uploads
    with_temp_dir do |root|
      local_calls = []
      reader = usage(
        root,
        ->(**) { wide([day('2026-09-15', 100)]) },
        local_query: lambda do |start_date:, end_date:|
          local_calls << [start_date, end_date]
          local([local_day('2026-09-15', 120), local_day('2026-09-16', 80)])
        end
      )

      result = reader.call

      rows = result.fetch('days').to_h { |row| [row.fetch('date'), row] }
      assert_equal 120, rows.fetch('2026-09-15').fetch('totalTokens')
      assert_equal 'combined', rows.fetch('2026-09-15').fetch('source')
      assert_equal 80, rows.fetch('2026-09-16').fetch('totalTokens')
      assert_equal 'local', rows.fetch('2026-09-16').fetch('source')
      assert_equal [['2025-09-17', '2026-09-16']], local_calls
      markdown = File.read(File.join(root, 'token-usage-history.md'))
      assert_match(/\| 2026-09-16 \| 70 \| 2 \| 10 \| 80 \| 1 \| 3 \| local \| complete \|/, markdown)
    end
  end

  def test_server_data_stays_authoritative_when_it_exceeds_local_scan
    with_temp_dir do |root|
      reader = usage(
        root,
        ->(**) { wide([day('2026-09-16', 150)]) },
        local_query: ->(**) { local([local_day('2026-09-16', 100, coverage: 'partial')]) }
      )

      row = reader.call.fetch('days').first

      assert_equal 150, row.fetch('totalTokens')
      assert_equal 'server', row.fetch('source')
      assert_equal 'complete', row.fetch('coverageStatus')
    end
  end

  def test_local_scan_can_refresh_history_when_server_query_is_unavailable
    with_temp_dir do |root|
      result = usage(
        root,
        ->(**) { raise 'server offline' },
        local_query: ->(**) { local([local_day('2026-09-16', 90)]) }
      ).call

      assert_equal 'local', result.fetch('status')
      assert_equal 90, result.fetch('days').first.fetch('totalTokens')
      assert_equal 'local', result.fetch('days').first.fetch('source')
    end
  end

  def test_cached_returns_saved_markdown_without_running_either_collector_query
    with_temp_dir do |root|
      calls = []
      reader = usage(
        root,
        ->(**) { calls << :server; wide([day('2026-09-16', 100)]) },
        local_query: ->(**) { calls << :local; local([]) }
      )
      reader.call
      calls.clear

      result = reader.cached

      assert_equal 'cached', result.fetch('status')
      assert_equal 100, result.fetch('days').first.fetch('totalTokens')
      assert_empty calls
    end
  end

  def test_first_load_backfills_and_writes_only_daily_totals_to_private_markdown
    with_temp_dir do |root|
      calls = []
      query = lambda do |start_date:, end_date:, page:, person:|
        calls << [start_date, end_date, page, person]
        wide([day('2026-09-15', 100), day('2026-09-16', 120)])
      end

      result = usage(root, query).call
      markdown = File.read(File.join(root, 'token-usage-history.md'))

      assert_equal 'fresh', result.fetch('status')
      assert_equal '2026-09-16', result.fetch('throughDate')
      assert_equal 2, result.fetch('days').length
      assert_equal [['2025-09-17', '2026-09-16', 1, 'Sample User']], calls
      assert_match(/\| 2026-09-16 \| 110 \| 2 \| 10 \| 120 \| 1 \| 3 \|/, markdown)
      assert_match(/^Person key: [0-9a-f]{64}$/, markdown)
      refute_match(/private-employee-id|never-display|Sample User/, markdown)
      refute_match(/private-employee-id|never-display/, JSON.generate(result))
      assert_equal 0o600, File.stat(File.join(root, 'token-usage-history.md')).mode & 0o777
    end
  end

  def test_refresh_replaces_recent_day_and_preserves_older_history
    with_temp_dir do |root|
      calls = []
      current = wide([day('2026-04-01', 40), day('2026-09-16', 100)])
      query = lambda do |start_date:, **|
        calls << start_date
        current
      end
      reader = usage(root, query)
      reader.call
      current = wide([day('2026-09-16', 150)])

      result = reader.call

      assert_equal ['2025-09-17', '2026-08-18'], calls
      assert_equal({ '2026-04-01' => 40, '2026-09-16' => 150 }, result.fetch('days').to_h { |row| [row.fetch('date'), row.fetch('totalTokens')] })
      assert_equal 1, File.read(File.join(root, 'token-usage-history.md')).scan(/\| 2026-09-16 \|/).length
    end
  end

  def test_failed_query_returns_cache_without_claiming_freshness
    with_temp_dir do |root|
      current = wide([day('2026-09-16', 100)])
      reader = usage(root, ->(**) { current })
      reader.call
      current = nil
      failed = usage(root, ->(**) { raise 'secret server detail' }).call

      assert_equal 'cached', failed.fetch('status')
      assert_equal '2026-09-16', failed.fetch('throughDate')
      assert_equal 100, failed.fetch('days').first.fetch('totalTokens')
      refute_match(/secret server detail/, JSON.generate(failed))
      assert_match(/\| 2026-09-16 \|/, File.read(File.join(root, 'token-usage-history.md')))
    end
  end

  def test_paginates_and_rejects_unfiltered_or_failed_results
    with_temp_dir do |root|
      pages = []
      query = lambda do |page:, person:, **|
        pages << [page, person]
        page == 1 ? wide([day('2026-09-15', 90)], total: 2) : wide([day('2026-09-16', 100)], total: 2)
      end
      result = usage(root, query).call
      assert_equal [[1, 'Sample User'], [2, 'Sample User']], pages
      assert_equal 2, result.fetch('days').length

      bad = usage(root, ->(**) { { 'code' => 403, 'message' => 'private detail' } }).call
      assert_equal 'cached', bad.fetch('status')
      refute_match(/private detail/, JSON.generate(bad))
    end
  end

  def test_changing_configured_person_never_mixes_or_reveals_old_history
    with_temp_dir do |root|
      usage(root, ->(**) { wide([day('2026-04-01', 40)]) }).call
      other = usage(root, ->(**) { wide([day('2026-09-16', 90)]) }, name: 'Other User').call

      assert_equal 'fresh', other.fetch('status')
      assert_equal ['2026-09-16'], other.fetch('days').map { |row| row.fetch('date') }
      refute_match(/2026-04-01/, File.read(File.join(root, 'token-usage-history.md')))

      unavailable = usage(root, ->(**) { raise 'offline' }, name: 'Third User').call
      assert_equal 'unavailable', unavailable.fetch('status')
      assert_empty unavailable.fetch('days')
    end
  end

  def test_slow_collector_is_terminated_and_returns_cache
    with_temp_dir do |root|
      usage(root, ->(**) { wide([day('2026-09-16', 100)]) }).call
      script = File.join(root, 'slow.py')
      child_pid_path = File.join(root, 'child.pid')
      File.write(
        script,
        "import subprocess, sys, time\n" \
        "child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])\n" \
        "open(#{child_pid_path.inspect}, 'w').write(str(child.pid))\n" \
        "time.sleep(30)\n"
      )
      collector = TabOutProxy::TokenUsage.new(
        root: root,
        config_path: File.join(root, 'config.json'),
        script_path: script,
        local_query: ->(**) { raise 'local unavailable' },
        query_timeout: 0.5,
        clock: -> { Time.utc(2026, 9, 17, 3) }
      )

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = collector.call
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_equal 'cached', result.fetch('status')
      assert_equal 100, result.fetch('days').first.fetch('totalTokens')
      assert_operator elapsed, :<, 2.5
      child_pid = Integer(File.read(child_pid_path))
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
      alive = true
      loop do
        Process.kill(0, child_pid)
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.02
      rescue Errno::ESRCH
        alive = false
        break
      end
      refute alive, 'collector timeout left a child process running'
    ensure
      if defined?(child_pid) && alive
        begin
          Process.kill('KILL', child_pid)
        rescue Errno::ESRCH
          nil
        end
      end
    end
  end

  def test_date_range_query_replaces_only_that_range_and_preserves_latest_through_date
    with_temp_dir do |root|
      calls = []
      current = wide([day('2026-04-01', 40), day('2026-09-16', 100)])
      query = lambda do |start_date:, end_date:, **|
        calls << [start_date, end_date]
        current
      end
      reader = usage(root, query)
      reader.call
      current = wide([day('2026-04-02', 60)])

      result = reader.call_range(start_date: '2026-04-01', end_date: '2026-04-03')

      assert_equal ['2026-04-01', '2026-04-03'], calls.last
      assert_equal 'fresh', result.fetch('status')
      assert_equal '2026-09-16', result.fetch('throughDate')
      assert_equal({ '2026-04-02' => 60, '2026-09-16' => 100 }, result.fetch('days').to_h { |row| [row.fetch('date'), row.fetch('totalTokens')] })
    end
  end

  def test_date_range_rejects_invalid_or_unfinished_dates_before_query
    with_temp_dir do |root|
      calls = 0
      reader = usage(root, ->(**) { calls += 1; wide([]) })
      [['2026-09-16', '2026-09-14'], ['2026-09-17', '2026-09-17'],
       ['2025-01-01', '2026-09-16'], ['2026-02-30', '2026-03-01']].each do |start_date, end_date|
        assert_raises(TabOutProxy::ValidationError) do
          reader.call_range(start_date: start_date, end_date: end_date)
        end
      end
      assert_equal 0, calls
    end
  end
end
