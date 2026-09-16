# frozen_string_literal: true

require 'digest'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'timeout'

class InstallerTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  INSTALLER = File.join(ROOT, 'scripts', 'install-native-host')
  UNINSTALLER = File.join(ROOT, 'scripts', 'uninstall-native-host')
  HOST_NAME = 'com.samuel.tabout.proxy'

  def setup
    @tmp = Dir.mktmpdir('tab-out-installer-')
    @home = File.join(@tmp, 'home')
    @extension = File.join(@tmp, 'unpacked', 'extension')
    FileUtils.mkdir_p([@home, @extension])
    write_extension
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_install_binds_exact_path_derived_id_and_copies_host
    stdout, stderr, status = run_script(INSTALLER, '--extension-path', @extension)

    assert status.success?, "#{stdout}\n#{stderr}"
    manifest = JSON.parse(File.read(host_manifest))
    expected_id = Digest::SHA256.hexdigest(File.expand_path(@extension))[0, 32].tr('0123456789abcdef', 'abcdefghijklmnop')
    assert_equal 'mjdgpafhcdpdckehldcammdkjcicfdka',
                 Digest::SHA256.hexdigest('/Users/Samuel/Desktop/Samuel/Slef/github/tab-out/extension')[0, 32].tr('0123456789abcdef', 'abcdefghijklmnop')
    assert_equal HOST_NAME, manifest.fetch('name')
    assert_equal 'stdio', manifest.fetch('type')
    assert_equal ["chrome-extension://#{expected_id}/"], manifest.fetch('allowed_origins')
    assert_equal installed_host, manifest.fetch('path')
    assert File.executable?(installed_host)
    assert File.file?(File.join(native_dir, 'lib', 'tab_out_proxy', 'service.rb'))
  end

  def test_reinstall_is_idempotent_and_preserves_managed_data
    assert run_script(INSTALLER, '--extension-path', @extension).last.success?
    data = File.join(data_dir, 'rules.json')
    File.write(data, '{"sentinel":true}')
    original_manifest = File.binread(host_manifest)

    assert run_script(INSTALLER, '--extension-path', @extension).last.success?

    assert_equal original_manifest, File.binread(host_manifest)
    assert_equal '{"sentinel":true}', File.read(data)
  end

  def test_failed_manifest_write_restores_previous_code_and_manifest_exactly
    assert run_script(INSTALLER, '--extension-path', @extension).last.success?
    File.binwrite(installed_host, "old host\x00\xff".b)
    File.chmod(0o700, installed_host)
    old_manifest = "old manifest\x00\xff".b
    File.binwrite(host_manifest, old_manifest)
    File.chmod(0o640, host_manifest)
    rules = File.join(data_dir, 'rules.json')
    File.write(rules, '{"sentinel":true}')

    refute run_failing_manifest_install.success?

    assert_equal "old host\x00\xff".b, File.binread(installed_host)
    assert_equal 0o700, File.stat(installed_host).mode & 0o777
    assert_equal old_manifest, File.binread(host_manifest)
    assert_equal 0o640, File.stat(host_manifest).mode & 0o777
    assert_equal '{"sentinel":true}', File.read(rules)
  end

  def test_failed_first_install_removes_new_code_and_manifest
    refute run_failing_manifest_install.success?

    refute File.exist?(native_dir)
    refute File.exist?(host_manifest)
  end

  def test_failure_after_manifest_replacement_restores_previous_bytes_and_mode
    assert run_script(INSTALLER, '--extension-path', @extension).last.success?
    old_manifest = File.binread(host_manifest)
    File.chmod(0o640, host_manifest)
    script = <<~RUBY
      require #{File.join(ROOT, 'scripts', 'native_host_install').inspect}
      module TabOutNativeHostInstall
        class << self
          alias_method :original_atomic_write, :atomic_write
          def atomic_write(path, content)
            original_atomic_write(path, content)
            raise IOError, 'injected failure after manifest replacement'
          end
        end
      end
      TabOutNativeHostInstall.install(ARGV.fetch(0))
    RUBY

    refute Open3.capture3({ 'HOME' => @home }, RbConfig.ruby, '-e', script, @extension).last.success?
    assert_equal old_manifest, File.binread(host_manifest)
    assert_equal 0o640, File.stat(host_manifest).mode & 0o777
  end

  def test_failed_backup_rename_never_deletes_existing_code
    assert run_script(INSTALLER, '--extension-path', @extension).last.success?
    File.binwrite(installed_host, 'old host')
    script = <<~RUBY
      require #{File.join(ROOT, 'scripts', 'native_host_install').inspect}
      class << File
        alias_method :original_rename, :rename
        def rename(source, target)
          raise IOError, 'injected backup rename failure' if source == TabOutNativeHostInstall.native_dir
          original_rename(source, target)
        end
      end
      TabOutNativeHostInstall.install(ARGV.fetch(0))
    RUBY

    refute Open3.capture3({ 'HOME' => @home }, RbConfig.ruby, '-e', script, @extension).last.success?
    assert_equal 'old host', File.binread(installed_host)
  end

  def test_concurrent_installs_are_serialized_and_last_id_wins
    other_extension = File.join(@tmp, 'other-extension')
    FileUtils.cp_r(@extension, other_extension)
    marker = File.join(@tmp, 'first-at-manifest')
    first_script = <<~RUBY
      require #{File.join(ROOT, 'scripts', 'native_host_install').inspect}
      module TabOutNativeHostInstall
        class << self
          alias_method :original_atomic_write, :atomic_write
          def atomic_write(path, content)
            File.write(ENV.fetch('PAUSE_MARKER'), 'ready')
            sleep 1.5
            original_atomic_write(path, content)
          end
        end
      end
      TabOutNativeHostInstall.install(ARGV.fetch(0))
    RUBY
    first = Process.spawn({ 'HOME' => @home, 'PAUSE_MARKER' => marker }, RbConfig.ruby, '-e', first_script, @extension, out: File::NULL, err: File::NULL)
    second = nil
    begin
      Timeout.timeout(5) { sleep 0.02 until File.exist?(marker) }
      second = Process.spawn({ 'HOME' => @home }, RbConfig.ruby, INSTALLER, '--extension-path', other_extension, out: File::NULL, err: File::NULL)
      sleep 0.2
      assert_nil Process.waitpid(second, Process::WNOHANG), 'second install completed while first held the transaction'
      Process.waitpid(first)
      assert_equal 0, $?.exitstatus
      Process.waitpid(second)
      assert_equal 0, $?.exitstatus
      second = nil
    ensure
      [first, second].compact.each do |pid|
        Process.kill('TERM', pid) rescue nil
        Process.waitpid(pid) rescue nil
      end
    end

    expected_id = Digest::SHA256.hexdigest(File.expand_path(other_extension))[0, 32].tr('0123456789abcdef', 'abcdefghijklmnop')
    assert_equal ["chrome-extension://#{expected_id}/"], JSON.parse(File.read(host_manifest)).fetch('allowed_origins')
    assert File.executable?(installed_host)
  end

  def test_install_uses_supplied_absolute_path_for_id_even_when_symlinked
    linked = File.join(@tmp, 'linked-extension')
    File.symlink(@extension, linked)

    assert run_script(INSTALLER, '--extension-path', linked).last.success?

    expected_id = Digest::SHA256.hexdigest(linked)[0, 32].tr('0123456789abcdef', 'abcdefghijklmnop')
    assert_equal ["chrome-extension://#{expected_id}/"], JSON.parse(File.read(host_manifest)).fetch('allowed_origins')
  end

  def test_install_refuses_wrong_name_or_missing_permission_without_writing
    write_extension(name: 'Not Tab Out')
    refute run_script(INSTALLER, '--extension-path', @extension).last.success?
    refute File.exist?(host_manifest)

    write_extension(permissions: ['tabs'])
    refute run_script(INSTALLER, '--extension-path', @extension).last.success?
    refute File.exist?(host_manifest)
  end

  def test_install_does_not_run_host_or_modify_clash
    clash_dir = File.join(@home, 'Library', 'Application Support', 'io.github.clash-verge-rev.clash-verge-rev')
    FileUtils.mkdir_p(clash_dir)
    marker = File.join(clash_dir, 'clash-verge.yaml')
    File.write(marker, 'unchanged')
    sentinel = File.join(@tmp, 'host-ran')
    env = { 'TAB_OUT_HOST_RUN_MARKER' => sentinel, 'TAB_OUT_CLASH_CONFIG_DIR' => clash_dir }

    assert run_script(INSTALLER, '--extension-path', @extension, env: env).last.success?

    assert_equal 'unchanged', File.read(marker)
    refute File.exist?(sentinel)
    refute File.exist?(File.join(data_dir, 'rules.json'))
  end

  def test_uninstall_removes_registration_and_code_but_keeps_rules
    assert run_script(INSTALLER, '--extension-path', @extension).last.success?
    data = File.join(data_dir, 'rules.json')
    File.write(data, '{"sentinel":true}')

    stdout, stderr, status = run_script(UNINSTALLER)

    assert status.success?, "#{stdout}\n#{stderr}"
    refute File.exist?(host_manifest)
    refute File.exist?(native_dir)
    assert_equal '{"sentinel":true}', File.read(data)
    assert run_script(UNINSTALLER).last.success?
  end

  private

  def run_failing_manifest_install
    script = <<~RUBY
      require #{File.join(ROOT, 'scripts', 'native_host_install').inspect}
      module TabOutNativeHostInstall
        def self.atomic_write(_path, _content)
          raise IOError, 'injected manifest write failure'
        end
      end
      TabOutNativeHostInstall.install(ARGV.fetch(0))
    RUBY
    Open3.capture3({ 'HOME' => @home }, RbConfig.ruby, '-e', script, @extension).last
  end

  def write_extension(name: 'Tab Out', permissions: ['tabs', 'nativeMessaging'])
    File.write(File.join(@extension, 'manifest.json'), JSON.generate({
      'manifest_version' => 3, 'name' => name, 'permissions' => permissions
    }))
  end

  def run_script(script, *args, env: {})
    Open3.capture3({ 'HOME' => @home }.merge(env), RbConfig.ruby, script, *args)
  end

  def data_dir
    File.join(@home, 'Library', 'Application Support', 'Tab Out Proxy')
  end

  def native_dir
    File.join(data_dir, 'native')
  end

  def installed_host
    File.join(native_dir, 'bin', 'tab-out-proxy-host')
  end

  def host_manifest
    File.join(@home, 'Library', 'Application Support', 'Google', 'Chrome', 'NativeMessagingHosts', "#{HOST_NAME}.json")
  end
end
