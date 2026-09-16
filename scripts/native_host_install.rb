# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'tmpdir'

module TabOutNativeHostInstall
  HOST_NAME = 'com.samuel.tabout.proxy'
  ROOT = File.expand_path('..', __dir__)
  DEFAULT_EXTENSION = '/Users/Samuel/Desktop/Samuel/Slef/github/tab-out/extension'

  def self.data_dir
    File.join(Dir.home, 'Library', 'Application Support', 'Tab Out Proxy')
  end

  def self.native_dir
    File.join(data_dir, 'native')
  end

  def self.manifest_path
    File.join(Dir.home, 'Library', 'Application Support', 'Google', 'Chrome', 'NativeMessagingHosts', "#{HOST_NAME}.json")
  end

  def self.extension_id(path)
    absolute = File.expand_path(path)
    Digest::SHA256.hexdigest(absolute)[0, 32].tr('0123456789abcdef', 'abcdefghijklmnop')
  end

  def self.verify_extension!(path)
    manifest = JSON.parse(File.read(File.join(path, 'manifest.json')))
    raise ArgumentError, 'Extension manifest must be named Tab Out' unless manifest['name'] == 'Tab Out'
    raise ArgumentError, 'Extension must include nativeMessaging permission' unless manifest['permissions'].is_a?(Array) && manifest['permissions'].include?('nativeMessaging')
    raise ArgumentError, 'Extension manifest must not define a key (path-derived ID required)' if manifest.key?('key')
  end

  def self.install(extension_path)
    verify_extension!(extension_path)
    id = extension_id(extension_path)
    FileUtils.mkdir_p(data_dir)
    install_code
    host_path = File.join(native_dir, 'bin', 'tab-out-proxy-host')
    template = JSON.parse(File.read(File.join(ROOT, 'native', "#{HOST_NAME}.json.template")))
    template['path'] = host_path
    template['allowed_origins'] = ["chrome-extension://#{id}/"]
    atomic_write(manifest_path, JSON.pretty_generate(template) + "\n")
    id
  end

  def self.install_code
    stage = Dir.mktmpdir('.native-stage-', data_dir)
    backup = nil
    begin
      FileUtils.mkdir_p(File.join(stage, 'bin'))
      FileUtils.cp(File.join(ROOT, 'native', 'bin', 'tab-out-proxy-host'), File.join(stage, 'bin', 'tab-out-proxy-host'))
      FileUtils.chmod(0o755, File.join(stage, 'bin', 'tab-out-proxy-host'))
      FileUtils.cp_r(File.join(ROOT, 'native', 'lib'), File.join(stage, 'lib'))
      if File.exist?(native_dir)
        backup = Dir.mktmpdir('.native-backup-', data_dir)
        FileUtils.remove_entry(backup)
        File.rename(native_dir, backup)
      end
      File.rename(stage, native_dir)
      stage = nil
      FileUtils.remove_entry(backup) if backup
    rescue StandardError
      File.rename(backup, native_dir) if backup && File.exist?(backup) && !File.exist?(native_dir)
      raise
    ensure
      FileUtils.remove_entry(stage) if stage && File.exist?(stage)
    end
  end

  def self.atomic_write(path, content)
    parent = File.dirname(path)
    FileUtils.mkdir_p(parent)
    temp = File.join(parent, ".#{File.basename(path)}.#{Process.pid}.tmp")
    begin
      File.open(temp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(content)
        file.flush
        file.fsync
      end
      File.rename(temp, path)
    ensure
      File.delete(temp) if File.exist?(temp)
    end
  end

  def self.uninstall
    File.delete(manifest_path) if File.file?(manifest_path)
    FileUtils.remove_entry(native_dir) if File.directory?(native_dir)
  end
end
