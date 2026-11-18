# frozen_string_literal: true

# ─── Coverage (must start before loading main.rb) ─────────────────────────────
require 'coverage'
Coverage.start unless Coverage.running?

# ─── Dependencies ─────────────────────────────────────────────────────────────
require 'rspec'
require 'rspec/core/formatters/base_formatter'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'stringio'
require 'json'
require 'rbconfig'

MAIN_RB      = File.expand_path('../main.rb', __dir__)
PROJECT_ROOT = File.dirname(MAIN_RB)
GIT_CLONE_SH = File.join(PROJECT_ROOT, 'git_clone.sh')

require MAIN_RB

# Temporary directory for test support files (coverage hook, subprocess coverage).
SUPPORT_DIR = Dir.mktmpdir('git_clone_test')

# Subprocess runs of main.rb load this hook (via `-r coverage_hook`) and dump
# their line coverage of main.rb so it can be merged into the final report.
SUBPROCESS_COVERAGE_DIR = File.join(SUPPORT_DIR, 'coverage')
FileUtils.mkdir_p(SUBPROCESS_COVERAGE_DIR)
File.write(File.join(SUPPORT_DIR, 'coverage_hook.rb'), <<~RUBY)
  require 'coverage'
  require 'json'
  Coverage.start
  at_exit do
    target = ENV['AC_TEST_COVERAGE_TARGET']
    result = Coverage.result
    lines  = result[target] || result[File.realpath(target)] rescue nil
    if lines
      File.write(File.join(ENV['AC_TEST_COVERAGE_DIR'], "\#{Process.pid}-\#{rand(1_000_000)}.json"), JSON.dump(lines))
    end
  end
RUBY

# ─── Custom Formatter ─────────────────────────────────────────────────────────
class ReadableFormatter < RSpec::Core::Formatters::BaseFormatter
  RSpec::Core::Formatters.register(
    self,
    :example_group_started,
    :example_group_finished,
    :example_passed,
    :example_failed,
    :example_pending,
    :dump_summary
  )

  PASS  = "\e[32;1m[ PASS ]\e[0m"
  FAIL  = "\e[31;1m[ FAIL ]\e[0m"
  ERROR = "\e[31;1m[ERROR ]\e[0m"
  SKIP  = "\e[33;1m[ SKIP ]\e[0m"

  DIVIDER     = "\e[90m#{'─' * 72}\e[0m"
  DIVIDER_FAT = "\e[90m#{'═' * 72}\e[0m"

  def initialize(output)
    super
    @depth    = 0
    @failures = []
    @counts   = { passed: 0, failed: 0, pending: 0 }
  end

  # Top-level describe groups cycle through distinct colors
  GROUP_COLORS = [
    "\e[34;1m",  # bold blue
    "\e[35;1m",  # bold magenta
    "\e[36;1m",  # bold cyan
    "\e[33;1m",  # bold yellow
  ].freeze

  def example_group_started(notification)
    group = notification.group
    if group.parent_groups.size <= 1
      output.puts if @depth.zero?
      color = GROUP_COLORS[@depth % GROUP_COLORS.size]
      output.puts "  #{color}#{group.description}\e[0m"
    else
      output.puts "    #{'  ' * (@depth - 1)}\e[90m▸ \e[0m\e[37m#{group.description}\e[0m"
    end
    @depth += 1
  end

  def example_group_finished(_notification)
    @depth -= 1 if @depth > 0
  end

  def example_passed(notification)
    @counts[:passed] += 1
    print_example(PASS, notification.example)
  end

  def example_failed(notification)
    @counts[:failed] += 1
    ex    = notification.example
    exc   = ex.execution_result.exception
    badge = exc.is_a?(RSpec::Expectations::ExpectationNotMetError) ? FAIL : ERROR
    print_example(badge, ex)
    @failures << notification
  end

  def example_pending(notification)
    @counts[:pending] += 1
    ex = notification.example
    output.puts "    #{'  ' * [0, @depth - 1].max}#{SKIP}  #{ex.description}"
  end

  def dump_summary(notification)
    output.puts
    output.puts DIVIDER_FAT

    unless @failures.empty?
      output.puts "\n  \e[1;31mFailures:\e[0m\n"
      @failures.each_with_index do |n, i|
        ex  = n.example
        exc = ex.execution_result.exception
        output.puts "  \e[1m#{i + 1}) #{ex.full_description}\e[0m"
        exc.message.lines.first(6).each do |line|
          output.puts "     \e[31m#{line.rstrip}\e[0m"
        end
        output.puts "     \e[90m# #{ex.location}\e[0m"
        output.puts
      end
      output.puts DIVIDER
    end

    t   = notification.examples.size
    p   = @counts[:passed]
    f   = @counts[:failed]
    s   = @counts[:pending]
    sec = format('%.3fs', notification.duration)

    parts = ["\e[32m#{p} passed\e[0m"]
    parts << "\e[31m#{f} failed\e[0m"  if f > 0
    parts << "\e[33m#{s} pending\e[0m" if s > 0

    overall = f.zero? ? "\e[32;1m✔  All #{t} tests passed\e[0m" : "\e[31;1m✖  #{f} of #{t} tests failed\e[0m"
    output.puts "\n  #{overall}"
    output.puts "  #{parts.join('  |  ')}  \e[90m(#{sec})\e[0m"
    output.puts DIVIDER_FAT
  end

  private

  def print_example(badge, example)
    indent = '  ' * [0, @depth - 1].max
    time   = format('%.3fs', example.execution_result.run_time)
    output.puts "    #{indent}#{badge}  #{example.description}  \e[90m(#{time})\e[0m"
  end
