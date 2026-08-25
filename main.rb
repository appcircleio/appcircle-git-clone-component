require 'open3'
require 'shellwords'
require 'yaml'

def env_has_key(key)
	return (ENV[key] == nil || ENV[key] == "") ? nil : ENV[key]
end

def run_command(*command)
  display_command = command.map do |argument|
    if argument.start_with?("--authToken=", "--extraParams=")
      "#{argument.split("=", 2).first}=********"
    else
      Shellwords.escape(argument)
    end
  end.join(" ")
  puts "@@[command] #{display_command}"
  status = nil
  stdout_str = nil
  stderr_str = nil
  Open3.popen3(*command) do |stdin, stdout, stderr, wait_thr|
    stdout.each_line do |line|
      puts line
    end
    stdout_str = stdout.read
    stderr_str = stderr.read
    status = wait_thr.value
  end

  unless status.success?
    raise stderr_str
  end
end

options = {}
options[:git_url] = env_has_key("AC_GIT_URL") || raise("Git url can not be null.")
if ENV["AC_GIT_CACHE_CREDENTIALS"] != "false"
  options[:git_url] = options[:git_url].sub(/:(443|80)\//, "/")
  run_command("git", "config", "--global", "credential.helper", "cache --timeout=7200")
end
temporary_path = env_has_key("AC_TEMP_DIR") || raise("Temporary path can not be null.")
options[:branch] = ENV["AC_GIT_BRANCH"]
options[:tag] = ENV["AC_GIT_TAG"]
options[:commit] = ENV["AC_GIT_COMMIT"]
options[:lfs] = ENV["AC_GIT_LFS"]
options[:submodule] = ENV["AC_GIT_SUBMODULE"]
options[:repository_path] = "#{temporary_path}/Repository"
options[:extra_params] = env_has_key("AC_GIT_EXTRA_PARAMS")
options[:auth_type] = env_has_key("AC_GIT_PROVIDER_AUTH_TYPE")
options[:auth_token] = env_has_key("AC_GIT_PROVIDER_TOKEN")
options[:fetch_depth] = env_has_key("AC_GIT_FETCH_DEPTH")
options[:fetch_jobs] = env_has_key("AC_GIT_FETCH_JOBS")

Dir.mkdir("#{options[:repository_path]}")

sh_script_path = "#{File.expand_path(File.dirname(__FILE__))}/git_clone.sh"

command = [
  "bash",
  sh_script_path,
  "--localPath=#{options[:repository_path]}",
  "--gitURL=#{options[:git_url]}"
]
command << "--extraParams=#{options[:extra_params]}" if options[:extra_params]
command << "--authType=#{options[:auth_type]}" if options[:auth_type]
command << "--authToken=#{options[:auth_token]}" if options[:auth_token]
command << "--depth=#{options[:fetch_depth]}" if options[:fetch_depth]
command << "--fetchJobs=#{options[:fetch_jobs]}" if options[:fetch_jobs]

if options[:commit]
  if options[:branch]
    command << "--commit=#{options[:commit]}"
    command << "--branch=#{options[:branch]}"
  else
    raise "Commit parameter cannot be used without branch parameter."
  end
elsif options[:branch]
  command << "--branch=#{options[:branch]}"
elsif options[:tag]
  command << "--tag=#{options[:tag]}"
else
  raise "One of Branch, tag and commit parameters must have value."
end

if options[:lfs] == 'false'
  command << "--lfs=false"
end

if options[:submodule] == 'false'
  command << "--submodule=false"
end

run_command(*command)

#Write Environment Variable
open(ENV['AC_ENV_FILE_PATH'], 'a') { |f|
  f.puts "AC_REPOSITORY_DIR=#{options[:repository_path]}"
}

exit 0
