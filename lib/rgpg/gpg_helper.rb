require 'tempfile'
require 'shellwords'

module Rgpg
  module GpgHelper
    def self.generate_key_pair(key_base_name, recipient, real_name)
      public_key_file_name = "#{key_base_name}.pub"
      private_key_file_name = "#{key_base_name}.sec"
      script = generate_key_script(public_key_file_name, private_key_file_name, recipient, real_name)
      script_file = Tempfile.new('gpg-script')
      begin
        script_file.write(script)
        script_file.close
        run_gpg_no_capture(
          '--batch',
          '--gen-key', script_file.path
        )
      ensure
        script_file.close
        script_file.unlink
      end
    end

    def self.encrypt_file(public_key_file_name, input_file_name, output_file_name)
      raise ArgumentError.new("Public key file \"#{public_key_file_name}\" does not exist") unless File.exist?(public_key_file_name)
      raise ArgumentError.new("Input file \"#{input_file_name}\" does not exist") unless File.exist?(input_file_name)

      recipient = get_recipient(public_key_file_name)
      with_temporary_encrypt_keyring(public_key_file_name) do |keyring_file_name|
        run_gpg_capture(
          '--keyring', keyring_file_name,
          '--output', output_file_name,
          '--encrypt',
          '--armor',
          '--recipient', recipient,
          '--yes',
          '--trust-model', 'always',
          input_file_name
        )
      end
    end

    def self.decrypt_file(public_key_file_name, private_key_file_name, input_file_name, output_file_name, passphrase=nil)
      raise ArgumentError.new("Public key file \"#{public_key_file_name}\" does not exist") unless File.exist?(public_key_file_name)
      raise ArgumentError.new("Private key file \"#{private_key_file_name}\" does not exist") unless File.exist?(private_key_file_name)
      raise ArgumentError.new("Input file \"#{input_file_name}\" does not exist") unless File.exist?(input_file_name)

      recipient = get_recipient(private_key_file_name)
      with_temporary_decrypt_keyrings(public_key_file_name, private_key_file_name) do |keyring_file_name, secret_keyring_file_name|
        args = '--keyring', keyring_file_name,
               '--secret-keyring', secret_keyring_file_name,
               '--output', output_file_name,
               '--decrypt',
               '--yes',
               '--trust-model', 'always',
               input_file_name
        args.unshift '--passphrase', passphrase unless passphrase.nil?
        run_gpg_capture(*args)
      end
    end

    private

    def self.with_temp_home_dir
      Dir.mktmpdir('.rgpg-tmp-', ENV['HOME']) do |home_dir|
        yield home_dir
      end
    end

    def self.build_safe_command_line(home_dir, *args)
      fragments = [
        'gpg',
        '--homedir', home_dir,
        '--no-default-keyring'
      ] + args
      fragments.collect { |fragment| Shellwords.escape(fragment) }.join(' ')
    end

    def self.run_gpg_no_capture(*args)
      with_temp_home_dir do |home_dir|
        command_line = build_safe_command_line(home_dir, *args)
        result = system(command_line)
        raise RuntimeError.new('gpg failed') unless result
      end
    end

    def self.run_gpg_capture(*args)
      with_temp_home_dir do |home_dir|
        command_line = build_safe_command_line(home_dir, *args)

        output_file = Tempfile.new('gpg-output')
        begin
          output_file.close
          result = system("#{command_line} > #{Shellwords.escape(output_file.path)} 2>&1")

          output = nil
          File.open(output_file.path) do |f|
            output = f.read
          end
          raise RuntimeError.new("gpg failed: #{output}") unless result

          output.lines.collect(&:chomp)
        ensure
          output_file.unlink
        end
      end
    end

    def self.generate_key_script(public_key_file_name, private_key_file_name, recipient, real_name)
      <<-EOS
  %echo Generating a standard key
  Key-Type: DSA
  Key-Length: 1024
  Subkey-Type: ELG-E
  Subkey-Length: 1024
  Name-Real: #{real_name}
  Name-Comment: Key automatically generated by rgpg
  Name-Email: #{recipient}
  Expire-Date: 0
  %pubring #{public_key_file_name}
  %secring #{private_key_file_name}
  # Do a commit here, so that we can later print "done" :-)
  %commit
  %echo done
      EOS
    end

    def self.get_recipient(key_file_name)
      lines = run_gpg_capture(key_file_name)
      result = lines.detect { |line| line =~ /^(pub|sec)\s+\d+(D|R)\/([0-9a-fA-F]{8}).+<(.+)>/ }
      raise RuntimeError.new('Invalid output') unless result
      key_id = $2
      recipient = $3
    end

    def self.with_temporary_encrypt_keyring(public_key_file_name)
      with_temporary_keyring_file do |keyring_file_name|
        run_gpg_capture(
          '--keyring', keyring_file_name,
          '--import', public_key_file_name
        )
        yield keyring_file_name
      end
    end

    def self.with_temporary_decrypt_keyrings(public_key_file_name, private_key_file_name)
      with_temporary_keyring_file do |keyring_file_name|
        with_temporary_keyring_file do |secret_keyring_file_name|
          run_gpg_capture(
            '--keyring', keyring_file_name,
            '--secret-keyring', secret_keyring_file_name,
            '--import', private_key_file_name
          )
          yield keyring_file_name, secret_keyring_file_name
        end
      end
    end

    def self.with_temporary_keyring_file
      keyring_file = Tempfile.new('gpg-key-ring')
      begin
        keyring_file_name = keyring_file.path
        keyring_file.close
        keyring_file.unlink
        yield keyring_file_name
      ensure
        File.unlink(keyring_file_name) if File.exist?(keyring_file_name)
        backup_keyring_file_name = "#{keyring_file_name}~"
        File.unlink(backup_keyring_file_name) if File.exist?(backup_keyring_file_name)
      end
    end
  end
end