end


# ─── Helpers ──────────────────────────────────────────────────────────────────

# Every ENV key main.rb reads. In-process tests reset them around each example
# and subprocess tests unset them, so the ambient shell can never leak in.
MAIN_ENV_KEYS = %w[
  AC_GIT_URL
  AC_GIT_CACHE_CREDENTIALS
  AC_TEMP_DIR
  AC_GIT_BRANCH
  AC_GIT_TAG
  AC_GIT_COMMIT
  AC_GIT_LFS
  AC_GIT_SUBMODULE
  AC_GIT_EXTRA_PARAMS
  AC_GIT_PROVIDER_AUTH_TYPE
  AC_GIT_PROVIDER_TOKEN
  AC_GIT_FETCH_DEPTH
  AC_GIT_FETCH_JOBS
  AC_ENV_FILE_PATH
].freeze

def with_env(vars)
  previous = vars.keys.to_h { |k| [k, [ENV.key?(k), ENV[k]]] }
  vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  yield
ensure
  previous.each { |k, (had_key, old)| had_key ? ENV[k] = old : ENV.delete(k) }
end

def write_executable(path, content)
  File.write(path, content)
  File.chmod(0o755, path)
end

# Fake `bash` and `git` for subprocess tests. main.rb invokes `bash git_clone.sh ...`
# and `git config --global ...` through PATH, so these stand-ins log every argument
# (one per line, invocations separated by "--") and never clone, fetch or touch the
# real global git config. `bash` exits with FAKE_BASH_EXIT and prints FAKE_BASH_STDERR.
def build_fake_toolchain(base)
  bin = File.join(base, 'bin')
  FileUtils.mkdir_p(bin)
  logs = { bash: File.join(base, 'bash.log'), git: File.join(base, 'git.log') }
  logs.each do |tool, log|
    write_executable(File.join(bin, tool.to_s), <<~SH)
      #!/bin/sh
      for arg; do printf '%s\\n' "$arg" >> "#{log}"; done
      echo -- >> "#{log}"
      #{tool == :bash ? 'echo "fake bash ran"; [ -n "$FAKE_BASH_STDERR" ] && echo "$FAKE_BASH_STDERR" >&2; exit "${FAKE_BASH_EXIT:-0}"' : 'exit 0'}
    SH
  end
  { bin: bin, logs: logs }
