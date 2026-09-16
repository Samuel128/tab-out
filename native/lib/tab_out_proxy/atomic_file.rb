# frozen_string_literal: true

require 'fileutils'

module TabOutProxy
  module AtomicFile
    module_function

    def write(path, content)
      FileUtils.mkdir_p(File.dirname(path))
      replace("#{path}.bak", File.binread(path), backup: false) if File.exist?(path)
      replace(path, content, backup: false)
    end

    def replace(path, content, backup: false)
      FileUtils.mkdir_p(File.dirname(path))
      write("#{path}.bak", File.binread(path)) if backup && File.exist?(path)
      temp = "#{path}.tmp.#{$$}.#{Thread.current.object_id}.#{rand(1_000_000)}"
      File.open(temp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.binmode
        file.write(content)
        file.flush
        file.fsync
      end
      File.rename(temp, path)
      fsync_directory(File.dirname(path))
    ensure
      FileUtils.rm_f(temp) if defined?(temp) && temp
    end

    def restore_backup(path)
      backup = "#{path}.bak"
      raise Errno::ENOENT, backup unless File.exist?(backup)

      replace(path, File.binread(backup), backup: false)
    end

    def fsync_directory(directory)
      File.open(directory, 'r') { |file| file.fsync }
    rescue Errno::EINVAL, Errno::EISDIR
      nil
    end
    private_class_method :fsync_directory
  end
end
