#!/usr/bin/env ruby

require 'rubygems'
require 'fileutils'
require 'warbler'

class CiBuild
  attr_accessor :app_name, :workspace_path, :jenkins_home, :run_specs_flag, :compile_assets_flag

  def initialize(args={})
    @app_name = args.fetch(:app_name)
    @workspace_path = args.fetch(:workspace_path)
    @jenkins_home = args.fetch(:jenkins_home)

    @run_specs_flag = args.fetch(:run_specs_flag, true)
    @compile_assets_flag = args.fetch(:compile_assets_flag, true)
  end

  def run
    Dir.chdir(workspace_path) do
      clean_workspace
      run_bundle_install
      setup_dot_yml_files

      if run_specs_flag
        setup_db
        run_rspec_suite
      end

      compile_assets if compile_assets_flag
      archive_war_file
    end
  end


  private

  def clean_workspace
    FileUtils.rm_rf("#{workspace_path}/.rvmrc") if File.exists?("#{workspace_path}/.rvmrc")
  end

  def job_name
    workspace_path =~ /jobs\/(.+)\/workspace$/
    $1
  end

  def war_archive_url
    "#{war_archive_root}/#{app_name}/"
  end

  def war_archive_root
    "svn+ssh://svn@code.berkeley.edu/eas-rails/wars"
  end

  def war_name
    if git_repo?
      git_war_name
    elsif svn_repo?
      svn_war_name
    else
      raise "Unrecognized SCM"
    end
  end

  def git_repo?
    Dir["#{workspace_path}/.*"].any? { |f| File.basename(f) == ".git" }
  end

  def svn_repo?
    Dir["#{workspace_path}/.*"].any? { |f| File.basename(f) == ".svn" }
  end

  def svn_war_name
    ENV['SVN_URL'].split("/").pop
  end

  def git_war_name
    branch = ENV['GIT_BRANCH']
    (branch == "master") ? "trunk" : branch
  end

  def default_env_vars
    ["WEBKIT=false", "QMAKE=/usr/bin/qmake-qt47"]
  end

  def run_cmd(cmd, env_vars = [])
    # TODO: Enable after qt47 is installed
    # env = (default_env_vars + env_vars).join(" ")

    env = env_vars.join(" ")
    full_cmd = "#{env} #{cmd}"
    $stdout.puts("#{full_cmd} ... ")

    output = `#{full_cmd} 2>&1`
    $stdout.puts(output)

    if $?.success?
      $stdout.puts("[OK]")
    else
      $stdout.puts("[FAILED]")
      $stdout.puts($?.exitstatus)
      exit($?.exitstatus)
    end

    output
  end

  def run_bundle_install
    run_cmd("bundle install")
  end

  def setup_dot_yml_files
    create_db_yml
    Dir.glob("config/*.yml.example").each do |file_path|
      file_name = File.basename(file_path).split(".")[0..1].join(".")
      next if file_name == "database.yml"
      dir_name = File.dirname(file_path)
      FileUtils.cp(file_path, File.join(dir_name, file_name))
    end
  end

  def setup_db
    run_cmd("bundle exec rake db:migrate", ["RAILS_ENV=test"])
  end

  def create_db_yml
    db_yml_contents = <<-DB
test: &test
   adapter: sqlite3
   database: #{app_name}
   username: jenkins
   password: jenkins
   host: localhost

ci:
   <<: *test
    DB
    File.open("config/database.yml", "w") do |f|
      f.write(db_yml_contents)
    end
  end

  def run_rspec_suite
    run_cmd("bundle exec rspec spec --tag ~js --format RspecJunitFormatter --out results.xml", ["RAILS_ENV=test"])
  end

  def compile_assets
    cache_compiled_assets
    run_cmd("bundle exec rake assets:precompile", ["RAILS_ENV=ci"])
  end

  def cache_compiled_assets
    link = "#{jenkins_home}/.jenkins/jobs/#{job_name}/workspace/tmp"
    target = "#{jenkins_home}/tmp/#{job_name}"

    FileUtils.mkdir(target) unless File.exists?(target)
    FileUtils.rm_rf(link) if File.exists?(link)
    File.symlink(target, link) unless File.symlink?(link)
  end

  def archive_war_file
    create_war
    remove_war if war_checked_in?
    commit_war
  end

  def create_war
    RakeFileUtils.verbose_flag = true
    Warbler::Task.new('trunk')

    $stdout.print("Building war file: ")
    Rake::Task['trunk'].invoke()

    FileUtils.mv("workspace.war", "#{war_name}.war")
  end

  def war_checked_in?
    wars = run_cmd("svn list #{war_archive_url}").split("\n")
    wars.include?("#{war_name}.war")
  end

  def remove_war
    run_cmd("svn rm #{war_archive_url}/#{war_name}.war -m 'removing war #{war_name}.war' &")
    run_cmd("sleep 2s")
  end

  def commit_war
    run_cmd("svn import #{war_name}.war #{war_archive_url}/#{war_name}.war -m 'committing war #{war_name}.war'")
  end
end


if __FILE__ == $PROGRAM_NAME
  def extract_optional_args(optional_args)
    optional_args.inject({}) do |hash, arg|
      key, val = arg.split("=")
      val = (val == "false") ? false : true
      key = key[2..-1].gsub("-", "_").to_sym
      hash[key] = val
      hash
    end
  end

  args = {
      :app_name => ARGV[0],
      :workspace_path => ENV['WORKSPACE'],
      :jenkins_home => ENV['HOME'],
  }

  optional_args = extract_optional_args(ARGV[1..-1])


  CiBuild.new(args.merge(optional_args)).run
end