end

# Arguments of each logged invocation, e.g. [["config", "--global", ...], ...].
def invocations(log)
  return [] unless File.exist?(log)

  File.read(log).split("--\n").map(&:lines).map { |l| l.map(&:chomp) }
end

# Run main.rb in a subprocess with a clean environment and the fake toolchain on PATH.
def run_main(env, fake_bin:, home:)
  clean_env = MAIN_ENV_KEYS.to_h { |k| [k, nil] }.merge(
    'RUBYLIB'                 => SUPPORT_DIR,
    'AC_TEST_COVERAGE_TARGET' => MAIN_RB,
    'AC_TEST_COVERAGE_DIR'    => SUBPROCESS_COVERAGE_DIR,
    'HOME'                    => home,
    'PATH'                    => "#{fake_bin}#{File::PATH_SEPARATOR}#{ENV['PATH']}"
  )
  Open3.capture3(clean_env.merge(env), RbConfig.ruby, '-r', 'coverage_hook', MAIN_RB)
end

FakeStream = Struct.new(:lines, :rest) do
  def each_line(&block) = lines.each(&block)
  def read = rest
end

# Stubs Open3.popen3 so run_command never spawns a process. Captures the argv.
def stub_popen3(context, stdout_lines: [], stderr: '', success: true)
  captured = []
  status = context.instance_double(Process::Status, success?: success)
  context.allow(Open3).to context.receive(:popen3) do |*argv, &block|
    captured << argv
    block.call(nil, FakeStream.new(stdout_lines, ''), FakeStream.new([], stderr), Struct.new(:value).new(status))
  end
  captured
end

RSpec.configure do |config|
  # Restore ENV and keep the functions' stdout out of the report.
  config.around do |example|
    saved_env = MAIN_ENV_KEYS.to_h { |k| [k, ENV[k]] }
    MAIN_ENV_KEYS.each { |k| ENV.delete(k) }
    original_stdout = $stdout
    $stdout = StringIO.new
    begin
      example.run
    ensure
      $stdout = original_stdout
      saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end
  end
end

# ─── Tests ────────────────────────────────────────────────────────────────────

RSpec.describe 'main.rb loading' do
  it 'can be required without running the script body' do
    Dir.mktmpdir do |dir|
      out, err, status = Open3.capture3({ 'AC_TEMP_DIR' => dir }, RbConfig.ruby, '-e', "require #{MAIN_RB.dump}; puts 'loaded'")
      expect(status.exitstatus).to eq(0), "stderr: #{err}"
      expect(out).to eq("loaded\n")
      expect(Dir.children(dir)).to be_empty
    end
  end

  it 'defines env_has_key and run_command' do
    expect(respond_to?(:env_has_key, true)).to be(true)
    expect(respond_to?(:run_command, true)).to be(true)
  end
end

RSpec.describe '#env_has_key' do
  it 'returns the value when the variable is set' do
    with_env('AC_GIT_BRANCH' => 'main') { expect(env_has_key('AC_GIT_BRANCH')).to eq('main') }
  end

  it 'returns the value unchanged, including surrounding whitespace' do
    with_env('AC_GIT_BRANCH' => ' main ') { expect(env_has_key('AC_GIT_BRANCH')).to eq(' main ') }
  end

  it 'returns nil when the variable is missing' do
    with_env('AC_GIT_BRANCH' => nil) { expect(env_has_key('AC_GIT_BRANCH')).to be_nil }
  end

  it 'returns nil when the variable is empty' do
    with_env('AC_GIT_BRANCH' => '') { expect(env_has_key('AC_GIT_BRANCH')).to be_nil }
  end

  it 'raises with context for a nil key' do
    expect { env_has_key(nil) }.to raise_error(RuntimeError, 'Environment variable key can not be nil.')
  end
