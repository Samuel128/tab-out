# frozen_string_literal: true

require 'date'
require 'digest'
require 'json'
require 'open3'
require 'time'
require_relative 'atomic_file'
require_relative 'errors'

module TabOutProxy
  class TokenUsage
    HISTORY_NAME = 'token-usage-history.md'
    PAGE_SIZE = 100
    MAX_PAGES = 20
    ROW_PATTERN = /\A\| (\d{4}-\d{2}-\d{2}) \| (\d+) \| (\d+) \| (\d+) \| (\d+) \| (\d+) \| (\d+) \| (server|local|combined) \| (complete|partial) \|\z/
    LEGACY_ROW_PATTERN = /\A\| (\d{4}-\d{2}-\d{2}) \| (\d+) \| (\d+) \| (\d+) \| (\d+) \| (\d+) \| (\d+) \|\z/
    NUMERIC_FIELDS = %w[inputTokens cachedInputTokens outputTokens totalTokens sessionCount turns].freeze

    def initialize(root:, config_path: File.join(Dir.home, '.ZhixiaoCodexToken', 'config.json'),
                   script_path: File.join(Dir.home, '.codex', 'skills', 'TokenCollector', 'scripts', 'upgrade.py'),
                   query: nil, local_query: nil, clock: -> { Time.now }, query_timeout: 35,
                   local_query_timeout: 90)
      @root = File.expand_path(root)
      @config_path = config_path
      @script_path = script_path
      @query = query || method(:query_collector)
      @local_query = local_query || method(:query_local_collector)
      @clock = clock
      @query_timeout = query_timeout
      @local_query_timeout = local_query_timeout
    end

    def call
      with_history do |history, through_date|
        [through_date - (history[:days].empty? ? 364 : 29), through_date]
      end
    end

    def call_range(start_date:, end_date:)
      dates = validated_range(start_date, end_date)
      with_history { dates }
    end

    def cached
      person = configured_person
      person_key = Digest::SHA256.hexdigest(person)
      history = read_history
      history = empty_history unless history[:person_key] == person_key
      response(history[:days].empty? ? 'unavailable' : 'cached', person, history[:through_date],
               history[:days], history[:updated_at])
    rescue StandardError
      response('unavailable', nil, nil, {}, nil)
    end

    private

    def completed_through_date
      @clock.call.getlocal('+08:00').to_date - 1
    end

    def validated_range(start_date, end_date)
      unless [start_date, end_date].all? { |value| value.is_a?(String) && /\A\d{4}-\d{2}-\d{2}\z/.match?(value) }
        raise ValidationError.new('invalid_request', 'Select valid start and end dates')
      end
      start_on = Date.iso8601(start_date)
      end_on = Date.iso8601(end_date)
      unless start_on <= end_on && end_on <= completed_through_date && (end_on - start_on).to_i < 365
        raise ValidationError.new('invalid_request', 'Select up to 365 completed days')
      end

      [start_on, end_on]
    rescue ArgumentError
      raise ValidationError.new('invalid_request', 'Select valid start and end dates')
    end

    def with_history
      person = configured_person
      person_key = Digest::SHA256.hexdigest(person)
      history = read_history
      history = empty_history unless history[:person_key] == person_key
      start_on, end_on = yield(history, completed_through_date)
      server_rows = attempt { fetch_rows(start_on, end_on, person) }
      local_rows = attempt { fetch_local_rows(start_on, end_on) }
      raise ArgumentError, 'Token usage sources are unavailable' if server_rows.nil? && local_rows.nil?

      cached_range = history[:days].select { |date, _| date.between?(start_on.iso8601, end_on.iso8601) }
      base_rows = server_rows || cached_range
      fresh_rows = merge_source_rows(base_rows, local_rows || {})
      merged = history[:days].reject { |date, _| date.between?(start_on.iso8601, end_on.iso8601) }.merge(fresh_rows)
      through_date = [history[:through_date], end_on].compact.max
      updated_at = @clock.call.utc.iso8601
      write_history(merged, updated_at, through_date, person_key)
      response(server_rows.nil? ? 'local' : 'fresh', person, through_date, merged, updated_at)
    rescue StandardError
      history ||= empty_history
      response(history[:days].empty? ? 'unavailable' : 'cached', person, history[:through_date],
               history[:days], history[:updated_at])
    end

    def empty_history
      { days: {}, updated_at: nil, through_date: nil, person_key: nil }
    end

    def attempt
      yield
    rescue StandardError
      nil
    end

    def configured_person
      config = JSON.parse(File.binread(@config_path))
      name = config.fetch('username')
      raise ArgumentError, 'Collector username is missing' unless name.is_a?(String) && !name.strip.empty?

      name.strip
    end

    def fetch_rows(start_date, end_date, person)
      collected = []
      page = 1
      loop do
        result = @query.call(start_date: start_date.iso8601, end_date: end_date.iso8601,
                             page: page, person: person)
        raise ArgumentError, 'Collector query failed' unless result.is_a?(Hash) && result['code'] == 0

        data = result.dig('data', 'result')
        raise ArgumentError, 'Collector result is invalid' unless data.is_a?(Hash) && data['items'].is_a?(Array)

        total = Integer(data.fetch('total'))
        raise ArgumentError, 'Collector result is too large' if total.negative? || total > PAGE_SIZE * MAX_PAGES

        items = data['items']
        raise ArgumentError, 'Collector page is empty' if items.empty? && collected.length < total

        collected.concat(items)
        break if collected.length >= total

        page += 1
        raise ArgumentError, 'Collector pagination exceeded limit' if page > MAX_PAGES
      end

      collected.each_with_object({}) do |item, days|
        row = normalize_row(item, start_date, end_date, source: 'server', coverage_status: 'complete')
        date = row.fetch('date')
        if days.key?(date)
          days[date] = sum_rows(days.fetch(date), row)
        else
          days[date] = row
        end
      end
    end

    def fetch_local_rows(start_date, end_date)
      result = @local_query.call(start_date: start_date.iso8601, end_date: end_date.iso8601)
      raise ArgumentError, 'Collector local query failed' unless result.is_a?(Hash) && result['code'] == 0

      data = result.dig('data', 'result')
      raise ArgumentError, 'Collector local result is invalid' unless data.is_a?(Hash) && data['items'].is_a?(Array)

      data['items'].each_with_object({}) do |item, days|
        row = normalize_row(
          item, start_date, end_date,
          source: 'local', coverage_status: item.fetch('coverage_status', 'complete')
        )
        date = row.fetch('date')
        days[date] = days.key?(date) ? sum_rows(days.fetch(date), row) : row
      end
    end

    def normalize_row(item, start_date, end_date, source:, coverage_status:)
      raise ArgumentError, 'Collector row is invalid' unless item.is_a?(Hash)

      date = Date.iso8601(item.fetch('period_start').to_s)
      raise ArgumentError, 'Collector date is outside requested range' unless date.between?(start_date, end_date)

      raise ArgumentError, 'Collector coverage is invalid' unless %w[complete partial].include?(coverage_status)

      {
        'date' => date.iso8601,
        'inputTokens' => nonnegative(item.fetch('input_tokens')),
        'cachedInputTokens' => nonnegative(item.fetch('cached_input_tokens', 0)),
        'outputTokens' => nonnegative(item.fetch('output_tokens')),
        'totalTokens' => nonnegative(item.fetch('total_tokens')),
        'sessionCount' => nonnegative(item.fetch('session_count', 0) || 0),
        'turns' => nonnegative(item.fetch('turns', 0) || 0),
        'source' => source,
        'coverageStatus' => coverage_status
      }
    end

    def nonnegative(value)
      number = Integer(value)
      raise ArgumentError, 'Collector count is invalid' if number.negative?

      number
    end

    def sum_rows(left, right)
      left.each_with_object({}) do |(key, value), combined|
        combined[key] = if NUMERIC_FIELDS.include?(key)
                          value + right.fetch(key)
                        elsif key == 'coverageStatus'
                          [value, right.fetch(key)].include?('partial') ? 'partial' : 'complete'
                        else
                          value
                        end
      end
    end

    def merge_source_rows(server_rows, local_rows)
      (server_rows.keys | local_rows.keys).each_with_object({}) do |date, merged|
        server = server_rows[date]
        local = local_rows[date]
        if server && local
          row = server.dup
          local_increased = NUMERIC_FIELDS.any? { |field| local.fetch(field) > server.fetch(field) }
          NUMERIC_FIELDS.each { |field| row[field] = [server.fetch(field), local.fetch(field)].max }
          row['totalTokens'] = [row.fetch('totalTokens'), row.fetch('inputTokens') + row.fetch('outputTokens')].max
          row['source'] = local_increased ? 'combined' : 'server'
          row['coverageStatus'] = local_increased ? local.fetch('coverageStatus') : 'complete'
          merged[date] = row
        else
          merged[date] = (server || local).dup
        end
      end
    end

    def query_collector(start_date:, end_date:, page:, person:)
      args = ['python3', @script_path, '--query-wide', '--grain', 'day',
              '--start-date', start_date, '--end-date', end_date,
              '--personnel', person, '--page', page.to_s, '--page-size', PAGE_SIZE.to_s]
      stdout = nil
      status = nil
      Open3.popen3(*args, pgroup: true) do |stdin, output, errors, process|
        stdin.close
        output_reader = Thread.new { output.read }
        error_reader = Thread.new { errors.read }
        unless process.join(@query_timeout)
          terminate_collector(process, output_reader, error_reader)
          raise ArgumentError, 'Collector query timed out'
        end
        stdout = output_reader.value
        error_reader.value
        status = process.value
      end
      raise ArgumentError, 'Collector query failed' unless status.success?

      JSON.parse(stdout)
    end

    def query_local_collector(start_date:, end_date:)
      args = ['python3', @script_path, '--query-local', '--start-date', start_date, '--end-date', end_date]
      run_collector(args, @local_query_timeout)
    end

    def run_collector(args, timeout)
      stdout = nil
      status = nil
      Open3.popen3(*args, pgroup: true) do |stdin, output, errors, process|
        stdin.close
        output_reader = Thread.new { output.read }
        error_reader = Thread.new { errors.read }
        unless process.join(timeout)
          terminate_collector(process, output_reader, error_reader)
          raise ArgumentError, 'Collector query timed out'
        end
        stdout = output_reader.value
        error_reader.value
        status = process.value
      end
      raise ArgumentError, 'Collector query failed' unless status.success?

      JSON.parse(stdout)
    end

    def terminate_collector(process, output_reader, error_reader)
      Process.kill('TERM', -process.pid)
      process.join(0.2)
      Process.kill('KILL', -process.pid)
    rescue Errno::ESRCH
      nil
    ensure
      process.join(1)
      output_reader.join(1)
      error_reader.join(1)
    end

    def history_path
      File.join(@root, HISTORY_NAME)
    end

    def read_history
      return empty_history unless File.exist?(history_path)

      stat = File.lstat(history_path)
      raise ArgumentError, 'History file is unsafe' unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero?

      content = File.binread(history_path)
      person_key = content[/^Person key: ([0-9a-f]{64})$/, 1]
      updated_at = content[/^Last successful sync: ([^\n]+)$/, 1]
      through_text = content[/^Through date: (\d{4}-\d{2}-\d{2})$/, 1]
      through_date = Date.iso8601(through_text) if through_text
      days = {}
      content.each_line do |line|
        match = ROW_PATTERN.match(line.strip)
        legacy = LEGACY_ROW_PATTERN.match(line.strip) unless match
        match ||= legacy
        next unless match

        values = match.captures
        row = {
          'date' => Date.iso8601(values[0]).iso8601,
          'inputTokens' => nonnegative(values[1]),
          'cachedInputTokens' => nonnegative(values[2]),
          'outputTokens' => nonnegative(values[3]),
          'totalTokens' => nonnegative(values[4]),
          'sessionCount' => nonnegative(values[5]),
          'turns' => nonnegative(values[6]),
          'source' => legacy ? 'server' : values[7],
          'coverageStatus' => legacy ? 'complete' : values[8]
        }
        days[row.fetch('date')] = row
      end
      { days: days, updated_at: updated_at, through_date: through_date, person_key: person_key }
    end

    def write_history(days, updated_at, through_date, person_key)
      lines = [
        '# Token usage history', '',
        'Local, private daily totals from TokenCollector. Cached input is part of input, not an extra amount.',
        '', "Person key: #{person_key}", "Last successful sync: #{updated_at}", "Through date: #{through_date.iso8601}", '',
        '| Date | Input | Cached input | Output | Total | Sessions | Turns | Source | Coverage |',
        '| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |'
      ]
      days.keys.sort.each do |date|
        row = days.fetch(date)
        lines << "| #{date} | #{row.fetch('inputTokens')} | #{row.fetch('cachedInputTokens')} | #{row.fetch('outputTokens')} | #{row.fetch('totalTokens')} | #{row.fetch('sessionCount')} | #{row.fetch('turns')} | #{row.fetch('source', 'server')} | #{row.fetch('coverageStatus', 'complete')} |"
      end
      AtomicFile.replace(history_path, lines.join("\n") + "\n")
    end

    def response(status, person, through_date, days, updated_at)
      {
        'status' => status,
        'person' => person,
        'throughDate' => through_date && through_date.iso8601,
        'updatedAt' => updated_at,
        'days' => days.keys.sort.reverse.map { |date| days.fetch(date) }
      }
    end
  end
end