end

RSpec.describe '#run_command' do
  it 'passes the arguments to Open3.popen3 unchanged and prints the escaped command' do
    captured = stub_popen3(self, stdout_lines: ["line one\n", "line two\n"])
    expect { run_command('git', 'config', '--global', 'credential.helper', 'cache --timeout=7200') }
      .to output("@@[command] git config --global credential.helper cache\\ --timeout\\=7200\nline one\nline two\n").to_stdout
    expect(captured).to eq([['git', 'config', '--global', 'credential.helper', 'cache --timeout=7200']])
  end

  it 'masks --authToken and --extraParams values in the printed command only' do
    captured = stub_popen3(self)
    argv = ['bash', '/s/git_clone.sh', '--authToken=s3cr3t', '--extraParams=-c http.extraheader=x', '--branch=main']
    expect { run_command(*argv) }
      .to output("@@[command] bash /s/git_clone.sh --authToken=******** --extraParams=******** --branch\\=main\n").to_stdout
    expect(captured).to eq([argv])
  end

  it 'prints an empty argument as quotes' do
    captured = stub_popen3(self)
    expect { run_command('echo', '') }.to output("@@[command] echo ''\n").to_stdout
    expect(captured).to eq([['echo', '']])
  end

  it 'raises the command stderr when the command fails' do
    stub_popen3(self, stderr: "fatal: repository not found\n", success: false)
    expect { run_command('bash', 'git_clone.sh') }.to raise_error(RuntimeError, "fatal: repository not found\n")
  end

  it 'raises with context and spawns nothing when an argument is nil' do
    captured = stub_popen3(self)
    expect { run_command('git', nil) }.to raise_error(RuntimeError, 'Command argument at index 1 can not be nil.')
    expect(captured).to be_empty
  end

  it 'raises when called without any command' do
    expect { run_command }.to raise_error(StandardError)
  end
end

RSpec.describe 'main.rb script' do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir       = dir
      @tools     = build_fake_toolchain(dir)
      @temp      = File.join(dir, 'temp')
      @home      = File.join(dir, 'home')
      @env_file  = File.join(dir, 'env')
      @repo_path = File.join(@temp, 'Repository')
      FileUtils.mkdir_p([@temp, @home])
      example.run
    end
  end

  let(:base_env) do
    { 'AC_GIT_URL' => 'https://example.com/org/repo.git', 'AC_TEMP_DIR' => @temp,
      'AC_GIT_BRANCH' => 'main', 'AC_ENV_FILE_PATH' => @env_file }
  end

  def run(overrides = {})
    run_main(base_env.merge(overrides), fake_bin: @tools[:bin], home: @home)
  end

  def bash_args = invocations(@tools[:logs][:bash])
  def git_args  = invocations(@tools[:logs][:git])

  def expect_success(result)
    out, err, status = result
    expect(status.exitstatus).to eq(0), "stdout: #{out}\nstderr: #{err}"
    result
  end

  def expect_failure(result, message)
    out, err, status = result
    expect(status.exitstatus).not_to eq(0), "stdout: #{out}\nstderr: #{err}"
    expect(err).to include(message)
  end

  describe 'happy path' do
    it 'calls git_clone.sh with the composed arguments and writes AC_REPOSITORY_DIR' do
      out, = expect_success(run)
      expect(bash_args).to eq([[GIT_CLONE_SH, "--localPath=#{@repo_path}", '--gitURL=https://example.com/org/repo.git', '--branch=main']])
      expect(out).to include('fake bash ran')
      expect(Dir.exist?(@repo_path)).to be(true)
      expect(File.read(@env_file)).to eq("AC_REPOSITORY_DIR=#{@repo_path}\n")
    end

    it 'appends to an existing env file' do
      File.write(@env_file, "EXISTING=1\n")
      expect_success(run)
      expect(File.read(@env_file)).to eq("EXISTING=1\nAC_REPOSITORY_DIR=#{@repo_path}\n")
    end

    it 'forwards the optional parameters and masks the token in the output' do
      out, = expect_success(run('AC_GIT_EXTRA_PARAMS' => '-c http.sslVerify=false', 'AC_GIT_PROVIDER_AUTH_TYPE' => 'oauth',
                                'AC_GIT_PROVIDER_TOKEN' => 's3cr3t-token', 'AC_GIT_FETCH_DEPTH' => '5', 'AC_GIT_FETCH_JOBS' => '4'))
      expect(bash_args.first).to eq([GIT_CLONE_SH, "--localPath=#{@repo_path}", '--gitURL=https://example.com/org/repo.git',
                                     '--extraParams=-c http.sslVerify=false', '--authType=oauth', '--authToken=s3cr3t-token',
                                     '--depth=5', '--fetchJobs=4', '--branch=main'])
      expect(out).to include('--authToken=******** ', '--extraParams=******** ')
      expect(out).not_to include('s3cr3t-token')
    end

    it 'leaves empty optional parameters out' do
      expect_success(run('AC_GIT_EXTRA_PARAMS' => '', 'AC_GIT_PROVIDER_AUTH_TYPE' => '', 'AC_GIT_PROVIDER_TOKEN' => '',
                         'AC_GIT_FETCH_DEPTH' => '', 'AC_GIT_FETCH_JOBS' => ''))
      expect(bash_args.first).to eq([GIT_CLONE_SH, "--localPath=#{@repo_path}", '--gitURL=https://example.com/org/repo.git', '--branch=main'])
    end
  end

  describe 'AC_GIT_URL' do
    it 'exits non-zero when missing' do
      expect_failure(run('AC_GIT_URL' => nil), 'Git url can not be null.')
      expect(bash_args).to be_empty
    end

    it 'exits non-zero when empty' do
      expect_failure(run('AC_GIT_URL' => ''), 'Git url can not be null.')
      expect(bash_args).to be_empty
    end
  end

  describe 'AC_TEMP_DIR' do
    it 'exits non-zero when missing' do
      expect_failure(run('AC_TEMP_DIR' => nil), 'Temporary path can not be null.')
      expect(bash_args).to be_empty
    end

    it 'exits non-zero when empty' do
      expect_failure(run('AC_TEMP_DIR' => ''), 'Temporary path can not be null.')
      expect(bash_args).to be_empty
    end
  end

  describe 'AC_GIT_CACHE_CREDENTIALS' do
    let(:cache_config) { ['config', '--global', 'credential.helper', 'cache --timeout=7200'] }
    let(:port_url) { 'https://example.com:443/org/repo.git' }

    it 'caches credentials and strips the :443 port when missing' do
      expect_success(run('AC_GIT_URL' => port_url, 'AC_GIT_CACHE_CREDENTIALS' => nil))
      expect(git_args).to eq([cache_config])
      expect(bash_args.first).to include('--gitURL=https://example.com/org/repo.git')
    end

    it 'caches credentials and strips the :80 port when empty' do
      expect_success(run('AC_GIT_URL' => 'http://example.com:80/org/repo.git', 'AC_GIT_CACHE_CREDENTIALS' => ''))
      expect(git_args).to eq([cache_config])
      expect(bash_args.first).to include('--gitURL=http://example.com/org/repo.git')
    end

    it 'caches credentials when "true"' do
      expect_success(run('AC_GIT_CACHE_CREDENTIALS' => 'true'))
      expect(git_args).to eq([cache_config])
    end

    it 'keeps other ports' do
      expect_success(run('AC_GIT_URL' => 'https://example.com:8443/org/repo.git'))
      expect(bash_args.first).to include('--gitURL=https://example.com:8443/org/repo.git')
    end

    it 'skips caching and keeps the URL unchanged when "false"' do
      expect_success(run('AC_GIT_URL' => port_url, 'AC_GIT_CACHE_CREDENTIALS' => 'false'))
      expect(git_args).to be_empty
      expect(bash_args.first).to include("--gitURL=#{port_url}")
    end

    it 'exits non-zero when the git config command fails' do
      write_executable(File.join(@tools[:bin], 'git'), "#!/bin/sh\necho 'config locked' >&2\nexit 1\n")
      expect_failure(run, 'config locked')
      expect(bash_args).to be_empty
    end
  end

  describe 'AC_GIT_BRANCH / AC_GIT_TAG / AC_GIT_COMMIT' do
    it 'exits non-zero when all three are missing' do
      expect_failure(run('AC_GIT_BRANCH' => nil), 'One of Branch, tag and commit parameters must have value.')
      expect(bash_args).to be_empty
    end

    it 'uses the tag when the branch is missing' do
      expect_success(run('AC_GIT_BRANCH' => nil, 'AC_GIT_TAG' => 'v1.0'))
      expect(bash_args.first.last).to eq('--tag=v1.0')
    end

    it 'prefers the branch over the tag' do
      expect_success(run('AC_GIT_TAG' => 'v1.0'))
      expect(bash_args.first).to include('--branch=main')
      expect(bash_args.first).not_to include('--tag=v1.0')
    end

    it 'passes commit and branch together' do
      expect_success(run('AC_GIT_COMMIT' => 'abc123'))
      expect(bash_args.first.last(2)).to eq(['--commit=abc123', '--branch=main'])
    end

    it 'exits non-zero when the commit is given without a branch' do
      expect_failure(run('AC_GIT_BRANCH' => nil, 'AC_GIT_COMMIT' => 'abc123'),
                     'Commit parameter cannot be used without branch parameter.')
      expect(bash_args).to be_empty
    end

    # main.rb reads these three with ENV[] (not env_has_key), so an empty string
    # counts as "set". These tests pin the current behavior; git_clone.sh then
    # treats the empty value as not given.
    it 'passes an empty branch through as --branch=' do
      expect_success(run('AC_GIT_BRANCH' => ''))
      expect(bash_args.first.last).to eq('--branch=')
    end

    it 'passes an empty tag through as --tag=' do
      expect_success(run('AC_GIT_BRANCH' => nil, 'AC_GIT_TAG' => ''))
      expect(bash_args.first.last).to eq('--tag=')
    end

    it 'passes an empty commit through as --commit=' do
      expect_success(run('AC_GIT_COMMIT' => ''))
      expect(bash_args.first.last(2)).to eq(['--commit=', '--branch=main'])
    end
  end

  describe 'AC_GIT_LFS' do
    it 'adds no flag when missing' do
      expect_success(run('AC_GIT_LFS' => nil))
      expect(bash_args.first.grep(/--lfs/)).to be_empty
    end

    it 'adds no flag when empty' do
      expect_success(run('AC_GIT_LFS' => ''))
      expect(bash_args.first.grep(/--lfs/)).to be_empty
    end

    it 'adds no flag when "true"' do
      expect_success(run('AC_GIT_LFS' => 'true'))
      expect(bash_args.first.grep(/--lfs/)).to be_empty
    end

    it 'adds --lfs=false when "false"' do
      expect_success(run('AC_GIT_LFS' => 'false'))
      expect(bash_args.first.last).to eq('--lfs=false')
    end
  end

  describe 'AC_GIT_SUBMODULE' do
    it 'adds no flag when missing' do
      expect_success(run('AC_GIT_SUBMODULE' => nil))
      expect(bash_args.first.grep(/--submodule/)).to be_empty
    end

    it 'adds no flag when empty' do
      expect_success(run('AC_GIT_SUBMODULE' => ''))
      expect(bash_args.first.grep(/--submodule/)).to be_empty
    end

    it 'adds --submodule=false when "false"' do
      expect_success(run('AC_GIT_SUBMODULE' => 'false', 'AC_GIT_LFS' => 'false'))
      expect(bash_args.first.last(2)).to eq(['--lfs=false', '--submodule=false'])
    end
  end

  describe 'AC_ENV_FILE_PATH' do
    it 'exits non-zero after cloning when missing' do
      expect_failure(run('AC_ENV_FILE_PATH' => nil), 'Environment file path can not be null.')
      expect(bash_args.size).to eq(1)
    end

    it 'exits non-zero after cloning when empty' do
      expect_failure(run('AC_ENV_FILE_PATH' => ''), 'Environment file path can not be null.')
      expect(bash_args.size).to eq(1)
    end
  end

  describe 'failures' do
    it 'exits non-zero with the clone script stderr and writes no env file when git_clone.sh fails' do
      expect_failure(run('FAKE_BASH_EXIT' => '1', 'FAKE_BASH_STDERR' => 'fatal: could not read Username'),
                     'fatal: could not read Username')
      expect(File.exist?(@env_file)).to be(false)
    end

    it 'exits non-zero when the Repository directory already exists' do
      FileUtils.mkdir_p(@repo_path)
      expect_failure(run, 'File exists')
      expect(bash_args).to be_empty
    end
  end
end

# ─── Coverage Report ──────────────────────────────────────────────────────────
def print_coverage_report
  result = Coverage.result
  lines  = result[MAIN_RB] || result[File.realpath(MAIN_RB)]
  return puts("\n  Coverage: main.rb was not tracked") if lines.nil?

  in_process = lines.compact.count(&:positive?)
  merged     = lines.dup
  runs       = 0
  Dir.glob(File.join(SUBPROCESS_COVERAGE_DIR, '*.json')).each do |file|
    sub = JSON.parse(File.read(file))
    next unless sub.is_a?(Array) && sub.size == merged.size

    runs += 1
    sub.each_with_index do |hits, i|
      next if hits.nil? || merged[i].nil?

      merged[i] += hits
    end
  end

  executable = merged.compact
  covered    = executable.count(&:positive?)
  total      = executable.size
  pct        = total.zero? ? 100.0 : (covered * 100.0 / total).round(1)
  color      = pct == 100 ? "\e[32;1m" : pct >= 80 ? "\e[33m" : "\e[31m"
  filled     = (pct / 5).round
  bar        = "\e[32m" + '█' * filled + "\e[90m" + '░' * (20 - filled) + "\e[0m"

  puts "\n\e[90m#{'═' * 72}\e[0m"
  puts '  Coverage Report'
  puts "\e[90m#{'─' * 72}\e[0m"
  puts "  main.rb  #{bar}  #{color}#{pct}%\e[0m  (#{covered}/#{total} lines)"
  puts "  \e[90m#{in_process} lines by in-process tests, #{runs} subprocess runs merged in\e[0m"
  missed = merged.each_with_index.select { |hits, _| hits&.zero? }.map { |_, i| i + 1 }
  unless missed.empty?
    ranges = missed.slice_when { |a, b| b != a + 1 }.map { |r| r.size == 1 ? r.first.to_s : "#{r.first}-#{r.last}" }
    puts "  Uncovered lines: \e[90m#{ranges.join(', ')}\e[0m"
  end
  puts "\e[90m#{'═' * 72}\e[0m"
rescue StandardError => e
  puts "\n  Coverage: unavailable (#{e.class}: #{e.message})"
end

# ─── Runner ───────────────────────────────────────────────────────────────────
if __FILE__ == $PROGRAM_NAME
  RSpec.configure do |config|
    config.add_formatter ReadableFormatter
    config.color = true
    config.order = :defined
  end

  exit_code = RSpec::Core::Runner.run(['--order', 'defined'])
  print_coverage_report
  FileUtils.rm_rf(SUPPORT_DIR)
  exit exit_code
end
